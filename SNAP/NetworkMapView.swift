// NetworkMapView.swift
// SNAP — Network Map (rewritten in v1.2.1)
// Created by Sevag Bardakjian
// Copyright © 2025 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md
//
// Three view modes share the same model:
//   • Grid    — info-dense device cards (status, model, MAC, ping, ports)
//   • List    — sortable Table with model / status / open ports / last seen
//   • Visual  — gateway-centered constellation with type-grouped angular
//               layout; click a node to open a detail panel with all
//               identity signals + quick actions.
//
// The model pipelines:
//   1. ARP table sweep (instant)
//   2. /24 ping sweep, chunked to 32 in flight
//   3. LAN-wide mDNS + SSDP sweep (concurrent with #2)
//   4. Per-device probes (NetBIOS + HTTP banner + reverse DNS) on every
//      device that responded
//   5. Merge all signals into a DeviceIdentity, refine role, persist scan.

import SwiftUI
import AppKit
import Darwin

// MARK: - Device model

struct NetworkDevice: Identifiable, Hashable {
    let id: String                          // ip
    var ip: String
    var mac: String = ""
    var vendor: String = ""
    var identity = DeviceIdentity()
    var pingMs: Double?
    var status: ReachStatus = .unknown
    var openPorts: [Int] = []
    var lastSeen: Date = Date()

    enum ReachStatus { case alive, arpOnly, unreachable, unknown }

    static func == (lhs: NetworkDevice, rhs: NetworkDevice) -> Bool { lhs.ip == rhs.ip }
    func hash(into hasher: inout Hasher) { hasher.combine(ip) }

    var displayName: String { identity.bestLabel }
    var role: DeviceRole    { identity.role }
    var icon: String        { identity.role.icon }

    var statusColor: Color {
        switch status {
        case .alive:        return NS.green
        case .arpOnly:      return NS.amber
        case .unreachable:  return NS.red
        case .unknown:      return NS.text3
        }
    }

    var statusLabel: String {
        switch status {
        case .alive:        return "Online"
        case .arpOnly:      return "ARP cache only"
        case .unreachable:  return "Unreachable"
        case .unknown:      return "—"
        }
    }
}

// MARK: - Model

@MainActor
final class NetworkMapModel: ObservableObject {
    @Published var devices: [NetworkDevice] = []
    @Published var isScanning = false
    @Published var phase: ScanPhase = .idle
    @Published var progress: Double = 0
    @Published var subnet: String = ""
    @Published var gatewayIP: String? = nil
    @Published var selfIP: String? = nil
    @Published var lastScan: Date? = nil
    /// IPs currently being re-pinged (for the detail panel's Ping button)
    @Published var pinging: Set<String> = []

    enum ScanPhase: String {
        case idle, arp, pingSweep, lanDiscovery, perDeviceProbes, done
        var label: String {
            switch self {
            case .idle:           return "Idle"
            case .arp:            return "Reading ARP cache…"
            case .pingSweep:      return "Pinging + UBNT sweep…"
            case .lanDiscovery:   return "mDNS + SSDP + UBNT discovery…"
            case .perDeviceProbes:return "Per-device probes…"
            case .done:           return "Done"
            }
        }
    }

    // MARK: Scan range

    /// Most addresses one scan covers: a full /16 (65,534 hosts).
    nonisolated static let maxScanHosts = 65_536
    /// Bigger than a /22 → show the time estimate and ask first.
    nonisolated static let confirmAboveHosts = 1_024

    /// What the range field currently means — CIDR, custom ranges, or the
    /// classic /24 shorthand, comma-separated (see `ScanRange`).
    var scanRange: Result<ScanRange, ScanRange.ParseError> {
        ScanRange.parse(subnet, maxHosts: Self.maxScanHosts)
    }

    /// The /24 around this Mac — offered as a quick alternative when the
    /// detected network is large.
    private(set) var localSlash24: String?

    /// Set when a scan is big enough to confirm first; drives the alert.
    @Published var pendingLargeScan: LargeScanPrompt?

    struct LargeScanPrompt: Identifiable {
        let id = UUID()
        let hostCount: Int
        let estimate: String
        /// The local /24, when it's inside the range and smaller than it.
        let quickAlternative: String?
    }

    /// Addresses for the scan in progress, fixed when it starts.
    private var scanTargets: [String] = []

    var canScan: Bool {
        if case .success = scanRange { return true }
        return false
    }

    /// Rough wall-clock time for a scan. Calibrated on an M-series Mac: a
    /// batch of 32 pings to dead addresses takes ~1.06 s, and the UBNT
    /// unicast sweep runs alongside it in batches of 48 with a 1.5 s
    /// timeout. Later stages only touch live hosts. ~19 s for a /24,
    /// ~38 min for a /16.
    nonisolated static func estimatedScanSeconds(hosts: Int) -> Int {
        let ping = Double((hosts + 31) / 32) * 1.1
        let ubnt = Double((hosts + 47) / 48) * 1.5
        return Int(max(ping, ubnt).rounded(.up)) + 10
    }

    nonisolated static func describeDuration(seconds: Int) -> String {
        if seconds < 90 { return "about \(seconds) seconds" }
        return "about \(Int((Double(seconds) / 60).rounded())) minutes"
    }

    init() {
        if let net = ScanRange.localNetwork() {
            subnet = net.cidr
            localSlash24 = net.slash24
        } else {
            subnet = "192.168.1.0/24"
        }
    }

    // MARK: Scan pipeline

    /// The Scan button: runs small scans straight away, asks before big ones.
    func requestScan() {
        guard !isScanning, case .success(let range) = scanRange else { return }
        if range.hostCount <= Self.confirmAboveHosts {
            scan()
            return
        }
        // Offer the local /24 only if it's actually part of what was typed.
        var quick: String? = nil
        if let s24 = localSlash24, case .success(let small) = ScanRange.parse(s24, maxHosts: 256),
           let first = small.spans.first,
           range.spans.contains(where: { $0.first <= first.first && first.last <= $0.last }) {
            quick = s24
        }
        pendingLargeScan = LargeScanPrompt(
            hostCount: range.hostCount,
            estimate: Self.describeDuration(seconds: Self.estimatedScanSeconds(hosts: range.hostCount)),
            quickAlternative: quick)
    }

