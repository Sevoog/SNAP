// MTRView.swift
// SNAP — mtr-style combined traceroute + per-hop continuous ping
// Created by Sevag Bardakjian
// Copyright © 2025 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md
//
// Two phases:
//   1. Discover the path with one traceroute (`/usr/sbin/traceroute -n -q1 -m N`)
//   2. Spawn a continuous ping per hop (`/sbin/ping -i 1 <hop>`); each
//      reply updates the hop's running stats (Welford for stddev).
//
// The gold-standard view for diagnosing flaky paths: when *one specific
// hop* is dropping packets, the whole upstream looks broken — mtr lets you
// see exactly which one.

import SwiftUI
import Darwin

// MARK: - Model

struct MTRHop: Identifiable {
    let id = UUID()
    let num: Int
    var ip: String
    var hostname: String?
    var sent: Int = 0
    var recv: Int = 0
    var lastMs: Double?
    var bestMs: Double?
    var worstMs: Double?
    // Welford running stats — private storage means the auto-synthesized
    // init is `private`, so define an explicit init that callers can use.
    private var mean: Double = 0
    private var m2: Double = 0

    init(num: Int, ip: String, hostname: String? = nil) {
        self.num = num
        self.ip = ip
        self.hostname = hostname
    }

    var avgMs: Double? {
        recv > 0 ? mean : nil
    }
    var stdDevMs: Double? {
        recv > 1 ? sqrt(m2 / Double(recv - 1)) : nil
    }
    var lossPct: Double {
        sent == 0 ? 0 : Double(sent - recv) / Double(sent) * 100.0
    }

    mutating func recordReply(ms: Double) {
        sent += 1
        recv += 1
        lastMs = ms
        bestMs  = min(bestMs ?? ms, ms)
        worstMs = max(worstMs ?? ms, ms)
        // Welford
        let delta = ms - mean
        mean += delta / Double(recv)
        let delta2 = ms - mean
        m2 += delta * delta2
    }

    mutating func recordTimeout() {
        sent += 1
    }
}

@MainActor
final class MTRModel: ObservableObject {
    @Published var hops: [MTRHop] = []
    @Published var isRunning = false
    @Published var phase: Phase = .idle
    @Published var target: String = ""
    @Published var maxHops: Int = 25
    @Published var elapsed: TimeInterval = 0
    @Published var error: String = ""

    enum Phase: String {
        case idle, discovering, running, stopped
        var label: String {
            switch self {
            case .idle:        return "Idle"
            case .discovering: return "Discovering path…"
            case .running:     return "Running"
            case .stopped:     return "Stopped"
            }
        }
    }

    private var pingProcesses: [Process] = []
    private var startedAt: Date?
    private var tickTimer: Timer?

    // MARK: Start / stop

    func start() {
        guard !isRunning, !target.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        error = ""
        hops = []
        isRunning = true
        startedAt = Date()
        phase = .discovering

        // Tick timer for the session elapsed counter. Captured `start`
        // avoids touching the main-actor-isolated `startedAt` from inside
        // the Timer's Sendable closure.
        tickTimer?.invalidate()
        let start = Date()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let s = self else { return }
            DispatchQueue.main.async { s.elapsed = Date().timeIntervalSince(start) }
        }
        RunLoop.main.add(t, forMode: .common)
        tickTimer = t

