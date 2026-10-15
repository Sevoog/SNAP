// SpeedTestView.swift
// SNAP v1.1 — Speed Test with persistent history, iPerf3 LAN test, fixed multi-provider streaming
// Created by Sevag Bardakjian
// Copyright © 2025-2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md

import SwiftUI
import Charts
import CoreWLAN

// MARK: - Test Size

enum TestSize: String, CaseIterable, Identifiable {
    case mb25  = "25 MB"
    case mb100 = "100 MB"
    case mb500 = "500 MB"
    case gb1   = "1 GB"
    case gb2   = "2 GB"
    var id: String { rawValue }

    var downloadBytes: Int {
        switch self {
        case .mb25:  return 25_000_000
        case .mb100: return 100_000_000
        case .mb500: return 500_000_000
        case .gb1:   return 1_000_000_000
        case .gb2:   return 2_000_000_000
        }
    }
    // All providers use 25 MB chunks for streaming accuracy
    var chunkBytes: Int { 25_000_000 }
    var chunks: Int { max(1, downloadBytes / chunkBytes) }
    var uploadBytes: Int {
        switch self {
        case .mb25:  return 10_000_000
        case .mb100: return 25_000_000
        case .mb500: return 50_000_000
        case .gb1:   return 75_000_000
        case .gb2:   return 100_000_000
        }
    }
    var uploadDescription: String {
        switch self {
        case .mb25:  return "10 MB upload"
        case .mb100: return "25 MB upload"
        case .mb500: return "50 MB upload"
        case .gb1:   return "75 MB upload"
        case .gb2:   return "100 MB upload"
        }
    }
    var description: String {
        switch self {
        case .mb25:  return "Quick (~5–10s)"
        case .mb100: return "Standard (~15–30s)"
        case .mb500: return "Accurate (~30–60s)"
        case .gb1:   return "Thorough (~1–2min)"
        case .gb2:   return "Maximum (~2–4min)"
        }
    }
}

// MARK: - Speed Provider

enum SpeedProvider: String, CaseIterable, Identifiable {
    case cloudflare = "Cloudflare"
    case iperf      = "iPerf3 (LAN)"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .cloudflare: return "bolt.horizontal"
        case .iperf:      return "network"
        }
    }

    var pingURL: String {
        switch self {
        case .cloudflare: return "https://www.cloudflare.com/cdn-cgi/trace"
        case .iperf:      return ""
        }
    }

    func chunkURL(index: Int, bytes: Int) -> String {
        switch self {
        case .cloudflare: return "https://speed.cloudflare.com/__down?bytes=\(bytes)"
        case .iperf:      return ""
        }
    }

    var uploadURL: String { "https://speed.cloudflare.com/__up" }

    var description: String {
        switch self {
        case .cloudflare: return "Cloudflare CDN · speed.cloudflare.com"
        case .iperf:      return "LAN speed test via iPerf3 binary"
        }
    }

    var isInternetProvider: Bool { self != .iperf }
}

// MARK: - Main View

struct SpeedTestView: View {
    @StateObject private var historyStore = SpeedTestHistoryStore.shared

    @State private var phase: TestPhase = .idle
    @State private var provider: SpeedProvider = .cloudflare
    @State private var testSize: TestSize = .mb100
    @State private var downloadMbps: Double = 0
    @State private var uploadMbps: Double = 0
    @State private var pingMs: Double = 0
    @State private var jitterMs: Double = 0
    @State private var progress: Double = 0
    @State private var status = ""
    @State private var testTask: Task<Void, Never>?
    @State private var livePoints: [LivePoint] = []
    @State private var bytesTransferred: Int = 0
    @State private var totalBytesTarget: Int = 0
    // iPerf3
    @State private var iperfHost = ""
    @State private var iperfPort = "5201"
    @State private var iperfMessage = ""          // "not found" / launch errors
    @State private var iperfDirection: IperfDirection = .upload
    @State private var iperfStreams = 1
    @State private var iperfSeconds = 10
    @State private var iperfRuns: [IperfRunOutput] = []
    @State private var iperfRunStreams = 1        // options used by the results on screen
    @State private var iperfRunSeconds = 10
    @State private var iperfLink: IperfLink?
    @StateObject private var iperfHistory = IperfHistoryStore.shared

    struct LivePoint: Identifiable {
        let id = UUID(); let index: Int; let mbps: Double
    }
    enum TestPhase: String {
        case idle = "Ready", ping = "Ping", download = "Download", upload = "Upload", done = "Complete"
    }

    // Formatted result text for Copy/Export
    private var resultText: String {
        guard phase == .done else { return "No results yet." }
        return """
        SNAP Speed Test Result
        ──────────────────────
        Provider:  \(provider.rawValue)
        Test Size: \(testSize.rawValue) down · \(testSize.uploadDescription)
        Date:      \(Date().formatted())

        HTTP Ping: \(String(format:"%.1f", pingMs)) ms
        Jitter:    \(String(format:"%.1f", jitterMs)) ms
        Download:  \(String(format:"%.2f", downloadMbps)) Mbps
        Upload:    \(String(format:"%.2f", uploadMbps)) Mbps
        """
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if provider == .iperf {
                iperfView
            } else {
                internetTestView
            }
        }
        .tabNavigationTitle(.speedTest)
        // Runs when the window closes (tabs now stay alive across switches) — cancel the running test (the
        // cancellation handlers abort the transfer / terminate iperf3)
        .onDisappear { testTask?.cancel() }
        // The Status Board's "Run Now" hands off with the autostart sentinel;
        // kick the test off automatically so the button does what it says.
        .consumeHandoff(for: .speedTest) { value in
            guard value == ToolHandoff.autostartToken else { return }
            guard phase != .download, phase != .upload, phase != .ping else { return }
            // The board tile graphs `historyStore`, which only the internet
            // test writes to — so "Run Now" means an internet test. If the
            // user left this view on the iPerf3 pane, switch back, otherwise
            // the test would run behind a pane that never shows its progress.
            if provider == .iperf { provider = .cloudflare }
            startTest()
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "speedometer").foregroundStyle(.blue)

            Picker(selection: $provider) {
                ForEach(SpeedProvider.allCases) { p in Text(p.rawValue).tag(p) }
            } label: { EmptyView() }
            .pickerStyle(.menu).fixedSize().disabled(isRunning)

            // Test size applies only to internet tests; iPerf3 has its own
            // Duration and Streams options in the row below.
            if provider.isInternetProvider {
                Divider().frame(height: 18)

                Label("Size", systemImage: "arrow.up.and.down.circle")
                    .font(.caption).foregroundStyle(.secondary).labelStyle(.iconOnly)
                Picker(selection: $testSize) {
                    ForEach(TestSize.allCases) { s in Text(s.rawValue).tag(s) }
                } label: { EmptyView() }
                .pickerStyle(.menu).fixedSize().disabled(isRunning)

                Text("· \(testSize.description) · \(testSize.uploadDescription)")
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }

            Spacer()