    func confirmLargeScan() {
        pendingLargeScan = nil
        scan()
    }

    func scanQuickAlternative() {
        guard let quick = pendingLargeScan?.quickAlternative else { return }
        pendingLargeScan = nil
        subnet = quick
        scan()
    }

    func scan() {
        guard !isScanning else { return }
        guard case .success(let range) = scanRange else { return }
        scanTargets = range.addresses()
        isScanning = true
        progress = 0
        phase = .arp

        Task {
            // Stage 0: parse ARP cache + LAN-wide detection of self/gateway
            await loadARP()

            // Stage 1: ping sweep + unicast UBNT sweep + LAN broadcast sweep.
            // All three run concurrently. The unicast UBNT sweep catches
            // UniFi gear on the same subnets that filter ICMP, and also
            // works across VLANs (unicast routes via the gateway, broadcast
            // doesn't).
            phase = .pingSweep
            async let pingDevices: Void = pingSweep()
            async let ubntUnicast: [String: IdentitySignal] = unicastUBNTSweep()
            async let lanDiscovery: DeviceIdentifierResult = DeviceIdentifier.runLANSweep(wallClockTimeout: 6)

            _ = await pingDevices
            let unicastResults = await ubntUnicast
            let lan = await lanDiscovery
            gatewayIP = lan.gatewayIP
            selfIP    = lan.selfIP
            applyLANSweep(lan)
            applyUnicastUBNT(unicastResults)

            // Stage 2: per-device probes (NetBIOS / HTTP / rDNS / UBNT-unicast)
            phase = .perDeviceProbes
            await perDeviceProbes()

            // Tag self + gateway (must happen after all role-inferring signals)
            tagSelfAndGateway()

            // Final sort + finish
            devices.sort { Self.ipNumeric($0.ip) < Self.ipNumeric($1.ip) }
            phase = .done
            lastScan = Date()
            isScanning = false
            persist()
        }
    }

    // MARK: Stage 0 — ARP

    private func loadARP() async {
        let out = await Shell.run("/usr/sbin/arp", args: ["-an"])
        for line in out.split(separator: "\n").map(String.init) {
            guard let ipOpen = line.firstIndex(of: "("),
                  let ipClose = line.firstIndex(of: ")"),
                  let atRange = line.range(of: " at ")
            else { continue }
            let ip = String(line[line.index(after: ipOpen)..<ipClose])
            let rest = line[atRange.upperBound...]
            let mac = rest.split(separator: " ").first.map(String.init) ?? ""
            guard mac != "(incomplete)", !mac.isEmpty else { continue }

            var dev = devices.first { $0.ip == ip } ?? NetworkDevice(id: ip, ip: ip)
            dev.mac = mac
            if let hint = OUIDatabase.roleHint(mac) {
                dev.vendor = hint.vendor
                dev.identity.merge(.oui(vendor: hint.vendor, hintedRole: hint.role))
            }
            dev.status = .arpOnly
            upsert(dev)
        }
    }

    // MARK: Stage 1a — Ping sweep

    private func pingSweep() async {
        let targets = scanTargets
        guard !targets.isEmpty else { return }
        let chunkSize = 32
        let total = Double(targets.count)
        var completed = 0.0
        for start in stride(from: 0, to: targets.count, by: chunkSize) {
            let batch = targets[start..<min(start + chunkSize, targets.count)]
            await withTaskGroup(of: (String, Double?)?.self) { group in
                for ip in batch {
                    group.addTask {
                        return await Self.pingOne(ip: ip)
                    }
                }
                for await result in group {
                    if let (ip, ms) = result {
                        recordPing(ip: ip, ms: ms)
                    }
                }
            }
            completed += Double(batch.count)
            progress = min(0.5, completed / total * 0.5)
        }
    }

    // MARK: Stage 1c — Unicast UBNT sweep
    //
    // Sends a unicast UBNT discovery probe to every address in the scan
    // range. This catches UniFi gear on subnets the Mac can't broadcast
    // to (VLAN-segmented setups) and devices that filter ICMP. Unicast UDP
    // routes correctly through the gateway, so cross-VLAN discovery works
    // when the Mac has a route to the target subnet.

    private func unicastUBNTSweep() async -> [String: IdentitySignal] {
        let targets = scanTargets
        guard !targets.isEmpty else { return [:] }
        var results: [String: IdentitySignal] = [:]
        // Chunked to keep file-descriptor usage bounded.
        let chunkSize = 48
        for start in stride(from: 0, to: targets.count, by: chunkSize) {
            let chunk = targets[start..<min(start + chunkSize, targets.count)]
            let batch = await withTaskGroup(of: (String, IdentitySignal?).self) { group -> [(String, IdentitySignal)] in
                for ip in chunk {
                    group.addTask {
                        let sig = await UBNTUnicastProbe.probe(ip: ip, timeout: 1.5)
                        return (ip, sig)
                    }
                }
                var found: [(String, IdentitySignal)] = []
                for await (ip, sig) in group {
                    if let s = sig { found.append((ip, s)) }
                }
                return found
            }
            for (ip, sig) in batch { results[ip] = sig }
        }
        return results
    }

    /// Merge unicast UBNT sweep results into the device list. Each hit
    /// creates or updates a device with the .ubnt signal, marks it alive,
    /// and feeds the merge logic so role/manufacturer get refined.
    private func applyUnicastUBNT(_ results: [String: IdentitySignal]) {
        for (ip, sig) in results {
            var dev = devices.first { $0.ip == ip } ?? NetworkDevice(id: ip, ip: ip)
            if dev.status != .alive { dev.status = .alive }
            dev.identity.merge(sig)
            upsert(dev)
        }
    }

    private nonisolated static func pingOne(ip: String) async -> (String, Double?)? {
        let out = await Shell.run("/sbin/ping",
                                  args: ["-c", "1", "-W", "400", "-t", "1", "-q", ip])
        guard out.contains("bytes from") || out.contains("1 packets received") else { return nil }
        var ms: Double? = nil
        if let r = out.range(of: #"= [\d\.]+/([\d\.]+)/"#, options: .regularExpression) {
            let s = out[r]
            let digits = s.split(whereSeparator: { !$0.isNumber && $0 != "." })
            if digits.count >= 2, let v = Double(String(digits[1])) { ms = v }
        }
        return (ip, ms)
    }

