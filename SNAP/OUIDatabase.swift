// OUIDatabase.swift
// SNAP — OUI vendor lookup (curated role-hinted map + full IEEE registry)
// Created by Sevag Bardakjian
// Copyright © 2025 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
//
// Layered lookup:
//
//   1. A hand-curated map of ~300 OUIs we care about (Apple, Sonos, Roku,
//      Ubiquiti, …). Entries carry a DeviceRole hint so we can shortcut
//      role inference for known consumer brands.
//
//   2. The full IEEE MA-L OUI registry (~39k entries) bundled at
//      `oui_registry.txt`. Loaded lazily on first miss. Provides vendor
//      strings only.
//
//   3. A vendor-pattern role inference layer (v1.3) that maps registry
//      vendor strings to enterprise DeviceRoles ("Palo Alto Networks" →
//      .firewall, "Arista Networks" → .networkSwitch, etc.). Used when the
//      MAC isn't in the curated map.

import Foundation

enum OUIDatabase {

    /// Returns the vendor name for a MAC's OUI prefix, or nil if unknown.
    /// Curated map wins; falls back to the bundled IEEE registry.
    static func lookup(_ mac: String) -> String? {
        guard let key = normalize(mac) else { return nil }
        if let v = curatedMap[key]?.vendor { return v }
        return loadRegistry()[key]
    }

    /// Returns vendor + the device role this OUI commonly represents.
    /// Curated entries return their explicit role. Registry-only hits run
    /// vendor-pattern inference (enterprise vendors → switch/firewall/etc.).
    static func roleHint(_ mac: String) -> (vendor: String, role: DeviceRole)? {
        guard let key = normalize(mac) else { return nil }
        if let e = curatedMap[key] { return (e.vendor, e.role) }
        if let v = loadRegistry()[key] {
            return (v, roleFromVendorString(v))
        }
        return nil
    }

    /// Optional eager warm-up. The app can call this at startup to push the
    /// 1 MB registry parse off the first user-visible lookup.
    static func preload() {
        DispatchQueue.global(qos: .utility).async { _ = loadRegistry() }
    }

    // MARK: - Normalization

    private static func normalize(_ mac: String) -> String? {
        let cleaned = mac.replacingOccurrences(of: ":", with: "")
                         .replacingOccurrences(of: "-", with: "")
                         .replacingOccurrences(of: ".", with: "")
                         .uppercased()
        guard cleaned.count >= 6 else { return nil }
        return String(cleaned.prefix(6))
    }

    // MARK: - Vendor-pattern role inference (registry-only hits)

