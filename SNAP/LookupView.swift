// LookupView.swift
// SNAP — DNS Lookup Tab
// Created by Sevag Bardakjian
// Copyright © 2025-2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md

import SwiftUI
import Foundation
import Network

struct DNSRecord: Identifiable, Hashable {
    let id = UUID()
    static func == (lhs: DNSRecord, rhs: DNSRecord) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    let type: String
    let value: String
    let ttl: String
}

struct LookupView: View {
    @State private var host = ""
    @State private var recordType = "A"
    @State private var useServer = "1.1.1.1"   // DNS-over-HTTPS provider
    @State private var records: [DNSRecord] = []
    @State private var isRunning = false
    @State private var rawOutput = ""
    @State private var error = ""

    private let recordTypes = ["A", "AAAA", "MX", "NS", "TXT", "CNAME", "SOA", "PTR", "SRV", "CAA", "ANY"]
    private let dohProviders = ["1.1.1.1", "8.8.8.8", "9.9.9.9"]

    // DNS record type numbers for DoH queries
    private let typeNumbers: [String: Int] = [
        "A": 1, "NS": 2, "CNAME": 5, "SOA": 6, "PTR": 12,
        "MX": 15, "TXT": 16, "AAAA": 28, "SRV": 33, "CAA": 257, "ANY": 255
    ]