    private func recordPing(ip: String, ms: Double?) {
        var dev = devices.first { $0.ip == ip } ?? NetworkDevice(id: ip, ip: ip)
        dev.pingMs = ms
        dev.status = .alive
        dev.lastSeen = Date()
        upsert(dev)
    }

    // MARK: Stage 1b — LAN sweep results merge

    private func applyLANSweep(_ res: DeviceIdentifierResult) {
        for (ip, signals) in res.perIP {
            var dev = devices.first { $0.ip == ip } ?? NetworkDevice(id: ip, ip: ip)
            // mDNS/SSDP responses confirm the device is online even if our
            // ping was filtered (common on iOS devices and Sonos)
            if dev.status != .alive { dev.status = .alive }
            for sig in signals { dev.identity.merge(sig) }
            upsert(dev)
        }
        progress = 0.7
    }

    // MARK: Stage 2 — per-device probes

    private func perDeviceProbes() async {
        let targets = devices.filter { $0.status == .alive }
        let total = max(1, targets.count)
        var done = 0
        await withTaskGroup(of: (String, [IdentitySignal]).self) { group in
            for dev in targets {
                let ip = dev.ip
                group.addTask {
                    let sigs = await DeviceIdentifier.probeOne(ip: ip)
                    return (ip, sigs)
                }
            }
            for await (ip, sigs) in group {
                if var d = devices.first(where: { $0.ip == ip }) {
                    for s in sigs { d.identity.merge(s) }
                    upsert(d)
                }
                done += 1
                progress = 0.7 + 0.3 * (Double(done) / Double(total))
            }
        }
    }

    // MARK: Self + gateway tagging

    private func tagSelfAndGateway() {
        if let me = selfIP, var d = devices.first(where: { $0.ip == me }) {
            d.identity.merge(.selfDetected)
            upsert(d)
        }
        if let gw = gatewayIP {
            var d = devices.first { $0.ip == gw } ?? NetworkDevice(id: gw, ip: gw)
            d.identity.merge(.gatewayDetected)
            if d.status == .unknown { d.status = .alive }
            upsert(d)
        }
    }

    // MARK: Per-device actions

    /// Re-ping a single device and update its `pingMs` + `lastSeen` in place.
    /// Drives the Detail panel's Ping button so a click actually does something
    /// visible (previous build ran ping with discarded output).
    func repingDevice(ip: String) async {
        guard !pinging.contains(ip) else { return }
        pinging.insert(ip)
        defer { pinging.remove(ip) }

        let result = await Self.pingOne(ip: ip)
        if let (_, ms) = result {
            if let idx = devices.firstIndex(where: { $0.ip == ip }) {
                devices[idx].pingMs = ms
                devices[idx].status = .alive
                devices[idx].lastSeen = Date()
            }
        } else {
            // No response — mark unreachable but keep the row.
            if let idx = devices.firstIndex(where: { $0.ip == ip }) {
                devices[idx].pingMs = nil
                devices[idx].status = .unreachable
            }
        }
    }

    // MARK: Helpers

    private func upsert(_ device: NetworkDevice) {
        if let idx = devices.firstIndex(where: { $0.ip == device.ip }) {
            devices[idx] = device
        } else {
            devices.append(device)
        }
    }

    nonisolated static func ipNumeric(_ ip: String) -> UInt32 {
        let parts = ip.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4 else { return 0 }
        return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
    }

    // MARK: Persistence (last scan)

    private static let lastScanKey = "snap.networkMap.lastScan.v1"

    private func persist() {
        // Best-effort snapshot — minimal subset so re-opens have *something*
        let payload: [[String: Any]] = devices.map { d in
            [
                "ip": d.ip,
                "mac": d.mac,
                "vendor": d.vendor,
                "displayName": d.identity.displayName ?? "",
                "model": d.identity.model ?? "",
                "manufacturer": d.identity.manufacturer ?? "",
                "role": d.identity.role.rawValue,
                "pingMs": d.pingMs ?? 0,
                "ports": d.openPorts,
                "lastSeen": d.lastSeen.timeIntervalSince1970,
            ]
        }
        let snapshot: [String: Any] = [
            "scannedAt": Date().timeIntervalSince1970,
            "gateway": gatewayIP ?? "",
            "self": selfIP ?? "",
            "devices": payload,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: snapshot) {
            UserDefaults.standard.set(data, forKey: Self.lastScanKey)
        }
    }