        Task {
            let path = await discoverPath()
            if path.isEmpty {
                error = "Couldn't discover a path to \(target)"
                stop()
                return
            }
            self.hops = path.enumerated().map { (i, ip) in
                MTRHop(num: i + 1, ip: ip)
            }
            phase = .running
            launchPingPerHop()
        }
    }

    func stop() {
        for p in pingProcesses where p.isRunning {
            p.terminate()
        }
        pingProcesses.removeAll()
        tickTimer?.invalidate()
        tickTimer = nil
        isRunning = false
        phase = .stopped
    }

    func reset() {
        stop()
        hops = []
        elapsed = 0
        error = ""
        phase = .idle
    }

    // MARK: Phase A — path discovery

    private func discoverPath() async -> [String] {
        let t = target.trimmingCharacters(in: .whitespaces)
        let out = await Shell.run("/usr/sbin/traceroute",
                                  args: ["-n", "-q", "1", "-m", String(maxHops), "-w", "2", t])
        return Self.parseTraceroute(out)
    }

    /// Parses macOS `traceroute -n` output. Lines look like:
    ///   ` 1  192.168.1.1  1.234 ms`
    ///   ` 2  * * *`            (a fully-blackhole hop)
    /// Returns one IP per hop slot; "*" hops become "*" placeholders so
    /// the row exists in the table and the hop number is preserved.
    static func parseTraceroute(_ out: String) -> [String] {
        var result: [String] = []
        for raw in out.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // Skip header line
            if line.lowercased().hasPrefix("traceroute") { continue }
            // First token must be a hop number
            let tokens = line.split(whereSeparator: { $0.isWhitespace })
            guard let _ = Int(tokens.first ?? "") else { continue }
            // Second token is the IP, or "*" if hop didn't respond
            if tokens.count >= 2 {
                let second = String(tokens[1])
                if second == "*" {
                    result.append("*")
                } else {
                    result.append(second)
                }
            }
        }
        return result
    }

    // MARK: Phase B — continuous ping per hop

    private func launchPingPerHop() {
        for i in hops.indices {
            let hop = hops[i]
            if hop.ip == "*" { continue }
            let ip = hop.ip
            let proc = Shell.stream("/sbin/ping",
                                    args: ["-i", "1", "-W", "2000", ip],
                                    onLine: { [weak self] line in
                                        Task { @MainActor in self?.parsePingLine(hopIndex: i, line: line) }
                                    },
                                    onFinish: {})
            pingProcesses.append(proc)
        }
        // Best-effort reverse DNS for each non-blackhole hop, in the background.
        Task {
            for i in hops.indices {
                let ip = hops[i].ip
                guard ip != "*" else { continue }
                if let h = await Self.reverseDNS(ip) {
                    hops[i].hostname = h
                }
            }
        }
    }

    private func parsePingLine(hopIndex i: Int, line: String) {
        guard i < hops.count else { return }
        let lower = line.lowercased()
        // macOS ping per-reply line examples:
        //   "64 bytes from 192.168.1.1: icmp_seq=0 ttl=64 time=1.234 ms"
        //   "Request timeout for icmp_seq 1"
        if lower.contains("request timeout") || lower.contains("no answer") {
            hops[i].recordTimeout()
            return
        }
        // Latency parse: locate "time=" and take the number that follows.
        if let r = line.range(of: "time=") {
            let tail = line[r.upperBound...]
            let digits = tail.split(whereSeparator: { !$0.isNumber && $0 != "." })
            if let first = digits.first, let ms = Double(String(first)) {
                hops[i].recordReply(ms: ms)
            }
        }
    }

    // MARK: Helpers

    private static func reverseDNS(_ ip: String) async -> String? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                var hints = addrinfo()
                hints.ai_family = AF_INET
                hints.ai_socktype = SOCK_STREAM
                var res: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(ip, nil, &hints, &res) == 0, let r = res else {
                    cont.resume(returning: nil); return
                }
                defer { freeaddrinfo(r) }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let rc = getnameinfo(r.pointee.ai_addr, r.pointee.ai_addrlen,
                                     &host, socklen_t(host.count),
                                     nil, 0, NI_NAMEREQD)
                cont.resume(returning: rc == 0 ? String(cString: host) : nil)
            }
        }
    }
}

// MARK: - View