    var body: some View {
        VStack(spacing: 0) {
            // One row when it fits; narrow windows move the pickers to a second row
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.blue)
                    hostField.frame(width: 240)
                    HistoryMenuButton(key: .lookup) { host = $0 }
                    queryPickers
                    Spacer()
                    lookupActions
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.blue)
                        hostField.frame(minWidth: 140, maxWidth: .infinity)
                        HistoryMenuButton(key: .lookup) { host = $0 }
                        lookupActions
                    }
                    HStack(spacing: 12) {
                        queryPickers
                        Spacer()
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(NS.bg0)

            if !error.isEmpty {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(error).foregroundStyle(.red)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Color.red.opacity(0.05))
            }

            Divider()

            HSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    if records.isEmpty && !isRunning {
                        EmptyStateView(title: "No Results", systemImage: "magnifyingglass",
                                       description: "Enter a hostname and press Lookup")
                    } else {
                        Table(records) {
                            TableColumn("Type") { r in
                                Text(r.type)
                                    .font(.caption.monospaced())
                                    .padding(3)
                                    .background(typeColor(r.type).opacity(0.15))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }.width(60)
                            TableColumn("Value") { r in
                                Text(r.value).font(.caption.monospaced()).textSelection(.enabled)
                                    .hostMenu(r.value)
                            }
                            TableColumn("TTL") { r in
                                Text(r.ttl).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }.width(80)
                        }
                    }
                }
                .frame(minWidth: 360)

                VStack(alignment: .leading) {
                    HStack {
                        Text("Raw Output").font(.headline).fixedSize()
                        Spacer()
                        // Drop the aside before it wraps over the header
                        ViewThatFits(in: .horizontal) {
                            Text("via DNS-over-HTTPS (sandbox-safe)")
                            Text("via DNS-over-HTTPS")
                        }
                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    .padding(.horizontal)
                    ScrollView {
                        Text(rawOutput.isEmpty ? "No output yet" : rawOutput)
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
        .tabNavigationTitle(.lookup)
        .consumeHandoff(for: .lookup) { host = $0 }
    }

    // MARK: - Toolbar pieces (shared by the one- and two-row layouts)

    private var hostField: some View {
        TextField("Hostname or IP", text: $host)
            .textFieldStyle(.roundedBorder)
            .onSubmit { if !host.isEmpty && !isRunning { startLookup() } }
    }

    private var queryPickers: some View {
        HStack(spacing: 12) {
            Picker("Type", selection: $recordType) {
                ForEach(recordTypes, id: \.self) { t in Text(t).tag(t) }
            }
            .fixedSize()

            HStack(spacing: 4) {
                Text("DoH:").font(.caption).foregroundStyle(.secondary)
                Picker("Server", selection: $useServer) {
                    ForEach(dohProviders, id: \.self) { s in Text(s).tag(s) }
                }
                .fixedSize()   // a fixed 90 pt showed "1." instead of the resolver
            }
            .fixedSize()
        }
    }

    @ViewBuilder
    private var lookupActions: some View {
        if !records.isEmpty {
            ToolActionBar("DNS-Lookup",
                          text: { "DNS \(recordType) \(host) via \(useServer)\n\n" + records.map { "\($0.type)\tTTL \($0.ttl)\t\($0.value)" }.joined(separator: "\n") },
                          csv: { "type,ttl,value\n" + records.map { "\($0.type),\($0.ttl),\(csvEscape($0.value))" }.joined(separator: "\n") })
                .fixedSize()
        }
        Button("Lookup") { startLookup() }
            .buttonStyle(.borderedProminent)
            .disabled(host.isEmpty || isRunning)
            .keyboardShortcut(.return)
            .fixedSize()

        if isRunning { ProgressView().controlSize(.small) }
    }

    // MARK: - DNS over HTTPS (no raw sockets, sandbox-safe)
    private func startLookup() {
        let v = host.trimmingCharacters(in: .whitespaces)
        if !v.isEmpty { ToolHistory.shared.add(.lookup, v) }
        records = []
        rawOutput = ""
        error = ""
        isRunning = true

        Task {
            await performDoHLookup()
        }
    }

    @MainActor
    private func performDoHLookup() async {
        let qtype = typeNumbers[recordType] ?? 1
        let typed = host.trimmingCharacters(in: .whitespaces)
        // PTR needs the reverse name; an IP typed as-is was sent unchanged
        let name = recordType == "PTR" ? (DoH.reverseName(for: typed) ?? typed) : typed

        // Chosen once: the server picker can change while the request is out,
        // and the reply has to be read in the format it was asked in.
        let endpoint = DoH.endpoint(for: useServer)
        var req: URLRequest
        switch endpoint {
        case .json(let base):
            let urlStr = "\(base)?name=\(name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name)&type=\(qtype)"
            guard let url = URL(string: urlStr) else {
                error = "Invalid query URL"; isRunning = false; return
            }
            req = URLRequest(url: url)
            req.setValue("application/dns-json", forHTTPHeaderField: "Accept")
        case .wire(let url):
            guard let body = DoH.wireQuery(name: name, type: UInt16(qtype)) else {
                error = "\(typed) isn't a valid host name."; isRunning = false; return
            }
            req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.httpBody = body
            req.setValue("application/dns-message", forHTTPHeaderField: "Content-Type")
            req.setValue("application/dns-message", forHTTPHeaderField: "Accept")
        }
        req.timeoutInterval = 10

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let decoded: [String: Any]?
            switch endpoint {
            case .json:
                decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            case .wire:
                decoded = DoH.parseWire(data)
            }
            guard let json = decoded else {
                error = "Invalid response from DNS server"; isRunning = false; return
            }

            rawOutput = prettyPrint(json)

            let status = json["Status"] as? Int ?? -1
            switch status {
            case 0: break  // NOERROR
            case 2: error = "SERVFAIL — DNS server failure"; isRunning = false; return
            case 3: error = "NXDOMAIN — Domain not found"; isRunning = false; return
            default: error = "DNS error (status \(status))"; isRunning = false; return
            }

            var parsed: [DNSRecord] = []

            // Parse Answer section
            for section in ["Answer", "Authority", "Additional"] {
                if let answers = json[section] as? [[String: Any]] {
                    for ans in answers {
                        let typeNum = ans["type"] as? Int ?? 0
                        let typeName = dnsTypeName(typeNum)
                        let data = ans["data"] as? String ?? ""
                        let ttl  = ans["TTL"]  as? Int ?? 0
                        parsed.append(DNSRecord(type: typeName, value: data, ttl: "\(ttl)s"))
                    }
                }
            }

            records = parsed
            if parsed.isEmpty { error = "No records found for \(name) \(recordType)" }
        } catch {
            self.error = error.localizedDescription
        }
        isRunning = false
    }

    private func dnsTypeName(_ n: Int) -> String {
        let map: [Int: String] = [
            1: "A", 2: "NS", 5: "CNAME", 6: "SOA", 12: "PTR",
            15: "MX", 16: "TXT", 28: "AAAA", 33: "SRV", 257: "CAA",
            46: "RRSIG", 47: "NSEC", 48: "DNSKEY", 43: "DS"
        ]
        return map[n] ?? "TYPE\(n)"
    }

    private func prettyPrint(_ json: [String: Any]) -> String {
        var lines: [String] = []
        let status = json["Status"] as? Int ?? -1
        lines.append("; DoH Query to \(useServer)")
        lines.append("; Status: \(status == 0 ? "NOERROR" : "\(status)")")
        lines.append("")
        for section in ["Answer", "Authority", "Additional"] {
            if let answers = json[section] as? [[String: Any]], !answers.isEmpty {
                lines.append(";; \(section.uppercased()) SECTION:")
                for ans in answers {
                    let name = ans["name"] as? String ?? ""
                    let ttl  = ans["TTL"]  as? Int    ?? 0
                    let type = dnsTypeName(ans["type"] as? Int ?? 0)
                    let data = ans["data"] as? String ?? ""
                    lines.append("\(name)\t\(ttl)\tIN\t\(type)\t\(data)")
                }
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func typeColor(_ type: String) -> Color {
        switch type {
        case "A":     return .blue
        case "AAAA":  return .purple
        case "MX":    return .orange
        case "NS":    return .green
        case "TXT":   return .yellow
        case "CNAME": return .cyan
        case "SOA":   return .red
        case "PTR":   return .indigo
        default:      return .gray
        }
    }
}

// MARK: - DoH endpoints and wire format

/// How each DoH provider in the picker is queried. Checked live with curl
/// (2026-11-20): Cloudflare answers JSON at /dns-query, Google answers JSON
/// only at /resolve (/dns-query is RFC 8484 wire format), and Quad9 has no
/// JSON on 443 (its old :5053 JSON port didn't connect), so Quad9 gets the
/// RFC 8484 wire format, converted to the same dictionary shape as the JSON.
enum DoH {
    enum Endpoint: Equatable {
        case json(String)   // base URL; ?name=&type= appended
        case wire(URL)      // POST application/dns-message
    }

    static func endpoint(for provider: String) -> Endpoint {
        switch provider {
        case "8.8.8.8": return .json("https://8.8.8.8/resolve")
        case "9.9.9.9": return .wire(URL(string: "https://9.9.9.9/dns-query")!)
        default:        return .json("https://\(provider)/dns-query")
        }
    }

    /// in-addr.arpa / ip6.arpa name for an IP literal, nil for anything else.
    static func reverseName(for ip: String) -> String? {
        var v4 = in_addr()
        if inet_pton(AF_INET, ip, &v4) == 1 {
            let b = withUnsafeBytes(of: &v4) { Array($0) }
            return "\(b[3]).\(b[2]).\(b[1]).\(b[0]).in-addr.arpa"
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, ip, &v6) == 1 {
            let b = withUnsafeBytes(of: &v6) { Array($0) }
            let nibbles = b.reversed().flatMap { [String($0 & 0x0F, radix: 16), String($0 >> 4, radix: 16)] }
            return nibbles.joined(separator: ".") + ".ip6.arpa"
        }
        return nil
    }

    /// A recursive query (ID 0, as RFC 8484 suggests for caching), or nil
    /// when a label is empty or longer than 63 bytes.
    static func wireQuery(name: String, type: UInt16) -> Data? {
        var labels = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if labels.last == "" { labels.removeLast() }   // trailing root dot
        var q = Data([0x00, 0x00, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        var nameLength = 1
        for label in labels {
            let bytes = Array(label.utf8)
            guard (1...63).contains(bytes.count) else { return nil }
            q.append(UInt8(bytes.count))
            q.append(contentsOf: bytes)
            nameLength += bytes.count + 1
        }
        guard nameLength <= 255 else { return nil }
        q.append(0)
        q.append(contentsOf: [UInt8(type >> 8), UInt8(type & 0xFF), 0x00, 0x01])
        return q
    }

    /// Decode a DNS response into the JSON API's shape: "Status" plus
    /// "Answer" / "Authority" / "Additional" arrays of name, type, TTL, data.
    static func parseWire(_ data: Data) -> [String: Any]? {
        let p = [UInt8](data)
        guard p.count >= 12 else { return nil }
        func u16(_ i: Int) -> Int { Int(p[i]) << 8 | Int(p[i + 1]) }
        let counts = [u16(4), u16(6), u16(8), u16(10)]
        var idx = 12
        for _ in 0..<counts[0] {
            guard readName(p, &idx) != nil, idx + 4 <= p.count else { return nil }
            idx += 4
        }
        var out: [String: Any] = ["Status": u16(2) & 0x000F]
        for (section, count) in zip(["Answer", "Authority", "Additional"], counts.dropFirst()) {
            var records: [[String: Any]] = []
            for _ in 0..<count {
                guard let name = readName(p, &idx), idx + 10 <= p.count else { return nil }
                let type = u16(idx)
                let ttl = Int(p[idx + 4]) << 24 | Int(p[idx + 5]) << 16 | Int(p[idx + 6]) << 8 | Int(p[idx + 7])
                let rdlen = u16(idx + 8)
                idx += 10
                guard idx + rdlen <= p.count else { return nil }
                if type != 41 {   // OPT pseudo-record, not data
                    records.append(["name": name, "type": type, "TTL": ttl,
                                    "data": rdataText(type: type, p, start: idx, length: rdlen)])
                }
                idx += rdlen
            }
            if !records.isEmpty { out[section] = records }
        }
        return out
    }

    /// Presentation form, matching what the JSON providers return.
    private static func rdataText(type: Int, _ p: [UInt8], start: Int, length: Int) -> String {
        let r = Array(p[start..<(start + length)])
        func u16(_ i: Int) -> Int { Int(r[i]) << 8 | Int(r[i + 1]) }
        func u32(_ i: Int) -> UInt32 { UInt32(r[i]) << 24 | UInt32(r[i + 1]) << 16 | UInt32(r[i + 2]) << 8 | UInt32(r[i + 3]) }
        func name(at offset: Int) -> String? {
            var i = start + offset
            return readName(p, &i)
        }
        func quoted(_ bytes: ArraySlice<UInt8>) -> String {
            let s = String(decoding: bytes, as: UTF8.self)
            return "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        switch type {
        case 1 where length == 4:
            return r.map(String.init).joined(separator: ".")
        case 28 where length == 16:
            var addr = in6_addr()
            withUnsafeMutableBytes(of: &addr) { $0.copyBytes(from: r) }
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            return inet_ntop(AF_INET6, &addr, &buf, socklen_t(buf.count)).map { String(cString: $0) } ?? ""
        case 2, 5, 12:
            return name(at: 0) ?? ""
        case 15 where length >= 3:
            return "\(u16(0)) \(name(at: 2) ?? "")"
        case 16:
            var parts: [String] = []
            var i = 0
            while i < r.count {
                let len = Int(r[i])
                guard i + 1 + len <= r.count else { break }
                parts.append(quoted(r[(i + 1)..<(i + 1 + len)]))
                i += 1 + len
            }
            return parts.joined(separator: " ")
        case 6:
            var i = start
            guard let mname = readName(p, &i), let rname = readName(p, &i), i + 20 <= start + length else { break }
            let n = i - start
            return "\(mname) \(rname) \(u32(n)) \(u32(n + 4)) \(u32(n + 8)) \(u32(n + 12)) \(u32(n + 16))"
        case 33 where length >= 7:
            return "\(u16(0)) \(u16(2)) \(u16(4)) \(name(at: 6) ?? "")"
        case 257 where length >= 2:
            let tagLen = Int(r[1])
            guard 2 + tagLen <= r.count else { break }
            let tag = String(decoding: r[2..<(2 + tagLen)], as: UTF8.self)
            return "\(r[0]) \(tag) \(quoted(r[(2 + tagLen)...]))"
        default:
            break
        }
        // RFC 3597 generic form for anything else
        return "\\# \(length) " + r.map { String(format: "%02x", $0) }.joined()
    }

    /// Name at `idx` (following compression pointers) with a trailing dot;
    /// advances `idx` past it. Nil if malformed.
    private static func readName(_ p: [UInt8], _ idx: inout Int) -> String? {
        var labels: [String] = []
        var ptr = idx
        var jumped = false
        for _ in 0..<128 {
            guard ptr < p.count else { return nil }
            let len = Int(p[ptr])
            if len == 0 {
                if !jumped { idx = ptr + 1 }
                return labels.isEmpty ? "." : labels.joined(separator: ".") + "."
            }
            if len & 0xC0 == 0xC0 {
                guard ptr + 1 < p.count else { return nil }
                if !jumped { idx = ptr + 2 }
                jumped = true
                ptr = (len & 0x3F) << 8 | Int(p[ptr + 1])
                continue
            }
            guard ptr + 1 + len <= p.count else { return nil }
            labels.append(String(decoding: p[(ptr + 1)..<(ptr + 1 + len)], as: UTF8.self))
            ptr += 1 + len
        }
        return nil
    }
}