    func restoreLastScan() {
        guard let data = UserDefaults.standard.data(forKey: Self.lastScanKey),
              let snap = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        let ts = snap["scannedAt"] as? TimeInterval ?? 0
        if ts > 0 { lastScan = Date(timeIntervalSince1970: ts) }
        gatewayIP = (snap["gateway"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        selfIP    = (snap["self"]    as? String).flatMap { $0.isEmpty ? nil : $0 }
        guard let arr = snap["devices"] as? [[String: Any]] else { return }
        var restored: [NetworkDevice] = []
        for d in arr {
            guard let ip = d["ip"] as? String else { continue }
            var dev = NetworkDevice(id: ip, ip: ip)
            dev.mac = (d["mac"] as? String) ?? ""
            dev.vendor = (d["vendor"] as? String) ?? ""
            dev.identity.displayName  = (d["displayName"]  as? String).flatMap { $0.isEmpty ? nil : $0 }
            dev.identity.model        = (d["model"]        as? String).flatMap { $0.isEmpty ? nil : $0 }
            dev.identity.manufacturer = (d["manufacturer"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if let r = d["role"] as? String, let role = DeviceRole(rawValue: r) {
                dev.identity.role = role
            }
            if let p = d["pingMs"] as? Double, p > 0 { dev.pingMs = p }
            if let ports = d["ports"] as? [Int] { dev.openPorts = ports }
            if let lastSeen = d["lastSeen"] as? TimeInterval, lastSeen > 0 {
                dev.lastSeen = Date(timeIntervalSince1970: lastSeen)
            }
            dev.status = .arpOnly
            restored.append(dev)
        }
        restored.sort { Self.ipNumeric($0.ip) < Self.ipNumeric($1.ip) }
        devices = restored
    }

    // MARK: Asset inventory export
    //
    // Schema is shared with BulkDiscoveryModel + UniFiControllerModel so
    // CSVs from all three discovery surfaces line up column-for-column in
    // a spreadsheet for cross-source correlation.

    func exportInventoryText() -> String {
        var s = "Network Map — \(devices.count) device\(devices.count == 1 ? "" : "s")\n"
        if let g = gatewayIP { s += "gateway: \(g)\n" }
        if let me = selfIP   { s += "self: \(me)\n" }
        s += "\nip\tmac\thostname\tvendor\tmodel\trole\tports\tstatus\n"
        for d in devices {
            let host = d.identity.displayName ?? "—"
            let model = d.identity.model ?? "—"
            let vendor = (d.identity.manufacturer ?? d.vendor).nilIfEmpty ?? "—"
            let ports = d.openPorts.map(String.init).joined(separator: ",")
            s += "\(d.ip)\t\(d.mac.isEmpty ? "—" : d.mac)\t\(host)\t\(vendor)\t\(model)\t\(d.role.rawValue)\t\(ports.isEmpty ? "—" : ports)\t\(d.statusLabel)\n"
        }
        return s
    }

    func exportInventoryCSV() -> String {
        var s = "ip,mac,hostname,vendor,model,role,open_ports,status,ping_ms,last_seen\n"
        for d in devices {
            let host   = d.identity.displayName ?? ""
            let model  = d.identity.model ?? ""
            let vendor = d.identity.manufacturer ?? d.vendor
            let ports  = d.openPorts.map(String.init).joined(separator: ";")
            let ping   = d.pingMs.map { String(format: "%.1f", $0) } ?? ""
            let cells: [String] = [
                d.ip, d.mac, host, vendor, model, d.role.rawValue,
                ports, d.statusLabel, ping,
                ISO8601DateFormatter().string(from: d.lastSeen),
            ]
            s += cells.map { csvEscape($0) }.joined(separator: ",") + "\n"
        }
        return s
    }

    func exportInventoryJSON() -> String {
        let payload: [String: Any] = [
            "source": "network_map",
            "captured_at": ISO8601DateFormatter().string(from: Date()),
            "gateway": gatewayIP ?? "",
            "self": selfIP ?? "",
            "assets": devices.map { d in
                [
                    "ip": d.ip,
                    "mac": d.mac,
                    "hostname": d.identity.displayName ?? "",
                    "vendor": d.identity.manufacturer ?? d.vendor,
                    "model": d.identity.model ?? "",
                    "role": d.role.rawValue,
                    "open_ports": d.openPorts,
                    "status": d.statusLabel,
                    "ping_ms": d.pingMs as Any,
                    "last_seen": ISO8601DateFormatter().string(from: d.lastSeen),
                ] as [String: Any]
            },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Filters

struct DeviceFilters: Equatable {
    var search: String = ""
    var aliveOnly: Bool = false
    var group: DeviceGroup? = nil    // nil = all groups
    var vendor: String? = nil        // nil = all vendors

    func apply(_ devices: [NetworkDevice]) -> [NetworkDevice] {
        var out = devices
        if aliveOnly { out = out.filter { $0.status == .alive } }
        if let g = group { out = out.filter { $0.role.group == g } }
        if let v = vendor { out = out.filter { ($0.identity.manufacturer ?? $0.vendor) == v } }
        if !search.isEmpty {
            let s = search.lowercased()
            out = out.filter {
                $0.ip.contains(s) ||
                $0.mac.lowercased().contains(s) ||
                $0.displayName.lowercased().contains(s) ||
                $0.vendor.lowercased().contains(s) ||
                ($0.identity.manufacturer ?? "").lowercased().contains(s) ||
                ($0.identity.model ?? "").lowercased().contains(s)
            }
        }
        return out
    }
}

// MARK: - Top-level view

struct NetworkMapView: View {
    @StateObject private var model = NetworkMapModel()
    @State private var viewMode: ViewMode = .grid
    @State private var filters = DeviceFilters()
    @State private var selectedIP: String? = nil

    enum ViewMode: String, CaseIterable { case grid = "Grid", list = "List", map = "Visual" }

    private var filtered: [NetworkDevice] { filters.apply(model.devices) }
    private var selected: NetworkDevice?  { model.devices.first { $0.ip == selectedIP } }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            FilterBar(model: model, filters: $filters)
            Divider()

            if model.devices.isEmpty && !model.isScanning {
                EmptyStateView(title: "No Devices Found",
                               systemImage: "map.circle",
                               description: "SNAP fills in your current network. Adjust the range if you like (a subnet like 10.0.0.0/16, a range like 10.0.0.1-10.0.3.254, or several separated by commas), then press Scan Network. SNAP will ping every address, run mDNS + SSDP + NetBIOS probes, and identify each device.")
            } else {
                GeometryReader { geo in
                    HSplitView {
                        Group {
                            switch viewMode {
                            case .grid: GridView(devices: filtered, selectedIP: $selectedIP)
                            case .list: ListView(devices: filtered, selectedIP: $selectedIP)
                            case .map:  VisualView(model: model, devices: filtered, selectedIP: $selectedIP)
                            }
                        }
                        // 520 pt when there's room. In a narrow window it
                        // gives way so both panes fit; 520 + 280 used to
                        // push the whole layout off both edges.
                        .frame(minWidth: max(340, min(520, geo.size.width - 290)))

                        DeviceDetailPanel(device: selected, model: model)
                            .frame(minWidth: 280, idealWidth: 320)
                    }
                }
            }
        }
        .tabNavigationTitle(.networkMap)
        .onAppear { model.restoreLastScan() }
        .alert(Text(verbatim: model.pendingLargeScan.map { "Scan \($0.hostCount.formatted()) addresses?" } ?? ""),
               isPresented: Binding(get: { model.pendingLargeScan != nil },
                                    set: { if !$0 { model.pendingLargeScan = nil } }),
               presenting: model.pendingLargeScan) { p in
            Button("Scan All") { model.confirmLargeScan() }
            if let quick = p.quickAlternative {
                Button("Scan \(quick) Only") { model.scanQuickAlternative() }
            }
            Button("Cancel", role: .cancel) { model.pendingLargeScan = nil }
        } message: { p in
            if let quick = p.quickAlternative {
                Text(verbatim: "This takes \(p.estimate) and sends pings and discovery probes to every address, which network monitoring tools will see.\n\nOr scan just \(quick), the /24 this Mac is on, in \(NetworkMapModel.describeDuration(seconds: NetworkMapModel.estimatedScanSeconds(hosts: 254))).")
            } else {
                Text(verbatim: "This takes \(p.estimate) and sends pings and discovery probes to every address, which network monitoring tools will see.")
            }
        }
    }

    /// Host count for a valid range, or the reason it isn't one.
    @ViewBuilder private var rangeSummary: some View {
        switch model.scanRange {
        case .success(let r):
            Text(r.hostCount == 1 ? "1 host" : "\(r.hostCount.formatted()) hosts")
                .font(.caption).foregroundStyle(.secondary)
                .help(r.hostCount > NetworkMapModel.confirmAboveHosts
                      ? "Large range — \(NetworkMapModel.describeDuration(seconds: NetworkMapModel.estimatedScanSeconds(hosts: r.hostCount))). SNAP will ask before scanning."
                      : "Scans every address in the range.")
        case .failure(let e):
            Label(e == .empty ? "No range" : "Invalid range", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(NS.amber)
                .help(e.message)
        }
    }

    private var topBar: some View {
        // One row when everything fits at its natural width. Otherwise two:
        // range + scan on top, view mode + results underneath.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                mapIcon
                rangeField
                    // Measured at its minimum, so one row is used whenever
                    // everything else fits at full size; spare room widens it.
                    .frame(minWidth: 170, idealWidth: 170, maxWidth: 260)
                rangeSummary
                    .lineLimit(1)
                    .fixedSize()
                viewPicker
                Spacer()
                scanStatus(progressWidth: 140)
                deviceCount
                actionBar
                scanButton
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    mapIcon
                    rangeField
                        .frame(minWidth: 120, maxWidth: 260)
                    rangeSummary
                        .lineLimit(1)
                        .fixedSize()
                    Spacer(minLength: 0)
                    scanStatus(progressWidth: 80)
                    scanButton
                }
                HStack(spacing: 12) {
                    viewPicker
                    Spacer(minLength: 0)
                    deviceCount
                    actionBar
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(NS.bg0)
    }

    private var mapIcon: some View {
        Image(systemName: "map.circle").foregroundStyle(.blue)
    }

    private var rangeField: some View {
        TextField("Range (e.g. 192.168.1.0/24)", text: $model.subnet)
            .textFieldStyle(.roundedBorder)
            .disabled(model.isScanning)
            .help("""
                  A subnet (10.0.0.0/16), a range (10.0.0.1-10.0.3.254 or 192.168.1.100-150), \
                  a /24 shorthand (192.168.1), or a single address — several separated by commas. \
                  Up to 65,536 addresses. Add your UniFi management VLAN here if your APs/switches \
                  live on a different subnet than your Mac.
                  """)
    }

    private var viewPicker: some View {
        Picker("View", selection: $viewMode) {
            ForEach(ViewMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        // Sized to its content. A fixed 220 pt frame left the "View"
        // label almost no slack, so a fraction-of-a-point shift from the
        // device count's width changing (e.g. toggling Online only)
        // wrapped it onto two lines.
        .fixedSize()
    }

    /// Progress while scanning, otherwise when the last scan finished.
    @ViewBuilder private func scanStatus(progressWidth: CGFloat) -> some View {
        if model.isScanning {
            ProgressView(value: model.progress)
                .progressViewStyle(.linear)
                .frame(width: progressWidth)
            Text(model.phase.label)
                .font(.system(size: 11))
                .foregroundStyle(NS.text3)
                .lineLimit(1)
                .layoutPriority(1)
        } else if let t = model.lastScan {
            Text("Scanned \(t.formatted(date: .omitted, time: .shortened))")
                .font(.system(size: 11))
                .foregroundStyle(NS.text3)
                .lineLimit(1)
                .fixedSize()
        }
    }

    private var deviceCount: some View {
        Text("\(filtered.count) of \(model.devices.count)")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(NS.text3)
            .lineLimit(1)
            .fixedSize()
    }

    @ViewBuilder private var actionBar: some View {
        if !model.devices.isEmpty {
            ToolActionBar("Network-Map",
                          text: { model.exportInventoryText() },
                          csv:  { model.exportInventoryCSV() },
                          json: { model.exportInventoryJSON() })
                .fixedSize()
        }
    }

    private var scanButton: some View {
        Button(model.isScanning ? "Scanning…" : "Scan Network") { model.requestScan() }
            .buttonStyle(.borderedProminent)
            .disabled(model.isScanning || !model.canScan)
            .keyboardShortcut(.return)
            .fixedSize()
    }
}

// MARK: - Filter bar

private struct FilterBar: View {
    @ObservedObject var model: NetworkMapModel
    @Binding var filters: DeviceFilters

    private var allGroups: [DeviceGroup] {
        let present = Set(model.devices.map { $0.role.group })
        return DeviceGroup.allCases.filter { present.contains($0) }
    }

    private var allVendors: [String] {
        let vs = Set(model.devices.compactMap { dev -> String? in
            let v = dev.identity.manufacturer ?? dev.vendor
            return v.isEmpty ? nil : v
        })
        return Array(vs).sorted()
    }

    var body: some View {
        // One row when it all fits. Otherwise search, vendor and Online only
        // on top, with the group chips wrapping onto lines underneath.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                // Measured narrower than its 220 pt so one row still fits
                // at 1100 pt; spare room widens it back.
                searchField(minWidth: 190, idealWidth: 190, maxWidth: 220)
                chips
                if !allVendors.isEmpty {
                    Divider().frame(height: 18).background(NS.borderMid)
                    vendorMenu
                }
                Spacer()
                onlineToggle
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    searchField(minWidth: 140, idealWidth: 220, maxWidth: 220)
                    Spacer(minLength: 0)
                    if !allVendors.isEmpty { vendorMenu }
                    onlineToggle
                }
                FlowLayoutWiFi(spacing: 8) { chips }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(NS.bg1)
    }

    private func searchField(minWidth: CGFloat, idealWidth: CGFloat, maxWidth: CGFloat) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11)).foregroundStyle(NS.text3)
            TextField("search devices", text: $filters.search)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: minWidth, idealWidth: idealWidth, maxWidth: maxWidth)
        }
    }

    @ViewBuilder private var chips: some View {
        chip(label: "All groups",
             selected: filters.group == nil) { filters.group = nil }
        ForEach(allGroups, id: \.self) { g in
            chip(label: g.rawValue,
                 selected: filters.group == g) { filters.group = g }
        }
    }

    private var vendorMenu: some View {
        Menu {
            Button("All vendors") { filters.vendor = nil }
            Divider()
            ForEach(allVendors, id: \.self) { v in
                Button(v) { filters.vendor = v }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "tag")
                Text(filters.vendor ?? "Vendor")
            }
            .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var onlineToggle: some View {
        Toggle(isOn: $filters.aliveOnly) {
            Text("Online only").font(.system(size: 11))
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .fixedSize()
    }

    private func chip(label: String, selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? NS.bg0 : NS.text2)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(
                    Capsule().fill(selected ? NS.amber : NS.bg2)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Grid view

private struct GridView: View {
    let devices: [NetworkDevice]
    @Binding var selectedIP: String?

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(devices) { dev in
                    DeviceCard(device: dev, selected: selectedIP == dev.ip)
                        .onTapGesture { selectedIP = dev.ip }
                }
            }
            .padding(14)
        }
    }
}

private struct DeviceCard: View {
    let device: NetworkDevice
    let selected: Bool
    @State private var showSignals = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Image(systemName: device.icon)
                    .font(.system(size: 24))
                    .foregroundStyle(NS.amber)
                Spacer()
                if !device.identity.signals.isEmpty {
                    Button { showSignals.toggle() } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(NS.text3)
                    }
                    .buttonStyle(.plain)
                    .help("Why was this device classified this way?")
                    .popover(isPresented: $showSignals, arrowEdge: .trailing) {
                        SignalsPopover(device: device)
                    }
                }
                statusDot
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(NS.text1)
                    .lineLimit(1)
                Text(device.role.rawValue)
                    .font(.system(size: 10))
                    .foregroundStyle(NS.text3)
            }
            Divider().background(NS.borderMid)
            VStack(alignment: .leading, spacing: 3) {
                row("IP",     device.ip,         mono: true)
                    .hostMenu(device.ip)
                if !device.mac.isEmpty { row("MAC", device.mac, mono: true) }
                if let v = device.identity.manufacturer ?? (device.vendor.isEmpty ? nil : device.vendor) {
                    row("Vendor", v)
                }
                if let ms = device.pingMs {
                    HStack {
                        Text("Ping").font(.system(size: 10)).foregroundStyle(NS.text3)
                            .frame(width: 40, alignment: .leading)
                        Text(String(format: "%.0f ms", ms))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(ms < 5 ? NS.green : ms < 20 ? NS.amber : NS.red)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NS.bg2)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? NS.amber : NS.border, lineWidth: selected ? 1.5 : 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var statusDot: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 4) {
                Circle().fill(device.statusColor).frame(width: 8, height: 8)
                Text(device.statusLabel)
                    .font(.system(size: 9))
                    .foregroundStyle(device.statusColor)
            }
            if device.identity.signals.contains(.selfDetected) {
                Text("THIS MAC").font(.system(size: 8, weight: .bold)).foregroundStyle(NS.amber)
            } else if device.identity.signals.contains(.gatewayDetected) {
                Text("GATEWAY").font(.system(size: 8, weight: .bold)).foregroundStyle(NS.amber)
            }
        }
    }