            // Internet results only: in iPerf3 mode the iPerf3 row has its
            // own Copy/Export for the iperf3 output.
            if phase == .done && provider.isInternetProvider {
                ToolActionBar("Speed Test", text: { resultText },
                    csv: { historyStore.exportCSV() },
                    json: { historyStore.exportJSON() })
            }

            if isRunning {
                Text(phase.rawValue + "…").font(.caption).foregroundStyle(.secondary)
                Button("Stop") { testTask?.cancel(); phase = .idle; status = "Stopped" }
                    .buttonStyle(.bordered).tint(.red)
            } else if provider.isInternetProvider {
                Button(phase == .done ? "Test Again" : "Start Test") { startTest() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.return)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(NS.bg0)
    }

    private var isRunning: Bool { phase != .idle && phase != .done }

    // MARK: - Internet Test View

    private var internetTestView: some View {
        ScrollView {
            VStack(spacing: 20) {
                gaugeRow
                if !livePoints.isEmpty { liveChart }
                if isRunning { progressBarView }
                if !status.isEmpty && phase != .done {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                if historyStore.results.isEmpty && phase == .idle { emptyState }
                if !historyStore.results.isEmpty { historySection }
            }
            .padding(.bottom, 24)
        }
    }

    // MARK: - iPerf3 LAN View

    /// Everything iperf3 printed, unchanged, for Copy / Export.
    private var iperfAllOutput: String {
        ([iperfMessage] + iperfRuns.map(\.output)).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private var iperfView: some View {
        VStack(spacing: 0) {
            // Config bar: one row when there's room, two when narrow.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    iperfServerFields
                    Divider().frame(height: 18)
                    iperfOptions
                    Spacer(minLength: 8)
                    iperfActions
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        iperfServerFields
                        Spacer(minLength: 8)
                        iperfActions
                    }
                    HStack(spacing: 10) {
                        iperfOptions
                        Spacer()
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(NS.bg0)

            Divider()

            // Info banner
            HStack(spacing: 8) {
                Image(systemName: "info.circle").foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("iPerf3 must be installed and running on the remote machine.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Install: brew install iperf3 · Run on server: iperf3 -s")
                        .font(.caption2).foregroundStyle(.tertiary).fontDesign(.monospaced)
                }
                Spacer()
            }
            .padding(10)
            .background(Color.blue.opacity(0.06))

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if iperfRuns.isEmpty && iperfMessage.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "network").font(.system(size: 36)).foregroundStyle(.tertiary)
                            Text("Enter the IP of a machine running iperf3 -s")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Text("Tests local network speed between two machines on the same subnet")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 40)
                    } else {
                        ForEach(iperfRuns) { run in
                            IperfRunSection(direction: run.direction,
                                            result: IperfOutputParser.parse(run.output),
                                            link: iperfLink,
                                            streams: iperfRunStreams,
                                            seconds: iperfRunSeconds,
                                            live: isRunning && run.id == iperfRuns.last?.id)
                        }
                        IperfRawOutputSection(text: iperfAllOutput, showLegend: !iperfRuns.isEmpty)
                    }
                    if !iperfHistory.entries.isEmpty {
                        IperfHistoryList(store: iperfHistory)
                    }
                }
                .padding(16)
            }
        }
    }

    @ViewBuilder private var iperfServerFields: some View {
        Image(systemName: "network").foregroundStyle(.blue)
        Text("iPerf3 Server:").font(.caption).foregroundStyle(.secondary).fixedSize()
        TextField("192.168.1.x", text: $iperfHost)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 110, idealWidth: 140, maxWidth: 160)
        Text("Port:").font(.caption).foregroundStyle(.secondary).fixedSize()
        TextField("5201", text: $iperfPort)
            .textFieldStyle(.roundedBorder).frame(width: 60)
    }

    private var iperfOptions: some View {
        HStack(spacing: 8) {
            Picker(selection: $iperfDirection) {
                ForEach(IperfDirection.allCases) { d in Text(d.rawValue).tag(d) }
            } label: { EmptyView() }
            .pickerStyle(.menu).fixedSize()
            .help("Direction: \(iperfDirection.detail)")

            Picker(selection: $iperfStreams) {
                ForEach([1, 2, 4, 8], id: \.self) { n in Text(n == 1 ? "1 stream" : "\(n) streams").tag(n) }
            } label: { EmptyView() }
            .pickerStyle(.menu).fixedSize()
            .help("Parallel connections (iperf3 -P). One connection sometimes can't fill a fast link.")

            Picker(selection: $iperfSeconds) {
                ForEach([5, 10, 20, 30, 60], id: \.self) { s in Text("\(s) sec").tag(s) }
            } label: { EmptyView() }
            .pickerStyle(.menu).fixedSize()
            .help("Test length in seconds (iperf3 -t). iperf3 reports once per second.")
        }
        .disabled(isRunning)
    }

    @ViewBuilder private var iperfActions: some View {
        Button("Run iPerf3 Test") { runIperf() }
            .buttonStyle(.borderedProminent).fixedSize()
            .disabled(iperfHost.trimmingCharacters(in: .whitespaces).isEmpty || isRunning)
        if !iperfAllOutput.isEmpty {
            CopyButton { iperfAllOutput }.fixedSize()
            ExportButton(toolName: "iPerf3", getText: { iperfAllOutput }).fixedSize()
        }
    }

    // MARK: - Gauges

    private var gaugeRow: some View {
        HStack {
            Spacer()
            speedGauge("HTTP Ping", pingMs,       "ms",   .green,  maxVal: 200)
            Spacer()
            speedGauge("Download",  downloadMbps, "Mbps", .blue,   maxVal: 1000)
            Spacer()
            speedGauge("Upload",    uploadMbps,   "Mbps", .orange, maxVal: 500)
            Spacer()
            speedGauge("Jitter",    jitterMs,     "ms",   .purple, maxVal: 50)
            Spacer()
        }
        .padding(.top, 20).padding(.horizontal, 16)
    }

    private func speedGauge(_ label: String, _ value: Double, _ unit: String,
                            _ color: Color, maxVal: Double) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(Color.gray.opacity(0.2), lineWidth: 8).frame(width: 100, height: 100)
                Circle()
                    .trim(from: 0, to: CGFloat(Swift.min(value / maxVal, 1)))
                    .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .frame(width: 100, height: 100)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.3), value: value)
                VStack(spacing: 2) {
                    Text(String(format: value < 100 ? "%.1f" : "%.0f", value))
                        .font(.title3.bold().monospaced())
                    Text(unit).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Live Chart

    private var liveChart: some View {
        let axisText = ChartAxis.text
        return GroupBox {
            if livePoints.count > 1 {
                Chart(livePoints) { pt in
                    LineMark(x: .value("s", pt.index), y: .value("Mbps", pt.mbps))
                        .foregroundStyle(phase == .upload ? Color.orange : Color.blue)
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    AreaMark(x: .value("s", pt.index), y: .value("Mbps", pt.mbps))
                        .foregroundStyle((phase == .upload ? Color.orange : Color.blue).opacity(0.1))
                        .interpolationMethod(.catmullRom)
                }
                .chartYAxisLabel { Text("Mbps").foregroundStyle(axisText) }.chartXAxis(.hidden)
                .chartYAxis { AxisMarks { AxisGridLine(stroke: StrokeStyle(lineWidth:0.5,dash:[4,4])); AxisValueLabel().foregroundStyle(axisText) } }
                .frame(height: 110).padding(.top, 4)
            } else {
                Text("Collecting samples…").font(.caption).foregroundStyle(.secondary)
                    .frame(height: 60, alignment: .center).frame(maxWidth: .infinity)
            }
        } label: {
            Label(phase == .upload ? "Live Upload" : "Live Download",
                  systemImage: phase == .upload ? "arrow.up.circle" : "arrow.down.circle")
            .font(.caption.bold())
        }
        .padding(.horizontal)
    }

    // MARK: - Progress Bar

    private var progressBarView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(status).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if totalBytesTarget > 0 {
                    Text("\(fmt(bytesTransferred)) / \(fmt(totalBytesTarget))")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            ProgressView(value: progress).tint(phase == .upload ? .orange : .blue)
        }
        .padding(.horizontal)
    }

    // MARK: - History

    private var historySection: some View {
        let axisText = ChartAxis.text
        return VStack(spacing: 12) {
            GroupBox {
                Chart(historyStore.results.prefix(10).reversed() as [SpeedResult]) { r in
                    BarMark(x: .value("t", r.date, unit: .second), y: .value("↓", r.download))
                        .foregroundStyle(.blue.opacity(0.75))
                        .annotation(position: .top) {
                            Text(String(format:"%.0f", r.download)).font(.system(size:9)).foregroundStyle(.blue)
                        }
                    BarMark(x: .value("t", r.date, unit: .second), y: .value("↑", r.upload))
                        .foregroundStyle(.orange.opacity(0.75))
                }
                .chartYAxisLabel { Text("Mbps").foregroundStyle(axisText) }
                .chartYAxis { AxisMarks { AxisGridLine(stroke:StrokeStyle(lineWidth:0.5,dash:[4,4])); AxisValueLabel().foregroundStyle(axisText) } }
                .frame(height: 130).padding(.top, 4)
            } label: {
                HStack {
                    Label("Test History", systemImage: "chart.bar").font(.caption.bold())
                    Spacer()
                    Button("Clear") { historyStore.clear() }
                        .font(.caption).buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)

            VStack(spacing: 0) {
                ForEach(historyStore.results.prefix(20)) { r in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2).foregroundStyle(.secondary)
                            Text(r.provider).font(.caption).foregroundStyle(.blue)
                        }
                        Text("[\(r.testSize)]").font(.caption2.monospaced()).foregroundStyle(.tertiary)
                        Spacer()
                        Label(String(format:"↓ %.1f Mbps", r.download), systemImage:"arrow.down")
                            .font(.caption.bold()).foregroundStyle(.blue)
                        Label(String(format:"↑ %.1f Mbps", r.upload), systemImage:"arrow.up")
                            .font(.caption.bold()).foregroundStyle(.orange)
                        Text(String(format:"%.0fms", r.ping))
                            .font(.caption2.monospaced()).foregroundStyle(.green)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    Divider().padding(.leading, 16)
                }
            }
            .background(NS.bg3)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "speedometer").font(.system(size:40)).foregroundStyle(.tertiary)
            Text("Press Start Test to measure your connection").font(.subheadline).foregroundStyle(.secondary)
            Text(provider.description).font(.caption2).foregroundStyle(.tertiary)
            Text("Test size: \(testSize.rawValue) download · \(testSize.uploadDescription)")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }

    // MARK: - Internet Test Engine

    private func startTest() {
        phase = .ping; progress = 0
        downloadMbps = 0; uploadMbps = 0; pingMs = 0; jitterMs = 0
        livePoints = []; bytesTransferred = 0; totalBytesTarget = 0
        status = "Connecting to \(provider.rawValue)…"
        let sel = provider; let size = testSize

        testTask = Task {
            await MainActor.run { self.phase = .ping; self.status = "Measuring latency…" }
            let (avgPing, jitter) = await measurePing(urlStr: sel.pingURL)
            // Check cancellation BEFORE publishing — Stop sets status/phase
            // and a late update here would clobber the "Stopped" state
            guard !Task.isCancelled else { return }
            await MainActor.run { self.pingMs = avgPing; self.jitterMs = jitter; self.progress = 0.15 }

            await MainActor.run {
                self.phase = .download
                self.totalBytesTarget = size.downloadBytes
                self.status = "Downloading \(size.rawValue) via \(sel.rawValue)…"
            }
            let dlMbps = await measureDownload(provider: sel, size: size)
            guard !Task.isCancelled else { return }
            await MainActor.run { self.downloadMbps = dlMbps; self.progress = 0.75 }

            await MainActor.run {
                self.phase = .upload; self.livePoints = []
                self.bytesTransferred = 0; self.totalBytesTarget = size.uploadBytes
                self.status = "Uploading \(size.uploadDescription) to \(sel.rawValue)…"
            }
            let ulMbps = await measureUpload(size: size)
            // A test stopped mid-upload must not flip to "Complete" or save
            // a partial result to history
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.uploadMbps = ulMbps; self.progress = 1.0; self.phase = .done
                self.status = "Complete — \(sel.rawValue) · \(size.rawValue)"
                let result = SpeedResult(date: Date(), download: dlMbps, upload: ulMbps,
                                         ping: avgPing, jitter: jitter,
                                         provider: sel.rawValue, testSize: size.rawValue)
                self.historyStore.add(result)
            }
        }
    }

    // MARK: - Ping

    private func measurePing(urlStr: String) async -> (Double, Double) {
        guard !urlStr.isEmpty, let url = URL(string: urlStr) else { return (0, 0) }
        let session = URLSession(configuration: {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = 5
            c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            return c
        }())
        var warmup = URLRequest(url: url); warmup.httpMethod = "HEAD"
        _ = try? await session.data(for: warmup)
        var times: [Double] = []
        for _ in 0..<8 {
            guard !Task.isCancelled else { break }
            var req = URLRequest(url: url); req.httpMethod = "HEAD"
            req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let t0 = Date()
            _ = try? await session.data(for: req)
            times.append(Date().timeIntervalSince(t0) * 1000)
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        guard times.count > 1 else { return (times.first ?? 0, 0) }
        let sorted = times.sorted().dropLast()
        let avg = sorted.reduce(0,+) / Double(sorted.count)
        let jitter = sorted.map { abs($0 - avg) }.reduce(0,+) / Double(sorted.count)
        return (avg, jitter)
    }

    // MARK: - Download
    // Uses a URLSessionDataDelegate to receive data in OS-natural chunks (~64KB-1MB each).
    // The byte-by-byte async sequence approach caps out around 10-20 Mbps due to
    // Swift async/await overhead per iteration. The delegate receives data as fast
    // as the OS delivers it, giving accurate readings at 400+ Mbps.

    private func measureDownload(provider: SpeedProvider, size: TestSize) async -> Double {
        var totalDownloaded = 0
        let testStart = Date()
        var sampleIndex = 0

        for chunkIdx in 0..<size.chunks {
            guard !Task.isCancelled else { break }
            let urlStr = provider.chunkURL(index: chunkIdx, bytes: size.chunkBytes)
            guard let url = URL(string: urlStr) else { continue }

            var req = URLRequest(url: url)
            req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

            // Delegate-based download: OS delivers data in large natural chunks
            let delegate = DownloadDelegate()
            let session = URLSession(
                configuration: {
                    let c = URLSessionConfiguration.default
                    c.timeoutIntervalForRequest = 120
                    c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                    return c
                }(),
                delegate: delegate,
                delegateQueue: nil   // background queue
            )

            let chunkStart = Date()

            // Cancelling the session on Task.cancel aborts the in-flight
            // chunk (Stop used to wait out the full 25 MB transfer) and
            // completes the task with an error, which fires onDone below
            await withTaskCancellationHandler {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    delegate.onData = { bytes in
                        totalDownloaded += bytes
                        let elapsed   = Date().timeIntervalSince(testStart)
                        let chunkElap = Swift.max(Date().timeIntervalSince(chunkStart), 0.001)
                        let avg  = elapsed > 0 ? Double(totalDownloaded) * 8 / elapsed / 1_000_000 : 0
                        let inst = Double(totalDownloaded) * 8 / chunkElap / 1_000_000
                        let prog = 0.15 + 0.60 * Double(totalDownloaded) / Double(size.downloadBytes)
                        sampleIndex += 1; let si = sampleIndex
                        let transferred = totalDownloaded
                        let statusStr = "↓ \(fmt(totalDownloaded)) · \(String(format:"%.1f", avg)) Mbps"
                        DispatchQueue.main.async {
                            self.bytesTransferred = transferred
                            self.downloadMbps = avg
                            self.progress = Swift.min(prog, 0.75)
                            self.livePoints.append(LivePoint(index: si, mbps: inst))
                            self.status = statusStr
                        }
                    }
                    delegate.onDone = { cont.resume() }
                    session.dataTask(with: req).resume()
                }
            } onCancel: {
                session.invalidateAndCancel()
            }
            session.invalidateAndCancel()
        }

        let elapsed = Date().timeIntervalSince(testStart)
        let final = elapsed > 0 ? Double(totalDownloaded) * 8 / elapsed / 1_000_000 : 0
        if !Task.isCancelled {
            await MainActor.run {
                self.bytesTransferred = totalDownloaded
                self.downloadMbps = final
            }
        }
        return final
    }

    // MARK: - Upload

    private func measureUpload(size: TestSize) async -> Double {
        guard let url = URL(string: "https://speed.cloudflare.com/__up") else { return 0 }
        let chunkSize = 1_000_000
        let numChunks = Swift.min(size.uploadBytes / chunkSize, 25)
        var totalUploaded = 0
        let start = Date()
        var si = 0
        let chunk = Data((0..<chunkSize).map { _ in UInt8.random(in: 0...255) })
        for _ in 0..<numChunks {
            guard !Task.isCancelled else { break }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"; req.httpBody = chunk
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 30
            req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            if let (_, _) = try? await URLSession.shared.data(for: req) {
                totalUploaded += chunkSize
                let elapsed = Date().timeIntervalSince(start)
                let mbps = elapsed > 0 ? Double(totalUploaded)*8/elapsed/1_000_000 : 0
                si += 1; let sii = si
                await MainActor.run {
                    self.uploadMbps = mbps
                    self.bytesTransferred = totalUploaded
                    self.livePoints.append(LivePoint(index: sii, mbps: mbps))
                    self.status = "↑ \(self.fmt(totalUploaded)) · \(String(format:"%.1f",mbps)) Mbps"
                }
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        return elapsed > 0 ? Double(totalUploaded)*8/elapsed/1_000_000 : 0
    }

    // MARK: - iPerf3 LAN Test

    private func runIperf() {
        let host = iperfHost.trimmingCharacters(in: .whitespaces)
        let port = iperfPort.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        let directions: [IperfDirection] = iperfDirection == .both ? [.upload, .download] : [iperfDirection]
        let streams = iperfStreams, seconds = iperfSeconds
        iperfRuns = []
        iperfMessage = ""
        iperfLink = nil
        iperfRunStreams = streams
        iperfRunSeconds = seconds
        phase = directions[0] == .download ? .download : .upload

        testTask = Task {
            // Find iperf3: the usual install folders first, then `which`.
            // Shell.run does the blocking work on a background queue —
            // waitUntilExit here would pin a cooperative pool thread.
            var binaryPath = IperfLocator.firstExecutable(in: IperfLocator.candidates) ?? ""
            if binaryPath.isEmpty {
                binaryPath = (await Shell.run("/usr/bin/which", args: ["iperf3"]))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            guard !binaryPath.isEmpty, !binaryPath.hasPrefix("Error:") else {
                await MainActor.run {
                    self.iperfMessage = """
                    iperf3 not found.
                    SNAP looked in \(IperfLocator.candidates.map { ($0 as NSString).deletingLastPathComponent }.joined(separator: ", ")), then on its PATH.

                    Install with Homebrew:
                      brew install iperf3

                    Then run the server on the remote machine:
                      iperf3 -s

                    And make sure port \(port) is open in the firewall.
                    """
                    self.phase = .done
                }
                return
            }

            // Which connection reaches the server, and how fast it is,
            // for the verdict. Read once, before the test loads the link.
            let link = await IperfLinkProbe.detect(host: host)
            await MainActor.run { self.iperfLink = link }

            for direction in directions {
                guard !Task.isCancelled else { return }
                var args = ["-c", host, "-p", port, "-t", String(seconds)]
                if streams > 1 { args += ["-P", String(streams)] }
                if direction == .download { args.append("-R") }
                let header = "iperf3 " + args.joined(separator: " ") + "\n"
                           + String(repeating: "─", count: 50) + "\n"
                let index: Int = await MainActor.run {
                    self.phase = direction == .download ? .download : .upload
                    self.iperfRuns.append(IperfRunOutput(direction: direction, output: header))
                    return self.iperfRuns.count - 1
                }
                await runIperfProcess(binaryPath, args: args + ["--forceflush"], runIndex: index)
            }

            guard !Task.isCancelled else { return }
            await MainActor.run {
                for run in self.iperfRuns {
                    let r = IperfOutputParser.parse(run.output)
                    guard let received = r.receiverBps else { continue }
                    self.iperfHistory.add(IperfHistoryEntry(
                        date: Date(), server: host, port: port, direction: run.direction,
                        streams: streams, seconds: seconds, receiverBps: received,
                        retransmits: r.retransmits, linkMbps: link?.speedMbps))
                }
                self.phase = .done
            }
        }
    }

    /// Runs one iperf3 client, streaming its output into `iperfRuns[runIndex]`.
    /// Returns once the process has exited AND its output has been fully read,
    /// so the summary always sees iperf3's final sender/receiver lines.
    private func runIperfProcess(_ binaryPath: String, args: [String], runIndex: Int) async {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        // Wait via terminationHandler instead of waitUntilExit: no blocked
        // cooperative thread, and Stop (Task.cancel) actually terminates the
        // run instead of being ignored.
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let gate = IperfDoneGate(cont)   // process exit + end of output
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        // EOF: release the handler so the pipe can deallocate.
                        // Signal on main, after the output appends queued there.
                        handle.readabilityHandler = nil
                        DispatchQueue.main.async { gate.done() }
                        return
                    }
                    if let str = String(data: data, encoding: .utf8) {
                        DispatchQueue.main.async {
                            if runIndex < self.iperfRuns.count { self.iperfRuns[runIndex].output += str }
                        }
                    }
                }
                proc.terminationHandler = { _ in gate.done() }
                do {
                    try proc.run()
                } catch {
                    proc.terminationHandler = nil
                    pipe.fileHandleForReading.readabilityHandler = nil
                    DispatchQueue.main.async {
                        if runIndex < self.iperfRuns.count {
                            self.iperfRuns[runIndex].output += "Failed to launch iperf3: \(error.localizedDescription)\n"
                        }
                    }
                    gate.done(); gate.done()
                }
            }
        } onCancel: {
            if proc.isRunning { proc.terminate() }
        }
    }

    // MARK: - Helpers

    private func fmt(_ n: Int) -> String {
        if n >= 1_000_000_000 { return String(format:"%.1f GB", Double(n)/1e9) }
        if n >= 1_000_000     { return String(format:"%.0f MB", Double(n)/1e6) }
        return String(format:"%.0f KB", Double(n)/1e3)
    }
}

