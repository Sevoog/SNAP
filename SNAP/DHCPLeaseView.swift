// DHCPLeaseView.swift
// SNAP — DHCP Lease Inspector
// Created by Sevag Bardakjian
// Copyright © 2025 Sevag Bardakjian. All rights reserved.
//
// Surfaces the current DHCP lease on each network interface using
// `ipconfig getpacket` — same data macOS itself uses. Useful for confirming
// DNS, gateway, lease times, and DHCP option fields without leaving SNAP.

import SwiftUI

struct DHCPLeaseView: View {
    @State private var leases: [DHCPLease] = []
    @State private var isLoading = false
    @State private var error = ""
    @State private var selectedIface: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if !error.isEmpty { errorBar }
            Divider()
            if leases.isEmpty && !isLoading {
                EmptyStateView(title: "No DHCP Leases",
                               systemImage: "doc.text.below.ecg",
                               description: "No active DHCP-assigned interfaces detected. Statically-configured interfaces won't appear here.")
            } else {
                HSplitView {
                    interfaceList.frame(minWidth: 200, idealWidth: 220)
                    leaseDetail.frame(minWidth: 360)
                }
            }
        }
        .navigationTitle("DHCP Leases")
        .onAppear { reload() }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text.below.ecg").foregroundStyle(.blue)
            Text("DHCP Lease Inspector")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(NS.text1)
            Spacer()
            if !leases.isEmpty {
                ToolActionBar("DHCP Leases",
                              text: { exportText() },
                              json: { exportJSON() })
            }
            Button(isLoading ? "Loading…" : "Refresh") { reload() }
                .buttonStyle(.bordered)
                .disabled(isLoading)
                .keyboardShortcut("r", modifiers: .command)
            if isLoading { ProgressView().controlSize(.small) }
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

    private var interfaceList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(leases) { lease in
                Button {
                    selectedIface = lease.iface
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: lease.hasLease ? "checkmark.circle.fill" : "questionmark.circle")
                            .foregroundStyle(lease.hasLease ? NS.green : NS.text3)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(lease.iface)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(NS.text1)
                            Text(lease.yiaddr ?? "no lease")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(NS.text3)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(selectedIface == lease.iface ? NS.amber.opacity(0.10) : Color.clear)
                }
                .buttonStyle(.plain)
                Divider().background(NS.borderMid)
            }
            Spacer()
        }
        .background(NS.bg1)
    }

    @ViewBuilder
    private var leaseDetail: some View {
        let lease = leases.first { $0.iface == selectedIface } ?? leases.first
        if let l = lease {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerCard(l)
                    optionGrid(l)
                    rawCard(l)
                }
                .padding(16)
            }
        } else {
            EmptyStateView(title: "Select an interface", systemImage: "arrow.left")
        }
    }

    private func headerCard(_ l: DHCPLease) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(l.iface).font(.system(size: 16, weight: .semibold)).foregroundStyle(NS.text1)
            kvHost("Client IP",   l.yiaddr)
            kvHost("DHCP Server", l.serverIdentifier)
            kvHost("Router",      l.router)
            kv("Subnet Mask", l.subnetMask ?? "—")
            kv("Domain Name", l.domainName ?? "—")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NS.bg2)
        .cornerRadius(8)
    }

    private func optionGrid(_ l: DHCPLease) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DHCP Options").font(.system(size: 12, weight: .semibold)).foregroundStyle(NS.text2)
            VStack(spacing: 0) {
                if !l.dnsServers.isEmpty {
                    kv("DNS Servers", l.dnsServers.joined(separator: ", "))
                }
                if let t = l.leaseTime { kv("Lease Time",     formatDuration(t)) }
                if let t = l.renewalTime { kv("Renewal (T1)", formatDuration(t)) }
                if let t = l.rebindingTime { kv("Rebind (T2)", formatDuration(t)) }
                if let t = l.leaseExpires { kv("Expires",     t.formatted()) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NS.bg2)
        .cornerRadius(8)
    }

    private func rawCard(_ l: DHCPLease) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Raw packet").font(.system(size: 12, weight: .semibold)).foregroundStyle(NS.text2)
            Text(l.raw)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(NS.text2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(NS.bg0)
                .cornerRadius(6)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NS.bg2)
        .cornerRadius(8)
    }

    private func kv(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).font(.system(size: 11)).foregroundStyle(NS.text3).frame(width: 110, alignment: .leading)
            Text(v).font(.system(size: 11, design: .monospaced)).foregroundStyle(NS.text2).textSelection(.enabled)
            Spacer()
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func kvHost(_ k: String, _ host: String?) -> some View {
        if let h = host {
            kv(k, h).hostMenu(h)
        } else {
            kv(k, "—")
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    // MARK: Reload

    private func reload() {
        isLoading = true
        error = ""
        Task {
            let result = await Self.fetchAll()
            await MainActor.run {
                self.leases = result
                if selectedIface == nil { selectedIface = result.first?.iface }
                isLoading = false
            }
        }
    }

    private static func fetchAll() async -> [DHCPLease] {
        // Pull DHCP-eligible interfaces from getifaddrs (en*), then call
        // `ipconfig getpacket <iface>` for each. Returns only those with a lease.
        let candidates = listInterfaces().filter { $0.hasPrefix("en") || $0.hasPrefix("bridge") }
        var out: [DHCPLease] = []
        for iface in candidates {
            let raw = await Shell.run("/usr/sbin/ipconfig", args: ["getpacket", iface])
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.lowercased().contains("not bound") || trimmed == "<none>" {
                continue
            }
            out.append(parseDHCPPacket(iface: iface, raw: trimmed))
        }
        return out
    }

    private static func listInterfaces() -> [String] {
        var out = Set<String>()
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return [] }
        defer { freeifaddrs(ifaddr) }
        var cur = ifaddr
        while let c = cur {
            out.insert(String(cString: c.pointee.ifa_name))
            cur = c.pointee.ifa_next
        }
        return out.sorted()
    }

    private static func parseDHCPPacket(iface: String, raw: String) -> DHCPLease {
        var lease = DHCPLease(iface: iface, raw: raw, hasLease: true)

        // ipconfig getpacket emits a header (op, htype, …) then "options:" with
        // semi-structured fields. We grep for the named DHCP option fields.

        if let m = matchScalar(raw, key: "yiaddr") { lease.yiaddr = m }

        for line in raw.split(separator: "\n").map(String.init) {
            let t = line.trimmingCharacters(in: .whitespaces)

            if t.hasPrefix("server_identifier"),
               let v = capture(t, after: ":") { lease.serverIdentifier = v }
            else if t.hasPrefix("router"),
                    let v = capture(t, after: ":") { lease.router = v.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) }
            else if t.hasPrefix("subnet_mask"),
                    let v = capture(t, after: ":") { lease.subnetMask = v }
            else if t.hasPrefix("domain_name "),
                    let v = capture(t, after: ":") { lease.domainName = v }
            else if t.hasPrefix("domain_name_server"),
                    let v = capture(t, after: ":") {
                lease.dnsServers = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            }
            else if t.hasPrefix("lease_time"),
                    let v = capture(t, after: ":"),
                    let n = parseSeconds(v) { lease.leaseTime = n }
            else if t.hasPrefix("renewal_t1_time_value"),
                    let v = capture(t, after: ":"),
                    let n = parseSeconds(v) { lease.renewalTime = n }
            else if t.hasPrefix("rebinding_t2_time_value"),
                    let v = capture(t, after: ":"),
                    let n = parseSeconds(v) { lease.rebindingTime = n }
        }

        // Compute expiry from "lease_time" + the most recent lease file's mtime if available.
        if let t = lease.leaseTime {
            if let leaseDir = leaseFileMTime(iface: iface) {
                lease.leaseExpires = leaseDir.addingTimeInterval(TimeInterval(t))
            }
        }
        return lease
    }

    private static func leaseFileMTime(iface: String) -> Date? {
        let path = "/var/db/dhcpclient/leases/\(iface).plist"
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let date = attrs[.modificationDate] as? Date else { return nil }
        return date
    }

    private static func matchScalar(_ raw: String, key: String) -> String? {
        for line in raw.split(separator: "\n").map(String.init) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("\(key) ") || t.hasPrefix("\(key)=") || t.hasPrefix("\(key):") {
                return capture(t, after: "=") ?? capture(t, after: ":")
            }
        }
        return nil
    }

    private static func capture(_ s: String, after sep: String) -> String? {
        guard let range = s.range(of: sep) else { return nil }
        let after = s[range.upperBound...].trimmingCharacters(in: .whitespaces)
        // strip parens like "(ip): 1.2.3.4"
        if let openParen = after.firstIndex(of: ")") {
            return String(after[after.index(after: openParen)...]).trimmingCharacters(in: .whitespaces)
        }
        return after.isEmpty ? nil : after
    }

    private static func parseSeconds(_ v: String) -> Int? {
        // Inputs look like "(uint32): 3600" or "3600"
        let digits = v.split(whereSeparator: { !$0.isNumber }).last.flatMap { Int($0) }
        return digits
    }

    // MARK: Export

    private func exportText() -> String {
        var out = "DHCP Leases\n" + String(repeating: "—", count: 60) + "\n"
        for l in leases {
            out += "[\(l.iface)] \(l.yiaddr ?? "no lease")\n"
            if let s = l.serverIdentifier { out += "    DHCP server: \(s)\n" }
            if let r = l.router            { out += "    Router:      \(r)\n" }
            if let m = l.subnetMask        { out += "    Subnet:      \(m)\n" }
            if !l.dnsServers.isEmpty       { out += "    DNS:         \(l.dnsServers.joined(separator: ", "))\n" }
            if let d = l.domainName        { out += "    Domain:      \(d)\n" }
            if let t = l.leaseTime         { out += "    Lease:       \(formatDuration(t))\n" }
            if let e = l.leaseExpires      { out += "    Expires:     \(e.formatted())\n" }
            out += "\n"
        }
        return out
    }

    private func exportJSON() -> String {
        let arr: [[String: Any]] = leases.map { l in
            var d: [String: Any] = [
                "interface": l.iface,
                "client_ip": l.yiaddr as Any,
                "router": l.router as Any,
                "subnet_mask": l.subnetMask as Any,
                "dhcp_server": l.serverIdentifier as Any,
                "domain": l.domainName as Any,
                "dns_servers": l.dnsServers
            ]
            if let t = l.leaseTime { d["lease_seconds"] = t }
            if let e = l.leaseExpires { d["lease_expires_iso"] = ISO8601DateFormatter().string(from: e) }
            return d
        }
        let payload: [String: Any] = [
            "tool": "DHCP Leases",
            "exported_at": ISO8601DateFormatter().string(from: Date()),
            "leases": arr
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}

// MARK: - Model

private struct DHCPLease: Identifiable {
    var id: String { iface }
    let iface: String
    let raw: String
    let hasLease: Bool
    var yiaddr: String? = nil
    var serverIdentifier: String? = nil
    var router: String? = nil
    var subnetMask: String? = nil
    var domainName: String? = nil
    var dnsServers: [String] = []
    var leaseTime: Int? = nil
    var renewalTime: Int? = nil
    var rebindingTime: Int? = nil
    var leaseExpires: Date? = nil
}