    private func row(_ k: String, _ v: String, mono: Bool = false) -> some View {
        HStack {
            Text(k).font(.system(size: 10)).foregroundStyle(NS.text3)
                .frame(width: 40, alignment: .leading)
            Text(v)
                .font(.system(size: 10, design: mono ? .monospaced : .default))
                .foregroundStyle(NS.text2)
                .lineLimit(1)
            Spacer()
        }
    }
}

/// Why-this-classification popover. Shows the raw signals that voted for the
/// device's identity, with the highest-confidence one at the top. Useful when
/// the model picked a surprising label and you want to trust (or refute) it.
private struct SignalsPopover: View {
    let device: NetworkDevice

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(NS.amber)
                Text("How this device was identified")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(NS.text1)
            }
            Text(verbatim: "\(device.displayName) · \(device.ip)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(NS.text3)

            Divider().background(NS.borderMid)

            if device.identity.signals.isEmpty {
                Text("No discovery signals recorded.")
                    .font(.system(size: 11))
                    .foregroundStyle(NS.text3)
                    .padding(.vertical, 6)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(device.identity.signals.enumerated()), id: \.offset) { _, signal in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: signal.label)
                                .font(.system(size: 10, weight: .bold))
                                .tracking(0.4)
                                .foregroundStyle(NS.amber)
                            Text(verbatim: signal.summary)
                                .font(.system(size: 11))
                                .foregroundStyle(NS.text2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            Divider().background(NS.borderMid)
            Text(verbatim: "Final role: \(device.role.rawValue)")
                .font(.system(size: 10))
                .foregroundStyle(NS.text3)
        }
        .padding(12)
        .frame(width: 280)
        .background(NS.bg2)
    }
}

