// DNSPropagationView.swift
// SNAP — DNS Propagation Tool
// Created by Sevag Bardakjian
// Copyright © 2025 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md
//
// Queries the same record across many public resolvers and surfaces which
// ones agree. When you change a DNS record, propagation across recursive
// caches is uneven — this tool gives you a quick global consistency view.

import SwiftUI

struct DNSPropagationView: View {
    @State private var host = ""
    @State private var recordType: DNSWireType = .a
    @State private var rows: [PropagationRow] = []
    @State private var isRunning = false
    @State private var error = ""

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if !error.isEmpty { errorBar }
            Divider()
            content
        }
        .tabNavigationTitle(.dnsPropagation)
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: "globe.americas").foregroundStyle(.blue)
            TextField("Hostname (e.g. example.com)", text: $host)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit { if !host.isEmpty && !isRunning { run() } }

            Picker("Type", selection: $recordType) {
                Text("A").tag(DNSWireType.a)
                Text("AAAA").tag(DNSWireType.aaaa)
                Text("CNAME").tag(DNSWireType.cname)
                Text("MX").tag(DNSWireType.mx)
                Text("NS").tag(DNSWireType.ns)
                Text("TXT").tag(DNSWireType.txt)
            }
            .frame(width: 100)

            Spacer()

            if !rows.isEmpty {
                consensusBadge
                Spacer().frame(width: 8)
                ToolActionBar("DNS Propagation",
                              text: { exportText() },
                              csv:  { exportCSV() },
                              json: { exportJSON() })
            }

            Button(isRunning ? "Checking…" : "Check") { run() }
                .buttonStyle(.borderedProminent)
                .disabled(host.isEmpty || isRunning)
                .keyboardShortcut(.return)

            if isRunning { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(NS.bg0)
    }

    @ViewBuilder
    private var consensusBadge: some View {
        let groups = answerGroups()
        let total = rows.filter { $0.status != .running }.count
        if total > 0 {
            let pct = PropagationConsensus.percent(top: groups.first?.rows.count ?? 0, of: total)
            HStack(spacing: 6) {
                Circle()
                    .fill(pct >= 100 ? NS.green : (pct >= 80 ? NS.amber : NS.red))
                    .frame(width: 8, height: 8)
                Text("\(pct)% consensus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(NS.text2)
                Text("· \(groups.count) distinct \(groups.count == 1 ? "answer" : "answers")")
                    .font(.system(size: 11))
                    .foregroundStyle(NS.text3)
            }
        }
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

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if rows.isEmpty && !isRunning {
            EmptyStateView(title: "DNS Propagation",
                           systemImage: "globe.americas",
                           description: "Enter a hostname and SNAP will query \(PublicResolvers.all.count) public resolvers in parallel and compare their answers.")
        } else {
            HSplitView {
                resolverTable
                    .frame(minWidth: 460)
                detailPane
                    .frame(minWidth: 280)
            }
        }
    }

    private var resolverTable: some View {
        Table(rows) {
            TableColumn("Resolver") { row in
                HStack(spacing: 6) {
                    Circle()
                        .fill(row.statusColor)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.resolver.name)
                            .font(.system(size: 12, weight: .medium))
                        Text("\(row.resolver.ip) · \(row.resolver.region)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .width(min: 200, ideal: 220)
            TableColumn("Answer") { row in
                if row.status == .running {
                    Text("…").foregroundStyle(.secondary).font(.caption.monospaced())
                } else if let err = row.error {
                    Text(err).foregroundStyle(.red).font(.caption.monospaced()).textSelection(.enabled)
                } else if row.values.isEmpty {
                    Text("(empty)").foregroundStyle(.secondary).font(.caption.monospaced())
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(row.values, id: \.self) { v in
                            Text(v).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }
            }
            TableColumn("Latency") { row in
                if let ms = row.elapsedMs {
                    Text("\(Int(ms)) ms")
                        .font(.caption.monospaced())
                        .foregroundStyle(ms < 80 ? NS.green : (ms < 200 ? NS.amber : NS.red))
                } else {
                    Text("—").foregroundStyle(.secondary).font(.caption.monospaced())
                }
            }
            .width(70)
        }
    }

    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Consensus").font(.headline).padding(.horizontal).padding(.top, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(answerGroups().enumerated()), id: \.offset) { _, group in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("\(group.rows.count)× resolvers")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(NS.text1)
                                Spacer()
                            }
                            ForEach(groupLines(group.answer), id: \.self) { v in
                                Text(v)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(NS.text2)
                                    .textSelection(.enabled)
                            }
                            Text(group.rows.map { $0.resolver.name }.joined(separator: ", "))
                                .font(.system(size: 10))
                                .foregroundStyle(NS.text3)
                                .padding(.top, 2)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(NS.bg2)
                        .cornerRadius(6)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 12)
            }
        }
        .background(NS.bg1)
    }

    // MARK: Execution

    private func run() {
        rows = PublicResolvers.all.map {
            PropagationRow(resolver: $0, status: .running, values: [], elapsedMs: nil, error: nil)
        }
        error = ""
        isRunning = true

        let target = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let qtype = recordType

        Task.detached {
            await withTaskGroup(of: (String, PropagationRow).self) { group in
                for r in PublicResolvers.all {
                    group.addTask {
                        let result = await Self.runOne(server: r.ip, name: target, type: qtype)
                        let row = PropagationRow(
                            resolver: r,
                            status: result.error == nil ? .ok : .failed,
                            values: result.values,
                            elapsedMs: result.elapsedMs,
                            error: result.error,
                            nxdomain: result.nxdomain
                        )
                        return (r.id, row)
                    }
                }
                for await (id, row) in group {
                    await MainActor.run {
                        if let i = rows.firstIndex(where: { $0.resolver.id == id }) {
                            rows[i] = row
                        }
                    }
                }
            }
            await MainActor.run { isRunning = false }
        }
    }

    private static func runOne(server: String, name: String, type: DNSWireType) async -> (values: [String], elapsedMs: Double?, error: String?, nxdomain: Bool) {
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let r = try DNSWire.query(server: server, name: name, type: type, timeout: 3.0)
                    let values = r.answers
                        .filter { $0.type == type.label }
                        .map { $0.value }
                    // Fallback: if no matches at all (e.g. CNAME chase), use whatever answers were returned
                    let final = values.isEmpty ? r.answers.map { "\($0.type) \($0.value)" } : values
                    cont.resume(returning: (final, r.elapsedMs, nil, false))
                } catch {
                    let nx: Bool
                    if case .rcode(3)? = error as? DNSWireError { nx = true } else { nx = false }
                    cont.resume(returning: ([], nil, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, nx))
                }
            }
        }
    }

    // MARK: Grouping for consensus

    private func answerGroups() -> [(answer: PropagationAnswer, rows: [PropagationRow])] {
        PropagationConsensus.groups(rows) { row in
            switch row.status {
            case .running: return nil
            case .ok:      return .records(row.values)
            case .failed:  return row.nxdomain ? .nxdomain : nil
            }
        }
    }

    private func groupLines(_ answer: PropagationAnswer) -> [String] {
        switch answer {
        case .records(let values) where values.isEmpty: return ["No \(recordType.label) record"]
        case .records(let values):                      return values
        case .nxdomain:                                 return ["Name doesn't exist"]
        }
    }

    // MARK: Export

    private func exportText() -> String {
        var out = "DNS Propagation — \(host) \(recordType.label)\n"
        out += String(repeating: "—", count: 60) + "\n"
        for r in rows {
            let val = r.values.joined(separator: ", ")
            let ms  = r.elapsedMs.map { "\(Int($0)) ms" } ?? "—"
            let status = r.error ?? val
            out += String(format: "%-14s  %-22s  %-7s  %@\n",
                          (r.resolver.ip as NSString).utf8String!,
                          (r.resolver.name as NSString).utf8String!,
                          (ms as NSString).utf8String!,
                          status)
        }
        return out
    }

    private func exportCSV() -> String {
        var out = "resolver_ip,resolver_name,region,latency_ms,status,answer\n"
        for r in rows {
            let lat = r.elapsedMs.map { "\(Int($0))" } ?? ""
            let status = r.error ?? "ok"
            let answer = r.values.joined(separator: "|")
            out += "\(r.resolver.ip),\(r.resolver.name),\(r.resolver.region),\(lat),\(status),\(answer)\n"
        }
        return out
    }

    private func exportJSON() -> String {
        let arr: [[String: Any]] = rows.map { r in
            [
                "resolver_ip": r.resolver.ip,
                "resolver_name": r.resolver.name,
                "region": r.resolver.region,
                "latency_ms": r.elapsedMs as Any,
                "status": r.error ?? "ok",
                "answer": r.values
            ]
        }
        let payload: [String: Any] = [
            "tool": "DNS Propagation",
            "host": host,
            "type": recordType.label,
            "exported_at": ISO8601DateFormatter().string(from: Date()),
            "results": arr
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}

// MARK: - Consensus

/// What consensus compares for one resolver.
enum PropagationAnswer: Hashable {
    /// Sorted values; empty means the name exists but has no record of this type
    case records([String])
    /// NXDOMAIN: the resolver says the name doesn't exist
    case nxdomain

    fileprivate var sortKey: String {
        switch self {
        case .records(let v): return "r:" + v.joined(separator: "|")
        case .nxdomain:       return "nx"
        }
    }
}

enum PropagationConsensus {
    /// Resolvers grouped by identical answer, largest group first. A nil
    /// answer (still running, or failed: timeout, SERVFAIL, refused) is left
    /// out. Agreeing NXDOMAIN or empty answers form a group like any other;
    /// counting only non-empty answers showed "0% consensus" when every
    /// resolver agreed the name or record doesn't exist.
    static func groups<Row>(_ rows: [Row], answer: (Row) -> PropagationAnswer?) -> [(answer: PropagationAnswer, rows: [Row])] {
        var order: [PropagationAnswer] = []
        var buckets: [PropagationAnswer: [Row]] = [:]
        for row in rows {
            guard var a = answer(row) else { continue }
            if case .records(let v) = a { a = .records(v.sorted()) }
            if buckets[a] == nil { order.append(a) }
            buckets[a, default: []].append(row)
        }
        return order
            .map { (answer: $0, rows: buckets[$0] ?? []) }
            .sorted { $0.rows.count != $1.rows.count ? $0.rows.count > $1.rows.count : $0.answer.sortKey < $1.answer.sortKey }
    }

    /// Share of finished resolvers in the largest group, 0 to 100.
    static func percent(top: Int, of total: Int) -> Int {
        guard total > 0 else { return 0 }
        return Int((Double(top) / Double(total)) * 100)
    }
}

// MARK: - Row model

private struct PropagationRow: Identifiable {
    var id: String { resolver.id }
    let resolver: DNSResolver
    var status: RowStatus
    var values: [String]
    var elapsedMs: Double?
    var error: String?
    var nxdomain = false

    enum RowStatus { case running, ok, failed }

    var statusColor: Color {
        switch status {
        case .running: return .gray
        case .ok:      return NS.green
        case .failed:  return NS.red
        }
    }
}
