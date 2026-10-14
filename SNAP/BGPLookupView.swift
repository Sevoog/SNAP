// BGPLookupView.swift
// SNAP — BGP / ASN Lookup (Team Cymru DNS service)
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md
//
// Uses Team Cymru's IP-to-ASN service over plain DNS — no HTTP API key,
// no rate limits to speak of, no third-party dependency. Two TXT queries:
//
//   1. <reversed-IP>.origin.asn.cymru.com
//      Returns:  "ASN | BGP prefix | CC | Registry | Allocated"
//
//   2. AS<ASN>.asn.cymru.com
//      Returns:  "ASN | CC | Registry | Allocated | AS Name"
//
// Both queries go out concurrently to 8.8.8.8; the result panel shows the
// merged record once both come back. IPv6 is supported via the parallel
// `origin6.asn.cymru.com` zone.

import SwiftUI

struct BGPResult: Hashable {
    let queriedIP: String
    let asn: UInt32
    let asName: String
    let prefix: String
    let country: String
    let registry: String
    let allocated: String
}

@MainActor
final class BGPLookupModel: ObservableObject {
    @Published var query = ""
    @Published var result: BGPResult?
    @Published var errorMessage: String?
    @Published var isRunning = false

    nonisolated static let resolver = "8.8.8.8"

    func lookup() {
        errorMessage = nil
        result = nil
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isRunning = true

        Task {
            do {
                let r = try await Self.fullLookup(for: trimmed)
                await MainActor.run {
                    self.result = r
                    self.isRunning = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "\(error.localizedDescription)"
                    self.isRunning = false
                }
            }
        }
    }

    // MARK: Two-step query

    static func fullLookup(for input: String) async throws -> BGPResult {
        // If the user typed an ASN ("AS15169" or "15169"), skip the
        // origin lookup and just resolve the AS name + metadata.
        if let asn = parseASN(input) {
            let info = try await asnInfo(asn)
            return BGPResult(
                queriedIP: "AS\(asn)",
                asn: asn,
                asName: info.name,
                prefix: "—",
                country: info.cc,
                registry: info.registry,
                allocated: info.allocated
            )
        }

        guard let queryName = originQueryName(for: input) else {
            throw NSError(domain: "BGPLookup", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Not a valid IP or ASN: \(input)"])
        }

        let originText = try await txt(queryName)
        let parts = originText.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        // Format: ASN(s) | Prefix | CC | Registry | Allocated
        guard parts.count >= 5, let asn = UInt32(parts[0].split(separator: " ").first.map(String.init) ?? "") else {
            throw NSError(domain: "BGPLookup", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Unrecognized response: \(originText)"])
        }
        let prefix = parts[1]
        let cc = parts[2]
        let reg = parts[3]
        let allocated = parts[4]

        // Second-step AS-name lookup is best-effort — if it fails, still
        // return what we have from origin.
        let asName: String = (try? await asnInfo(asn).name) ?? "AS\(asn)"

        return BGPResult(
            queriedIP: input,
            asn: asn,
            asName: asName,
            prefix: prefix,
            country: cc,
            registry: reg,
            allocated: allocated
        )
    }

    // MARK: Single-query helpers

    private struct ASInfo { let name: String; let cc: String; let registry: String; let allocated: String }

    private static func asnInfo(_ asn: UInt32) async throws -> ASInfo {
        let name = "AS\(asn).asn.cymru.com"
        let text = try await txt(name)
        // Format: ASN | CC | Registry | Allocated | AS Name
        let parts = text.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 5 else {
            return ASInfo(name: "AS\(asn)", cc: "", registry: "", allocated: "")
        }
        return ASInfo(name: parts[4], cc: parts[1], registry: parts[2], allocated: parts[3])
    }

    private static func txt(_ name: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let res = try DNSWire.query(server: resolver, name: name, type: .txt, timeout: 3.0)
            // Take the first TXT answer (Cymru returns one record).
            guard let first = res.answers.first(where: { $0.type == "TXT" }) else {
                throw NSError(domain: "BGPLookup", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "No TXT record"])
            }
            return first.value
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }.value
    }

    // MARK: IP / ASN parsing

    private static func parseASN(_ s: String) -> UInt32? {
        var t = s.trimmingCharacters(in: .whitespaces).uppercased()
        if t.hasPrefix("AS") { t = String(t.dropFirst(2)) }
        return UInt32(t)
    }

    /// Returns `<reversed>.origin.asn.cymru.com` for IPv4 or
    /// `<nibble-reversed>.origin6.asn.cymru.com` for IPv6. Nil if input
    /// isn't a recognizable IP.
    private static func originQueryName(for ip: String) -> String? {
        // IPv4
        if let v4 = reverseIPv4(ip) { return "\(v4).origin.asn.cymru.com" }
        if let v6 = reverseIPv6(ip) { return "\(v6).origin6.asn.cymru.com" }
        return nil
    }