// MARK: - List view

private struct ListView: View {
    let devices: [NetworkDevice]
    @Binding var selectedIP: String?

    @State private var sortOrder: [KeyPathComparator<NetworkDevice>] = [
        KeyPathComparator(\NetworkDevice.ip)
    ]

    private var sorted: [NetworkDevice] {
        devices.sorted(using: sortOrder)
    }

    var body: some View {
        Table(sorted, selection: $selectedIP, sortOrder: $sortOrder) {
            TableColumn("Status") { d in
                HStack(spacing: 4) {
                    Circle().fill(d.statusColor).frame(width: 8, height: 8)
                    Text(d.statusLabel).font(.system(size: 11))
                }
            }
            .width(120)
            TableColumn("IP", value: \.ip) { d in
                HStack(spacing: 4) {
                    if d.identity.signals.contains(.gatewayDetected) {
                        Image(systemName: "house.fill").font(.system(size: 9)).foregroundStyle(NS.amber)
                    } else if d.identity.signals.contains(.selfDetected) {
                        Image(systemName: "laptopcomputer").font(.system(size: 9)).foregroundStyle(NS.amber)
                    }
                    Text(d.ip).font(.system(size: 11, design: .monospaced))
                }
                .hostMenu(d.ip)
            }
            .width(min: 120, ideal: 140)
            TableColumn("Name", value: \.displayName) { d in
                Text(d.displayName).font(.system(size: 11))
            }
            TableColumn("Role") { d in
                Label(d.role.rawValue, systemImage: d.icon)
                    .font(.system(size: 11))
            }
            .width(160)
            TableColumn("Vendor") { d in
                Text(d.identity.manufacturer ?? d.vendor).font(.system(size: 11))
            }
            TableColumn("MAC") { d in
                Text(d.mac).font(.system(size: 11, design: .monospaced)).foregroundStyle(NS.text2)
            }
            .width(140)
            TableColumn("Ping") { d in
                Text(d.pingMs.map { String(format: "%.0f ms", $0) } ?? "—")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(d.pingMs.map { $0 < 5 ? NS.green : $0 < 20 ? NS.amber : NS.red } ?? NS.text3)
            }
            .width(70)
            TableColumn("Last seen") { d in
                Text(d.lastSeen.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 11))
                    .foregroundStyle(NS.text3)
            }
            .width(90)
        }
    }
}

