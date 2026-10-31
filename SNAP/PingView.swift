// PingView.swift
// SNAP — Ping Tab
// Created by Sevag Bardakjian
// Copyright © 2025-2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md

import SwiftUI
import Charts
import Darwin

struct PingResult: Identifiable, Hashable {
    let id = UUID()
    static func == (lhs: PingResult, rhs: PingResult) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    let seq: Int
    let ms: Double?
    let status: String
    var timestamp: Date = Date()
}

/// ICMP echo (the system `ping`), or a timed TCP handshake for hosts and
/// firewalls that drop ICMP.
enum PingMode: String, CaseIterable, Identifiable {
    case icmp = "ICMP", tcp = "TCP"
    var id: String { rawValue }
}

struct PingView: View {
    @State private var host = ""
    @State private var mode: PingMode = .icmp
    @State private var count = "10"
    @State private var interval = "1"
    @State private var packetSize = "56"
    @State private var port = "443"
    @State private var tcpTask: Task<Void, Never>?
    @State private var results: [PingResult] = []
    @State private var isRunning = false
    @State private var process: Process?
    // Identifies the current run. terminate() is asynchronous and
    // Shell.stream flushes buffered lines via main.async, so a stopped run
    // can still deliver lines after a new one starts — stale callbacks
    // check this token and drop out instead of interleaving into the new
    // run's results (which scrambled the table and chart).
    @State private var runID = UUID()
    @State private var rawOutput = ""
    @State private var stats = ""

    private var successResults: [PingResult] { results.filter { $0.ms != nil } }
    private var avgMs: Double { successResults.isEmpty ? 0 : successResults.reduce(0) { $0 + $1.ms! } / Double(successResults.count) }
    private var minMs: Double { successResults.compactMap { $0.ms }.min() ?? 0 }
    private var maxMs: Double { successResults.compactMap { $0.ms }.max() ?? 0 }
    private var lossPercent: Double {
        guard !results.isEmpty else { return 0 }
        let failed = results.filter { $0.ms == nil }.count
        return Double(failed) / Double(results.count) * 100
    }

