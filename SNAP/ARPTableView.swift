// ARPTableView.swift
// SNAP — ARP Table Viewer (Local Device Discovery)
// Created by Sevag Bardakjian
// Copyright © 2025 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
//
// Reads the local ARP cache via `arp -an` and surfaces every L2 neighbor on
// the subnet with vendor lookup (OUI), hostname (reverse DNS), and a hint
// flag for the gateway. An optional ARP sweep pings every host on /24 to
// repopulate the cache for stale entries.

import SwiftUI

struct ARPTableView: View {
    @State private var entries: [ARPEntry] = []
    @State private var isLoading = false
    @State private var isSweeping = false
    @State private var sweepProgress: Double = 0
    @State private var error = ""
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if !error.isEmpty { errorBar }
            Divider()
            content
        }
        .navigationTitle("ARP Table")
        .onAppear { reload() }
        .onTabVisibilityChange(shown: { reload() })   // fresh table on return
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right").foregroundStyle(.green)
            Text("ARP Table")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(NS.text1)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(NS.text3)
                TextField("filter", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
            }

            Text("\(filteredEntries.count) of \(entries.count) hosts")
                .font(.system(size: 11)).foregroundStyle(NS.text3)

            if isSweeping {
                ProgressView(value: sweepProgress)
                    .progressViewStyle(.linear)
                    .frame(width: 120)
            }

            Spacer()

            if !entries.isEmpty {
                ToolActionBar("ARP Table",
                              text: { exportText() },
                              csv:  { exportCSV() },
                              json: { exportJSON() })
            }

            Button(isSweeping ? "Sweeping…" : "Sweep /24") { sweep() }
                .buttonStyle(.bordered)
                .disabled(isSweeping || isLoading)

            Button(isLoading ? "Loading…" : "Refresh") { reload() }
                .buttonStyle(.borderedProminent)
                .disabled(isLoading)
                .keyboardShortcut("r", modifiers: .command)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(NS.bg0)
    }

    private var errorBar: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(error).foregroundStyle(.red).font(.caption)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(Color.red.opacity(0.05))
    }

    private var filteredEntries: [ARPEntry] {
        guard !filter.isEmpty else { return entries }
        let f = filter.lowercased()
        return entries.filter {
            $0.ip.lowercased().contains(f) ||
            $0.mac.lowercased().contains(f) ||
            ($0.hostname?.lowercased().contains(f) ?? false) ||
            ($0.vendor?.lowercased().contains(f) ?? false) ||
            $0.iface.lowercased().contains(f)
        }
    }

    private var content: some View {
        Group {
            if entries.isEmpty && !isLoading {
                EmptyStateView(title: "ARP Cache Empty",
                               systemImage: "antenna.radiowaves.left.and.right",
                               description: "Try Sweep /24 to ping every host on the local subnet and populate the cache.")
            } else {
                Table(filteredEntries) {
                    TableColumn("IP") { e in
                        HStack(spacing: 6) {
                            if e.isGateway {
                                Image(systemName: "house.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(NS.amber)
                                    .help("Default gateway")
                            }
                            Text(e.ip)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(NS.text1)
                                .textSelection(.enabled)
                        }
                        .hostMenu(e.ip)
                    }
                    .width(min: 110, ideal: 130)
                    TableColumn("MAC") { e in
                        Text(e.mac)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(NS.text2)
                            .textSelection(.enabled)
                    }
                    .width(min: 130, ideal: 150)
                    TableColumn("Vendor") { e in
                        Text(e.vendor ?? "—")
                            .font(.system(size: 11))
                            .foregroundStyle(NS.text2)
                    }
                    TableColumn("Hostname") { e in
                        Text(e.hostname ?? "—")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(NS.text3)
                            .textSelection(.enabled)
                    }
                    TableColumn("Iface") { e in
                        Text(e.iface).font(.system(size: 11, design: .monospaced)).foregroundStyle(NS.text3)
                    }
                    .width(60)
                }
            }
        }
    }

    // MARK: Loaders

    private func reload() {
        isLoading = true
        error = ""
        Task {
            let raw = await Shell.run("/usr/sbin/arp", args: ["-an"])
            let gw  = await Self.defaultGateway()
            var parsed = Self.parseARP(raw, gateway: gw)
            // Best-effort reverse DNS for the first 64 entries (cheap fan-out)
            parsed = await Self.attachHostnames(parsed)
            await MainActor.run {
                entries = parsed
                isLoading = false
            }
        }
    }

    private func sweep() {
        isSweeping = true
        sweepProgress = 0
        error = ""
        Task {
            // Determine local /24 from primary IPv4
            guard let net = Self.primaryIPv4Network() else {
                await MainActor.run {
                    error = "Could not determine local /24"
                    isSweeping = false
                }
                return
            }
            let prefix = net.prefix
            let total = 254.0
            // Chunked sweep — keep concurrent pings bounded so we don't spawn
            // 254 processes at once.
            let chunkSize = 32
            var completed = 0.0
            for batchStart in stride(from: 1, through: 254, by: chunkSize) {
                let batchEnd = min(batchStart + chunkSize - 1, 254)
                await withTaskGroup(of: Void.self) { group in
                    for i in batchStart...batchEnd {
                        let target = "\(prefix).\(i)"
                        group.addTask {
                            _ = await Shell.run("/sbin/ping", args: ["-c", "1", "-W", "300", "-q", target])
                        }
                    }
                }
                completed += Double(batchEnd - batchStart + 1)
                await MainActor.run { sweepProgress = completed / total }
            }
            await MainActor.run {
                isSweeping = false
                sweepProgress = 1.0
            }
            reload()
        }
    }

    // MARK: Parsers

    static func parseARP(_ raw: String, gateway: String?) -> [ARPEntry] {
        // Sample line:
        // ? (192.168.1.1) at 8c:85:90:aa:bb:cc on en0 ifscope [ethernet]
        var out: [ARPEntry] = []
        for line in raw.split(separator: "\n").map(String.init) {
            guard let ip = capture(line, between: "(", and: ")"),
                  let macRange = line.range(of: " at "),
                  let onRange  = line.range(of: " on ") else { continue }
            let mac = String(line[macRange.upperBound..<onRange.lowerBound])
            if mac.contains("incomplete") { continue }
            let rest = line[onRange.upperBound...]
            let iface = rest.split(separator: " ").first.map(String.init) ?? "?"
            let vendor = OUIDatabase.lookup(mac)
            let isGateway = (gateway != nil && gateway == ip)
            out.append(ARPEntry(ip: ip, mac: mac, vendor: vendor, hostname: nil, iface: iface, isGateway: isGateway))
        }
        // Stable sort by IP numeric
        return out.sorted { ipNumeric($0.ip) < ipNumeric($1.ip) }
    }

    private static func capture(_ s: String, between a: String, and b: String) -> String? {
        guard let r1 = s.range(of: a), let r2 = s.range(of: b, range: r1.upperBound..<s.endIndex)
        else { return nil }
        return String(s[r1.upperBound..<r2.lowerBound])
    }

    private static func ipNumeric(_ ip: String) -> UInt32 {
        let parts = ip.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4 else { return 0 }
        return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
    }

    private static func defaultGateway() async -> String? {
        RouteInfo.defaultGateway()
    }

    private static func attachHostnames(_ in_: [ARPEntry]) async -> [ARPEntry] {
        // Reverse DNS for the first N (limit to keep things snappy)
        var entries = in_
        let limit = min(entries.count, 64)
        await withTaskGroup(of: (Int, String?).self) { group in
            for i in 0..<limit {
                let ip = entries[i].ip
                group.addTask {
                    let h = await Self.reverseDNS(ip)
                    return (i, h)
                }
            }
            for await (i, h) in group {
                if let h = h, !h.isEmpty {
                    entries[i].hostname = h
                }
            }
        }
        return entries
    }

    private static func reverseDNS(_ ip: String) async -> String? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo()
                hints.ai_family   = AF_INET
                hints.ai_socktype = SOCK_STREAM
                var res: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(ip, nil, &hints, &res) == 0, let r = res else {
                    cont.resume(returning: nil); return
                }
                defer { freeaddrinfo(r) }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let rc = getnameinfo(r.pointee.ai_addr, r.pointee.ai_addrlen,
                                     &host, socklen_t(host.count),
                                     nil, 0, NI_NAMEREQD)
                cont.resume(returning: rc == 0 ? String(cString: host) : nil)
            }
        }
    }

    private static func primaryIPv4Network() -> (prefix: String, iface: String)? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        var cur = ifaddr
        while let c = cur {
            defer { cur = c.pointee.ifa_next }
            let name = String(cString: c.pointee.ifa_name)
            if !(name.hasPrefix("en")) { continue }
            // ifa_addr can be NULL for some pseudo-interfaces
            guard let sa = c.pointee.ifa_addr, Int32(sa.pointee.sa_family) == AF_INET else { continue }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
            let ip = String(cString: buf)
            if ip == "127.0.0.1" || ip == "0.0.0.0" { continue }
            let octets = ip.split(separator: ".")
            guard octets.count == 4 else { continue }
            return ("\(octets[0]).\(octets[1]).\(octets[2])", name)
        }
        return nil
    }

    // MARK: Export

    private func exportText() -> String {
        var out = "ARP Table — \(entries.count) hosts\n"
        out += String(repeating: "—", count: 78) + "\n"
        out += String(format: "%-16s %-19s %-10s %-30s %s\n",
                      "IP", "MAC", "iface", "vendor", "hostname")
        for e in entries {
            out += String(format: "%-16s %-19s %-10s %-30s %s\n",
                          (e.ip as NSString).utf8String!,
                          (e.mac as NSString).utf8String!,
                          (e.iface as NSString).utf8String!,
                          ((e.vendor ?? "") as NSString).utf8String!,
                          ((e.hostname ?? "") as NSString).utf8String!)
        }
        return out
    }

    private func exportCSV() -> String {
        var out = "ip,mac,iface,vendor,hostname,is_gateway\n"
        for e in entries {
            out += "\(e.ip),\(e.mac),\(e.iface),\(e.vendor ?? ""),\(e.hostname ?? ""),\(e.isGateway)\n"
        }
        return out
    }

    private func exportJSON() -> String {
        let arr: [[String: Any]] = entries.map { e in
            [
                "ip": e.ip,
                "mac": e.mac,
                "iface": e.iface,
                "vendor": e.vendor as Any,
                "hostname": e.hostname as Any,
                "is_gateway": e.isGateway
            ]
        }
        let payload: [String: Any] = [
            "tool": "ARP Table",
            "exported_at": ISO8601DateFormatter().string(from: Date()),
            "entries": arr
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}

// MARK: - Row model

struct ARPEntry: Identifiable, Hashable {
    var id: String { ip + mac }
    let ip: String
    let mac: String
    var vendor: String?
    var hostname: String?
    let iface: String
    let isGateway: Bool
}

// OUIDatabase was extracted to OUIDatabase.swift in v1.2.1 and shared with
// the Network Map. Its public surface (`OUIDatabase.lookup(_:)`) is unchanged.
