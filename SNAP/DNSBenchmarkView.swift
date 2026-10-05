// DNSBenchmarkView.swift
// SNAP — DNS Resolver Benchmark
// Created by Sevag Bardakjian
// Copyright © 2025 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
//
// Races a configurable set of public resolvers across N queries to a basket
// of domains. Reports per-resolver mean / median / p95 / failure rate so you
// can pick the fastest resolver from your network's vantage point.

import SwiftUI

struct DNSBenchmarkView: View {
    @State private var samplesPerResolver: Int = 8
    @State private var domainBasket: String = "google.com\napple.com\ncloudflare.com\nwikipedia.org\namazon.com"
    @State private var includeSystem = true
    @State private var rows: [BenchmarkRow] = []
    @State private var progress: Double = 0
    @State private var isRunning = false
    @State private var error = ""

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if !error.isEmpty { errorBar }
            Divider()
            HSplitView {
                resultTable.frame(minWidth: 520)
                configPane.frame(minWidth: 220, idealWidth: 260)
            }
        }
        .navigationTitle("DNS Benchmark")
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: "stopwatch").foregroundStyle(.purple)
            Text("Resolver Benchmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(NS.text1)
            if isRunning {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 160)
            }
            Spacer()
            if !rows.isEmpty {
                ToolActionBar("DNS Benchmark",
                              text: { exportText() },
                              csv:  { exportCSV() },
                              json: { exportJSON() })
            }
            Button(isRunning ? "Running…" : "Run Benchmark") { run() }
                .buttonStyle(.borderedProminent)
                .disabled(isRunning)
                .keyboardShortcut(.return)
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

    private var resultTable: some View {
        Group {
            if rows.isEmpty && !isRunning {
                EmptyStateView(title: "DNS Benchmark",
                               systemImage: "stopwatch",
                               description: "Race \(PublicResolvers.all.count) public resolvers against a basket of domains. Adjust the sample count and domain list on the right, then press Run Benchmark.")
            } else {
                Table(rows.sorted { sortRows($0, $1) }) {
                    TableColumn("Rank") { r in
                        Text("\(rankOf(r))")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(rankColor(rankOf(r)))
                    }.width(40)
                    TableColumn("Resolver") { r in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.name).font(.system(size: 12, weight: .medium))
                            Text(r.ip).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }.width(min: 170, ideal: 200)
                    TableColumn("Mean") { r in
                        Text(r.meanMs.map { String(format: "%.1f ms", $0) } ?? "—")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(latencyColor(r.meanMs))
                    }.width(80)
                    TableColumn("Median") { r in
                        Text(r.medianMs.map { String(format: "%.1f ms", $0) } ?? "—")
                            .font(.system(size: 11, design: .monospaced))
                    }.width(80)
                    TableColumn("p95") { r in
                        Text(r.p95Ms.map { String(format: "%.1f ms", $0) } ?? "—")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(NS.text3)
                    }.width(80)
                    TableColumn("Loss") { r in
                        let lossPct = r.totalAttempts == 0 ? 0 : Int((Double(r.failures) / Double(r.totalAttempts)) * 100)
                        Text("\(lossPct)%")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(lossPct == 0 ? NS.green : (lossPct < 20 ? NS.amber : NS.red))
                    }.width(60)
                    TableColumn("Samples") { r in
                        Text("\(r.totalAttempts - r.failures)/\(r.totalAttempts)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }.width(80)
                }
            }
        }
    }

    private var configPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Configuration").font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Queries per resolver")
                    .font(.system(size: 11))
                    .foregroundStyle(NS.text3)
                Stepper("\(samplesPerResolver)", value: $samplesPerResolver, in: 3...30)
                    .frame(maxWidth: 140)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Domain basket (one per line)")
                    .font(.system(size: 11))
                    .foregroundStyle(NS.text3)
                TextEditor(text: $domainBasket)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(minHeight: 120)
                    .background(NS.bg2)
                    .cornerRadius(4)
            }

            Toggle(isOn: $includeSystem) {
                Text("Include system resolver")
                    .font(.system(size: 11))
                    .foregroundStyle(NS.text2)
            }
            .toggleStyle(.checkbox)

            Text("Resolvers are queried via UDP/53. Each receives \(samplesPerResolver) queries × \(domains.count) domains = \(samplesPerResolver * domains.count) total.")
                .font(.system(size: 10))
                .foregroundStyle(NS.text3)

            Spacer()
        }
        .padding(16)
        .background(NS.bg1)
    }

    // MARK: Run

    private var domains: [String] {
        domainBasket.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func run() {
        let basket = domains
        guard !basket.isEmpty else { error = "Domain basket is empty"; return }
        error = ""

        let resolvers = PublicResolvers.all
        rows = resolvers.map {
            BenchmarkRow(id: $0.id, name: $0.name, ip: $0.ip, samples: [], failures: 0, totalAttempts: 0)
        }
        isRunning = true
        progress = 0

        let perResolver = samplesPerResolver
        let totalResolvers = Double(resolvers.count)

        Task.detached {
            await withTaskGroup(of: BenchmarkRow.self) { group in
                for r in resolvers {
                    group.addTask {
                        var samples: [Double] = []
                        var failures = 0
                        for _ in 0..<perResolver {
                            for d in basket {
                                let res = await Self.timedQuery(server: r.ip, name: d)
                                if let ms = res { samples.append(ms) } else { failures += 1 }
                            }
                        }
                        return BenchmarkRow(
                            id: r.id, name: r.name, ip: r.ip,
                            samples: samples,
                            failures: failures,
                            totalAttempts: perResolver * basket.count
                        )
                    }
                }
                for await finalRow in group {
                    await MainActor.run {
                        if let i = rows.firstIndex(where: { $0.id == finalRow.id }) {
                            rows[i] = finalRow
                        }
                        progress = min(1.0, progress + 1.0 / totalResolvers)
                    }
                }
            }
            await MainActor.run {
                isRunning = false
                progress = 1.0
            }
        }
    }

    private static func timedQuery(server: String, name: String) async -> Double? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let r = try DNSWire.query(server: server, name: name, type: .a, timeout: 2.0)
                    cont.resume(returning: r.elapsedMs)
                } catch {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    // MARK: Sorting / Display

    private func sortRows(_ a: BenchmarkRow, _ b: BenchmarkRow) -> Bool {
        let aLoss = a.totalAttempts == 0 ? 1.0 : Double(a.failures) / Double(a.totalAttempts)
        let bLoss = b.totalAttempts == 0 ? 1.0 : Double(b.failures) / Double(b.totalAttempts)
        // Resolvers that lost any query rank below ones with no loss, all else equal
        if (aLoss == 0) != (bLoss == 0) { return aLoss < bLoss }
        let aMed = a.medianMs ?? .infinity
        let bMed = b.medianMs ?? .infinity
        return aMed < bMed
    }

    private func rankOf(_ row: BenchmarkRow) -> Int {
        (rows.sorted { sortRows($0, $1) }.firstIndex { $0.id == row.id } ?? 0) + 1
    }

    private func rankColor(_ rank: Int) -> Color {
        switch rank {
        case 1: return NS.green
        case 2, 3: return NS.amber
        default: return NS.text3
        }
    }

    private func latencyColor(_ ms: Double?) -> Color {
        guard let ms = ms else { return NS.text3 }
        if ms < 25 { return NS.green }
        if ms < 80 { return NS.amber }
        return NS.red
    }

    // MARK: Export

    private func exportText() -> String {
        var out = "DNS Benchmark\n"
        out += String(repeating: "—", count: 60) + "\n"
        out += "Domains: \(domains.joined(separator: ", "))\n"
        out += "Samples/resolver: \(samplesPerResolver) × \(domains.count) = \(samplesPerResolver * domains.count)\n\n"
        for r in rows.sorted(by: sortRows) {
            let mean = r.meanMs.map { String(format: "%.1f", $0) } ?? "—"
            let med  = r.medianMs.map { String(format: "%.1f", $0) } ?? "—"
            let p95  = r.p95Ms.map { String(format: "%.1f", $0) } ?? "—"
            let lossPct = r.totalAttempts == 0 ? 0 : Int((Double(r.failures) / Double(r.totalAttempts)) * 100)
            out += "\(r.name)  \(r.ip)\n"
            out += "    mean=\(mean)ms  median=\(med)ms  p95=\(p95)ms  loss=\(lossPct)%\n"
        }
        return out
    }

    private func exportCSV() -> String {
        var out = "resolver_ip,resolver_name,mean_ms,median_ms,p95_ms,failures,attempts\n"
        for r in rows.sorted(by: sortRows) {
            let mean = r.meanMs.map { String(format: "%.2f", $0) } ?? ""
            let med  = r.medianMs.map { String(format: "%.2f", $0) } ?? ""
            let p95  = r.p95Ms.map { String(format: "%.2f", $0) } ?? ""
            out += "\(r.ip),\(r.name),\(mean),\(med),\(p95),\(r.failures),\(r.totalAttempts)\n"
        }
        return out
    }

    private func exportJSON() -> String {
        let arr: [[String: Any]] = rows.sorted(by: sortRows).map { r in
            [
                "resolver_ip": r.ip,
                "resolver_name": r.name,
                "mean_ms": r.meanMs as Any,
                "median_ms": r.medianMs as Any,
                "p95_ms": r.p95Ms as Any,
                "failures": r.failures,
                "attempts": r.totalAttempts
            ]
        }
        let payload: [String: Any] = [
            "tool": "DNS Benchmark",
            "domains": domains,
            "samples_per_resolver": samplesPerResolver,
            "exported_at": ISO8601DateFormatter().string(from: Date()),
            "results": arr
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}

// MARK: - Row model

private struct BenchmarkRow: Identifiable {
    let id: String
    let name: String
    let ip: String
    let samples: [Double]
    let failures: Int
    let totalAttempts: Int

    var meanMs: Double? {
        guard !samples.isEmpty else { return nil }
        return samples.reduce(0, +) / Double(samples.count)
    }

    var medianMs: Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let n = sorted.count
        return n % 2 == 0 ? (sorted[n/2 - 1] + sorted[n/2]) / 2 : sorted[n/2]
    }

    var p95Ms: Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let idx = min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        return sorted[max(0, idx)]
    }
}
