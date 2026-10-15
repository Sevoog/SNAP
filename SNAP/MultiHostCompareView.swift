// MultiHostCompareView.swift
// SNAP — Multi-Host Compare
// Created by Sevag Bardakjian
// Copyright © 2025-2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md

import SwiftUI
import Charts

struct HostCompareResult: Identifiable , Hashable {
    let id = UUID()
    static func == (lhs: HostCompareResult, rhs: HostCompareResult) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    var host: String
    var isRunning = false
    var pingAvg: Double?
    var pingMin: Double?
    var pingMax: Double?
    var pingLoss: Double?
    var dnsResolved: String?
    var httpStatus: Int?
    var httpMs: Double?
    var portOpen: [Int: Bool] = [:]
    var error: String?
    var samples: [Double] = []
}

struct MultiHostCompareView: View {
    @State private var hosts: [String] = ["google.com", "cloudflare.com", ""]
    @State private var results: [HostCompareResult] = []
    @State private var isRunning = false
    @State private var pingCount = "5"
    @State private var checkPorts = "80,443"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "server.rack").foregroundStyle(.blue)
                Text("Multi-Host Compare").font(.subheadline.bold())
                Spacer()
                Text("Pings:").font(.caption).foregroundStyle(.secondary)
                TextField("", text: $pingCount).textFieldStyle(.roundedBorder).frame(width: 40)
                Text("Check Ports:").font(.caption).foregroundStyle(.secondary)
                TextField("80,443", text: $checkPorts).textFieldStyle(.roundedBorder).frame(width: 100)
                if !results.isEmpty {
                    ToolActionBar("Multi-Host",
                                  text: { "host\tping_avg\tping_loss\tdns\thttp\thttp_ms\n" + results.map { r in
                                      "\(r.host)\t\(r.pingAvg.map { String(format: "%.1f", $0) } ?? "—")\t\(r.pingLoss.map { String(format: "%.0f%%", $0) } ?? "—")\t\(r.dnsResolved ?? "—")\t\(r.httpStatus.map(String.init) ?? "—")\t\(r.httpMs.map { String(format: "%.0f", $0) } ?? "—")" }.joined(separator: "\n") },
                                  csv: { "host,ping_avg_ms,ping_min_ms,ping_max_ms,ping_loss_pct,dns,http_status,http_ms\n" + results.map { r in
                                      "\(csvEscape(r.host)),\(r.pingAvg.map { String(format: "%.2f", $0) } ?? ""),\(r.pingMin.map { String(format: "%.2f", $0) } ?? ""),\(r.pingMax.map { String(format: "%.2f", $0) } ?? ""),\(r.pingLoss.map { String(format: "%.0f", $0) } ?? ""),\(r.dnsResolved ?? ""),\(r.httpStatus.map(String.init) ?? ""),\(r.httpMs.map { String(format: "%.0f", $0) } ?? "")" }.joined(separator: "\n") })
                }
                if isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Compare") { startCompare() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(NS.bg0)

            Divider()

            HSplitView {
                // Host input list
                VStack(spacing: 0) {
                    Text("Hosts to Compare")
                        .font(.headline).padding(10)
                    List {
                        ForEach(hosts.indices, id: \.self) { i in
                            HStack {
                                TextField("Hostname or IP", text: $hosts[i])
                                    .textFieldStyle(.roundedBorder)
                                if hosts.count > 1 {
                                    Button {
                                        hosts.remove(at: i)
                                    } label: {
                                        Image(systemName: "minus.circle.fill")
                                            .foregroundStyle(.red)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        Button {
                            hosts.append("")
                        } label: {
                            Label("Add Host", systemImage: "plus")
                        }
                    }
                }
                .frame(minWidth: 180, maxWidth: 240)

                // Results
                if results.isEmpty {
                    EmptyStateView(title: "No Results", systemImage: "server.rack", description: "Add hosts and press Compare")
                } else {
                    ScrollView {
                        VStack(spacing: 16) {
                            // Summary table
                            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                                GridRow {
                                    Text("Host").font(.caption.bold())
                                    Text("Ping Avg").font(.caption.bold())
                                    Text("Ping Min").font(.caption.bold())
                                    Text("Ping Max").font(.caption.bold())
                                    Text("Loss").font(.caption.bold())
                                    Text("HTTP").font(.caption.bold())
                                    Text("HTTP ms").font(.caption.bold())
                                    Text("DNS").font(.caption.bold())
                                }
                                Divider()
                                ForEach(results) { r in
                                    GridRow {
                                        HStack {
                                            if r.isRunning {
                                                ProgressView().controlSize(.mini)
                                            } else {
                                                Image(systemName: r.error != nil ? "xmark.circle.fill" : "checkmark.circle.fill")
                                                    .foregroundStyle(r.error != nil ? .red : .green)
                                                    .font(.caption)
                                            }
                                            Text(r.host).font(.caption.bold())
                                                .hostMenu(r.host)
                                        }
                                        metricCell(r.pingAvg.map { String(format: "%.1fms", $0) }, quality: pingQuality(r.pingAvg))
                                        metricCell(r.pingMin.map { String(format: "%.1fms", $0) }, quality: .neutral)
                                        metricCell(r.pingMax.map { String(format: "%.1fms", $0) }, quality: pingQuality(r.pingMax))
                                        metricCell(r.pingLoss.map { String(format: "%.0f%%", $0) }, quality: lossQuality(r.pingLoss))
                                        metricCell(r.httpStatus.map { "\($0)" }, quality: httpQuality(r.httpStatus))
                                        metricCell(r.httpMs.map { String(format: "%.0fms", $0) }, quality: pingQuality(r.httpMs))
                                        metricCell(r.dnsResolved.map { String($0.prefix(18)) }, quality: r.dnsResolved != nil ? .good : .bad)
                                    }
                                }
                            }
                            .padding()
                            .background(NS.bg3)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .padding(.horizontal)

                            // Bar chart comparison
                            if results.compactMap({ $0.pingAvg }).count > 1 {
                                let axisText = ChartAxis.text
                                GroupBox("Ping Comparison") {
                                    Chart(results.filter { $0.pingAvg != nil }) { r in
                                        BarMark(x: .value("Host", r.host), y: .value("ms", r.pingAvg ?? 0))
                                            .foregroundStyle(pingQualityColor(r.pingAvg))
                                            .annotation(position: .top) {
                                                Text(String(format: "%.1fms", r.pingAvg ?? 0))
                                                    .font(.caption2)
                                            }
                                    }
                                    .chartYAxisLabel { Text("ms").foregroundStyle(axisText) }
                                    .chartXAxis { AxisMarks { AxisGridLine(); AxisTick(); AxisValueLabel().foregroundStyle(axisText) } }
                                    .chartYAxis { AxisMarks { AxisGridLine(); AxisTick(); AxisValueLabel().foregroundStyle(axisText) } }
                                    .frame(height: 160)
                                    .padding()
                                }
                                .padding(.horizontal)
                            }

                            // Sparklines
                            let axisText = ChartAxis.text
                            ForEach(results.filter { !$0.samples.isEmpty }) { r in
                                GroupBox("\(r.host) — Response Time") {
                                    Chart(r.samples.indices, id: \.self) { i in
                                        LineMark(x: .value("Ping", i), y: .value("ms", r.samples[i]))
                                            .foregroundStyle(pingQualityColor(r.pingAvg))
                                            .interpolationMethod(.catmullRom)
                                    }
                                    .chartYAxisLabel { Text("ms").foregroundStyle(axisText) }
                                    .chartXAxis { AxisMarks { AxisGridLine(); AxisTick(); AxisValueLabel().foregroundStyle(axisText) } }
                                    .chartYAxis { AxisMarks { AxisGridLine(); AxisTick(); AxisValueLabel().foregroundStyle(axisText) } }
                                    .frame(height: 80)
                                    .padding(.horizontal)
                                }
                                .padding(.horizontal)
                            }
                        }
                        .padding(.vertical)
                    }
                }
            }
        }
        .tabNavigationTitle(.multiHost)
    }

    enum Quality { case good, warn, bad, neutral }

    private func metricCell(_ val: String?, quality: Quality) -> some View {
        let color: Color = switch quality {
        case .good:    .green
        case .warn:    .orange
        case .bad:     .red
        case .neutral: .secondary
        }
        return Text(val ?? "—")
            .font(.caption.monospaced())
            .foregroundStyle(val == nil ? Color.secondary : color)
    }

    private func pingQuality(_ ms: Double?) -> Quality {
        guard let ms else { return .neutral }
        if ms < 50 { return .good } else if ms < 150 { return .warn } else { return .bad }
    }

    private func pingQualityColor(_ ms: Double?) -> Color {
        switch pingQuality(ms) {
        case .good: return .green
        case .warn: return .yellow
        case .bad:  return .red
        case .neutral: return .gray
        }
    }

    private func lossQuality(_ loss: Double?) -> Quality {
        guard let loss else { return .neutral }
        if loss == 0 { return .good } else if loss < 10 { return .warn } else { return .bad }
    }

    private func httpQuality(_ status: Int?) -> Quality {
        guard let s = status else { return .neutral }
        if (200...299).contains(s) { return .good } else if (300...399).contains(s) { return .warn } else { return .bad }
    }

    private func startCompare() {
        let validHosts = hosts.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        results = validHosts.map { HostCompareResult(host: $0, isRunning: true) }
        isRunning = true
        let cnt = Int(pingCount) ?? 5
        let ports = checkPorts.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }

        Task {
            await withTaskGroup(of: HostCompareResult.self) { group in
                for host in validHosts {
                    group.addTask { await runChecks(host: host, pingCount: cnt, ports: ports) }
                }
                var done = 0
                for await result in group {
                    await MainActor.run {
                        if let idx = results.firstIndex(where: { $0.host == result.host }) {
                            results[idx] = result
                        }
                        done += 1
                        if done == validHosts.count { isRunning = false }
                    }
                }
            }
        }
    }

    private func runChecks(host: String, pingCount: Int, ports: [Int]) async -> HostCompareResult {
        var r = HostCompareResult(host: host, isRunning: true)

        // Ping
        let pingOut = await Shell.run("/sbin/ping", args: ["-c", "\(pingCount)", "-W", "3000", host])
        var pings: [Double] = []
        for line in pingOut.components(separatedBy: "\n") {
            guard line.contains("bytes from"), let range = line.range(of: "time=") else { continue }
            // macOS ping: "time=5.123 ms" — number then space then ms
            let sub = String(line[range.upperBound...])
            let tokens = sub.split(separator: " ")
            if let firstTok = tokens.first, let ms = Double(firstTok) {
                pings.append(ms)
            }
        }
        r.samples = pings
        r.pingAvg = pings.isEmpty ? nil : pings.reduce(0, +) / Double(pings.count)
        r.pingMin = pings.min()
        r.pingMax = pings.max()
        r.pingLoss = Double(pingCount - pings.count) / Double(pingCount) * 100

        // DNS — resolve the first A record via getaddrinfo (no shell-out)
        r.dnsResolved = Self.resolveIPv4(host)

        // HTTP
        if let url = URL(string: "https://\(host)") {
            let start = Date()
            if let (_, resp) = try? await URLSession.shared.data(from: url),
               let httpResp = resp as? HTTPURLResponse {
                r.httpStatus = httpResp.statusCode
                r.httpMs = Date().timeIntervalSince(start) * 1000
            }
        }

        r.isRunning = false
        return r
    }

    /// Resolve the first IPv4 address for a host via getaddrinfo — replaces
    /// the `/usr/bin/host -t A` shell-out.
    private static func resolveIPv4(_ host: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return nil }
        defer { freeaddrinfo(first) }
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(first.pointee.ai_addr, first.pointee.ai_addrlen,
                          &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(cString: buf)
    }
}