// MARK: - DownloadDelegate
// Receives data in OS-natural chunks (typically 32KB–1MB depending on link speed).
// This is the correct way to measure high-speed connections — URLSession buffers
// and delivers data as fast as the network provides it, with no per-byte overhead.

final class DownloadDelegate: NSObject, URLSessionDataDelegate {
    var onData: ((Int) -> Void)?
    var onDone: (() -> Void)?

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        onData?(data.count)
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        onDone?()
    }
}

// MARK: - Finding iperf3

/// Apps opened from Finder don't get the shell's PATH (it's just
/// /usr/bin:/bin:/usr/sbin:/sbin), so `which iperf3` misses Homebrew and
/// MacPorts installs. Check their folders directly.
enum IperfLocator {
    static let candidates = [
        "/opt/homebrew/bin/iperf3",   // Homebrew, Apple silicon
        "/usr/local/bin/iperf3",      // Homebrew, Intel
        "/opt/local/bin/iperf3",      // MacPorts
        "/usr/bin/iperf3",
    ]

    static func firstExecutable(in paths: [String],
                                isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        paths.first(where: isExecutable)
    }
}

// MARK: - iPerf3 results

/// Which way the data flows, from this Mac's point of view.
enum IperfDirection: String, CaseIterable, Identifiable, Codable {
    case upload = "Upload", download = "Download", both = "Both"
    var id: String { rawValue }
    var detail: String {
        switch self {
        case .upload:   return "This Mac sends to the server (iperf3's default)"
        case .download: return "The server sends to this Mac (iperf3 -R)"
        case .both:     return "Upload, then download"
        }
    }
}

