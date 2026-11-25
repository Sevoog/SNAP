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
    /// Stop was pressed before this host's checks finished
    var stopped = false
}

struct MultiHostCompareView: View {
    @State private var hosts: [String] = ["google.com", "cloudflare.com", ""]
    @State private var results: [HostCompareResult] = []
    @State private var isRunning = false
    @State private var pingCount = "5"
    @State private var checkPorts = "80,443"
    @State private var errorMessage: String?
    @State private var runTask: Task<Void, Never>?
    /// Identifies the current run; Stop and a new Compare change it, so a
    /// stopped run's late results are dropped
    @State private var runID = UUID()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "server.rack").foregroundStyle(.blue)
                Text("Multi-Host Compare").font(.subheadline.bold())
                Spacer()
                Text("Pings:").font(.caption).foregroundStyle(.secondary)
                TextField("", text: $pingCount).textFieldStyle(.roundedBorder).frame(width: 40)
                    .onSubmit(submitCompare)
                Text("Check Ports:").font(.caption).foregroundStyle(.secondary)
                TextField("80,443", text: $checkPorts).textFieldStyle(.roundedBorder).frame(width: 100)
                    .onSubmit(submitCompare)
                if !results.isEmpty {
                    ToolActionBar("Multi-Host",
                                  text: { "host\tping_avg\tping_loss\tdns\thttp\thttp_ms\topen_ports\tproblem\n" + results.map { r in
                                      "\(r.host)\t\(r.pingAvg.map { String(format: "%.1f", $0) } ?? "—")\t\(r.pingLoss.map { String(format: "%.0f%%", $0) } ?? "—")\t\(r.dnsResolved ?? "—")\t\(r.httpStatus.map(String.init) ?? "—")\t\(r.httpMs.map { String(format: "%.0f", $0) } ?? "—")\t\(Self.portSummary(r.portOpen) ?? "")\t\(r.error ?? "")" }.joined(separator: "\n") },
                                  csv: { "host,ping_avg_ms,ping_min_ms,ping_max_ms,ping_loss_pct,dns,http_status,http_ms,open_ports,not_open_ports,problem\n" + results.map { r in
                                      "\(csvEscape(r.host)),\(r.pingAvg.map { String(format: "%.2f", $0) } ?? ""),\(r.pingMin.map { String(format: "%.2f", $0) } ?? ""),\(r.pingMax.map { String(format: "%.2f", $0) } ?? ""),\(r.pingLoss.map { String(format: "%.0f", $0) } ?? ""),\(r.dnsResolved ?? ""),\(r.httpStatus.map(String.init) ?? ""),\(r.httpMs.map { String(format: "%.0f", $0) } ?? ""),\(Self.ports(r.portOpen, open: true)),\(Self.ports(r.portOpen, open: false)),\(csvEscape(r.error ?? ""))" }.joined(separator: "\n") })
                }
                if isRunning {
                    Button("Stop") { stopCompare() }
                        .buttonStyle(.bordered).tint(.red)
                        .fixedSize()
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

            if let errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(NS.amber)
                    Text(errorMessage).font(.caption).foregroundStyle(NS.text1)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 6)
                .background(NS.bg3)
                Divider()
            }

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
                                    .onSubmit(submitCompare)
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
                                    Text("Open Ports").font(.caption.bold())
                                }
                                Divider()
                                ForEach(results) { r in
                                    GridRow {
                                        HStack(alignment: .firstTextBaseline) {
                                            if r.isRunning {
                                                ProgressView().controlSize(.mini)
                                            } else if r.stopped {
                                                Image(systemName: "stop.circle")
                                                    .foregroundStyle(NS.text3)
                                                    .font(.caption)
                                            } else {
                                                Image(systemName: r.error != nil ? "xmark.circle.fill" : "checkmark.circle.fill")
                                                    .foregroundStyle(r.error != nil ? NS.red : NS.green)
                                                    .font(.caption)
                                            }
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(r.host).font(.caption.bold())
                                                    .hostMenu(r.host)
                                                if r.stopped {
                                                    Text("Stopped").font(.caption2).foregroundStyle(NS.text3)
                                                        .fixedSize()
                                                } else if let err = r.error {
                                                    Text(err).font(.caption2).foregroundStyle(NS.red)
                                                        .fixedSize()
                                                }
                                            }
                                        }
                                        metricCell(r.pingAvg.map { String(format: "%.1fms", $0) }, quality: pingQuality(r.pingAvg))
                                        metricCell(r.pingMin.map { String(format: "%.1fms", $0) }, quality: .neutral)
                                        metricCell(r.pingMax.map { String(format: "%.1fms", $0) }, quality: pingQuality(r.pingMax))
                                        metricCell(r.pingLoss.map { String(format: "%.0f%%", $0) }, quality: lossQuality(r.pingLoss))
                                        metricCell(r.httpStatus.map { "\($0)" }, quality: httpQuality(r.httpStatus))
                                        metricCell(r.httpMs.map { String(format: "%.0fms", $0) }, quality: pingQuality(r.httpMs))
                                        metricCell(r.dnsResolved.map { String($0.prefix(18)) }, quality: r.dnsResolved != nil ? .good : .bad)
                                        metricCell(Self.portSummary(r.portOpen), quality: .neutral)
                                            .help(Self.portDetail(r.portOpen))
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
        .onDisappear { stopCompare() }
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

    /// Return in a field: same condition as the Compare button, which only
    /// shows while nothing is running.
    private func submitCompare() {
        if !isRunning { startCompare() }
    }

    private func startCompare() {
        guard !isRunning else { return }
        errorMessage = nil
        // Results are matched back by host, so a host listed twice would
        // leave its second row spinning: compare each host once
        var seenHosts = Set<String>()
        let validHosts = hosts.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seenHosts.insert($0.lowercased()).inserted }
        // Blank hosts used to leave the tool spinning forever: with no hosts
        // the group never reports a finished one
        guard !validHosts.isEmpty else {
            errorMessage = "Add at least one host to compare."
            return
        }
        // 0 or less ran `ping -c 0`, which pings until stopped, then divided by zero
        guard let cnt = Self.pingCount(pingCount) else {
            errorMessage = "Enter a ping count from 1 to 50."
            return
        }
        let ports = Self.parsePorts(checkPorts)
        guard ports.count <= Self.maxPorts else {
            errorMessage = "Check up to \(Self.maxPorts) ports at a time."
            return
        }
        results = validHosts.map { HostCompareResult(host: $0, isRunning: true) }
        isRunning = true
        let id = UUID()
        runID = id

        runTask = Task {
            await withTaskGroup(of: HostCompareResult.self) { group in
                for host in validHosts {
                    group.addTask { await runChecks(host: host, pingCount: cnt, ports: ports) }
                }
                var done = 0
                for await result in group {
                    await MainActor.run {
                        guard runID == id else { return }
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

    /// Ends the run: pings are terminated, and hosts still being checked
    /// read "Stopped". Finished rows keep their results.
    private func stopCompare() {
        guard isRunning else { return }
        runID = UUID()
        runTask?.cancel()
        runTask = nil
        isRunning = false
        for i in results.indices where results[i].isRunning {
            results[i].isRunning = false
            results[i].stopped = true
        }
    }

    private func runChecks(host: String, pingCount: Int, ports: [UInt16]) async -> HostCompareResult {
        var r = HostCompareResult(host: host, isRunning: true)

        // Ports, alongside the ping
        async let portResults = Self.testPorts(host: host, ports: ports)

        // Ping
        let pingOut = await Shell.run("/sbin/ping", args: ["-c", "\(pingCount)", "-W", "3000", host],
                                      stopsOnCancel: true)
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
        // getaddrinfo blocks (seconds for a name that doesn't resolve), and
        // this method runs on the main actor, so look it up elsewhere
        r.dnsResolved = await Task.detached { Self.resolveIPv4(host) }.value

        // HTTP
        if let url = URL(string: "https://\(host)") {
            let start = Date()
            if let (_, resp) = try? await URLSession.shared.data(from: url),
               let httpResp = resp as? HTTPURLResponse {
                r.httpStatus = httpResp.statusCode
                r.httpMs = Date().timeIntervalSince(start) * 1000
            }
        }

        r.portOpen = await portResults
        // The DNS column is IPv4 only; an IPv6-only name still counts as found
        var found = r.dnsResolved != nil
        if !found { found = await Task.detached { TCPPing.resolve(host, port: 80) != nil }.value }
        r.error = Self.failure(found: found, pingReplies: pings.count,
                               httpStatus: r.httpStatus, portOpen: r.portOpen)

        r.isRunning = false
        return r
    }

    // MARK: Checks (static so tests can reach them)

    /// The ping count field, 1 to 50.
    nonisolated static func pingCount(_ text: String) -> Int? {
        guard let n = Int(text.trimmingCharacters(in: .whitespaces)), (1...50).contains(n) else { return nil }
        return n
    }

    /// The Check Ports field: valid ports in the order typed, no repeats.
    /// Each port is a blocking handshake of up to 2 s per host.
    nonisolated static let maxPorts = 20

    nonisolated static func parsePorts(_ text: String) -> [UInt16] {
        var seen = Set<UInt16>()
        return text.split(separator: ",").compactMap { TCPPing.port(String($0)) }.filter { seen.insert($0).inserted }
    }

    /// Why a finished row failed, or nil when the host answered something.
    nonisolated static func failure(found: Bool, pingReplies: Int, httpStatus: Int?, portOpen: [Int: Bool]) -> String? {
        if !found { return "Couldn't find this host. Check the spelling." }
        if pingReplies == 0 && httpStatus == nil && !portOpen.values.contains(true) {
            return "No answer to ping, HTTPS or port checks."
        }
        return nil
    }

    /// Open ports for the table cell; nil when no ports were checked.
    nonisolated static func portSummary(_ portOpen: [Int: Bool]) -> String? {
        guard !portOpen.isEmpty else { return nil }
        let open = ports(portOpen, open: true)
        return open.isEmpty ? "None" : open.replacingOccurrences(of: ";", with: ", ")
    }

    /// Every checked port and its state, for the cell's tooltip.
    nonisolated static func portDetail(_ portOpen: [Int: Bool]) -> String {
        portOpen.keys.sorted().map { "\($0) \(portOpen[$0] == true ? "open" : "not open")" }.joined(separator: ", ")
    }

    /// Ports in one state, sorted and separated by semicolons (for CSV).
    nonisolated static func ports(_ portOpen: [Int: Bool], open: Bool) -> String {
        portOpen.filter { $0.value == open }.keys.sorted().map(String.init).joined(separator: ";")
    }

    /// TCP-connects each port (the same handshake as Ping's TCP mode).
    /// True means the port accepted; a reset or no answer is false.
    nonisolated private static func testPorts(host: String, ports: [UInt16]) async -> [Int: Bool] {
        await withTaskGroup(of: (Int, Bool).self) { group in
            for p in ports {
                group.addTask {
                    // The lookup and handshake block, so they run on a GCD
                    // thread rather than tying up Swift's small shared pool
                    await withCheckedContinuation { cont in
                        DispatchQueue.global(qos: .userInitiated).async {
                            guard let target = TCPPing.resolve(host, port: p) else {
                                cont.resume(returning: (Int(p), false)); return
                            }
                            if case .open = TCPPing.probe(target.address, timeout: 2) {
                                cont.resume(returning: (Int(p), true)); return
                            }
                            cont.resume(returning: (Int(p), false))
                        }
                    }
                }
            }
            var out: [Int: Bool] = [:]
            for await (p, open) in group { out[p] = open }
            return out
        }
    }

    /// Resolve the first IPv4 address for a host via getaddrinfo — replaces
    /// the `/usr/bin/host -t A` shell-out.
    nonisolated private static func resolveIPv4(_ host: String) -> String? {
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