    var body: some View {
        VStack(spacing: 0) {
            // Controls bar: one row when the window is wide; narrow windows put the
            // host and Ping on the first row and count/interval/size on a second row
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    hostIcon
                    hostField.frame(width: 250)
                    HistoryMenuButton(key: .ping) { host = $0 }

                    Divider().frame(height: 20)

                    pingOptions

                    Spacer()

                    pingActions
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        hostIcon
                        hostField.frame(minWidth: 140, maxWidth: .infinity)
                        HistoryMenuButton(key: .ping) { host = $0 }
                        pingActions
                    }
                    HStack(spacing: 12) {
                        pingOptions
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(NS.bg0)

            Divider()

            HSplitView {
                // Results table
                VStack(spacing: 0) {
                    Table(results) {
                        TableColumn("Seq") { r in
                            Text("\(r.seq)").font(.monospaced(.caption)())
                        }.width(50)
                        TableColumn("Time (ms)") { r in
                            if let ms = r.ms {
                                Text(String(format: "%.3f", ms))
                                    .font(.monospaced(.caption)())
                                    .foregroundStyle(ms < 50 ? .green : ms < 200 ? .yellow : .red)
                            } else {
                                Text("Timeout").foregroundStyle(.red).font(.caption)
                            }
                        }.width(90)
                        TableColumn("Status") { r in
                            Text(r.status).font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    // Stats footer: one row when the pane is wide, two rows of three when narrow
                    if !results.isEmpty {
                        Divider()
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 20) {
                                countBadges
                                latencyBadges
                                Spacer()
                            }
                            Grid(horizontalSpacing: 20, verticalSpacing: 6) {
                                GridRow { countBadges }
                                GridRow { latencyBadges }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(NS.bg3)
                    }
                }
                .frame(minWidth: 300)

                // Chart
                VStack(alignment: .leading, spacing: 8) {
                    Text("Response Time").font(.headline).padding(.horizontal)
                    if successResults.isEmpty {
                        Spacer()
                        Text("No data yet").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                        Spacer()
                    } else {
                        let axisText = ChartAxis.text
                        Chart(successResults) { r in
                            LineMark(x: .value("Seq", r.seq), y: .value("ms", r.ms ?? 0))
                                .foregroundStyle(.blue)
                                .interpolationMethod(.catmullRom)
                            AreaMark(x: .value("Seq", r.seq), y: .value("ms", r.ms ?? 0))
                                .foregroundStyle(.blue.opacity(0.15))
                                .interpolationMethod(.catmullRom)
                            if let ms = r.ms {
                                PointMark(x: .value("Seq", r.seq), y: .value("ms", ms))
                                    .foregroundStyle(ms < 50 ? .green : ms < 200 ? .yellow : .red)
                                    .symbolSize(30)
                            }
                        }
                        .chartYAxisLabel { Text("ms").foregroundStyle(axisText) }
                        .chartXAxisLabel { Text("Sequence").foregroundStyle(axisText) }
                        .chartXAxis { AxisMarks { AxisGridLine(); AxisTick(); AxisValueLabel().foregroundStyle(axisText) } }
                        .chartYAxis { AxisMarks { AxisGridLine(); AxisTick(); AxisValueLabel().foregroundStyle(axisText) } }
                        .padding()
                    }
                }
                .frame(minWidth: 300)
            }
        }
        .tabNavigationTitle(.ping)
        // Runs when the window closes (tabs now stay alive across switches) — without this the ping process
        // keeps running with no UI handle left to stop it
        .onDisappear { stopPing() }
        .consumeHandoff(for: .ping) { host = $0 }
    }

    // MARK: - Controls bar pieces (shared by the one-row and two-row layouts)

    private var hostIcon: some View {
        Image(systemName: "network")
            .foregroundStyle(.blue)
    }

    private var hostField: some View {
        TextField("Hostname or IP", text: $host)
            .textFieldStyle(.roundedBorder)
    }

    @ViewBuilder
    private var pingOptions: some View {
        Picker("Mode", selection: $mode) {
            ForEach(PingMode.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 100)
        .disabled(isRunning)
        .help("ICMP sends echo requests. TCP times a connection to a port, for hosts that block ICMP.")

        Label("Count:", systemImage: "number")
            .foregroundStyle(.secondary).font(.caption)
            .fixedSize()
        TextField("", text: $count)
            .textFieldStyle(.roundedBorder)
            .frame(width: 50)

        Label("Interval:", systemImage: "clock")
            .foregroundStyle(.secondary).font(.caption)
            .fixedSize()
        TextField("", text: $interval)
            .textFieldStyle(.roundedBorder)
            .frame(width: 50)

        if mode == .tcp {
            Label("Port:", systemImage: "door.left.hand.open")
                .foregroundStyle(.secondary).font(.caption)
                .fixedSize()
            TextField("", text: $port)
                .textFieldStyle(.roundedBorder)
                .frame(width: 60)
        } else {
            Label("Size:", systemImage: "doc")
                .foregroundStyle(.secondary).font(.caption)
                .fixedSize()
            TextField("", text: $packetSize)
                .textFieldStyle(.roundedBorder)
                .frame(width: 50)
        }
    }

    @ViewBuilder
    private var pingActions: some View {
        if !results.isEmpty {
            ToolActionBar("Ping", text: { exportText() }, csv: { exportCSV() })
                .fixedSize()
        }
        if isRunning {
            Button("Stop") { stopPing() }
                .buttonStyle(.bordered)
                .tint(.red)
                .fixedSize()
            ProgressView().controlSize(.small)
        } else {
            Button("Ping") { startPing() }
                .buttonStyle(.borderedProminent)
                .disabled(host.isEmpty || (mode == .tcp && TCPPing.port(port) == nil))
                .keyboardShortcut(.return)
                .fixedSize()
        }
    }

    private func startPing() {
        let v = host.trimmingCharacters(in: .whitespaces)
        if !v.isEmpty { ToolHistory.shared.add(.ping, v) }
        results = []
        rawOutput = ""
        isRunning = true
        let c = Int(count) ?? 10
        let i = interval.isEmpty ? "1" : interval
        let s = packetSize.isEmpty ? "56" : packetSize
        var seq = 0
        let id = UUID()
        runID = id
        if mode == .tcp { startTCPPing(id: id); return }

        process = Shell.stream("/sbin/ping", args: ["-c", "\(c)", "-i", i, "-s", s, host],
            onLine: { line in
                guard runID == id else { return }  // line from a stopped run
                self.rawOutput += line
                // Parse "icmp_seq=1 ... time=5.123 ms" or "Request timeout"
                if line.contains("bytes from") {
                    let ms: Double?
                    if let r = line.range(of: "time=") {
                        let sub = String(line[r.upperBound...])
                        if let sp = sub.firstIndex(of: " ") {
                            ms = Double(String(sub[..<sp]))
                        } else { ms = nil }
                    } else {
                        ms = nil
                    }
                    seq += 1
                    self.results.append(PingResult(seq: seq, ms: ms, status: ms != nil ? "Reply" : "No reply"))
                } else if line.contains("timeout") || line.contains("Timeout") {
                    seq += 1
                    self.results.append(PingResult(seq: seq, ms: nil, status: "Timeout"))
                } else if line.contains("---") || line.contains("packets transmitted") {
                    self.stats = line
                }
            },
            onFinish: {
                if runID == id { self.isRunning = false }
            }
        )
    }

    /// Count 0 or less runs until Stop. Each handshake gets 2 s; the next
    /// starts one interval after the last one began.
    private func startTCPPing(id: UUID) {
        guard let p = TCPPing.port(port) else { isRunning = false; return }
        let target = host.trimmingCharacters(in: .whitespaces)
        let total = Int(count) ?? 10
        let gap = max(0.2, Double(interval) ?? 1)
        tcpTask = Task {
            let resolved = await Task.detached { TCPPing.resolve(target, port: p) }.value
            guard runID == id else { return }
            guard let resolved else {
                results.append(PingResult(seq: 1, ms: nil, status: "Couldn't resolve \(target)"))
                isRunning = false
                return
            }
            rawOutput = "TCP ping \(target) (\(resolved.display)) port \(p)\n"
            var seq = 0
            while !Task.isCancelled && runID == id && (total <= 0 || seq < total) {
                let began = Date()
                let outcome = await Task.detached { TCPPing.probe(resolved.address, timeout: 2) }.value
                guard runID == id else { return }
                seq += 1
                results.append(PingResult(seq: seq, ms: outcome.ms,
                                          status: seq == 1 ? "\(outcome.status) · \(resolved.display)" : outcome.status))
                if total > 0 && seq >= total { break }
                let wait = gap - Date().timeIntervalSince(began)
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            }
            if runID == id { isRunning = false }
        }
    }

    private func stopPing() {
        runID = UUID()  // invalidate in-flight callbacks from this run
        if process?.isRunning == true { process?.terminate() }
        tcpTask?.cancel()
        tcpTask = nil
        isRunning = false
    }

    private func exportText() -> String {
        var s = mode == .tcp ? "TCP ping \(host) port \(port)\n" : "Ping \(host)\n"
        s += "sent \(results.count) · recv \(successResults.count) · loss \(String(format: "%.1f%%", lossPercent))\n"
        s += "min \(String(format: "%.2f", minMs)) / avg \(String(format: "%.2f", avgMs)) / max \(String(format: "%.2f", maxMs)) ms\n\n"
        s += "seq\ttime(ms)\tstatus\n"
        for r in results { s += "\(r.seq)\t\(r.ms.map { String(format: "%.3f", $0) } ?? "—")\t\(r.status)\n" }
        return s
    }
    private func exportCSV() -> String {
        var s = "seq,time_ms,status\n"
        for r in results { s += "\(r.seq),\(r.ms.map { String(format: "%.3f", $0) } ?? ""),\(r.status)\n" }
        return s
    }

    @ViewBuilder
    private var countBadges: some View {
        statBadge("Sent", "\(results.count)")
        statBadge("Recv", "\(successResults.count)", color: .green)
        statBadge("Loss", String(format: "%.1f%%", lossPercent), color: lossPercent > 0 ? .red : .green)
    }

    @ViewBuilder
    private var latencyBadges: some View {
        statBadge("Min", String(format: "%.2fms", minMs))
        statBadge("Avg", String(format: "%.2fms", avgMs))
        statBadge("Max", String(format: "%.2fms", maxMs))
    }

    private func statBadge(_ label: String, _ value: String, color: Color = .primary) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline).foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .fixedSize()
    }
}

// MARK: - TCP ping

/// Times a TCP handshake to one port. The name is resolved once, before the
/// first probe, so DNS time isn't counted. A reset (connection refused) still
/// means the host answered, so it counts as a reply with the port closed.
enum TCPPing {
    enum Outcome: Equatable {
        case open(ms: Double)
        case refused(ms: Double)
        case timeout
        case failed(String)

