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
        // Cloudflare / Google DoH JSON API
        let urlStr = "https://\(useServer)/dns-query?name=\(host.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? host)&type=\(qtype)"

        guard let url = URL(string: urlStr) else {
            error = "Invalid query URL"; isRunning = false; return
        }

        var req = URLRequest(url: url)
        req.setValue("application/dns-json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
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
            if parsed.isEmpty { error = "No records found for \(host) \(recordType)" }
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
