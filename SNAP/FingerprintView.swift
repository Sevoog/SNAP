// FingerprintView.swift
// SNAP — Network Fingerprint
// Created by Sevag Bardakjian
//
// v1.3: extended with enterprise probes — SNMP-public probe (uses the
// SNMP v2c client) and a vendor classifier that fuses SSH banner, HTTP
// Server header, SNMP sysDescr/sysObjectID, and the OUI registry into
// a single "this is probably …" verdict shown at the top of results.

import SwiftUI
import Network

struct FingerprintClassification {
    var vendor: String?
    var model: String?
    var role: DeviceRole = .unknown
    var basis: [String] = []        // human-readable reasons we landed here

    var isEmpty: Bool { vendor == nil && model == nil && role == .unknown }
    var displayLine: String {
        var parts: [String] = []
        if let v = vendor { parts.append(v) }
        if let m = model  { parts.append(m) }
        if role != .unknown { parts.append("(\(role.rawValue))") }
        return parts.joined(separator: " · ")
    }
}

struct FingerprintView: View {
    @State private var host = ""
    @State private var results: [String: String] = [:]
    @State private var isRunning = false
    @State private var log = ""
    @State private var classification = FingerprintClassification()
    @State private var snmpCommunity = "public"
    @State private var probeSNMP = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "person.badge.key").foregroundStyle(.blue)
                TextField("Hostname or IP", text: $host)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                Toggle("SNMP probe", isOn: $probeSNMP)
                    .toggleStyle(.checkbox)
                if probeSNMP {
                    TextField("community", text: $snmpCommunity)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }
                Spacer()
                if !results.isEmpty {
                    ToolActionBar("Fingerprint", text: {
                        var s = "Fingerprint — \(host)\n"
                        if !classification.isEmpty { s += "Identified: \(classification.displayLine)\n" }
                        s += "\n" + results.keys.sorted().map { "\($0): \(results[$0] ?? "")" }.joined(separator: "\n")
                        return s
                    })
                }
                if isRunning {
                    ProgressView().controlSize(.small)
                    Text("Fingerprinting...").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Fingerprint") { startFingerprint() }
                        .buttonStyle(.borderedProminent)
                        .disabled(host.isEmpty)
                        .keyboardShortcut(.return)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(NS.bg0)

            if !classification.isEmpty { classificationBanner }

            Divider()

            HSplitView {
                VStack(alignment: .leading, spacing: 16) {
                    if results.isEmpty {
                        EmptyStateView(title: "No Data", systemImage: "person.badge.key", description: "Enter a host to fingerprint")
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(Array(results.keys.sorted()), id: \.self) { key in
                                    fingerprintRow(key: key, value: results[key] ?? "")
                                    Divider()
                                }
                            }
                            .padding(16)
                        }
                    }
                }
                .frame(minWidth: 300)

                VStack(alignment: .leading) {
                    Text("Probe Log").font(.headline).padding([.horizontal, .top])
                    ScrollView {
                        Text(log.isEmpty ? "Probe log will appear here" : log)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    .background(NS.bg3)
                }
                .frame(minWidth: 260)
            }
        }
        .tabNavigationTitle(.fingerprint)
    }

    private var classificationBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: classification.role.icon)
                .font(.system(size: 20))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(classification.displayLine)
                    .font(.system(size: 14, weight: .semibold))
                Text(classification.basis.joined(separator: " • "))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.orange.opacity(0.08))
    }

    private func startFingerprint() {
        results = [:]
        log = ""
        isRunning = true
        classification = FingerprintClassification()
        let target = host
        let useSNMP = probeSNMP
        let community = snmpCommunity.isEmpty ? "public" : snmpCommunity

        Task {
            var gathered: [String: String] = [:]
            var logLines = ""

            // DNS — native UDP/53 via DNSWire (was three `/usr/bin/dig` shell-outs).
            logLines += "→ Resolving \(target)...\n"
            let resolver = "1.1.1.1"

            let ips: [String] = (try? DNSWire.query(server: resolver, name: target, type: .a))?
                .answers.filter { $0.type == "A" }.map(\.value) ?? []
            if let firstIP = ips.first {
                gathered["IPv4 Address"] = firstIP
                logLines += "  IPv4: \(firstIP)\n"
            }
            if let v6 = (try? DNSWire.query(server: resolver, name: target, type: .aaaa))?
                .answers.first(where: { $0.type == "AAAA" })?.value {
                gathered["IPv6 Address"] = v6
            }

            // Reverse DNS — build the in-addr.arpa name and query PTR.
            if let ip = ips.first {
                let arpa = ip.split(separator: ".").reversed().joined(separator: ".") + ".in-addr.arpa"
                if let ptr = (try? DNSWire.query(server: resolver, name: arpa, type: .ptr))?
                    .answers.first(where: { $0.type == "PTR" })?.value {
                    gathered["Reverse DNS"] = ptr
                    logLines += "  Reverse DNS: \(ptr)\n"
                }
            }

            // HTTP banner
            logLines += "→ HTTP probe...\n"
            if let url = URL(string: "http://\(target)") {
                var req = URLRequest(url: url)
                req.timeoutInterval = 5
                if let (_, resp) = try? await URLSession.shared.data(for: req),
                   let httpResp = resp as? HTTPURLResponse {
                    gathered["HTTP Status"] = "\(httpResp.statusCode)"
                    if let server = httpResp.value(forHTTPHeaderField: "Server") {
                        gathered["HTTP Server"] = server
                        logLines += "  Server: \(server)\n"
                    }
                    if let powered = httpResp.value(forHTTPHeaderField: "X-Powered-By") {
                        gathered["X-Powered-By"] = powered
                    }
                }
            }

            // HTTPS banner
            if let url = URL(string: "https://\(target)") {
                var req = URLRequest(url: url)
                req.timeoutInterval = 5
                if let (_, resp) = try? await URLSession.shared.data(for: req),
                   let httpResp = resp as? HTTPURLResponse {
                    gathered["HTTPS Status"] = "\(httpResp.statusCode)"
                }
            }

            // SSH banner (port 22)
            logLines += "→ SSH banner check...\n"
            let sshBanner = await readBanner(host: target, port: 22)
            if !sshBanner.isEmpty {
                gathered["SSH Banner"] = sshBanner
                logLines += "  SSH: \(sshBanner)\n"
            }

            // FTP banner
            let ftpBanner = await readBanner(host: target, port: 21)
            if !ftpBanner.isEmpty { gathered["FTP Banner"] = ftpBanner }

            // SMTP banner
            let smtpBanner = await readBanner(host: target, port: 25)
            if !smtpBanner.isEmpty { gathered["SMTP Banner"] = smtpBanner }

            // TTL-based OS hint
            let pingOut = await Shell.run("/sbin/ping", args: ["-c", "1", "-t", "1", target])
            if let ttlRange = pingOut.range(of: "ttl=") {
                let sub = String(pingOut[ttlRange.upperBound...]); let ttlStr = sub.prefix(3)
                if let ttl = Int(ttlStr) {
                    let osHint = ttl <= 64 ? "Linux/Unix/macOS (TTL≤64)" :
                                 ttl <= 128 ? "Windows (TTL≤128)" : "Network device (TTL>128)"
                    gathered["OS Guess (TTL)"] = "\(osHint) [TTL=\(ttl)]"
                    logLines += "  TTL=\(ttl) → \(osHint)\n"
                }
            }

            // SNMP probe (v1.3) — sysDescr + sysObjectID with the provided
            // community. Two retries × 2s timeout means at most ~4s if the
            // host doesn't speak SNMP, then we move on.
            if useSNMP {
                logLines += "→ SNMP probe (community=\(community))...\n"
                let client = SNMPClient(host: target,
                                        community: community,
                                        version: .v2c,
                                        timeout: 2.0,
                                        retries: 1)
                do {
                    let vbs = try await client.get([SNMPOID.sysDescr,
                                                    SNMPOID.sysObjectID,
                                                    SNMPOID.sysName])
                    let byOID = Dictionary(uniqueKeysWithValues: vbs.map { ($0.oid, $0.value) })
                    if let d = byOID[SNMPOID.sysDescr] {
                        gathered["SNMP sysDescr"] = d.description
                        logLines += "  sysDescr: \(d.description)\n"
                    }
                    if let o = byOID[SNMPOID.sysObjectID] {
                        gathered["SNMP sysObjectID"] = o.description
                        logLines += "  sysObjectID: \(o.description)\n"
                    }
                    if let n = byOID[SNMPOID.sysName] {
                        gathered["SNMP sysName"] = n.description
                    }
                } catch {
                    logLines += "  (no SNMP response — \(error))\n"
                }
            }

            // Vendor classification — fuse SSH banner, HTTP Server header,
            // SNMP sysDescr/sysObjectID, and (when available) OUI into a
            // single best-guess role+vendor verdict.
            let verdict = classifyVendor(gathered)
            if !verdict.isEmpty {
                gathered["Identified As"] = verdict.displayLine
                logLines += "→ Classified: \(verdict.displayLine)\n"
            }

            logLines += "✓ Fingerprint complete.\n"
            await MainActor.run {
                results = gathered
                log = logLines
                classification = verdict
                isRunning = false
            }
        }
    }

    /// Fuses every signal we've gathered into a single best-guess vendor +
    /// model + role. Higher-confidence sources (SNMP sysObjectID, SSH banner)
    /// win over lower-confidence ones (HTTP Server header).
    private func classifyVendor(_ signals: [String: String]) -> FingerprintClassification {
        var c = FingerprintClassification()

        // 1. SNMP sysObjectID — strongest signal. We can map most enterprise
        //    OIDs to a precise vendor + role.
        if let oidStr = signals["SNMP sysObjectID"],
           let oid = OID(string: oidStr),
           let m = SysObjectIDDatabase.match(oid) {
            c.vendor = m.vendor
            c.model = m.model
            c.role = m.role
            c.basis.append("sysObjectID \(oidStr)")
        }

        // 2. SNMP sysDescr — often contains exact model + firmware string.
        //    Examples:
        //      "Cisco IOS Software, C2960X Software (C2960X-UNIVERSALK9-M), Version 15.2(7)…"
        //      "Juniper Networks, Inc. ex2300 Ethernet Switch, kernel JUNOS …"
        //      "FortiGate-100F"
        //      "Linux router 5.10.0-19-amd64 …"
        if let d = signals["SNMP sysDescr"] {
            classifyBanner(d, into: &c, label: "sysDescr")
        }

        // 3. SSH banner — vendor-revealing strings come from this surprisingly
        //    often in enterprise gear ("SSH-2.0-Cisco_1.25", "ROSSH" =
        //    Mikrotik, "SSH-2.0-OpenSSH_for_HPN…" = HP/HPE).
        if let ssh = signals["SSH Banner"] {
            classifyBanner(ssh, into: &c, label: "SSH banner")
        }

        // 4. HTTP Server header — lower confidence, but useful for embedded
        //    devices ("HP-ChaiSOE" = HP printer, "GoAhead-Webs" = generic
        //    embedded, "lighttpd" alone is no help).
        if let srv = signals["HTTP Server"] {
            classifyBanner(srv, into: &c, label: "HTTP Server")
        }

        // 5. Hostname / Reverse DNS — sometimes contains the model.
        if let rev = signals["Reverse DNS"] {
            classifyBanner(rev, into: &c, label: "rDNS")
        }

        return c
    }

    /// Searches a banner string for vendor + role keywords. Updates the
    /// classification only for fields we don't already know.
    private func classifyBanner(_ banner: String,
                                into c: inout FingerprintClassification,
                                label: String) {
        let s = banner.lowercased()

        let vendorPatterns: [(String, String, DeviceRole)] = [
            // (substring, vendor name, default role if not already set)
            ("palo alto", "Palo Alto Networks", .firewall),
            ("fortigate",  "Fortinet",            .firewall),
            ("fortinet",   "Fortinet",            .firewall),
            ("sonicwall",  "SonicWall",           .firewall),
            ("watchguard", "WatchGuard",          .firewall),
            ("sophos",     "Sophos",              .firewall),
            ("pfsense",    "pfSense",             .firewall),
            ("opnsense",   "OPNsense",            .firewall),
            ("checkpoint", "Check Point",         .firewall),
            ("check point","Check Point",         .firewall),
            ("juniper",    "Juniper Networks",    .networkSwitch),
            ("junos",      "Juniper Networks",    .networkSwitch),
            ("arista",     "Arista Networks",     .networkSwitch),
            ("nx-os",      "Cisco",               .networkSwitch),
            ("ios-xe",     "Cisco",               .networkSwitch),
            ("ios-xr",     "Cisco",               .router),
            ("cisco ios",  "Cisco",               .networkSwitch),
            ("cisco",      "Cisco",               .networkSwitch),
            ("meraki",     "Cisco Meraki",        .accessPoint),
            ("aruba",      "Aruba Networks",      .accessPoint),
            ("arubanet",   "Aruba Networks",      .accessPoint),
            ("hp-chaisoe", "HP",                  .printer),
            ("jetdirect",  "HP",                  .printer),
            ("hewlett",    "HPE",                 .networkSwitch),
            ("comware",    "H3C",                 .networkSwitch),
            ("h3c",        "H3C",                 .networkSwitch),
            ("rossh",      "MikroTik",            .router),
            ("mikrotik",   "MikroTik",            .router),
            ("routeros",   "MikroTik",            .router),
            ("ubnt",       "Ubiquiti",            .accessPoint),
            ("unifi",      "Ubiquiti",            .accessPoint),
            ("edgeos",     "Ubiquiti",            .router),
            ("edgemax",    "Ubiquiti",            .router),
            ("ruckus",     "Ruckus",              .accessPoint),
            ("extreme",    "Extreme Networks",    .networkSwitch),
            ("brocade",    "Brocade",             .networkSwitch),
            ("dell switch","Dell",                .networkSwitch),
            ("force10",    "Dell Force10",        .networkSwitch),
            ("zyxel",      "Zyxel",               .router),
            ("draytek",    "DrayTek",             .router),
            ("f5 networks","F5 Networks",         .loadBalancer),
            ("big-ip",     "F5 Networks",         .loadBalancer),
            ("netscaler",  "Citrix",              .loadBalancer),
            ("a10 networks","A10 Networks",       .loadBalancer),
            ("polycom",    "Polycom",             .voipPhone),
            ("yealink",    "Yealink",             .voipPhone),
            ("grandstream","Grandstream",         .voipPhone),
            ("avaya",      "Avaya",               .voipPhone),
            ("synology",   "Synology",            .nas),
            ("qnap",       "QNAP",                .nas),
            ("openssh_for_hpn", "HPE",            .networkSwitch),
        ]

        for (needle, vendor, role) in vendorPatterns where s.contains(needle) {
            if c.vendor == nil { c.vendor = vendor }
            if c.role == .unknown { c.role = role }
            c.basis.append("\(label) → \(vendor)")
            return
        }

        // OS hints last (lowest priority — only set role if nothing else has).
        if s.contains("linux") && c.role == .unknown { c.role = .linux }
        if s.contains("windows") && c.role == .unknown { c.role = .windowsPC }
    }

    /// Grab a service banner by connecting and reading whatever the server
    /// emits on connect (SSH/FTP/SMTP greet immediately). Native NWConnection
    /// replaces the `/usr/bin/nc` shell-out. 3-second budget.
    private func readBanner(host: String, port: Int) async -> String {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(exactly: port) ?? 0) else { return "" }
        return await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            let lock = NSLock(); var done = false
            func finish(_ s: String) {
                lock.lock(); let already = done; done = true; lock.unlock()
                if already { return }
                conn.cancel()
                cont.resume(returning: String(s.prefix(200)))
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 512) { data, _, _, _ in
                        let banner = data.flatMap { String(data: $0, encoding: .utf8) }?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        finish(banner)
                    }
                case .failed, .cancelled:
                    finish("")
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { finish("") }
        }
    }

    @ViewBuilder
    private func fingerprintRow(key: String, value: String) -> some View {
        let row = HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconForKey(key))
                .foregroundStyle(.blue)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(key).font(.caption.bold()).foregroundStyle(.secondary)
                Text(value).font(.subheadline).textSelection(.enabled)
            }
            Spacer()
        }
        .padding(.vertical, 4)

        // Only the three IP-bearing keys get a host context menu — others
        // (HTTP Server, OS Guess, etc.) wouldn't make sense to right-click as hosts.
        let isHost = key == "IPv4 Address" || key == "IPv6 Address" || key == "Reverse DNS"
        if isHost && !value.isEmpty {
            row.hostMenu(value)
        } else {
            row
        }
    }

    private func iconForKey(_ key: String) -> String {
        switch key {
        case _ where key.contains("IPv4"): return "4.circle"
        case _ where key.contains("IPv6"): return "6.circle"
        case _ where key.contains("HTTP"): return "globe"
        case _ where key.contains("SSH"):  return "terminal"
        case _ where key.contains("OS"):   return "desktopcomputer"
        case _ where key.contains("DNS"):  return "magnifyingglass"
        case _ where key.contains("Server"): return "server.rack"
        default: return "info.circle"
        }
    }
}