        var ms: Double? {
            switch self {
            case .open(let ms), .refused(let ms): return ms
            case .timeout, .failed: return nil
            }
        }

        var status: String {
            switch self {
            case .open:             return "Open"
            case .refused:          return "Port closed (reset)"
            case .timeout:          return "Timeout"
            case .failed(let why):  return why
            }
        }
    }

    /// The port typed into the field, 1 to 65535.
    static func port(_ text: String) -> UInt16? {
        guard let n = Int(text.trimmingCharacters(in: .whitespaces)), (1...65535).contains(n) else { return nil }
        return UInt16(n)
    }

    /// The first address the system resolver gives for `host` (IPv4 or IPv6),
    /// as a sockaddr with `port` filled in, plus the address as text.
    static func resolve(_ host: String, port: UInt16) -> (address: Data, display: String)? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let r = res, let sa = r.pointee.ai_addr else { return nil }
        defer { freeaddrinfo(r) }
        var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        getnameinfo(sa, r.pointee.ai_addrlen, &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST)
        return (Data(bytes: sa, count: Int(r.pointee.ai_addrlen)), String(cString: name))
    }

    /// One handshake to an address from `resolve`. Blocks for up to
    /// `timeout`, so run it off the main thread.
    static func probe(_ address: Data, timeout: TimeInterval) -> Outcome {
        address.withUnsafeBytes { raw -> Outcome in
            guard let sa = raw.baseAddress?.assumingMemoryBound(to: sockaddr.self) else { return .failed("No address") }
            let sock = Darwin.socket(Int32(sa.pointee.sa_family), SOCK_STREAM, IPPROTO_TCP)
            guard sock >= 0 else { return .failed("Couldn't open a socket") }
            defer { Darwin.close(sock) }
            var on: Int32 = 1
            setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(sock, F_SETFL, fcntl(sock, F_GETFL, 0) | O_NONBLOCK)

            let start = DispatchTime.now().uptimeNanoseconds
            func elapsed() -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }
            if Darwin.connect(sock, sa, socklen_t(raw.count)) == 0 { return .open(ms: elapsed()) }
            guard errno == EINPROGRESS else { return outcome(errno, ms: elapsed()) }

            var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&pfd, 1, Int32(timeout * 1000))
            let ms = elapsed()
            if ready == 0 { return .timeout }
            if ready < 0 { return outcome(errno, ms: ms) }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(sock, SOL_SOCKET, SO_ERROR, &err, &len)
            return err == 0 ? .open(ms: ms) : outcome(err, ms: ms)
        }
    }

    static func outcome(_ err: Int32, ms: Double) -> Outcome {
        switch err {
        case ECONNREFUSED:            return .refused(ms: ms)
        case ETIMEDOUT:               return .timeout
        case EHOSTUNREACH, EHOSTDOWN: return .failed("Host unreachable")
        case ENETUNREACH, ENETDOWN:   return .failed("Network unreachable")
        default:                      return .failed(String(cString: strerror(err)))
        }
    }
}