// MARK: - Visual constellation

private struct VisualView: View {
    @ObservedObject var model: NetworkMapModel
    let devices: [NetworkDevice]
    @Binding var selectedIP: String?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.clear

                let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                let positioned = layout(devices: devices, in: geo.size, center: center)

                // Edges
                ForEach(positioned) { p in
                    Path { path in
                        path.move(to: center)
                        path.addLine(to: p.pos)
                    }
                    .stroke(edgeColor(p.device.pingMs).opacity(0.35),
                            lineWidth: edgeWidth(p.device.pingMs))
                }

                // Gateway node (center)
                CenterNode(device: gatewayDevice, selected: selectedIP == gatewayDevice?.ip)
                    .position(center)
                    .onTapGesture {
                        if let ip = gatewayDevice?.ip { selectedIP = ip }
                    }

                // Devices on the constellation
                ForEach(positioned) { p in
                    NodeChip(device: p.device, selected: selectedIP == p.device.ip)
                        .position(p.pos)
                        .onTapGesture { selectedIP = p.device.ip }
                }

                // Legend bottom-left
                legend
                    .position(x: 110, y: geo.size.height - 50)
            }
            .background(NS.bg0)
        }
    }

    private var gatewayDevice: NetworkDevice? {
        if let gw = model.gatewayIP {
            return model.devices.first { $0.ip == gw }
        }
        return nil
    }

    // MARK: Layout

    private struct PositionedNode: Identifiable {
        let id: String
        let device: NetworkDevice
        let pos: CGPoint
    }

    private func layout(devices: [NetworkDevice], in size: CGSize, center: CGPoint) -> [PositionedNode] {
        // Exclude gateway (it's drawn at center) and any selfless duplicates
        let nodes = devices.filter { $0.ip != model.gatewayIP }
        // Bucket by group
        let groups = Dictionary(grouping: nodes, by: { $0.role.group })
        let ordered = DeviceGroup.allCases.compactMap { g -> (DeviceGroup, [NetworkDevice])? in
            guard let arr = groups[g], !arr.isEmpty else { return nil }
            return (g, arr)
        }

        let baseRadius = max(160, min(size.width, size.height) / 2.4)
        let nodesPerArc = max(ordered.map { $0.1.count }.max() ?? 1, 1)
        let radiusStep: CGFloat = 30
        // Allow up to 3 rings per group, then more rings as we add nodes.
        // Each device in a group is placed at increasing radius along the
        // group's anchor angle ± a small angular spread.

        var out: [PositionedNode] = []
        let groupAngleSpread: Double = .pi / Double(max(ordered.count, 1)) * 0.8

        for (g, arr) in ordered {
            let anchor = g.anchorAngle
            let count = arr.count
            for (idx, dev) in arr.enumerated() {
                // Fan within the group's slice; first device sits on the anchor,
                // then alternate to either side, stepping radius outward as we go.
                let depth = idx / 5
                let posInRing = idx % 5
                let spreadIdx = posInRing - 2 // -2,-1,0,1,2
                let angle = anchor + groupAngleSpread * Double(spreadIdx) / 4.0
                let radius = baseRadius + CGFloat(depth) * radiusStep
                let x = center.x + radius * CGFloat(cos(angle))
                let y = center.y + radius * CGFloat(sin(angle))
                out.append(PositionedNode(id: dev.ip, device: dev, pos: CGPoint(x: x, y: y)))
            }
            _ = count; _ = nodesPerArc  // reserved for future tuning
        }
        return out
    }

    private func edgeColor(_ ms: Double?) -> Color {
        guard let ms = ms else { return NS.text4 }
        if ms < 5  { return NS.green }
        if ms < 20 { return NS.amber }
        return NS.red
    }

    private func edgeWidth(_ ms: Double?) -> CGFloat {
        guard let ms = ms else { return 0.5 }
        if ms < 5  { return 1.5 }
        if ms < 20 { return 1.1 }
        return 0.7
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Latency").font(.system(size: 9, weight: .semibold)).foregroundStyle(NS.text3)
            legendRow(color: NS.green, label: "< 5 ms")
            legendRow(color: NS.amber, label: "5 – 20 ms")
            legendRow(color: NS.red,   label: "> 20 ms")
        }
        .padding(8)
        .background(NS.bg1.opacity(0.85))
        .cornerRadius(6)
    }

    private func legendRow(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            Rectangle().fill(color).frame(width: 12, height: 2)
            Text(label).font(.system(size: 9)).foregroundStyle(NS.text2)
        }
    }
}