/// One iperf3 run, read from its normal text output. SNAP still shows that
/// output unchanged; this is only for the summary, chart, and verdict.
struct IperfResult: Equatable {
    var intervalsBps: [Double] = []   // per interval, all streams combined (bits/s)
    var senderBps: Double?
    var receiverBps: Double?          // the real result: what actually arrived
    var transferBytes: Double?        // receiver's total, in bytes
    var transferText: String?         // the same total as iperf3 printed it, e.g. "13.9 GBytes"
    var retransmits: Int?
    var seconds: Double?
    var reverse = false
    var streams = 0
    var error: String?
}

enum IperfOutputParser {
    // [  4]   0.00-1.00   sec  4.74 GBytes  40.6 Gbits/sec    0   4.00 MBytes
    // [SUM]   0.00-3.00   sec  7.86 GBytes  22.5 Gbits/sec    0             sender
    private static let line = try! NSRegularExpression(pattern:
        #"^\[\s*(SUM|\d+)\]\s+([\d.]+)-([\d.]+)\s+sec\s+([\d.]+)\s+([KMGT]?)Bytes\s+([\d.]+)\s+([KMGT]?)bits/sec(.*)$"#)

    static func parse(_ text: String) -> IperfResult {
        var r = IperfResult()
        let lines = text.components(separatedBy: .newlines)
        for l in lines {
            if l.hasPrefix("iperf3: error") {
                r.error = l.replacingOccurrences(of: "iperf3: error - ", with: "")
                           .replacingOccurrences(of: "iperf3: error: ", with: "")
            }
            if l.hasPrefix("Reverse mode") { r.reverse = true }
            if l.contains(" connected to ") { r.streams += 1 }
        }
        // With several streams, the [SUM] lines are the combined figures.
        let multi = r.streams > 1
        for l in lines {
            let ns = l as NSString
            guard let m = line.firstMatch(in: l, range: NSRange(location: 0, length: ns.length)) else { continue }
            func g(_ i: Int) -> String { ns.substring(with: m.range(at: i)) }
            guard (g(1) == "SUM") == multi,
                  let start = Double(g(2)), let end = Double(g(3)), let value = Double(g(6)) else { continue }
            let bps = value * multiplier(g(7))
            let rest = g(8).trimmingCharacters(in: .whitespaces)
            if rest.hasSuffix("sender") {
                r.senderBps = bps
                r.retransmits = rest.split(separator: " ").first.flatMap { Int($0) }
            } else if rest.hasSuffix("receiver") {
                r.receiverBps = bps
                r.transferBytes = Double(g(4)).map { $0 * binaryMultiplier(g(5)) }
                r.transferText = "\(g(4)) \(g(5))Bytes"
                r.seconds = end - start
            } else {
                r.intervalsBps.append(bps)
            }
        }
        return r
    }

    // iperf3's byte totals are binary: 1 GByte = 1,073,741,824 bytes.
    private static func binaryMultiplier(_ prefix: String) -> Double {
        switch prefix {
        case "K": return 1024
        case "M": return 1024 * 1024
        case "G": return 1024 * 1024 * 1024
        case "T": return 1024 * 1024 * 1024 * 1024
        default:  return 1
        }
    }

    // iperf3's bitrates are decimal (its byte totals are binary).
    private static func multiplier(_ prefix: String) -> Double {
        switch prefix {
        case "K": return 1e3
        case "M": return 1e6
        case "G": return 1e9
        case "T": return 1e12
        default:  return 1
        }
    }
}

/// The network connection this Mac uses to reach the iPerf3 server.
struct IperfLink: Equatable {
    enum Kind: Equatable { case ethernet, wifi, loopback, other }
    var interface: String
    var kind: Kind
    var speedMbps: Double? = nil   // Ethernet: negotiated speed. Wi-Fi: current transmit rate.
    var media: String? = nil       // e.g. "10Gbase-T"
}

enum IperfLinkProbe {
    /// "interface: en0" from `route -n get <host>`.
    static func interface(fromRoute output: String) -> String? {
        for l in output.components(separatedBy: .newlines) {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("interface:") {
                return String(t.dropFirst("interface:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Negotiated Ethernet speed from `ifconfig`'s media line, e.g.
    /// "media: autoselect (10Gbase-T <full-duplex>)" -> 10,000 Mbps.
    static func ethernetSpeed(fromIfconfig output: String) -> (mbps: Double, media: String)? {
        guard let mediaLine = output.components(separatedBy: .newlines).first(where: { $0.contains("media:") }) else { return nil }
        let re = try! NSRegularExpression(pattern: #"\((\d+)(G?)base[-A-Za-z0-9]*"#, options: [.caseInsensitive])
        let ns = mediaLine as NSString
        guard let m = re.firstMatch(in: mediaLine, range: NSRange(location: 0, length: ns.length)),
              let n = Double(ns.substring(with: m.range(at: 1))) else { return nil }
        let gig = ns.substring(with: m.range(at: 2)).lowercased() == "g"
        return (gig ? n * 1000 : n, String(ns.substring(with: m.range).dropFirst()))
    }

    static func detect(host: String) async -> IperfLink? {
        let route = await Shell.run("/sbin/route", args: ["-n", "get", host], timeout: 5)
        guard let iface = interface(fromRoute: route) else { return nil }
        if iface.hasPrefix("lo") { return IperfLink(interface: iface, kind: .loopback) }
        if CWWiFiClient.interfaceNames()?.contains(iface) == true {
            let rate = CWWiFiClient.shared().interface(withName: iface)?.transmitRate() ?? 0
            return IperfLink(interface: iface, kind: .wifi, speedMbps: rate > 0 ? rate : nil)
        }
        if let e = ethernetSpeed(fromIfconfig: await Shell.run("/sbin/ifconfig", args: [iface], timeout: 5)) {
            return IperfLink(interface: iface, kind: .ethernet, speedMbps: e.mbps, media: e.media)
        }
        return IperfLink(interface: iface, kind: .other)
    }
}

/// A plain-language reading of an iPerf3 result.
struct IperfVerdict: Equatable {
    var headline: String
    var detail: String
    var notes: [String] = []
}

enum IperfAdvisor {
    static func rate(_ bps: Double) -> String {
        if bps >= 1e9 { return String(format: "%.2f Gbps", bps / 1e9) }
        if bps >= 1e8 { return String(format: "%.0f Mbps", bps / 1e6) }
        if bps >= 1e6 { return String(format: "%.1f Mbps", bps / 1e6) }
        return String(format: "%.0f Kbps", bps / 1e3)
    }

    /// Link speeds: "10 Gbps", "2.5 Gbps", "1 Gbps", "866 Mbps".
    static func linkRate(_ mbps: Double) -> String {
        if mbps >= 1000, mbps.truncatingRemainder(dividingBy: 100) == 0 {
            let g = mbps / 1000
            return g == g.rounded() ? "\(Int(g)) Gbps" : String(format: "%.1f Gbps", g)
        }
        return String(format: "%.0f Mbps", mbps)
    }

    /// Decimal units, like the rest of SNAP: 1 GB = 1,000,000,000 bytes.
    static func bytes(_ n: Double) -> String {
        if n >= 1e12 { return String(format: "%.2f TB", n / 1e12) }
        if n >= 1e10 { return String(format: "%.1f GB", n / 1e9) }
        if n >= 1e9  { return String(format: "%.2f GB", n / 1e9) }
        if n >= 1e6  { return String(format: "%.0f MB", n / 1e6) }
        return String(format: "%.0f KB", n / 1e3)
    }

    private static func pct(_ x: Double) -> String { String(format: "%.0f%%", x * 100) }

    struct Steadiness: Equatable { var plusMinusPct: Double; var minBps: Double; var maxBps: Double }

    static func steadiness(_ intervals: [Double]) -> Steadiness? {
        guard intervals.count >= 2, let mn = intervals.min(), let mx = intervals.max() else { return nil }
        let mean = intervals.reduce(0, +) / Double(intervals.count)
        guard mean > 0 else { return nil }
        return Steadiness(plusMinusPct: (mx - mn) / 2 / mean * 100, minBps: mn, maxBps: mx)
    }

    /// Common Ethernet speeds a slower device in the path would cap a test at.
    private static let ceilingsMbps: [Double] = [100, 1000, 2500, 5000, 10000]

    static func verdict(for r: IperfResult, link: IperfLink?, streams: Int) -> IperfVerdict? {
        guard r.error == nil, let got = r.receiverBps else { return nil }
        let gotMbps = got / 1e6
        var v: IperfVerdict
        if let link, link.kind == .loopback {
            v = IperfVerdict(headline: "This tested your Mac against itself",
                             detail: "The server address leads back to this Mac, so the result measures the computer, not the network. Use another machine's address to test the network.")
        } else if let link, link.kind == .ethernet, let L = link.speedMbps, L > 0 {
            let ratio = gotMbps / L
            let media = link.media.map { ", \($0)" } ?? ""
            if ratio > 1.05 {
                v = IperfVerdict(headline: "Faster than this Mac's link",
                                 detail: "\(rate(got)) is more than this Mac's \(linkRate(L)) link (\(link.interface)\(media)) can carry, so the test traffic probably didn't cross that link. This happens when the server runs on this Mac itself, for example in a virtual machine.")
            } else if ratio >= 0.85 {
                v = IperfVerdict(headline: "About as fast as a \(linkRate(L)) link gets",
                                 detail: "This Mac's link is \(linkRate(L)) (\(link.interface)\(media)). \(rate(got)) is \(pct(ratio)) of that, which is normal once TCP and Ethernet overhead are counted. The link itself is the limit.")
            } else if let cap = ceilingsMbps.first(where: { $0 < L * 0.95 && gotMbps >= $0 * 0.85 && gotMbps <= $0 * 1.02 }) {
                v = IperfVerdict(headline: "Capped near \(linkRate(cap))",
                                 detail: "This Mac's link is \(linkRate(L)), but the result stops just under \(linkRate(cap)). Something in the path most likely runs at \(linkRate(cap)): the other machine's network port, a switch, a cable, or an adapter.")
            } else {
                v = IperfVerdict(headline: "Below what this Mac's link can do",
                                 detail: "\(rate(got)) is \(pct(ratio)) of this Mac's \(linkRate(L)) link. Common causes are the other machine's link or CPU, other traffic on the network, or Wi-Fi somewhere in the path."
                                    + (streams == 1 ? " One connection sometimes can't fill a fast link, so try 4 streams." : ""))
            }
        } else if let link, link.kind == .wifi {
            if let L = link.speedMbps, L > 0 {
                let ratio = gotMbps / L
                v = ratio > 1.05
                    ? IperfVerdict(headline: "\(rate(got)) over Wi-Fi",
                                   detail: "That's faster than the \(linkRate(L)) link rate Wi-Fi reported just before the test (\(link.interface)). Wi-Fi changes its rate from moment to moment and usually speeds up once traffic starts, so that starting rate isn't a firm limit.")
                    : ratio >= 0.45
                    ? IperfVerdict(headline: "Typical for this Wi-Fi connection",
                                   detail: "Wi-Fi reports a link rate of \(linkRate(L)) (\(link.interface)). Real throughput is usually about half to two-thirds of that, and \(rate(got)) is \(pct(ratio)). For more speed, move closer to the access point or use Ethernet.")
                    : IperfVerdict(headline: "Slower than this Wi-Fi connection usually allows",
                                   detail: "Wi-Fi reports a link rate of \(linkRate(L)) (\(link.interface)), and \(rate(got)) is only \(pct(ratio)) of it. Distance, walls, interference, or other devices on the same Wi-Fi are the usual causes.")
            } else {
                v = IperfVerdict(headline: "\(rate(got)) over Wi-Fi",
                                 detail: "This Mac reaches the server over Wi-Fi (\(link.interface)), but macOS didn't report a link rate to compare against.")
            }
        } else {
            let via = link.map { " (\($0.interface))" } ?? ""
            v = IperfVerdict(headline: "\(rate(got)) measured",
                             detail: "SNAP couldn't read the speed of the connection that reaches this server\(via), so there's nothing to compare the result against.")
        }
        if let n = r.retransmits, n > 0 {
            v.notes.append("\(n) retransmit\(n == 1 ? "" : "s"): some packets were lost or delayed and sent again. A few are normal on busy or Wi-Fi networks; many point to a bad cable, a struggling switch, or congestion.")
        }
        if let s = steadiness(r.intervalsBps), s.plusMinusPct > 15 {
            v.notes.append("Speed swung between \(rate(s.minBps)) and \(rate(s.maxBps)) during the test, so the connection wasn't steady. Other traffic or Wi-Fi conditions usually cause this.")
        }
        return v
    }
}

// MARK: - iPerf3 views

/// One iperf3 client run (a "Both" test makes two) and its raw output.
struct IperfRunOutput: Identifiable {
    let id = UUID()
    let direction: IperfDirection
    var output: String
}

/// Resumes the run once iperf3 has exited AND its output has reached EOF,
/// in whichever order those happen.
final class IperfDoneGate: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining = 2
    private var cont: CheckedContinuation<Void, Never>?
    init(_ cont: CheckedContinuation<Void, Never>) { self.cont = cont }
    func done() {
        lock.lock()
        remaining -= 1
        let c = remaining == 0 ? cont : nil
        if remaining == 0 { cont = nil }
        lock.unlock()
        c?.resume()
    }
}

/// Summary, verdict, and per-second chart for one run.
struct IperfRunSection: View {
    let direction: IperfDirection
    let result: IperfResult
    let link: IperfLink?
    let streams: Int
    let seconds: Int
    let live: Bool        // iperf3 is still running this one

    private var finished: Bool { result.receiverBps != nil }
    private var color: Color { direction == .download ? .blue : .orange }

    private var title: String {
        direction == .download ? "Download: server \u{2192} this Mac" : "Upload: this Mac \u{2192} server"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: direction == .download ? "arrow.down.circle" : "arrow.up.circle")
                    .foregroundStyle(color)
                Text(title).font(.headline)
                if streams > 1 {
                    Text("\(streams) streams").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if live {
                    Text(result.intervalsBps.isEmpty ? "Connecting\u{2026}" : "Second \(min(result.intervalsBps.count, seconds)) of \(seconds)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                } else if !finished && result.error == nil {
                    Text("Stopped before iperf3 finished").font(.caption).foregroundStyle(.secondary)
                }
            }
            if live {
                ProgressView(value: Double(min(result.intervalsBps.count, seconds)), total: Double(max(seconds, 1)))
                    .tint(color)
            }

            if let error = result.error {
                ToolNoteCard(icon: "exclamationmark.triangle", tint: .red,
                              headline: "iperf3 couldn't run the test",
                              detail: error.prefix(1).uppercased() + error.dropFirst(),
                              notes: ["Check that iperf3 -s is running on the server, that the address and port are right, and that the server's firewall allows the port."])
            }

            if finished || !result.intervalsBps.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                    throughputCard
                    dataCard
                    retransmitCard
                    steadinessCard
                }
            }

            if !live, let v = IperfAdvisor.verdict(for: result, link: link, streams: streams) {
                ToolNoteCard(icon: "lightbulb", tint: .blue, headline: v.headline, detail: v.detail, notes: v.notes)
            }

            if !result.intervalsBps.isEmpty {
                IperfIntervalChart(intervalsBps: result.intervalsBps, seconds: seconds,
                                   link: link, color: color)
            }
        }
    }

    // MARK: Cards

    private var throughputCard: some View {
        let value: Double?
        let caption: String
        if let r = result.receiverBps {
            value = r; caption = "average, as received"
        } else if live {
            value = result.intervalsBps.last; caption = "live, this second"
        } else {
            value = result.intervalsBps.isEmpty ? nil : result.intervalsBps.reduce(0, +) / Double(result.intervalsBps.count)
            caption = "average so far"
        }
        return IperfStatCard(title: "Throughput", value: value.map(IperfAdvisor.rate) ?? "\u{2026}",
                             caption: caption, icon: "speedometer")
    }

    private var dataCard: some View {
        IperfStatCard(title: "Data moved",
                      value: result.transferBytes.map(IperfAdvisor.bytes) ?? "\u{2026}",
                      caption: result.transferText.map { "iperf3 shows \($0)" } ?? "shown when the test ends",
                      icon: "shippingbox")
    }

    private var retransmitCard: some View {
        let value: String
        let caption: String
        switch result.retransmits {
        case .some(0): value = "0"; caption = "nothing had to be resent"
        case .some(let n): value = n.formatted(); caption = "packets sent again"
        case .none: value = finished ? "n/a" : "\u{2026}"
                    caption = finished ? "not reported" : "shown when the test ends"
        }
        return IperfStatCard(title: "Retransmits", value: value, caption: caption, icon: "arrow.triangle.2.circlepath")
    }

    private var steadinessCard: some View {
        let s = IperfAdvisor.steadiness(result.intervalsBps)
        return IperfStatCard(title: "Steadiness",
                             value: s.map { String(format: $0.plusMinusPct < 10 ? "\u{00B1}%.1f%%" : "\u{00B1}%.0f%%", $0.plusMinusPct) } ?? "\u{2026}",
                             caption: s.map { "\(IperfAdvisor.rate($0.minBps)) to \(IperfAdvisor.rate($0.maxBps))" } ?? "needs two seconds",
                             icon: "waveform.path.ecg")
    }
}

private struct IperfStatCard: View {
    let title: String
    let value: String
    let caption: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .font(.caption).foregroundStyle(NS.text2)
            Text(value)
                .font(.title3.bold().monospacedDigit()).foregroundStyle(NS.text1)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(caption)
                .font(.caption2).foregroundStyle(NS.text2)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(NS.bg3)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// One bar per second, with this Mac's link speed as a dashed line.
private struct IperfIntervalChart: View {
    let intervalsBps: [Double]
    let seconds: Int
    let link: IperfLink?
    let color: Color

    private struct Bar: Identifiable { let id: Int; let label: String; let value: Double }

    private var linkBps: Double? {
        guard let link, link.kind != .loopback, let m = link.speedMbps, m > 0 else { return nil }
        return m * 1e6
    }
    /// The link line, when it fits the bars' scale (at most twice the fastest second).
    private var ruleBps: Double? {
        guard let l = linkBps, l <= 2 * (intervalsBps.max() ?? 0) else { return nil }
        return l
    }
    private var linkName: String {
        guard let link else { return "" }
        return "\(link.kind == .wifi ? "Wi-Fi link rate" : "Link") \(IperfAdvisor.linkRate(link.speedMbps ?? 0))"
    }
    private var useGbps: Bool { max(intervalsBps.max() ?? 0, ruleBps ?? 0) >= 1e9 }
    private var scale: Double { useGbps ? 1e9 : 1e6 }
    private var unit: String { useGbps ? "Gbps" : "Mbps" }
    private var slots: Int { max(seconds, intervalsBps.count) }
    private var labels: [String] { (1...max(slots, 1)).map(String.init) }
    private var bars: [Bar] {
        intervalsBps.enumerated().map { Bar(id: $0.offset, label: String($0.offset + 1), value: $0.element / scale) }
    }
    /// Keep the axis readable on a 60-second test.
    private var axisLabels: [String] {
        let step = slots <= 12 ? 1 : slots <= 30 ? 5 : 10
        return labels.filter { (Int($0) ?? 0) == 1 || (Int($0) ?? 0) % step == 0 }
    }

    var body: some View {
        let axisText = ChartAxis.text
        GroupBox {
            Chart {
                ForEach(bars) { b in
                    BarMark(x: .value("Second", b.label), y: .value(unit, b.value))
                        .foregroundStyle(color.opacity(0.8))
                }
                if let l = ruleBps {
                    RuleMark(y: .value("Link", l / scale))
                        .foregroundStyle(axisText)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        .annotation(position: .top, alignment: .leading) {
                            Text(linkName).font(.caption2).foregroundStyle(axisText)
                        }
                }
            }
            .chartXScale(domain: labels)
            .chartXAxis { AxisMarks(values: axisLabels) { _ in AxisValueLabel().foregroundStyle(axisText) } }
            .chartYAxisLabel { Text(unit).foregroundStyle(axisText) }
            .chartYAxis { AxisMarks { AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4, 4])); AxisValueLabel().foregroundStyle(axisText) } }
            .frame(height: 140).padding(.top, 4)
        } label: {
            HStack {
                Label("Each second", systemImage: "chart.bar").font(.caption.bold())
                Spacer()
                if linkBps != nil && ruleBps == nil {
                    Text("\(linkName), above this scale").font(.caption2).foregroundStyle(NS.text2)
                }
            }
        }
    }
}

/// iperf3's output exactly as it printed it, with a key to its columns.
struct IperfRawOutputSection: View {
    let text: String
    var showLegend = true   // off for SNAP's own messages, e.g. "iperf3 not found"