    /// Maps a vendor string from the IEEE registry to a DeviceRole when
    /// the vendor unambiguously implies a role (firewall vendor, switch
    /// vendor, etc.). Returns `.unknown` when the vendor sells across
    /// categories or we have no signal.
    ///
    /// Matched case-insensitively against substrings of the vendor name.
    static func roleFromVendorString(_ vendor: String) -> DeviceRole {
        let v = vendor.lowercased()

        // Firewall / next-gen firewall vendors
        for k in ["palo alto", "fortinet", "fortigate", "sonicwall",
                  "watchguard", "barracuda", "check point", "checkpoint",
                  "sophos", "pfsense", "netgate", "stormshield", "forcepoint"] {
            if v.contains(k) { return .firewall }
        }

        // Load balancer / ADC vendors
        for k in ["f5 networks", "a10 networks",
                  "citrix systems", "kemp technologies", "array networks",
                  "radware"] {
            if v.contains(k) { return .loadBalancer }
        }

        // Wireless-LAN-controller-heavy vendors (APs more often than not).
        // Aruba/Ruckus/Aerohive/Meraki/Mist OUIs almost always ship APs.
        for k in ["aruba", "ruckus", "aerohive", "meraki", "mist systems",
                  "extreme wireless", "cambium networks"] {
            if v.contains(k) { return .accessPoint }
        }

        // Pure-play switch/router vendors
        for k in ["arista networks", "juniper", "extreme networks",
                  "brocade", "force10", "edge-core", "edgecore",
                  "ubnt"] {
            if v.contains(k) { return .networkSwitch }
        }

        // Routers (small-business + carrier)
        for k in ["mikrotik", "routerboard", "draytek", "zyxel"] {
            if v.contains(k) { return .router }
        }

        // VoIP / IP-phone vendors
        for k in ["polycom", "yealink", "grandstream", "snom",
                  "mitel", "ascom"] {
            if v.contains(k) { return .voipPhone }
        }

        // Server / hyperconverged hardware
        for k in ["super micro", "supermicro", "nutanix",
                  "dell emc", "hpe", "hewlett packard enterprise",
                  "lenovo enterprise", "fujitsu siemens"] {
            if v.contains(k) { return .serverHardware }
        }

        // NAS
        for k in ["synology", "qnap", "netapp", "drobo", "buffalo",
                  "western digital", "iomega", "thecus"] {
            if v.contains(k) { return .nas }
        }

        // IP cameras / video
        for k in ["hikvision", "dahua", "axis communications",
                  "bosch security", "vivotek", "uniview"] {
            if v.contains(k) { return .ipCamera }
        }

        // Printers — only match brands that overwhelmingly ship print gear
        // from their OUIs. (HP and Brother also ship NICs in PCs/laptops,
        // so we leave them to the curated map.)
        for k in ["lexmark", "xerox", "ricoh", "konica minolta",
                  "kyocera", "sharp"] {
            if v.contains(k) { return .printer }
        }

        // Cisco — sells everything. Prefer .accessPoint if the string
        // mentions "meraki" or "linksys/wireless"; otherwise lean .networkSwitch
        // since enterprise Cisco OUIs are most often Catalyst/Nexus switches.
        if v.contains("cisco") {
            if v.contains("meraki") || v.contains("wireless") { return .accessPoint }
            return .networkSwitch
        }

        // HPE / Aruba — sells everything; lean infrastructure.
        if v.contains("hewlett packard") || v == "hpe" {
            return .networkSwitch
        }

        return .unknown
    }

    // MARK: - Bundled IEEE registry (lazy)

    private static var _registry: [String: String]?
    private static let registryLock = NSLock()

    private static func loadRegistry() -> [String: String] {
        registryLock.lock(); defer { registryLock.unlock() }
        if let r = _registry { return r }

        var result: [String: String] = [:]
        result.reserveCapacity(40_000)

        if let url = Bundle.main.url(forResource: "oui_registry", withExtension: "txt"),
           let data = try? String(contentsOf: url, encoding: .utf8) {
            for line in data.split(separator: "\n", omittingEmptySubsequences: true) {
                // Format: "<6 hex>\t<vendor>"
                guard let tabIdx = line.firstIndex(of: "\t") else { continue }
                let oui = String(line[..<tabIdx])
                let vendor = String(line[line.index(after: tabIdx)...])
                if oui.count == 6 { result[oui] = vendor }
            }
        }
        _registry = result
        return result
    }

    // MARK: - Curated map (role-hinted)

    private struct E { let vendor: String; let role: DeviceRole }

    private static let apple   = E(vendor: "Apple",     role: .appleDevice)
    private static let google  = E(vendor: "Google",    role: .iot)
    private static let amazon  = E(vendor: "Amazon",    role: .iot)
    private static let msft    = E(vendor: "Microsoft", role: .windowsPC)
    private static let samsung = E(vendor: "Samsung",   role: .unknown)
    private static let intel   = E(vendor: "Intel",     role: .unknown)