private struct CenterNode: View {
    let device: NetworkDevice?
    let selected: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(NS.amber.opacity(0.10))
                .frame(width: 96, height: 96)
            Circle()
                .strokeBorder(selected ? NS.amber : NS.amber.opacity(0.4), lineWidth: selected ? 2 : 1)
                .frame(width: 96, height: 96)
            VStack(spacing: 3) {
                Image(systemName: "wifi.router")
                    .font(.system(size: 28))
                    .foregroundStyle(NS.amber)
                Text(device?.ip ?? "no gateway")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(NS.text2)
                if let m = device?.identity.manufacturer ?? device?.vendor, !m.isEmpty {
                    Text(m).font(.system(size: 9)).foregroundStyle(NS.text3)
                }
            }
        }
    }
}

private struct NodeChip: View {
    let device: NetworkDevice
    let selected: Bool

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle()
                    .fill(NS.bg2)
                    .frame(width: 38, height: 38)
                Circle()
                    .strokeBorder(selected ? NS.amber : device.statusColor.opacity(0.6),
                                  lineWidth: selected ? 2 : 1)
                    .frame(width: 38, height: 38)
                Image(systemName: device.icon)
                    .font(.system(size: 16))
                    .foregroundStyle(NS.text1)
                if device.identity.signals.contains(.selfDetected) {
                    Text("YOU")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(NS.bg0)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(NS.amber))
                        .offset(y: 22)
                }
            }
            Text(device.displayName)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(NS.text1)
                .lineLimit(1)
                .frame(maxWidth: 110)
            Text(device.ip)
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(NS.text3)
        }
    }
}

// MARK: - Detail panel

private struct DeviceDetailPanel: View {
    let device: NetworkDevice?
    @ObservedObject var model: NetworkMapModel

    var body: some View {
        if let d = device { content(d) } else { placeholder }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 36))
                .foregroundStyle(NS.text4)
            Text("Select a device")
                .font(.system(size: 12))
                .foregroundStyle(NS.text3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NS.bg1)
    }

    private func content(_ d: NetworkDevice) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(d)
                quickActions(d)
                identityCard(d)
                signalsCard(d)
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(NS.bg1)
    }

    private func header(_ d: NetworkDevice) -> some View {
        HStack(spacing: 10) {
            Image(systemName: d.icon)
                .font(.system(size: 32))
                .foregroundStyle(NS.amber)
                .frame(width: 44, height: 44)
                .background(NS.bg2)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(d.displayName).font(.system(size: 14, weight: .semibold))
                Text(d.role.rawValue).font(.system(size: 11)).foregroundStyle(NS.text3)
            }
        }
    }

    private func quickActions(_ d: NetworkDevice) -> some View {
        HStack(spacing: 6) {
            actionButton("doc.on.doc", "Copy", busy: false) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(d.ip, forType: .string)
            }
            actionButton("globe", "Open", busy: false) {
                if let u = URL(string: "http://\(d.ip)") { NSWorkspace.shared.open(u) }
            }
            // Re-ping this specific device. The model updates pingMs +
            // status in place, so the Identity card refreshes live.
            actionButton("dot.radiowaves.left.and.right",
                         model.pinging.contains(d.ip) ? "Pinging…" : "Ping",
                         busy: model.pinging.contains(d.ip)) {
                Task { await model.repingDevice(ip: d.ip) }
            }
        }
    }

    private func actionButton(_ icon: String,
                              _ label: String,
                              busy: Bool,
                              _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                if busy {
                    ProgressView().controlSize(.small).scaleEffect(0.7).frame(height: 12)
                } else {
                    Image(systemName: icon).font(.system(size: 11))
                }
                Text(label).font(.system(size: 9))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(NS.bg2)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private func identityCard(_ d: NetworkDevice) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Identity")
            kv("Status",       d.statusLabel,                                 mono: false, color: d.statusColor)
            kv("IP",           d.ip)
            if !d.mac.isEmpty           { kv("MAC",          d.mac) }
            if let v = d.identity.manufacturer ?? (d.vendor.isEmpty ? nil : d.vendor) {
                kv("Manufacturer", v, mono: false)
            }
            if let m = d.identity.model { kv("Model",        m, mono: false) }
            kv("Role",         d.role.rawValue,                               mono: false)
            if let ms = d.pingMs        { kv("Ping",         String(format: "%.1f ms", ms)) }
            kv("Last seen",    d.lastSeen.formatted(date: .omitted, time: .standard))
            if !d.openPorts.isEmpty {
                kv("Open ports",   d.openPorts.map(String.init).joined(separator: ", "))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NS.bg2)
        .cornerRadius(8)
    }

    private func signalsCard(_ d: NetworkDevice) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Identification signals (\(d.identity.signals.count))")
            if d.identity.signals.isEmpty {
                Text("None — vendor inferred from MAC only.")
                    .font(.system(size: 11)).foregroundStyle(NS.text3)
            } else {
                ForEach(Array(d.identity.signals.enumerated()), id: \.offset) { _, sig in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: signalIcon(sig))
                            .font(.system(size: 10))
                            .foregroundStyle(NS.amber)
                            .frame(width: 14)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(sig.label).font(.system(size: 11, weight: .medium)).foregroundStyle(NS.text2)
                            Text(sig.summary).font(.system(size: 10, design: .monospaced)).foregroundStyle(NS.text3)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NS.bg2)
        .cornerRadius(8)
    }

    private func signalIcon(_ s: IdentitySignal) -> String {
        switch s {
        case .mDNS:             return "bonjour"
        case .ssdp:             return "antenna.radiowaves.left.and.right"
        case .netbios:          return "pc"
        case .reverseDNS:       return "arrow.triangle.swap"
        case .httpBanner:       return "globe"
        case .oui:              return "tag"
        case .ubnt:             return "wave.3.right"
        case .selfDetected:     return "laptopcomputer"
        case .gatewayDetected:  return "house"
        }
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(NS.text3)
    }

    private func kv(_ k: String, _ v: String, mono: Bool = true, color: Color? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k)
                .font(.system(size: 10))
                .foregroundStyle(NS.text3)
                .frame(width: 90, alignment: .leading)
            Text(v)
                .font(.system(size: 11, design: mono ? .monospaced : .default))
                .foregroundStyle(color ?? NS.text2)
                .textSelection(.enabled)
            Spacer()
        }
    }
}
