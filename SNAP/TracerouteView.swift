// TracerouteView.swift
// SNAP — Traceroute Tab
// Created by Sevag Bardakjian

import SwiftUI
import Charts

struct HopResult: Identifiable, Hashable {
    let id = UUID()
    static func == (lhs: HopResult, rhs: HopResult) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    var hop: Int
    var host: String
    var ip: String
    var rtt1: String
    var rtt2: String
    var rtt3: String
    var avgRTT: Double?
    var status: HopStatus
    enum HopStatus { case success, timeout, partial }
}

struct TracerouteView: View {
    @State private var host = ""
    @State private var maxHops = "20"
    @State private var hops: [HopResult] = []
    @State private var isRunning = false
    @State private var process: Process?
    // Invalidates buffered callbacks from a stopped run — terminate() is
    // asynchronous, so a restart could otherwise interleave stale hops
    @State private var runID = UUID()
    @State private var rawOutput = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(.blue)
                TextField("Hostname or IP", text: $host)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 250)
                    .onSubmit { if !host.isEmpty && !isRunning { startTrace() } }
                HistoryMenuButton(key: .traceroute) { host = $0 }
                Text("Max Hops:").font(.caption).foregroundStyle(.secondary)
                TextField("", text: $maxHops)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 50)
                Spacer()
                if !hops.isEmpty {
                    ToolActionBar("Traceroute",
                                  text: { "Traceroute to \(host)\n\nhop\thost\tip\trtt1\trtt2\trtt3\n" + hops.map { "\($0.hop)\t\($0.host)\t\($0.ip)\t\($0.rtt1)\t\($0.rtt2)\t\($0.rtt3)" }.joined(separator: "\n") },
                                  csv: { "hop,host,ip,rtt1,rtt2,rtt3\n" + hops.map { "\($0.hop),\(csvEscape($0.host)),\($0.ip),\($0.rtt1),\($0.rtt2),\($0.rtt3)" }.joined(separator: "\n") })
                }
                if isRunning {
                    Button("Stop") {
                        runID = UUID()  // invalidate in-flight callbacks
                        if process?.isRunning == true { process?.terminate() }
                        isRunning = false
                    }
                    .buttonStyle(.bordered).tint(.red)
                    ProgressView().controlSize(.small)
                } else {
                    Button("Trace") { startTrace() }
                        .buttonStyle(.borderedProminent)
                        .disabled(host.isEmpty)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(NS.bg0)

            Divider()

            HSplitView {
                Table(hops) {
                    TableColumn("Hop") { h in
                        Text("\(h.hop)").font(.caption.monospaced())
                    }.width(40)
                    TableColumn("Host") { h in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(h.host).font(.caption)
                            if !h.ip.isEmpty && h.ip != h.host {
                                Text(h.ip).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .hostMenu(h.ip.isEmpty ? h.host : h.ip)
                    }
                    TableColumn("RTT 1") { h in rttCell(h.rtt1) }.width(75)
                    TableColumn("RTT 2") { h in rttCell(h.rtt2) }.width(75)
                    TableColumn("RTT 3") { h in rttCell(h.rtt3) }.width(75)
                    TableColumn("Avg") { h in
                        if let avg = h.avgRTT {
                            Text(String(format: "%.1fms", avg))
                                .font(.caption.monospaced())
                                .foregroundStyle(avg < 50 ? .green : avg < 150 ? .yellow : .red)
                        } else {
                            Text("*").foregroundStyle(.secondary)
                        }
                    }.width(70)
                }
                .frame(minWidth: 400)

                VStack(alignment: .leading) {
                    Text("RTT by Hop").font(.headline).padding(.horizontal)
                    if hops.isEmpty {
                        Spacer()
                        Text("No data yet").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                        Spacer()
                    } else {
                        let chartHops = hops.filter { $0.avgRTT != nil }
                        Chart(chartHops) { h in
                            BarMark(x: .value("Hop", h.hop), y: .value("ms", h.avgRTT ?? 0))
                                .foregroundStyle(
                                    (h.avgRTT ?? 0) < 50 ? Color.green :
                                    (h.avgRTT ?? 0) < 150 ? Color.yellow : Color.red
                                )
                        }
                        .chartYAxisLabel("ms")
                        .chartXAxisLabel("Hop")
                        .padding()
                    }
                }
                .frame(minWidth: 250)
            }
        }
        .navigationTitle("Traceroute")
        // Tab switching recreates this view — terminate the traceroute
        // process instead of orphaning it
        .onDisappear {
            runID = UUID()
            if process?.isRunning == true { process?.terminate() }
            isRunning = false
        }
        .consumeHandoff(for: .traceroute) { host = $0 }
    }

    private func rttCell(_ rtt: String) -> some View {
        Text(rtt)
            .font(.caption.monospaced())
            .foregroundStyle(rtt == "*" ? Color.secondary : Color.primary)
    }

    private func startTrace() {
        let v = host.trimmingCharacters(in: .whitespaces)
        if !v.isEmpty { ToolHistory.shared.add(.traceroute, v) }
        hops = []
        rawOutput = ""
        isRunning = true
        let m = maxHops.isEmpty ? "20" : maxHops
        let id = UUID()
        runID = id

        // UDP traceroute — works without app sandbox (which we've disabled)
        process = Shell.stream("/usr/sbin/traceroute", args: ["-m", m, "-q", "3", host],
            onLine: { [self] line in
                guard runID == id else { return }  // line from a stopped run
                rawOutput += line
                if let hop = parseHop(line) {
                    if let idx = hops.firstIndex(where: { $0.hop == hop.hop }) {
                        hops[idx] = hop
                    } else {
                        hops.append(hop)
                    }
                }
            },
            onFinish: { [self] in
                if runID == id { isRunning = false }
            }
        )
    }

    private func parseHop(_ line: String) -> HopResult? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let hopNum = trimmed.split(separator: " ").first.flatMap({ Int($0) }) else { return nil }

        var hostname = ""
        var ip = ""
        var rtts: [String] = []
        let parts = trimmed.components(separatedBy: " ").filter { !$0.isEmpty }

        var i = 1
        while i < parts.count {
            let tok = parts[i]
            if tok == "*" {
                rtts.append("*")
                i += 1
            } else if tok == "ms" {
                i += 1
            } else if let ms = Double(tok.replacingOccurrences(of: "ms", with: "")), ms > 0 {
                rtts.append(String(format: "%.2fms", ms))
                if i + 1 < parts.count && parts[i + 1] == "ms" { i += 1 }
                i += 1
            } else if tok.hasPrefix("(") {
                ip = tok.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
                i += 1
            } else if tok.contains(".") || tok.contains(":") {
                if hostname.isEmpty { hostname = tok }
                i += 1
            } else if tok.hasPrefix("!") {
                i += 1
            } else {
                if hostname.isEmpty && !tok.isEmpty { hostname = tok }
                i += 1
            }
        }

        let validRTTs = rtts.compactMap { r -> Double? in
            guard r != "*" else { return nil }
            return Double(r.replacingOccurrences(of: "ms", with: ""))
        }
        let avg = validRTTs.isEmpty ? nil : validRTTs.reduce(0, +) / Double(validRTTs.count)
        let status: HopResult.HopStatus = rtts.allSatisfy { $0 == "*" } ? .timeout :
                                          rtts.contains("*") ? .partial : .success

        return HopResult(
            hop: hopNum,
            host: hostname.isEmpty ? (rtts.allSatisfy { $0 == "*" } ? "No response" : host) : hostname,
            ip: ip,
            rtt1: rtts.count > 0 ? rtts[0] : "*",
            rtt2: rtts.count > 1 ? rtts[1] : "*",
            rtt3: rtts.count > 2 ? rtts[2] : "*",
            avgRTT: avg,
            status: status
        )
    }
}