    private static func reverseIPv4(_ s: String) -> String? {
        let parts = s.split(separator: ".").map(String.init)
        guard parts.count == 4, parts.allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false }) else {
            return nil
        }
        return parts.reversed().joined(separator: ".")
    }

    /// IPv6 expansion + nibble reversal for `origin6.asn.cymru.com` queries.
    private static func reverseIPv6(_ s: String) -> String? {
        // Expand any `::` shorthand to a full eight-group form, then reverse
        // nibble-by-nibble.
        let lower = s.lowercased()
        guard lower.contains(":") else { return nil }
        let groups: [String]
        if lower.contains("::") {
            let halves = lower.components(separatedBy: "::")
            guard halves.count == 2 else { return nil }
            let left = halves[0].isEmpty ? [] : halves[0].split(separator: ":").map(String.init)
            let right = halves[1].isEmpty ? [] : halves[1].split(separator: ":").map(String.init)
            let zeros = 8 - left.count - right.count
            guard zeros >= 0 else { return nil }
            groups = left + Array(repeating: "0", count: zeros) + right
        } else {
            groups = lower.split(separator: ":").map(String.init)
        }
        guard groups.count == 8 else { return nil }
        let padded = groups.map { String(repeating: "0", count: 4 - $0.count) + $0 }
        let all = padded.joined()
        guard all.count == 32, all.allSatisfy({ $0.isHexDigit }) else { return nil }
        return all.reversed().map(String.init).joined(separator: ".")
    }

    // MARK: Export

    func exportText() -> String {
        guard let r = result else { return "(no result yet)" }
        return """
        BGP/ASN lookup — \(r.queriedIP)
          ASN:        AS\(r.asn)
          AS name:    \(r.asName)
          Prefix:     \(r.prefix)
          Country:    \(r.country)
          Registry:   \(r.registry)
          Allocated:  \(r.allocated)
        """
    }
}

// MARK: - View

struct BGPLookupView: View {
    @StateObject private var model = BGPLookupModel()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .tabNavigationTitle(.bgp)
        .consumeHandoff(for: .bgp) { model.query = $0 }
    }

    private func runBGP() {
        let v = model.query.trimmingCharacters(in: .whitespaces)
        if !v.isEmpty { ToolHistory.shared.add(.bgp, v) }
        model.lookup()
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.branch").foregroundStyle(.blue)
            TextField("IPv4 / IPv6 / ASN (e.g. 8.8.8.8, AS15169)", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit { runBGP() }
            HistoryMenuButton(key: .bgp) { model.query = $0 }
            Spacer()
            if !(model.result == nil) {
                ToolActionBar("BGP-ASN", text: { model.exportText() })
            }
            if model.isRunning {
                ProgressView().controlSize(.small)
            } else {
                Button("Lookup") { runBGP() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.query.isEmpty)
                    .keyboardShortcut(.return)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(NS.bg0)
    }

    @ViewBuilder
    private var content: some View {
        if let err = model.errorMessage {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(NS.red)
                Text(err).font(.system(size: 12, design: .monospaced)).foregroundStyle(NS.text1)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(NS.red.opacity(0.08))
            Spacer()
        } else if let r = model.result {
            resultPane(r)
        } else if model.isRunning {
            ProgressView("Querying Team Cymru…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EmptyStateView(title: "BGP / ASN",
                           systemImage: "arrow.triangle.branch",
                           description: "Enter an IP or AS number to look up routing-table info via Team Cymru's DNS-based ASN service.")
        }
    }

    private func resultPane(_ r: BGPResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "network").foregroundStyle(NS.amber).font(.system(size: 22))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AS\(r.asn) · \(r.asName)")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(NS.text1)
                            .textSelection(.enabled)
                        Text(r.queriedIP).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(NS.text3)
                    }
                    Spacer()
                }
                Divider().background(NS.borderMid)
                row("BGP Prefix", r.prefix.isEmpty ? "—" : r.prefix)
                row("Country",   r.country.isEmpty ? "—" : r.country)
                row("Registry",  r.registry.isEmpty ? "—" : r.registry.uppercased())
                row("Allocated", r.allocated.isEmpty ? "—" : r.allocated)
            }
            .padding(16)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(NS.text3).frame(width: 100, alignment: .leading)
            Text(value).font(.system(size: 13, design: .monospaced))
                .foregroundStyle(NS.text1).textSelection(.enabled)
        }
    }
}