    private static func router(_ mac: String, _ vendor: String) -> (String, E) {
        (mac, E(vendor: vendor, role: .router))
    }
    private static func ap(_ mac: String, _ vendor: String) -> (String, E) {
        (mac, E(vendor: vendor, role: .accessPoint))
    }
    private static func nas(_ mac: String, _ vendor: String) -> (String, E) {
        (mac, E(vendor: vendor, role: .nas))
    }
    private static func printer(_ mac: String, _ vendor: String) -> (String, E) {
        (mac, E(vendor: vendor, role: .printer))
    }
    private static func cam(_ mac: String, _ vendor: String) -> (String, E) {
        (mac, E(vendor: vendor, role: .ipCamera))
    }
    private static func tv(_ mac: String, _ vendor: String) -> (String, E) {
        (mac, E(vendor: vendor, role: .smartTV))
    }
    private static func phone(_ mac: String, _ vendor: String) -> (String, E) {
        (mac, E(vendor: vendor, role: .androidPhone))
    }
    private static func game(_ mac: String, _ vendor: String) -> (String, E) {
        (mac, E(vendor: vendor, role: .gameConsole))
    }
    private static func voip(_ mac: String, _ vendor: String) -> (String, E) {
        (mac, E(vendor: vendor, role: .voipPhone))
    }
    private static func iot(_ mac: String, _ vendor: String) -> (String, E) {
        (mac, E(vendor: vendor, role: .iot))
    }

