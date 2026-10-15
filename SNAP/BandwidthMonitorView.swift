// BandwidthMonitorView.swift
// SNAP — Bandwidth Monitor with latency, jitter, packet loss, retransmits
// Created by Sevag Bardakjian
// Copyright © 2025-2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md

import SwiftUI
import Charts
import Darwin
import Network

// MARK: - Sample model

struct BandwidthSample: Identifiable, Hashable {
    let id = UUID()
    static func == (l: BandwidthSample, r: BandwidthSample) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
    let time: Date
    let rxBps: Double
    let txBps: Double
    let interface: String
}

// MARK: - Monitor

final class BandwidthMonitor: ObservableObject {
    // Bandwidth
    @Published var samples: [BandwidthSample] = []
    @Published var currentRx: Double = 0
    @Published var currentTx: Double = 0
    @Published var peakRx: Double = 0
    @Published var peakTx: Double = 0
    @Published var totalRx: Double = 0
    @Published var totalTx: Double = 0
    @Published var selectedInterface = "en0"
    @Published var isRunning = false
    // Latency & quality
    @Published var latencyMs: Double = 0
    @Published var jitterMs: Double = 0
    @Published var packetLoss: Double = 0
    @Published var latencyHistory: [Double] = []
    @Published var packetLossHistory: [Double] = []
    @Published var sessionSeconds: Int = 0
    // Quality score 0–100
    @Published var qualityScore: Int = 100
    @Published var qualityLabel: String = "Excellent"
    // v1.2 additions
    @Published var retransmitRate: Double = 0      // % of segments retransmitted
    @Published var tcpRetransmits: UInt32 = 0      // cumulative count this session
    @Published var dnsLatencyMs: Double = 0        // DNS resolution time
    @Published var ispName: String = "—"           // ISP / org name
    @Published var asnInfo: String = "—"           // ASN string
    @Published var externalIP: String = "—"

    private var timer: Timer?
    private var latencyTimer: Timer?
    private var sessionTimer: Timer?
    private var ispTimer: Timer?
    private var lastRx: UInt64 = 0
    private var lastTx: UInt64 = 0
    private var lastTime = Date()
    private var lastPingTimes: [Double] = []
    private var baseRetransmits: UInt32 = 0        // snapshot at session start
    private var baseTCPSent: UInt32 = 0
    private let maxSamples = 120
    private let pingHost = "1.1.1.1"

    func start() {
        isRunning = true
        samples = []; latencyHistory = []; packetLossHistory = []
        currentRx = 0; currentTx = 0
        peakRx = 0; peakTx = 0
        totalRx = 0; totalTx = 0
        latencyMs = 0; jitterMs = 0; packetLoss = 0
        retransmitRate = 0; tcpRetransmits = 0
        dnsLatencyMs = 0
        sessionSeconds = 0
        (lastRx, lastTx) = getBytes()
        lastTime = Date()
        // Snapshot TCP stats at session start so retransmit rate is session-relative
        let (rt, sent) = Self.readTCPStats()
        baseRetransmits = rt; baseTCPSent = sent

        // Bandwidth — every 1s
        let bwt = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.sampleBandwidth() }
        RunLoop.main.add(bwt, forMode: .common); timer = bwt