    var body: some View {
        if showLegend { withLegend } else { raw }
    }

    private var withLegend: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                raw.frame(minWidth: 0, idealWidth: 540, maxWidth: .infinity)
                IperfLegend().frame(width: 260)
            }
            VStack(alignment: .leading, spacing: 12) {
                raw
                IperfLegend()
            }
        }
    }

    private var raw: some View {
        GroupBox {
            ScrollView(.horizontal) {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(NS.text1)
                    .textSelection(.enabled)
                    .fixedSize()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
        } label: {
            Label("iperf3 output", systemImage: "terminal").font(.caption.bold())
        }
    }
}

private struct IperfLegend: View {
    private let rows: [(String, String)] = [
        ("Interval", "The time slice, in seconds. iperf3 prints one line per second."),
        ("Transfer", "Data moved in that slice. iperf3 counts in binary units (1 GByte = 1,073,741,824 bytes), so SNAP's Data moved card, in decimal GB, reads a little higher."),
        ("Bitrate", "Speed during that slice. 1 Gbits/sec = 1,000 Mbps."),
        ("Retr", "Retransmits: packets lost or delayed and sent again. 0 is ideal. In a download test the server sends, so they appear only on its sender line."),
        ("Cwnd", "Congestion window: how much data TCP keeps in flight. Bigger usually means a faster, cleaner path."),
        ("sender / receiver", "The totals at the end. The receiver line is what actually arrived, so it's the result to quote."),
        ("[SUM]", "With more than one stream, all streams combined."),
        ("[  5]", "Which connection a line belongs to."),
    ]

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rows, id: \.0) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.0).font(.caption.bold().monospaced()).foregroundStyle(NS.text1)
                        Text(row.1).font(.caption).foregroundStyle(NS.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            Label("How to read this", systemImage: "questionmark.circle").font(.caption.bold())
        }
    }
}

