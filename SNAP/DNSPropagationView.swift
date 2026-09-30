// DNSPropagationView.swift
// SNAP — DNS Propagation Tool
// Created by Sevag Bardakjian
// Copyright © 2025 Sevag Bardakjian. All rights reserved.
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
        .navigationTitle("DNS Propagation")
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
            let topCount = groups.first?.1.count ?? 0
            let pct = Int((Double(topCount) / Double(total)) * 100)
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
                                Text("\(group.1.count)× resolvers")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(NS.text1)
                                Spacer()
                            }
                            ForEach(group.0, id: \.self) { v in
                                Text(v)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(NS.text2)
                                    .textSelection(.enabled)
                            }
                            Text(group.1.map { $0.resolver.name }.joined(separator: ", "))
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
                            error: result.error
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

    private static func sortKey(_ values: [String]) -> String {
        values.sorted().joined(separator: "|")
    }

    private static func runOne(server: String, name: String, type: DNSWireType) async -> (values: [String], elapsedMs: Double?, error: String?) {
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let r = try DNSWire.query(server: server, name: name, type: type, timeout: 3.0)
                    let values = r.answers
                        .filter { $0.type == type.label }
                        .map { $0.value }
                    // Fallback: if no matches at all (e.g. CNAME chase), use whatever answers were returned
                    let final = values.isEmpty ? r.answers.map { "\($0.type) \($0.value)" } : values
                    cont.resume(returning: (final, r.elapsedMs, nil))
                } catch {
                    cont.resume(returning: ([], nil, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
                }
            }
        }
    }

    // MARK: Grouping for consensus

    private func answerGroups() -> [([String], [PropagationRow])] {
        let successful = rows.filter { $0.status == .ok && !$0.values.isEmpty }
        let bucketed = Dictionary(grouping: successful, by: { Self.sortKey($0.values) })
        return bucketed
            .map { (key, rows) -> ([String], [PropagationRow]) in
                (rows.first?.values.sorted() ?? [], rows)
            }
            .sorted { $0.1.count > $1.1.count }
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

// MARK: - Row model

private struct PropagationRow: Identifiable {
    var id: String { resolver.id }
    let resolver: DNSResolver
    var status: RowStatus
    var values: [String]
    var elapsedMs: Double?
    var error: String?

    enum RowStatus { case running, ok, failed }

    var statusColor: Color {
        switch status {
        case .running: return .gray
        case .ok:      return NS.green
        case .failed:  return NS.red
        }
    }
}