struct MTRView: View {
    @StateObject private var model = MTRModel()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if !model.error.isEmpty { errorBar }
            Divider()
            content
            if !model.hops.isEmpty { Divider(); summaryBar }
        }
        .tabNavigationTitle(.mtr)
        .onDisappear { model.stop() }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(.purple)
            TextField("Hostname or IP", text: $model.target)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .disabled(model.isRunning)
                .onSubmit { if !model.isRunning { model.start() } }

            HStack(spacing: 4) {
                Text("Max hops").font(.caption).foregroundStyle(.secondary)
                Stepper("\(model.maxHops)", value: $model.maxHops, in: 5...64)
                    .labelsHidden()
                    .disabled(model.isRunning)
                Text("\(model.maxHops)")
                    .font(.caption.monospaced())
                    .foregroundStyle(NS.text2)
                    .frame(width: 24)
            }

            Spacer()

            if !model.hops.isEmpty {
                ToolActionBar("MTR",
                              text: { exportText() },
                              csv:  { exportCSV() })
            }

            if model.isRunning {
                Button("Stop") { model.stop() }
                    .buttonStyle(.bordered)
                    .tint(.red)
                Circle().fill(.green).frame(width: 8).opacity(0.8)
                Text(model.phase.label).font(.caption).foregroundStyle(.green)
            } else {
                Button("Start") { model.start() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.target.isEmpty)
                    .keyboardShortcut(.return)
                if !model.hops.isEmpty {
                    Button("Reset") { model.reset() }
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(NS.bg0)
    }

    private var errorBar: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(model.error).foregroundStyle(.red).font(.caption)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(Color.red.opacity(0.05))
    }

    @ViewBuilder
    private var content: some View {
        if model.hops.isEmpty {
            EmptyStateView(
                title: model.phase == .discovering ? "Discovering path…" : "MTR — Path Quality",
                systemImage: "point.3.connected.trianglepath.dotted",
                description: model.phase == .discovering
                    ? "Tracing the route to \(model.target)…"
                    : "Enter a host and press Start. SNAP traces the path once, then ping-stresses every hop continuously so you can see exactly which hop is dropping packets, adding jitter, or spiking latency.")
        } else {
            Table(model.hops) {
                TableColumn("Hop") { h in
                    Text("\(h.num)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(NS.text2)
                }.width(40)
                TableColumn("Host") { h in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(h.ip)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(h.ip == "*" ? NS.text3 : NS.text1)
                            .textSelection(.enabled)
                        if let n = h.hostname {
                            Text(n).font(.system(size: 10)).foregroundStyle(NS.text3).lineLimit(1)
                        }
                    }
                }
                TableColumn("Sent") { h in
                    Text("\(h.sent)").font(.system(size: 11, design: .monospaced)).foregroundStyle(NS.text2)
                }.width(50)
                TableColumn("Recv") { h in
                    Text("\(h.recv)").font(.system(size: 11, design: .monospaced)).foregroundStyle(NS.text2)
                }.width(50)
                TableColumn("Loss") { h in
                    Text(h.sent == 0 ? "—" : String(format: "%.0f%%", h.lossPct))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(lossColor(h.lossPct, sent: h.sent))
                }.width(60)
                TableColumn("Last") { h in
                    Text(h.lastMs.map { String(format: "%.1f", $0) } ?? "—")
                        .font(.system(size: 11, design: .monospaced))
                }.width(60)
                TableColumn("Avg") { h in
                    Text(h.avgMs.map { String(format: "%.1f", $0) } ?? "—")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(NS.text1)
                }.width(60)
                TableColumn("Best") { h in
                    Text(h.bestMs.map { String(format: "%.1f", $0) } ?? "—")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(NS.text3)
                }.width(60)
                TableColumn("Worst") { h in
                    Text(h.worstMs.map { String(format: "%.1f", $0) } ?? "—")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(NS.text3)
                }.width(60)
                TableColumn("StDev") { h in
                    Text(h.stdDevMs.map { String(format: "%.1f", $0) } ?? "—")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(NS.text3)
                }.width(60)
            }
        }
    }

    private var summaryBar: some View {
        HStack(spacing: 16) {
            Image(systemName: "clock").font(.system(size: 11)).foregroundStyle(NS.text3)
            Text(timeString(model.elapsed))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(NS.text2)
            Divider().frame(height: 14).background(NS.borderMid)
            Text("\(model.hops.count) hops").font(.system(size: 11)).foregroundStyle(NS.text3)
            Spacer()
            // Identify the "worst" hop (highest loss% with non-zero sent)
            if let worst = model.hops.max(by: { $0.lossPct < $1.lossPct }), worst.lossPct > 0 {
                Text("Worst: hop \(worst.num) (\(Int(worst.lossPct))% loss)")
                    .font(.system(size: 11))
                    .foregroundStyle(NS.amber)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(NS.bg1)
    }

    private func timeString(_ secs: TimeInterval) -> String {
        let s = Int(secs)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return String(format: "%dm %02ds", s/60, s%60) }
        return String(format: "%dh %02dm", s/3600, (s%3600)/60)
    }

    private func lossColor(_ pct: Double, sent: Int) -> Color {
        guard sent > 0 else { return NS.text3 }
        if pct >= 25 { return NS.red }
        if pct >= 5  { return NS.amber }
        if pct > 0   { return NS.amber.opacity(0.7) }
        return NS.green
    }

    // MARK: Export

    private func exportText() -> String {
        func pad(_ s: String, _ w: Int) -> String {
            s.padding(toLength: max(w, s.count), withPad: " ", startingAt: 0)
        }
        func fmt(_ v: Double?) -> String {
            v.map { String(format: "%.1f", $0) } ?? "—"
        }
        var out = "MTR — \(model.target)\n"
        out += "Elapsed: \(timeString(model.elapsed))\n"
        out += String(repeating: "—", count: 96) + "\n"
        out += "\(pad("Hop", 4)) \(pad("Host", 22)) \(pad("Sent", 6)) \(pad("Recv", 6)) \(pad("Loss", 7)) \(pad("Last", 7)) \(pad("Avg", 7)) \(pad("Best", 7)) \(pad("Worst", 7)) \(pad("StDev", 7))\n"
        for h in model.hops {
            let loss = String(format: "%.0f%%", h.lossPct)
            out += "\(pad(String(h.num), 4)) \(pad(h.ip, 22)) \(pad(String(h.sent), 6)) \(pad(String(h.recv), 6)) \(pad(loss, 7)) \(pad(fmt(h.lastMs), 7)) \(pad(fmt(h.avgMs), 7)) \(pad(fmt(h.bestMs), 7)) \(pad(fmt(h.worstMs), 7)) \(pad(fmt(h.stdDevMs), 7))\n"
        }
        return out
    }

    private func exportCSV() -> String {
        var out = "hop,ip,hostname,sent,recv,loss_pct,last_ms,avg_ms,best_ms,worst_ms,stddev_ms\n"
        for h in model.hops {
            out += "\(h.num),\(h.ip),\(h.hostname ?? ""),\(h.sent),\(h.recv),"
            out += String(format: "%.2f", h.lossPct) + ","
            out += (h.lastMs.map  { String(format: "%.2f", $0) } ?? "") + ","
            out += (h.avgMs.map   { String(format: "%.2f", $0) } ?? "") + ","
            out += (h.bestMs.map  { String(format: "%.2f", $0) } ?? "") + ","
            out += (h.worstMs.map { String(format: "%.2f", $0) } ?? "") + ","
            out += (h.stdDevMs.map { String(format: "%.2f", $0) } ?? "") + "\n"
        }
        return out
    }
}