/// Past LAN tests, newest first. Kept apart from internet tests.
struct IperfHistoryList: View {
    @ObservedObject var store: IperfHistoryStore

    var body: some View {
        GroupBox {
            VStack(spacing: 0) {
                ForEach(store.entries.prefix(20)) { e in
                    HStack(spacing: 10) {
                        Image(systemName: e.direction == .download ? "arrow.down" : "arrow.up")
                            .foregroundStyle(e.direction == .download ? Color.blue : Color.orange)
                            .frame(width: 14)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2).foregroundStyle(NS.text2)
                            Text("\(e.server):\(e.port)").font(.caption).foregroundStyle(NS.text1)
                        }
                        Text("\(e.direction.rawValue) \u{00B7} \(e.streams == 1 ? "1 stream" : "\(e.streams) streams") \u{00B7} \(e.seconds) sec")
                            .font(.caption2).foregroundStyle(NS.text2).lineLimit(1)
                        Spacer(minLength: 8)
                        if let link = e.linkMbps {
                            Text("link \(IperfAdvisor.linkRate(link))")
                                .font(.caption2).foregroundStyle(NS.text2).lineLimit(1)
                        }
                        if let r = e.retransmits {
                            Text("\(r) retr").font(.caption2.monospacedDigit()).foregroundStyle(NS.text2)
                        }
                        Text(IperfAdvisor.rate(e.receiverBps))
                            .font(.caption.bold().monospacedDigit()).foregroundStyle(NS.text1)
                    }
                    .padding(.vertical, 6)
                    if e.id != store.entries.prefix(20).last?.id { Divider() }
                }
            }
        } label: {
            HStack {
                Label("Recent LAN tests", systemImage: "clock.arrow.circlepath").font(.caption.bold())
                Spacer()
                Button("Clear") { store.clear() }
                    .font(.caption).buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
    }
}