        // Latency + jitter + packet loss + TCP retransmits — every 3s
        let lt = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in self?.measureLatency() }
        RunLoop.main.add(lt, forMode: .common); latencyTimer = lt

        // DNS latency — every 10s
        let dt = Timer(timeInterval: 10.0, repeats: true) { [weak self] _ in self?.measureDNS() }
        RunLoop.main.add(dt, forMode: .common); ispTimer = dt
        measureDNS()  // immediate first reading

        // Session clock
        let st = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.sessionSeconds += 1 }
        }
        RunLoop.main.add(st, forMode: .common); sessionTimer = st

        // ISP info — once at start
        fetchISPInfo()
    }

    func stop() {
        timer?.invalidate(); latencyTimer?.invalidate()
        sessionTimer?.invalidate(); ispTimer?.invalidate()
        timer = nil; latencyTimer = nil; sessionTimer = nil; ispTimer = nil
        isRunning = false
    }

    // MARK: Bandwidth sampling

    private func sampleBandwidth() {
        let now = Date()
        let (rx, tx) = getBytes()
        let elapsed = now.timeIntervalSince(lastTime)
        guard elapsed > 0 else { return }

        let rxRate = rx >= lastRx ? Double(rx - lastRx) / elapsed : 0
        let txRate = tx >= lastTx ? Double(tx - lastTx) / elapsed : 0

        DispatchQueue.main.async { [weak self] in
            guard let s = self else { return }
            s.currentRx = rxRate; s.currentTx = txRate
            s.peakRx = Swift.max(s.peakRx, rxRate)
            s.peakTx = Swift.max(s.peakTx, txRate)
            s.totalRx += rxRate * elapsed
            s.totalTx += txRate * elapsed
            let sample = BandwidthSample(time: now, rxBps: rxRate, txBps: txRate, interface: s.selectedInterface)
            if s.samples.count >= s.maxSamples { s.samples.removeFirst() }
            s.samples.append(sample)
            s.updateQuality()
            // Persist to SQLite for the time-range view. The store dispatches
            // the actual write off-thread; we just hand it the snapshot.
            BandwidthHistoryStore.shared.insert(HistorySample(
                ts: now,
                iface: s.selectedInterface,
                rxBps: rxRate,
                txBps: txRate,
                latencyMs:     s.latencyMs > 0     ? s.latencyMs     : nil,
                jitterMs:      s.jitterMs > 0      ? s.jitterMs      : nil,
                lossPct:       s.packetLoss,
                retransmitPct: s.retransmitRate > 0 ? s.retransmitRate : nil,
                dnsLatencyMs:  s.dnsLatencyMs > 0  ? s.dnsLatencyMs   : nil,
                quality:       s.qualityScore
            ))
        }
        lastRx = rx; lastTx = tx; lastTime = now
    }

    // MARK: Latency + jitter + packet loss via TCP connect to 1.1.1.1:80

    private func measureLatency() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            // `times`/`lost`/`resolved` are shared between this loop and the
            // state handler running on a Network.framework queue — the lock
            // makes that safe even when a handler fires after the 3s timeout
            var times: [Double] = []
            var lost = 0
            let lock = NSLock()

            for _ in 0..<4 {
                guard let port = NWEndpoint.Port(rawValue: 80) else { continue }
                let conn = NWConnection(host: "1.1.1.1", port: port, using: .tcp)
                var resolved = false
                let t0 = Date()
                let sema = DispatchSemaphore(value: 0)
                conn.stateUpdateHandler = { state in
                    lock.lock()
                    if resolved { lock.unlock(); return }
                    switch state {
                    case .ready:
                        resolved = true
                        times.append(Date().timeIntervalSince(t0) * 1000)
                        lock.unlock()
                        conn.cancel()
                        sema.signal()
                    case .failed:
                        resolved = true
                        lost += 1
                        lock.unlock()
                        conn.cancel()
                        sema.signal()
                    default:
                        lock.unlock()
                    }
                }
                conn.start(queue: .global())
                if sema.wait(timeout: .now() + 3) == .timedOut {
                    // A connection stuck in .preparing/.waiting counts as
                    // lost, and must be cancelled — this leaked one
                    // NWConnection per sample for the whole session
                    lock.lock()
                    if !resolved { resolved = true; lost += 1 }
                    lock.unlock()
                    conn.cancel()
                }
            }

            lock.lock()
            let sampleTimes = times
            let sampleLost = lost
            lock.unlock()

            let loss = sampleTimes.isEmpty ? 100.0 : Double(sampleLost) / 4.0 * 100.0
            let avg  = sampleTimes.isEmpty ? 0.0 : sampleTimes.reduce(0,+) / Double(sampleTimes.count)
            let jit  = sampleTimes.count > 1
                ? sampleTimes.map { abs($0 - avg) }.reduce(0,+) / Double(sampleTimes.count)
                : 0.0

            DispatchQueue.main.async { [weak self] in
                guard let s = self else { return }
                s.latencyMs   = avg
                s.jitterMs    = jit
                s.packetLoss  = loss
                if avg > 0 {
                    s.latencyHistory.append(avg)
                    if s.latencyHistory.count > 60 { s.latencyHistory.removeFirst() }
                }
                // Always record loss (0% is valid data)
                s.packetLossHistory.append(loss)
                if s.packetLossHistory.count > 60 { s.packetLossHistory.removeFirst() }
                s.sampleTCPRetransmits()
                s.updateQuality()
            }
        }
    }

    // MARK: TCP retransmit rate via sysctl (no netstat, no process spawning)

    // sysctl net.inet.tcp.stats returns a tcpstat struct with cumulative counters.
    // We snapshot at session start and compute the delta rate each cycle.
    static func readTCPStats() -> (retransmits: UInt32, sent: UInt32) {
        var name: [Int32] = [CTL_NET, AF_INET, IPPROTO_TCP, TCPCTL_STATS]
        var size = MemoryLayout<tcpstat>.size
        var stats = tcpstat()
        guard sysctl(&name, 4, &stats, &size, nil, 0) == 0 else { return (0, 0) }
        return (stats.tcps_sndrexmitpack, stats.tcps_sndtotal)
    }

    private func sampleTCPRetransmits() {
        let (rt, sent) = Self.readTCPStats()
        let sessionRt   = rt   >= baseRetransmits ? rt   - baseRetransmits : 0
        let sessionSent = sent >= baseTCPSent     ? sent - baseTCPSent     : 0
        let rate = sessionSent > 0
            ? Double(sessionRt) / Double(sessionSent) * 100.0 : 0.0
        DispatchQueue.main.async { [weak self] in
            self?.tcpRetransmits = sessionRt
            self?.retransmitRate = Swift.min(rate, 100.0)
        }
    }

    // MARK: DNS latency — time to resolve a known domain via system resolver

    private func measureDNS() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let t0 = Date()
            // Use getaddrinfo — the system resolver, same path as all app DNS
            var hints = addrinfo()
            hints.ai_family = AF_INET
            hints.ai_socktype = SOCK_STREAM
            var res: UnsafeMutablePointer<addrinfo>?
            let rc = getaddrinfo("one.one.one.one", "80", &hints, &res)
            let elapsed = Date().timeIntervalSince(t0) * 1000
            if rc == 0 { freeaddrinfo(res) }
            DispatchQueue.main.async { [weak self] in
                self?.dnsLatencyMs = rc == 0 ? elapsed : 0
            }
        }
    }

    // MARK: ISP info via ipinfo.io

    private func fetchISPInfo() {
        Task.detached {
            guard let url = URL(string: "https://ipinfo.io/json") else { return }
            var req = URLRequest(url: url)
            req.timeoutInterval = 8
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            let ip   = json["ip"]   as? String ?? "—"
            let org  = json["org"]  as? String ?? "—"   // e.g. "AS7922 Comcast Cable"
            let city = json["city"] as? String ?? ""
            let region = json["region"] as? String ?? ""

            // Split ASN and org name: "AS7922 Comcast Cable" → ASN = "AS7922", name = "Comcast Cable"
            let parts = org.split(separator: " ", maxSplits: 1).map(String.init)
            let asn  = parts.first ?? "—"
            let isp  = parts.count > 1 ? parts[1] : org
            let loc  = [city, region].filter { !$0.isEmpty }.joined(separator: ", ")

            await MainActor.run { [weak self] in
                self?.externalIP = ip
                self?.ispName    = isp.isEmpty ? "—" : isp
                self?.asnInfo    = asn == "—" ? "—" : "\(asn) · \(loc)"
            }
        }
    }

    // MARK: Quality score (updated to include retransmit rate)

    private func updateQuality() {
        var score = 100

        if latencyMs > 300 { score -= 40 }
        else if latencyMs > 150 { score -= 25 }
        else if latencyMs > 80  { score -= 10 }

        if jitterMs > 50  { score -= 20 }
        else if jitterMs > 20 { score -= 10 }
        else if jitterMs > 10 { score -= 5  }

        if packetLoss > 10 { score -= 30 }
        else if packetLoss > 5  { score -= 20 }
        else if packetLoss > 1  { score -= 10 }

        // TCP retransmit penalty — even 2% retransmits indicates congestion
        if retransmitRate > 10 { score -= 25 }
        else if retransmitRate > 5  { score -= 15 }
        else if retransmitRate > 2  { score -= 8  }

        score = Swift.max(0, Swift.min(100, score))
        qualityScore = score
        qualityLabel = score >= 90 ? "Excellent"
                     : score >= 70 ? "Good"
                     : score >= 50 ? "Fair"
                     : score >= 25 ? "Poor"
                     : "Critical"

        // Feed the alert manager with the freshest snapshot. The manager
        // applies thresholds + consecutive-sample debouncing internally.
        let snapshot: [AlertMetric: Double] = [
            .latencyMs:      latencyMs,
            .jitterMs:       jitterMs,
            .packetLoss:     packetLoss,
            .retransmitRate: retransmitRate,
            .dnsLatencyMs:   dnsLatencyMs,
        ]
        Task { @MainActor in AlertManager.shared.evaluate(snapshot) }
    }

    // MARK: Interface bytes via getifaddrs

    private func getBytes() -> (UInt64, UInt64) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return (0, 0) }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let ifa = ptr {
            let name = String(cString: ifa.pointee.ifa_name)
            if name == selectedInterface,
               let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_LINK),
               let data = ifa.pointee.ifa_data {
                let d = data.assumingMemoryBound(to: if_data.self).pointee
                return (UInt64(d.ifi_ibytes), UInt64(d.ifi_obytes))
            }
            ptr = ifa.pointee.ifa_next
        }
        return (0, 0)
    }

    static func availableInterfaces() -> [String] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return ["en0"] }
        defer { freeifaddrs(ifaddr) }
        var seen = Set<String>(); var result: [String] = []
        var ptr = ifaddr
        while let ifa = ptr {
            let name = String(cString: ifa.pointee.ifa_name)
            if let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_LINK),
               !seen.contains(name),
               !name.hasPrefix("lo"), !name.hasPrefix("utun"),
               !name.hasPrefix("gif"), !name.hasPrefix("stf") {
                seen.insert(name); result.append(name)
            }
            ptr = ifa.pointee.ifa_next
        }
        return result.isEmpty ? ["en0"] : result
    }
}