    private static let curatedMap: [String: E] = {
        var d: [String: E] = [:]

        // Apple — model disambiguation happens later via mDNS
        let appleOUIs = [
            "001451", "001B63", "001D4F", "0021E9", "0022FA", "0023DF",
            "0024E8", "00254B", "0025BC", "002608", "00264A", "002710",
            "0CBC9F", "0CD746", "1093E9", "10DDB1", "18AF61", "18EE69",
            "1C1AC0", "1C5CF2", "1C9E46", "1CABA7", "20A2E4", "2C5491",
            "2CB43A", "3408BC", "34159E", "34363B", "34A395", "34C059",
            "38B54D", "3CD0F8", "404D7F", "4098AD", "40A6D9", "44D884",
            "44FB42", "48437C", "48BF6B", "4C3275", "4C7C5F", "4C8D79",
            "5056BD", "5C95AE", "5C97F3", "60334B", "60C547", "60F445",
            "64200C", "645AED", "68967B", "6C19C0", "6C40C8", "70CD60",
            "70DEE2", "78CA39", "7CC537", "7CD1C3", "8030DC", "80B03D",
            "84B153", "8C8590", "8C8EF2", "9027E4", "9060F1", "9810E8",
            "98F0AB", "A4B197", "A4D1D2", "AC1F74", "AC3C0B", "AC87A3",
            "B065BD", "B0CA68", "B418D1", "B844D9", "BC5274", "BC926B",
            "BCEC5D", "C06394", "C0F2FB", "C42AD0", "C82A14", "CCC760",
            "D03311", "D0817A", "D49A20", "D4F46F", "DC2B61", "DCA904",
            "DCA4CA", "E0B9BA", "E0F5C6", "E48B7F", "E80688", "F0DBE2",
            "F0DBF8", "F0DCE2", "F40F24", "F41BA1", "F45C89", "F86214",
            "F8FFC2", "FCFC48",
        ]
        for mac in appleOUIs { d[mac] = apple }

        // Google (generic — Nest/Cast/Wifi mesh)
        let googleOUIs = [
            "20DF73", "286D97", "30FD38", "3417EB", "40789A", "44070B",
            "48D6D5", "541DFB", "5C2731", "6466B3", "70BB81", "7820D8",
            "947B0C", "94EB2C", "9CFC01", "C40BCB", "D8D770", "DA32CB",
            "DCA632", "F4F5D8", "F4F5DB", "F4F5E8",
        ]
        for mac in googleOUIs { d[mac] = google }

        // Pixel-line Google OUIs — phones, not Nest
        for mac in ["28BD89", "3C5AB4", "64BC0C", "94EBCD", "A4DA32"] {
            d[mac] = E(vendor: "Google", role: .androidPhone)
        }

        // Amazon (Echo / Fire TV / Kindle / Eero)
        let amazonOUIs = [
            "00FC8B", "04F021", "0C47C9", "1075BB", "14CC20", "1898FF",
            "34D270", "38F73D", "44650D", "4C0B3A", "4C17EB", "5483A0",
            "68DBF5", "6C5697", "74C246", "78E103", "84D6D0", "8871E5",
            "94B40F", "9C8E99", "A002DC", "AC63BE", "B07995", "B47C9C",
            "B85F98", "F0272D", "F0D2F1", "F0F005", "FCA13B",
        ]
        for mac in amazonOUIs { d[mac] = amazon }

        // Microsoft / Xbox / Surface
        let msftOUIs = [
            "0017FA", "00125A", "00155D", "0050F2", "28186E", "30599D",
            "30B2D6", "3499A1", "5C5197", "60450F", "60D9C7", "7CED8D",
            "84A93E", "98F49C", "A06105", "B073BF", "C8F733", "E89008",
            "F0922B",
        ]
        for mac in msftOUIs { d[mac] = msft }

        // Samsung (phones, smart TVs, appliances — needs mDNS to disambiguate)
        let samsungOUIs = [
            "00077A", "001632", "0023D7", "002491", "0026E2", "08D42B",
            "108EE0", "189EFC", "2C0E3D", "30CDA7", "34145F", "38AA3C",
            "3C5A37", "44783E", "4844F7", "5C0A5B", "60AF6D", "78F7BE",
            "885A92", "9489ED", "AC5F3E", "B05989", "B0DF3A", "BC4486",
            "BC8385", "CC07AB", "D487D8", "E84E84", "F8E61A",
        ]
        for mac in samsungOUIs { d[mac] = samsung }

        // Intel — usually a PC/laptop (NIC)
        for mac in ["001BFC", "001C25", "001E64", "0021CC", "402CF4",
                    "B43A28", "8C8CAA", "D0577B", "A0A8CD", "F8D3A9"] {
            d[mac] = intel
        }

        // Realtek
        for mac in ["001A4D", "00E04C", "525400"] {
            d[mac] = E(vendor: "Realtek", role: .unknown)
        }

        // Sonos
        for mac in ["000E58", "5CAAFD", "B8E937", "C843AE", "949F3E"] {
            d[mac] = E(vendor: "Sonos", role: .sonos)
        }

        // Roku
        for mac in ["08054F", "0C5A89", "20D5BF", "B0A737", "B0EE7B",
                    "BCD7D4", "C8BF4C", "D4E813", "DC3A5E", "DCFE07"] {
            d[mac] = E(vendor: "Roku", role: .roku)
        }

        // Philips Hue / Signify
        for mac in ["001788", "ECB5FA"] {
            d[mac] = E(vendor: "Philips Hue", role: .iot)
        }

        // Ring
        for mac in ["5C497A", "5CCA1A", "B047BF"] {
            d[mac] = E(vendor: "Ring", role: .ipCamera)
        }

        // Raspberry Pi
        for mac in ["28CDC1", "B827EB", "D83ADD", "E45F01"] {
            d[mac] = E(vendor: "Raspberry Pi", role: .raspberryPi)
        }

        // Networking gear — the curated set keeps role hints for the brands
        // that almost always ship a single device class. Everything else
        // (full Cisco/Juniper/Arista catalog, etc.) falls through to the
        // bundled IEEE registry + vendor-pattern inference.
        let networking: [(String, E)] = [
            // Ubiquiti / UniFi — exact role determined later by UBNT discovery / mDNS;
            // OUI just marks the device as Ubiquiti infrastructure.
            ap("245A4C", "Ubiquiti"), ap("B4FBE4", "Ubiquiti"),
            ap("DC9FDB", "Ubiquiti"), ap("FCECDA", "Ubiquiti"),
            ap("F09FC2", "Ubiquiti"), ap("44D9E7", "Ubiquiti"),
            ap("788A20", "Ubiquiti"), ap("0418D6", "Ubiquiti"),
            ap("042700", "Ubiquiti"), ap("18E829", "Ubiquiti"),
            ap("687251", "Ubiquiti"), ap("70A741", "Ubiquiti"),
            ap("74ACB9", "Ubiquiti"), ap("74D435", "Ubiquiti"),
            ap("78458C", "Ubiquiti"), ap("78A4D9", "Ubiquiti"),
            ap("8025D9", "Ubiquiti"), ap("80EA96", "Ubiquiti"),
            ap("8C5910", "Ubiquiti"), ap("9C05D6", "Ubiquiti"),
            ap("A0AB1B", "Ubiquiti"), ap("BC0235", "Ubiquiti"),
            ap("BC2210", "Ubiquiti"), ap("D021F9", "Ubiquiti"),
            ap("D4CA6D", "Ubiquiti"), ap("E063DA", "Ubiquiti"),
            ap("E43883", "Ubiquiti"), ap("E438B7", "Ubiquiti"),
            ap("E4FAC4", "Ubiquiti"), ap("F492BF", "Ubiquiti"),
            // Newer UDM-SE / UDM-Pro / UXG / U7 lineage
            ap("60226D", "Ubiquiti"), ap("7483C2", "Ubiquiti"),
            ap("D8B370", "Ubiquiti"), ap("F4E2C6", "Ubiquiti"),
            ap("9C8ECD", "Ubiquiti"),
            // TP-Link / Netgear / ASUS / D-Link / Linksys / Belkin —
            // small-business + consumer router gear. Keep curated since
            // these vendors also ship random IoT under the same OUIs.
            router("AC84C6", "TP-Link"), router("B0BE76", "TP-Link"),
            router("C006C3", "TP-Link"), router("C025E9", "TP-Link"),
            router("98DAC4", "TP-Link"), router("B4E62D", "TP-Link"),
            router("EC086B", "TP-Link"),
            router("18D6C2", "Netgear"), router("9C3DCF", "Netgear"),
            router("A040A0", "Netgear"), router("B0B98A", "Netgear"),
            router("9C5C8E", "ASUS"), router("049226", "ASUS"),
            router("1C872C", "ASUS"), router("4CEDFB", "ASUS"),
            router("B06EBF", "D-Link"), router("C8BE19", "D-Link"),
            router("001CF0", "D-Link"),
            router("00226B", "Linksys"), router("002129", "Linksys"),
            router("C0560E", "Belkin"), router("94103E", "Belkin"),
            router("3860F8", "Belkin"), router("6C4008", "Belkin"),
        ]
        for (k, v) in networking { d[k] = v }

        // NAS
        let nasGear: [(String, E)] = [
            nas("001132", "Synology"), nas("001135", "Synology"),
            nas("0014FD", "Synology"), nas("001A4A", "Synology"),
            nas("245EBE", "QNAP"), nas("00089B", "QNAP"),
            nas("003048", "QNAP"),
        ]
        for (k, v) in nasGear { d[k] = v }

        // Printers (consumer + workgroup brands)
        let printers: [(String, E)] = [
            printer("0001E6", "HP"), printer("0017A4", "HP"),
            printer("001A4B", "HP"), printer("0021F7", "HP"),
            printer("002655", "HP"),
            printer("5065F3", "HP"), printer("5C8A38", "HP"),
            printer("AC1635", "HP"), printer("B4992F", "HP"),
            printer("001B78", "HP"), printer("002413", "HP"),
            printer("0017C8", "Brother"), printer("008092", "Brother"),
            printer("30055C", "Brother"), printer("AC44F2", "Brother"),
            printer("001E8C", "Canon"), printer("0050BA", "Canon"),
            printer("F44D30", "Canon"),
            printer("0026AB", "Epson"), printer("08006E", "Epson"),
        ]
        for (k, v) in printers { d[k] = v }

        // Game consoles
        let games: [(String, E)] = [
            game("0009BF", "Nintendo"),   game("0017AB", "Nintendo"),
            game("0019FD", "Nintendo"),   game("002709", "Nintendo"),
            game("5C521E", "Nintendo"),   game("98E8FA", "Nintendo"),
            game("00041F", "Sony PlayStation"), game("001D0D", "Sony PlayStation"),
            game("001FA7", "Sony PlayStation"), game("0024BE", "Sony PlayStation"),
            game("00D9D1", "Sony PlayStation"), game("709E29", "Sony PlayStation"),
            game("F8DA0C", "Sony PlayStation"),
        ]
        for (k, v) in games { d[k] = v }

        // Smart TVs
        let tvs: [(String, E)] = [
            tv("001EE1", "LG"), tv("AC0D1B", "LG"),
            tv("C80210", "LG"), tv("DC0B1A", "LG"),
            tv("001D86", "Vizio"), tv("942DBE", "Vizio"),
        ]
        for (k, v) in tvs { d[k] = v }

        // VoIP / IP phones (legacy curated — full Polycom/Yealink/etc.
        // catalogs are also matched via vendor-pattern inference.)
        let voipPhones: [(String, E)] = [
            voip("00040D", "Avaya"),
            voip("00036B", "Polycom"), voip("0080F0", "Polycom"),
            voip("001580", "Yealink"),
        ]
        for (k, v) in voipPhones { d[k] = v }

        // Virtualization (Linux-ish guest)
        for mac in ["000C29", "001C14", "005056"] {
            d[mac] = E(vendor: "VMware", role: .linux)
        }
        d["001C42"] = E(vendor: "Parallels", role: .linux)
        d["00163E"] = E(vendor: "Xensource", role: .linux)

        // Other phone manufacturers
        let phones: [(String, E)] = [
            phone("000C8B", "Xiaomi"),
            phone("001F6C", "OnePlus"),
            phone("B445C0", "OPPO"), phone("F8D0AC", "OPPO"),
            phone("C03E0F", "Vivo"),
            phone("002241", "Motorola"), phone("B07594", "Motorola"),
            phone("EC1F72", "Motorola"),
        ]
        for (k, v) in phones { d[k] = v }

        // Smart-home / IoT
        let smartHome: [(String, E)] = [
            iot("447DAA", "Ecobee"), iot("84F3EB", "Ecobee"),
            iot("18B430", "Nest Labs"), iot("64166D", "Nest Labs"),
            iot("F0A772", "August"),
            cam("2CAA8E", "Wyze"), cam("D03F27", "Wyze"),
            cam("78A5DD", "Wyze"), cam("7C78B2", "Wyze"),
            cam("8CAAB5", "Eufy"), cam("8C53C3", "Eufy"),
            cam("EC71DB", "Reolink"), cam("3C52A1", "Reolink"),
            cam("385F66", "Arlo"), cam("CC40D0", "Arlo"),
            iot("E848B8", "TP-Link Kasa"), iot("9C5322", "TP-Link Kasa"),
            iot("503EAA", "TP-Link Kasa"), iot("AC84C9", "TP-Link Kasa"),
            iot("D073D5", "LIFX"),
            iot("9416B2", "Wemo"),
            iot("BCFF4D", "Shelly"), iot("E8DB84", "Shelly"),
            iot("349454", "Shelly"),
            iot("DC4F22", "Tuya"), iot("D8F15B", "Tuya"),
            iot("D81F12", "Tuya"),
            cam("B47C9C", "Ring"),
            iot("F0038C", "iRobot"), iot("502B73", "iRobot"),
            iot("000FD3", "Yale"),
            iot("3094D5", "Anker"),
            iot("004032", "Bose"), iot("70DF2F", "Bose"),
            tv("00194B", "Sony"), tv("002400", "Sony"), tv("003065", "Sony"),
            tv("0019DA", "Vizio"), tv("C842BC", "Vizio"),
            tv("9CADCE", "TCL"), tv("C42AB0", "TCL"),
            tv("000FC9", "Hisense"), tv("DC8C37", "Hisense"),
        ]
        for (k, v) in smartHome { d[k] = v }

        return d
    }()
}
