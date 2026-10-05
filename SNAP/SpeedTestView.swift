// SpeedTestView.swift
// SNAP v1.1 — Speed Test with persistent history, iPerf3 LAN test, fixed multi-provider streaming
// Created by Sevag Bardakjian

import SwiftUI
import Charts

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
    @State private var iperfOutput = ""

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
        .navigationTitle("Speed Test")
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

            Divider().frame(height: 18)

            Label("Size", systemImage: "arrow.up.and.down.circle")
                .font(.caption).foregroundStyle(.secondary).labelStyle(.iconOnly)
            Picker(selection: $testSize) {
                ForEach(TestSize.allCases) { s in Text(s.rawValue).tag(s) }
            } label: { EmptyView() }
            .pickerStyle(.menu).fixedSize().disabled(isRunning || !provider.isInternetProvider)

            Text("· \(testSize.description) · \(testSize.uploadDescription)")
                .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)

            Spacer()

            if phase == .done {
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

    private var iperfView: some View {
        VStack(spacing: 0) {
            // Config bar
            HStack(spacing: 10) {
                Image(systemName: "network").foregroundStyle(.blue)
                Text("iPerf3 Server:").font(.caption).foregroundStyle(.secondary)
                TextField("192.168.1.x", text: $iperfHost)
                    .textFieldStyle(.roundedBorder).frame(width: 140)
                Text("Port:").font(.caption).foregroundStyle(.secondary)
                TextField("5201", text: $iperfPort)
                    .textFieldStyle(.roundedBorder).frame(width: 60)
                Spacer()
                Button("Run iPerf3 Test") { runIperf() }
                    .buttonStyle(.borderedProminent)
                    .disabled(iperfHost.isEmpty || isRunning)
                if !iperfOutput.isEmpty {
                    CopyButton { iperfOutput }
                    ExportButton(toolName: "iPerf3", getText: { iperfOutput })
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

            // Output
            if iperfOutput.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "network").font(.system(size: 36)).foregroundStyle(.tertiary)
                    Text("Enter the IP of a machine running iperf3 -s")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text("Tests local network speed between two machines on the same subnet")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 40)
                Spacer()
            } else {
                ScrollView {
                    Text(iperfOutput)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            }
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
        GroupBox {
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
                .chartYAxisLabel("Mbps").chartXAxis(.hidden)
                .chartYAxis { AxisMarks { AxisGridLine(stroke: StrokeStyle(lineWidth:0.5,dash:[4,4])); AxisValueLabel() } }
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
        VStack(spacing: 12) {
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
                .chartYAxisLabel("Mbps")
                .chartYAxis { AxisMarks { AxisGridLine(stroke:StrokeStyle(lineWidth:0.5,dash:[4,4])); AxisValueLabel() } }
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
        guard !iperfHost.isEmpty else { return }
        iperfOutput = "Running iPerf3 test to \(iperfHost):\(iperfPort)…\n"
        phase = .download

        testTask = Task {
            // Check iperf3 binary exists. Shell.run does the blocking work on
            // a background queue — waitUntilExit here would pin a cooperative
            // pool thread.
            let binaryPath = (await Shell.run("/usr/bin/which", args: ["iperf3"]))
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !binaryPath.isEmpty, !binaryPath.hasPrefix("Error:") else {
                await MainActor.run {
                    self.iperfOutput = """
                    iperf3 not found.

                    Install with Homebrew:
                      brew install iperf3

                    Then run the server on the remote machine:
                      iperf3 -s

                    And make sure port \(self.iperfPort) is open in the firewall.
                    """
                    self.phase = .done
                }
                return
            }

            // Run iperf3 download test
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: binaryPath)
            proc.arguments = ["-c", iperfHost, "-p", iperfPort, "-t", "10", "--forceflush"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe

            let header = "iperf3 -c \(iperfHost) -p \(iperfPort) -t 10\n"
                       + String(repeating: "─", count: 50) + "\n"
            await MainActor.run { self.iperfOutput = header }

            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    // EOF — release the handler so the pipe can deallocate
                    handle.readabilityHandler = nil
                    return
                }
                if let str = String(data: data, encoding: .utf8) {
                    DispatchQueue.main.async { self.iperfOutput += str }
                }
            }

            // Wait via terminationHandler instead of waitUntilExit — no
            // blocked cooperative thread, and Stop (Task.cancel) actually
            // terminates the 10-second run instead of being ignored
            await withTaskCancellationHandler {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    proc.terminationHandler = { _ in cont.resume() }
                    do {
                        try proc.run()
                    } catch {
                        proc.terminationHandler = nil
                        DispatchQueue.main.async {
                            self.iperfOutput += "Failed to launch iperf3: \(error.localizedDescription)\n"
                        }
                        cont.resume()
                    }
                }
            } onCancel: {
                if proc.isRunning { proc.terminate() }
            }

            guard !Task.isCancelled else { return }
            await MainActor.run { self.phase = .done }
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
