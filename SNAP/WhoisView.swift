// WhoisView.swift
// SNAP — Whois Tab
// Created by Sevag Bardakjian

import SwiftUI

struct WhoisView: View {
    @State private var query = ""
    @State private var result = ""
    @State private var isRunning = false
    @State private var parsed: [(String, String)] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "person.text.rectangle").foregroundStyle(.blue)
                TextField("Domain, IP, or ASN", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
                HistoryMenuButton(key: .whois) { query = $0 }
                Spacer()
                if !result.isEmpty {
                    ToolActionBar("Whois", text: { "Whois \(query)\n\n" + result })
                }
                if isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Lookup") { startWhois() }
                        .buttonStyle(.borderedProminent)
                        .disabled(query.isEmpty)
                        .keyboardShortcut(.return)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(NS.bg0)

            Divider()

            HSplitView {
                // Parsed fields
                VStack(alignment: .leading) {
                    Text("Summary").font(.headline).padding([.horizontal, .top])
                    if parsed.isEmpty {
                        Spacer()
                        Text("No data").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                        Spacer()
                    } else {
                        List(parsed, id: \.0) { (key, val) in
                            HStack(alignment: .top) {
                                Text(key)
                                    .font(.caption.bold())
                                    .frame(width: 140, alignment: .trailing)
                                    .foregroundStyle(.secondary)
                                Text(val)
                                    .font(.caption)
                                    .textSelection(.enabled)
                                Spacer()
                            }
                        }
                    }
                }
                .frame(minWidth: 300, maxWidth: 380)

                // Raw output
                VStack(alignment: .leading) {
                    Text("Raw Whois").font(.headline).padding([.horizontal, .top])
                    ScrollView {
                        Text(result.isEmpty ? "Enter a domain or IP to look up" : result)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    .background(NS.bg3)
                }
            }
        }
        .navigationTitle("Whois")
        .consumeHandoff(for: .whois) { query = $0 }
    }

    private func startWhois() {
        let v = query.trimmingCharacters(in: .whitespaces)
        if !v.isEmpty { ToolHistory.shared.add(.whois, v) }
        result = ""
        parsed = []
        isRunning = true

        Task {
            let output = await Shell.run("/usr/bin/whois", args: [query])
            await MainActor.run {
                result = output
                parsed = parseWhois(output)
                isRunning = false
            }
        }
    }

    private func parseWhois(_ raw: String) -> [(String, String)] {
        let interestingKeys = [
            "Domain Name", "Registrar", "Registrant Name", "Registrant Organization",
            "Registrant Email", "Creation Date", "Updated Date", "Expiry Date",
            "Name Server", "DNSSEC", "Status", "Registry Domain ID",
            "NetRange", "CIDR", "NetName", "Organization", "Country",
            "OrgName", "Address", "City", "StateProv", "PostalCode",
            "abuse-mailbox", "descr", "origin", "route", "aut-num"
        ]
        var results: [(String, String)] = []
        var seen = Set<String>()

        for line in raw.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: ":").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 2 else { continue }
            let key = parts[0]
            let value = parts[1...].joined(separator: ":").trimmingCharacters(in: .whitespaces)
            guard !key.hasPrefix("#"), !key.hasPrefix("%"), !value.isEmpty else { continue }

            if interestingKeys.contains(where: { key.localizedCaseInsensitiveContains($0) }) {
                let dedupKey = key + value
                if !seen.contains(dedupKey) {
                    seen.insert(dedupKey)
                    results.append((key, value))
                }
            }
        }
        return results
    }
}