// MARK: - View

struct BandwidthMonitorView: View {
    @StateObject private var monitor = BandwidthMonitor()
    @State private var interfaces: [String] = BandwidthMonitor.availableInterfaces()

    // v1.2.3: historical view from SQLite-backed BandwidthHistoryStore.
    @State private var range: HistoryRange = .live
    @State private var historySamples: [BandwidthSample] = []
    @State private var historyRowCount: Int = 0
    @State private var isLoadingHistory: Bool = false

    private let green  = NS.green
    private let blue   = NS.blue
    private let amber  = Color(red: 1.0,   green: 0.584, blue: 0.0)
    private let purple = Color(red: 0.686, green: 0.322, blue: 1.0)

    /// Samples actually rendered. For .live we use the in-memory rolling
    /// buffer; for any other range we use what we fetched from SQLite.
    private var displayedSamples: [BandwidthSample] {
        range == .live ? monitor.samples : historySamples
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            AlertSettingsPanel()
            Divider()
            rangeBar
            Divider()
            content
        }
        .tabNavigationTitle(.bandwidth)
        .onAppear { historyRowCount = BandwidthHistoryStore.shared.rowCount() }
        .onDisappear { monitor.stop() }
        .onChange(of: range) { _ in reloadHistory() }
        .onChange(of: monitor.selectedInterface) { _ in if range != .live { reloadHistory() } }
    }

    @ViewBuilder
    private var content: some View {
        if range == .live && monitor.samples.isEmpty {
            EmptyStateView(title: "No Data", systemImage: "chart.bar",
                           description: "Press Start to begin monitoring bandwidth, or pick a historical range above (\(historyRowCount) samples in store).")
        } else if range != .live && historySamples.isEmpty {
            EmptyStateView(title: isLoadingHistory ? "Loading…" : "No History",
                           systemImage: "clock.arrow.circlepath",
                           description: isLoadingHistory
                             ? "Fetching samples from SQLite…"
                             : "No samples in this range for \(monitor.selectedInterface). Start the monitor and let it run, or pick a wider range.")
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    statsRow
                    Divider()
                    qualityRow
                    Divider()
                    bandwidthChart(samples: displayedSamples, valueKey: \.rxBps,
                                   color: green, label: "Download (RX)")
                    Divider()
                    bandwidthChart(samples: displayedSamples, valueKey: \.txBps,
                                   color: blue, label: "Upload (TX)")
                    Divider()
                    latencySection
                    Divider()
                    packetLossSection
                }
            }
        }
    }

    // MARK: Time-range bar

    private var rangeBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 11))
                .foregroundStyle(NS.text3)
            Text("Range")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(NS.text3)
            Picker("", selection: $range) {
                ForEach(HistoryRange.allCases) { r in
                    Text(r.rawValue).tag(r)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()

            if range != .live, !historySamples.isEmpty {
                Text("\(historySamples.count) bucket\(historySamples.count == 1 ? "" : "s")")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(NS.text3)
            }

            Spacer()

            Text("\(historyRowCount) total samples in store")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(NS.text4)

            Menu {
                Button("Refresh", action: reloadHistory)
                Button("Clear all history…", role: .destructive) {
                    BandwidthHistoryStore.shared.clearAll()
                    historySamples = []
                    historyRowCount = 0
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(NS.bg1)
    }

    private func reloadHistory() {
        let iface = monitor.selectedInterface
        let r = range
        guard r != .live else { historySamples = []; return }
        isLoadingHistory = true
        Task.detached(priority: .utility) {
            let raw = BandwidthHistoryStore.shared.samples(iface: iface, range: r)
            let mapped = raw.map { h in
                BandwidthSample(time: h.ts, rxBps: h.rxBps, txBps: h.txBps, interface: h.iface)
            }
            await MainActor.run {
                self.historySamples = mapped
                self.historyRowCount = BandwidthHistoryStore.shared.rowCount()
                self.isLoadingHistory = false
            }
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: "chart.bar").foregroundStyle(.blue)
            Picker("Interface", selection: $monitor.selectedInterface) {
                ForEach(interfaces, id: \.self) { i in Text(i).tag(i) }
            }
            .fixedSize()
            if monitor.isRunning {
                Text(sessionString).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            if monitor.isRunning {
                Button("Stop") { monitor.stop() }.buttonStyle(.bordered).tint(.red)
                Circle().fill(.green).frame(width: 8).opacity(0.8)
                Text("Live").font(.caption).foregroundStyle(.green)
            } else {
                Button("Start") { monitor.start() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(NS.bg0)
    }

    private var sessionString: String {
        let s = monitor.sessionSeconds
        if s < 60 { return String(format: "%ds", s) }
        if s < 3600 { return String(format: "%dm %ds", s/60, s%60) }
        return String(format: "%dh %dm", s/3600, (s%3600)/60)
    }

    // MARK: Stats row

    private var statsRow: some View {
        HStack(spacing: 0) {
            statCell("CURRENT RX", formatBps(monitor.currentRx), color: green)
            statDivider()
            statCell("CURRENT TX", formatBps(monitor.currentTx), color: blue)
            statDivider()
            statCell("PEAK RX",    formatBps(monitor.peakRx),    color: green.opacity(0.7))
            statDivider()
            statCell("PEAK TX",    formatBps(monitor.peakTx),    color: blue.opacity(0.7))
            statDivider()
            statCell("TOTAL RX",   formatBytes(monitor.totalRx), color: .teal)
            statDivider()
            statCell("TOTAL TX",   formatBytes(monitor.totalTx), color: .cyan)
        }
        .padding(.vertical, 10)
        .background(NS.bg3)
    }

    // MARK: Quality row

    private var qualityRow: some View {
        VStack(spacing: 0) {
            // Row 1: latency, jitter, packet loss, retransmit rate
            HStack(spacing: 0) {
                statCell("LATENCY",
                         monitor.latencyMs > 0 ? String(format: "%.1f ms", monitor.latencyMs) : "—",
                         color: latencyColor)
                statDivider()
                statCell("JITTER",
                         monitor.jitterMs > 0 ? String(format: "%.1f ms", monitor.jitterMs) : "—",
                         color: jitterColor)
                statDivider()
                statCell("PACKET LOSS",
                         String(format: "%.0f%%", monitor.packetLoss),
                         color: lossColor)
                statDivider()
                statCell("TCP RETX",
                         monitor.retransmitRate > 0
                             ? String(format: "%.1f%%", monitor.retransmitRate)
                             : "0%",
                         color: retxColor)
                statDivider()
                statCell("DNS LATENCY",
                         monitor.dnsLatencyMs > 0
                             ? String(format: "%.0f ms", monitor.dnsLatencyMs)
                             : "—",
                         color: dnsColor)
            }
            .padding(.vertical, 8)

            Divider().background(NS.text1.opacity(0.05))

            // Row 2: quality score + ISP info
            HStack(spacing: 0) {
                // Quality score
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("CONNECTION QUALITY")
                            .font(.system(size: 8)).foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Text(monitor.qualityLabel)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(qualityColor)
                            Text("\(monitor.qualityScore)/100")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(qualityColor.opacity(0.6))
                        }
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2).fill(NS.text1.opacity(0.08))
                            RoundedRectangle(cornerRadius: 2).fill(qualityColor)
                                .frame(width: geo.size.width * CGFloat(monitor.qualityScore) / 100)
                                .animation(.easeInOut(duration: 0.5), value: monitor.qualityScore)
                        }
                    }
                    .frame(width: 70, height: 4)
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)

                statDivider()

                // ISP info
                VStack(alignment: .leading, spacing: 2) {
                    Text("ISP / CARRIER")
                        .font(.system(size: 8)).foregroundStyle(.secondary)
                    Text(monitor.ispName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(monitor.asnInfo)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)

                statDivider()

                // External IP
                VStack(alignment: .leading, spacing: 2) {
                    Text("EXTERNAL IP")
                        .font(.system(size: 8)).foregroundStyle(.secondary)
                    Text(monitor.externalIP)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 8)
        }
        .background(NS.bg2)
    }

    // MARK: Latency section

    private var latencySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(amber)
                    .frame(width: 16, height: 3)
                Text("Latency (ms)")
                    .font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                Text(monitor.latencyMs > 0 ? String(format: "%.1f ms now", monitor.latencyMs) : "Measuring…")
                    .font(.caption.bold().monospaced()).foregroundStyle(latencyColor)
                Text("· sampled every 3s").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)

            if monitor.latencyHistory.count > 1 {
                Chart {
                    ForEach(Array(monitor.latencyHistory.enumerated()), id: \.offset) { i, v in
                        let segColor: Color = v > 150 ? .red : v > 80 ? .yellow : .green

                        // Area uses the segment colour subtly
                        AreaMark(x: .value("Sample", i), y: .value("ms", v))
                            .foregroundStyle(segColor.opacity(0.1))
                            .interpolationMethod(.catmullRom)

                        // Line coloured by this segment's threshold
                        LineMark(x: .value("Sample", i), y: .value("ms", v),
                                 series: .value("s", v > 150 ? "poor" : v > 80 ? "fair" : "good"))
                            .foregroundStyle(segColor)
                            .interpolationMethod(.catmullRom)
                            .lineStyle(StrokeStyle(lineWidth: 2))

                        PointMark(x: .value("Sample", i), y: .value("ms", v))
                            .foregroundStyle(segColor)
                            .symbolSize(20)
                    }
                }
                .chartYAxisLabel { Text("ms").foregroundStyle(ChartAxis.text) }
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4,4]))
                            .foregroundStyle(Color.secondary.opacity(0.3))
                        AxisTick()
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text(String(format: "%.0f", v)).font(.caption2).foregroundStyle(ChartAxis.text)
                            }
                        }
                    }
                }
                .frame(height: 140)
                .padding(.horizontal, 12).padding(.bottom, 12)

                // Latency legend
                HStack(spacing: 16) {
                    legendPill(color: .green,  label: "Good (<80ms)")
                    legendPill(color: .yellow, label: "Fair (80–150ms)")
                    legendPill(color: .red,    label: "Poor (>150ms)")
                }
                .padding(.horizontal, 16).padding(.bottom, 12)
            } else {
                HStack {
                    ProgressView().scaleEffect(0.7)
                    Text("Measuring latency to 1.1.1.1…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(height: 60)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 12)
            }
        }
    }

    // MARK: Packet loss section

    private var packetLossSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(Color.red.opacity(0.8))
                    .frame(width: 16, height: 3)
                Text("Packet Loss (%)")
                    .font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.0f%% now", monitor.packetLoss))
                    .font(.caption.bold().monospaced()).foregroundStyle(lossColor)
                Text("· sampled every 3s").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)

            if monitor.packetLossHistory.count > 1 {
                Chart {
                    // Reference lines — labels on y-axis, no trailing annotations
                    RuleMark(y: .value("Threshold", 1.0))
                        .foregroundStyle(Color.orange.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    RuleMark(y: .value("Threshold", 5.0))
                        .foregroundStyle(Color.red.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

                    ForEach(Array(monitor.packetLossHistory.enumerated()), id: \.offset) { i, v in
                        AreaMark(x: .value("Sample", i), y: .value("%", v))
                            .foregroundStyle(
                                v > 5 ? Color.red.opacity(0.2)
                                      : v > 1 ? Color.orange.opacity(0.15)
                                              : Color.green.opacity(0.08)
                            )
                            .interpolationMethod(.stepEnd)

                        LineMark(x: .value("Sample", i), y: .value("%", v))
                            .foregroundStyle(
                                v > 5 ? Color.red
                                      : v > 1 ? Color.orange
                                              : Color.green.opacity(0.6)
                            )
                            .interpolationMethod(.stepEnd)
                            .lineStyle(StrokeStyle(lineWidth: 2))

                        if v > 0 {
                            PointMark(x: .value("Sample", i), y: .value("%", v))
                                .foregroundStyle(v > 5 ? Color.red : Color.orange)
                                .symbolSize(30)
                        }
                    }
                }
                .chartYAxisLabel { Text("%").foregroundStyle(ChartAxis.text) }
                .chartXAxis(.hidden)
                .chartYScale(domain: 0...(Swift.max(10, (monitor.packetLossHistory.max() ?? 0) * 1.3)))
                .chartPlotStyle { plot in plot.padding(.trailing, 0) }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4, 4]))
                            .foregroundStyle(Color.secondary.opacity(0.3))
                        AxisTick()
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text(String(format: "%.0f%%", v)).font(.caption2).foregroundStyle(ChartAxis.text)
                            }
                        }
                    }
                }
                .frame(height: 130)
                .padding(.horizontal, 12).padding(.bottom, 8)

                HStack(spacing: 16) {
                    legendPill(color: .green,  label: "No loss (0%)")
                    legendPill(color: .orange, label: "Degraded (1–5%)")
                    legendPill(color: .red,    label: "Critical (>5%)")
                }
                .padding(.horizontal, 16).padding(.bottom, 12)

            } else {
                HStack {
                    ProgressView().scaleEffect(0.7)
                    Text("Measuring packet loss…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(height: 60)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 12)
            }
        }
    }

    // MARK: Reusable chart

    @ViewBuilder
    private func bandwidthChart(samples: [BandwidthSample],
                                 valueKey: KeyPath<BandwidthSample, Double>,
                                 color: Color, label: String) -> some View {
        let values = samples.map { $0[keyPath: valueKey] }
        let peakBps = values.max() ?? 1
        let (divisor, unit): (Double, String) = {
            if peakBps >= 1_000_000_000 { return (1_000_000_000, "GB/s") }
            if peakBps >= 1_000_000     { return (1_000_000,     "MB/s") }
            if peakBps >= 1_000         { return (1_000,         "KB/s") }
            return (1, "B/s")
        }()
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 16, height: 3)
                Text(label).font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                Text(formatBps(values.last ?? 0))
                    .font(.caption.bold().monospaced()).foregroundStyle(color)
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
            Chart {
                ForEach(samples) { s in
                    LineMark(x: .value("Time", s.time),
                             y: .value(label, s[keyPath: valueKey] / divisor))
                        .foregroundStyle(color).interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
                ForEach(samples) { s in
                    AreaMark(x: .value("Time", s.time),
                             y: .value(label, s[keyPath: valueKey] / divisor))
                        .foregroundStyle(color.opacity(0.1)).interpolationMethod(.catmullRom)
                }
            }
            .chartYAxisLabel { Text(unit).foregroundStyle(ChartAxis.text) }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4,4]))
                        .foregroundStyle(Color.secondary.opacity(0.3))
                    AxisTick()
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(String(format: v >= 100 ? "%.0f" : "%.1f", v)).font(.caption2).foregroundStyle(ChartAxis.text)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .second, count: 15)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4,4]))
                        .foregroundStyle(Color.secondary.opacity(0.3))
                    AxisTick()
                    AxisValueLabel(format: .dateTime.minute().second()).foregroundStyle(ChartAxis.text)
                }
            }
            .frame(height: 160)
            .padding(.horizontal, 12).padding(.bottom, 12)
        }
    }

    // MARK: Sub-views

    private func statCell(_ label: String, _ value: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Text(label).font(.system(size: 8)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
    }

    private func statDivider() -> some View {
        Rectangle().fill(NS.text1.opacity(0.06)).frame(width: 0.5)
    }

    private func legendPill(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: Colour helpers

    private var latencyColor: Color {
        guard monitor.latencyMs > 0 else { return .secondary }
        if monitor.latencyMs > 150 { return .red }
        if monitor.latencyMs > 80  { return .yellow }
        return green
    }
    private var jitterColor: Color {
        if monitor.jitterMs > 50  { return .red }
        if monitor.jitterMs > 20  { return .orange }
        if monitor.jitterMs > 0   { return green }
        return .secondary
    }
    private var lossColor: Color {
        if monitor.packetLoss > 5  { return .red }
        if monitor.packetLoss > 1  { return .orange }
        return green
    }
    private var retxColor: Color {
        if monitor.retransmitRate > 10 { return .red }
        if monitor.retransmitRate > 2  { return .orange }
        return green
    }
    private var dnsColor: Color {
        guard monitor.dnsLatencyMs > 0 else { return .secondary }
        if monitor.dnsLatencyMs > 200 { return .red }
        if monitor.dnsLatencyMs > 80  { return .orange }
        return green
    }
    private var qualityColor: Color {
        if monitor.qualityScore >= 90 { return green }
        if monitor.qualityScore >= 70 { return .yellow }
        if monitor.qualityScore >= 50 { return .orange }
        return .red
    }

    // MARK: Formatters

    func formatBps(_ bps: Double) -> String {
        if bps < 1_000        { return String(format: "%.0f B/s",  bps) }
        if bps < 1_000_000    { return String(format: "%.1f KB/s", bps/1_000) }
        return                         String(format: "%.2f MB/s", bps/1_000_000)
    }
    func formatBytes(_ b: Double) -> String {
        if b < 1_000          { return String(format: "%.0f B",    b) }
        if b < 1_000_000      { return String(format: "%.1f KB",   b/1_000) }
        if b < 1_000_000_000  { return String(format: "%.2f MB",   b/1_000_000) }
        return                         String(format: "%.2f GB",   b/1_000_000_000)
    }
}
