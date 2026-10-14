// StatusBoardTiles.swift
// SNAP — Customizable Status Board tile catalog + layout (v1.5.x)
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md
//
// Mirrors the Dashboard's customizable-card pattern, but scoped to the
// Status Board's fullscreen / detachable display. The layout (which tiles
// are visible, in what order) is persisted to UserDefaults.

import SwiftUI

// MARK: - Tile catalog

enum StatusTileKind: String, CaseIterable, Identifiable, Codable {
    case bandwidth, wifi, alerts, favorites, latency, speedTest
    // v1.5.2 additions:
    case dnsLatency, system, topTalkers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bandwidth:  "Live Bandwidth"
        case .wifi:       "Wi-Fi"
        case .alerts:     "System Health"
        case .favorites:  "Favorites"
        case .latency:    "Gateway Latency"
        case .speedTest:  "Latest Speed Test"
        case .dnsLatency: "DNS Latency"
        case .system:     "System"
        case .topTalkers: "Top Talkers"
        }
    }

    var icon: String {
        switch self {
        case .bandwidth:  "chart.line.uptrend.xyaxis"
        case .wifi:       "wifi"
        case .alerts:     "checkmark.shield.fill"
        case .favorites:  "star.fill"
        case .latency:    "bolt.fill"
        case .speedTest:  "speedometer"
        case .dnsLatency: "magnifyingglass"
        case .system:     "cpu"
        case .topTalkers: "square.stack.3d.up.fill"
        }
    }

    var desc: String {
        switch self {
        case .bandwidth:  "Big RX/TX numbers + area sparkline + session totals + interfaces"
        case .wifi:       "SSID, band, channel, RSSI, SNR, security — with quality ring"
        case .alerts:     "Composite health score + grade + 4-hour activity timeline"
        case .favorites:  "Pinned hosts with live status + RTT sparkline"
        case .latency:    "Ring gauge + sparkline + min/avg/max/jitter/loss"
        case .speedTest:  "Latest result + history sparkline + Run Now button"
        case .dnsLatency: "Round-trip latency to configured DNS resolvers"
        case .system:     "Mac uptime, CPU load, memory pressure, battery"
        case .topTalkers: "Top processes by RX/TX right now (via nettop)"
        }
    }
}

// MARK: - Layout (persisted)

@MainActor
final class StatusBoardLayout: ObservableObject {
    static let shared = StatusBoardLayout()
    private let key = "com.bardaklabs.snap.statusboardLayout.v1"

    @Published var tiles: [StatusTileKind] = []

    // v1.5.2 default — richer, ordered to match the POC-approved layout.
    static let defaultLayout: [StatusTileKind] = [
        .bandwidth, .wifi,
        .latency, .alerts, .speedTest,
        .favorites, .dnsLatency,
        .topTalkers, .system,
    ]

    private init() { load() }

    private func load() {
        if let raw = UserDefaults.standard.array(forKey: key) as? [String], !raw.isEmpty {
            tiles = raw.compactMap { StatusTileKind(rawValue: $0) }
        } else {
            tiles = Self.defaultLayout
        }
    }

    private func save() {
        UserDefaults.standard.set(tiles.map(\.rawValue), forKey: key)
    }

    func add(_ kind: StatusTileKind) {
        guard !tiles.contains(kind) else { return }
        tiles.append(kind); save()
    }

    func remove(_ kind: StatusTileKind) {
        tiles.removeAll { $0 == kind }; save()
    }

    func move(_ kind: StatusTileKind, to targetIdx: Int) {
        guard let fromIdx = tiles.firstIndex(of: kind) else { return }
        let bounded = max(0, min(targetIdx, tiles.count - 1))
        guard fromIdx != bounded else { return }
        let item = tiles.remove(at: fromIdx)
        tiles.insert(item, at: bounded)
        save()
    }

    func reset() { tiles = Self.defaultLayout; save() }

    func isPinned(_ kind: StatusTileKind) -> Bool { tiles.contains(kind) }
}

// MARK: - Drag-to-reorder (used in Edit Mode)

import UniformTypeIdentifiers

struct StatusTileReorderDropDelegate: DropDelegate {
    let target: StatusTileKind
    let layout: StatusBoardLayout
    @Binding var draggingTile: StatusTileKind?

    func dropEntered(info: DropInfo) {
        guard let from = draggingTile, from != target else { return }
        guard let targetIdx = layout.tiles.firstIndex(of: target) else { return }
        layout.move(from, to: targetIdx)
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        draggingTile = nil
        return true
    }
}

extension View {
    /// Mirrors `draggableWhenEditing` from the Dashboard but for Status Board
    /// tiles. Only attaches drag/drop when Edit Mode is on so clicks pass
    /// through to the tile content normally.
    @ViewBuilder
    func tileDraggableWhenEditing(_ editing: Bool,
                                  kind: StatusTileKind,
                                  layout: StatusBoardLayout,
                                  draggingTile: Binding<StatusTileKind?>) -> some View {
        if editing {
            self
                .onDrag {
                    draggingTile.wrappedValue = kind
                    return NSItemProvider(object: kind.rawValue as NSString)
                }
                .onDrop(of: [.plainText], delegate:
                    StatusTileReorderDropDelegate(target: kind,
                                                  layout: layout,
                                                  draggingTile: draggingTile))
        } else {
            self
        }
    }
}

// MARK: - Tile chrome

struct StatusTileChrome<Content: View>: View {
    let kind: StatusTileKind
    let editing: Bool
    let onRemove: () -> Void
    let content: () -> Content
    @ObservedObject private var themeMgr = ThemeManager.shared

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 14) {
                Text(kind.title.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.1)
                    .foregroundStyle(NS.text3)
                content()
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(NS.bg2)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(editing ? NS.amber.opacity(0.7) : NS.border,
                                  style: StrokeStyle(lineWidth: 1, dash: editing ? [5, 4] : []))
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))

            if editing {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(NS.red))
                }
                .buttonStyle(.plain)
                .padding(10)
                .help("Remove from Status Board")
            }
        }
    }
}

// MARK: - Tile dispatcher

struct StatusTileBody: View {
    let kind: StatusTileKind
    @ObservedObject var bwMonitor: BandwidthDashMonitor
    @ObservedObject private var themeMgr = ThemeManager.shared

    var body: some View {
        switch kind {
        case .bandwidth:  SBBandwidthTile(bwMonitor: bwMonitor)
        case .wifi:       SBWiFiTile()
        case .alerts:     SBAlertsTile()
        case .favorites:  SBFavoritesTile()
        case .latency:    SBLatencyTile()
        case .speedTest:  SBSpeedTestTile()
        case .dnsLatency: SBDNSLatencyTile()
        case .system:     SBSystemTile()
        case .topTalkers: SBTopTalkersTile()
        }
    }
}

// MARK: - Reusable components (used across v1.5.2 tiles)

/// Circular ring gauge. `progress` is 0…1. Auto-colored by state buckets:
/// good < warn threshold, warn < bad threshold, bad above.
struct RingGauge: View {
    let progress: Double     // 0…1
    let lineWidth: CGFloat
    let color: Color
    let track: Color

    init(progress: Double,
         lineWidth: CGFloat = 8,
         color: Color = NS.green,
         track: Color? = nil) {
        self.progress = max(0, min(1, progress))
        self.lineWidth = lineWidth
        self.color = color
        self.track = track ?? NS.bg3
    }

    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.4), value: progress)
        }
    }
}

/// Line + area-fill sparkline. Handles `nil` samples by breaking the line.
struct AreaSparkline: View {
    let values: [Double?]
    let color: Color
    let showAreaFill: Bool

    init(_ values: [Double?], color: Color = NS.green, showAreaFill: Bool = true) {
        self.values = values
        self.color = color
        self.showAreaFill = showAreaFill
    }

    var body: some View {
        GeometryReader { geo in
            let hits = values.compactMap { $0 }
            if hits.count >= 2 {
                let hi = hits.max() ?? 1
                let lo = hits.min() ?? 0
                let range = Swift.max(hi - lo, 0.001)
                let w = geo.size.width, h = geo.size.height
                let step = w / CGFloat(values.count - 1)
                let pts: [CGPoint] = values.enumerated().compactMap { i, v in
                    guard let v else { return nil }
                    let x = CGFloat(i) * step
                    let y = h - CGFloat((v - lo) / range) * (h - 4) - 2
                    return CGPoint(x: x, y: y)
                }
                if showAreaFill, let first = pts.first, let last = pts.last {
                    Path { p in
                        p.move(to: CGPoint(x: first.x, y: h))
                        for pt in pts { p.addLine(to: pt) }
                        p.addLine(to: CGPoint(x: last.x, y: h))
                        p.closeSubpath()
                    }
                    .fill(color.opacity(0.18))
                }
                Path { p in
                    guard let first = pts.first else { return }
                    p.move(to: first)
                    for pt in pts.dropFirst() { p.addLine(to: pt) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

/// Small colored stat pill "LIVE" style — inline in tile headers.
struct StatusPill: View {
    let text: String
    let color: Color
    var pulse: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            if pulse {
                Circle().fill(color).frame(width: 5, height: 5)
                    .modifier(PulseAnim())
            }
            Text(text)
                .font(.system(size: 9, weight: .bold))
                .tracking(0.4)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(color.opacity(0.14))
        .clipShape(Capsule())
    }
}

private struct PulseAnim: ViewModifier {
    @State private var on = false
    func body(content: Content) -> some View {
        content
            .opacity(on ? 1.0 : 0.35)
            .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

/// Byte-count formatter shared by several tiles.
enum ByteFormat {
    static func rate(_ bytes: UInt64) -> String {
        let d = Double(bytes)
        if d >= 1_000_000_000 { return String(format: "%.1f GB/s", d / 1_000_000_000) }
        if d >= 1_000_000     { return String(format: "%.1f MB/s", d / 1_000_000) }
        if d >= 1_000         { return String(format: "%.0f KB/s", d / 1_000) }
        return "\(bytes) B/s"
    }
    static func size(_ bytes: UInt64) -> String {
        let d = Double(bytes)
        if d >= 1_000_000_000 { return String(format: "%.1f GB", d / 1_000_000_000) }
        if d >= 1_000_000     { return String(format: "%.1f MB", d / 1_000_000) }
        if d >= 1_000         { return String(format: "%.0f KB", d / 1_000) }
        return "\(bytes) B"
    }
}

// MARK: - Individual tiles

// ─── BANDWIDTH — dual area sparklines + peaks + session totals + interfaces
private struct SBBandwidthTile: View {
    @ObservedObject var bwMonitor: BandwidthDashMonitor
    @ObservedObject private var themeMgr = ThemeManager.shared
    @State private var sessionStart = Date()
    @State private var peakRx: Double = 0
    @State private var peakTx: Double = 0
    @State private var totalRxBytes: UInt64 = 0
    @State private var totalTxBytes: UInt64 = 0
    @State private var lastSampleAt = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("↓ RX").font(.system(size: 10, weight: .semibold)).tracking(0.5)
                        .foregroundStyle(NS.text3)
                    Text(verbatim: bwMonitor.rxRateStr)
                        .font(.system(size: 32, weight: .heavy, design: .monospaced))
                        .foregroundStyle(NS.green)
                        .lineLimit(1).minimumScaleFactor(0.6)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("TX ↑").font(.system(size: 10, weight: .semibold)).tracking(0.5)
                        .foregroundStyle(NS.text3)
                    Text(verbatim: bwMonitor.txRateStr)
                        .font(.system(size: 32, weight: .heavy, design: .monospaced))
                        .foregroundStyle(NS.blue)
                        .lineLimit(1).minimumScaleFactor(0.6)
                }
            }

            ZStack {
                AreaSparkline(bwMonitor.rxHistory.map { $0 as Double? }, color: NS.green)
                AreaSparkline(bwMonitor.txHistory.map { $0 as Double? }, color: NS.blue)
            }
            .frame(maxWidth: .infinity, minHeight: 76)

            HStack {
                Text(verbatim: "Peak ↓ \(fmtRate(peakRx))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(NS.text4)
                Spacer()
                Text(verbatim: "Peak ↑ \(fmtRate(peakTx))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(NS.text4)
            }

            HStack(spacing: 14) {
                cell("Session ↓", ByteFormat.size(totalRxBytes), NS.green)
                cell("Session ↑", ByteFormat.size(totalTxBytes), NS.blue)
                cell("Uptime", uptimeStr, NS.text1)
                cell("Iface", "en0 · Wi-Fi", NS.text1)
            }
            .padding(.top, 8)
            .overlay(Divider().background(NS.border), alignment: .top)
        }
        .onAppear {
            bwMonitor.start()
            sessionStart = Date()
        }
        .onChange(of: bwMonitor.rxHistory) { _ in updatePeaksAndTotals() }
    }

    private func cell(_ k: String, _ v: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k).font(.system(size: 9, weight: .bold)).tracking(0.5).foregroundStyle(NS.text3)
            Text(verbatim: v).font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(color).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var uptimeStr: String {
        let s = Int(Date().timeIntervalSince(sessionStart))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s/60)m" }
        return "\(s/3600)h \((s%3600)/60)m"
    }

    private func fmtRate(_ v: Double) -> String {
        if v >= 1_000_000 { return String(format: "%.1f MB/s", v / 1_000_000) }
        if v >= 1_000     { return String(format: "%.0f KB/s", v / 1_000) }
        return String(format: "%.0f B/s", v)
    }

    private func updatePeaksAndTotals() {
        if let last = bwMonitor.rxHistory.last, last > peakRx { peakRx = last }
        if let last = bwMonitor.txHistory.last, last > peakTx { peakTx = last }
        let now = Date()
        let dt = now.timeIntervalSince(lastSampleAt)
        lastSampleAt = now
        if dt > 0 && dt < 10 {  // sanity — skip stale first tick
            if let rxRate = bwMonitor.rxHistory.last {
                totalRxBytes &+= UInt64(rxRate * dt)
            }
            if let txRate = bwMonitor.txHistory.last {
                totalTxBytes &+= UInt64(txRate * dt)
            }
        }
    }
}

// ─── WI-FI — quality ring + detail grid
private struct SBWiFiTile: View {
    @State private var ssid = "—"
    @State private var band = ""
    /// Latest CoreWLAN reading; nil until the first read or when there's
    /// no Wi-Fi interface.
    @State private var info: StatusBoardWiFi.Info?
    @State private var timer: Timer?
    @ObservedObject private var themeMgr = ThemeManager.shared

    private var rssi: Int { info?.rssi ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: ssid)
                        .font(.system(size: 20, weight: .bold))
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text(verbatim: band)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(NS.text3)
                }
                Spacer()
                ZStack {
                    RingGauge(progress: qualityFraction, lineWidth: 7, color: qualityColor)
                    VStack(spacing: 0) {
                        Text(verbatim: "\(qualityScore)")
                            .font(.system(size: 19, weight: .heavy, design: .monospaced))
                            .foregroundStyle(qualityColor)
                        Text("QUALITY")
                            .font(.system(size: 8, weight: .bold)).tracking(0.5)
                            .foregroundStyle(NS.text3)
                    }
                }
                .frame(width: 78, height: 78)
            }
            Spacer(minLength: 0)
            wifiDetailGrid
                .padding(.top, 6)
                .overlay(Divider().background(NS.border), alignment: .top)
        }
        .onAppear { refresh(); start() }
        .onDisappear { timer?.invalidate(); timer = nil }
    }

    /// Every cell is a live CoreWLAN reading, or "—" when unavailable. (In
    /// v1.5.2 TX Rate, Security, Noise, and MCS were hard-coded mockup
    /// values and SNR was RSSI + 95.) MCS was replaced by PHY: CoreWLAN
    /// doesn't expose the MCS index.
    private var wifiDetailGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                detailCell("RSSI", rssi == 0 ? "—" : "\(rssi)", rssiColor)
                detailCell("SNR", info?.snr.map { "\($0)" } ?? "—", snrColor)
                detailCell("TX Rate", info?.txRateMbps.map { "\(Int($0.rounded())) Mbps" } ?? "—",
                           info?.txRateMbps == nil ? NS.text3 : NS.text1)
            }
            GridRow {
                detailCell("Security", info?.security ?? "—", securityColor)
                detailCell("Noise", info?.noise.map { "\($0)" } ?? "—",
                           info?.noise == nil ? NS.text3 : NS.text1)
                detailCell("PHY", info?.standard ?? "—",
                           info?.standard == nil ? NS.text3 : NS.text1)
            }
        }
    }
    /// ≥ 25 dB is a clean link, 15–25 is usable, below 15 is struggling.
    private var snrColor: Color {
        guard let snr = info?.snr else { return NS.text3 }
        if snr >= 25 { return NS.green }
        if snr >= 15 { return NS.amber }
        return NS.red
    }
    private var securityColor: Color {
        guard info?.security != nil else { return NS.text3 }
        return info?.securityInsecure == true ? NS.red : NS.text1
    }
    private func detailCell(_ k: String, _ v: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(k).font(.system(size: 8, weight: .bold)).tracking(0.4).foregroundStyle(NS.text3)
            Text(verbatim: v).font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
        }
    }

    /// RSSI → 0…100, via the mapping the health score also uses.
    private var qualityScore: Int { ConnectionHealth.wifiQuality(rssi: rssi) }
    private var qualityFraction: Double { Double(qualityScore) / 100 }
    private var qualityColor: Color {
        if qualityScore >= 70 { return NS.green }
        if qualityScore >= 40 { return NS.amber }
        return NS.red
    }
    private var rssiColor: Color {
        if rssi == 0 { return NS.text3 }
        if rssi > -60 { return NS.green }
        if rssi > -75 { return NS.amber }
        return NS.red
    }
    private func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor in refresh() }
        }
    }
    private func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let reading = StatusBoardWiFi.read()
            DispatchQueue.main.async {
                info = reading
                ssid = reading.map { $0.rssi == 0 ? "Not associated" : $0.ssid } ?? "Not associated"
                band = reading?.rssi == 0 ? "" : (reading?.band ?? "")
            }
        }
    }
}

// ─── SYSTEM HEALTH — composite score + timeline + clean-for
private struct SBAlertsTile: View {
    @ObservedObject private var alerts = AlertManager.shared
    @ObservedObject private var mon = MenuBarMonitor.shared
    @ObservedObject private var themeMgr = ThemeManager.shared
    /// Wi-Fi signal (0–100), only while Wi-Fi carries the default route —
    /// on Ethernet a weak Wi-Fi signal doesn't affect the connection.
    @State private var wifiQuality: Int?
    @State private var wifiTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                ZStack {
                    RingGauge(progress: Double(assessment.score ?? 0) / 100, lineWidth: 7,
                              color: scoreColor)
                    VStack(spacing: 0) {
                        Text(verbatim: assessment.score.map(String.init) ?? "—")
                            .font(.system(size: 24, weight: .heavy, design: .monospaced))
                            .foregroundStyle(scoreColor)
                        Text("SCORE").font(.system(size: 8, weight: .bold))
                            .tracking(0.5).foregroundStyle(NS.text3)
                    }
                }
                .frame(width: 88, height: 88)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: assessment.grade)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(scoreColor)
                    Text(verbatim: assessment.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(NS.text2)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: cleanForText)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(0.3)
                        .foregroundStyle(NS.text3)
                        .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            timelineStrip
                .padding(.top, 6)
                .overlay(Divider().background(NS.border), alignment: .top)
        }
        .onAppear { readWiFi(); startWiFi() }
        .onDisappear { wifiTimer?.invalidate(); wifiTimer = nil }
    }

    private func startWiFi() {
        wifiTimer?.invalidate()
        wifiTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            Task { @MainActor in readWiFi() }
        }
    }

    private func readWiFi() {
        DispatchQueue.global(qos: .utility).async {
            let info = StatusBoardWiFi.read()
            let primary = RouteInfo.defaultInterface()
            let q: Int? = {
                guard let info, info.rssi != 0, info.iface != nil, info.iface == primary else { return nil }
                return ConnectionHealth.wifiQuality(rssi: info.rssi)
            }()
            DispatchQueue.main.async { wifiQuality = q }
        }
    }

    // 48 buckets covering ~4h; each is proportional to that period's alert
    // density. For a first pass we synthesize the shape from recent event
    // timestamps — heights vary but no bar exceeds 60% at rest.
    private var timelineStrip: some View {
        HStack(spacing: 2) {
            let buckets = alertBuckets(count: 48, hours: 4)
            ForEach(0..<buckets.count, id: \.self) { i in
                let (h, sev) = buckets[i]
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(sevColor(sev))
                    .opacity(sev == 0 ? 0.55 : (sev == 1 ? 0.85 : 1.0))
                    .frame(height: max(3, CGFloat(h)))
            }
        }
        .frame(height: 26)
    }

    private func alertBuckets(count: Int, hours: Double) -> [(Int, Int)] {
        // (height 3…24 px, severity 0=quiet, 1=warn, 2=bad)
        let now = Date()
        let span = hours * 3600
        let bucketSize = span / Double(count)
        var out: [(Int, Int)] = Array(repeating: (3, 0), count: count)
        // Idle animation: a very-low baseline so it doesn't look dead
        for i in 0..<count { out[i].0 = 3 + (i % 5) }
        for ev in alerts.recentEvents.prefix(50) {
            let delta = now.timeIntervalSince(ev.date)
            guard delta >= 0, delta <= span else { continue }
            let idx = Swift.max(0, Swift.min(count - 1, count - 1 - Int(delta / bucketSize)))
            let severe = ev.value > (ev.metric.severeThreshold ?? .greatestFiniteMagnitude)
            out[idx].0 = Swift.max(out[idx].0, severe ? 24 : 14)
            out[idx].1 = Swift.max(out[idx].1, severe ? 2 : 1)
        }
        return out
    }

    private func sevColor(_ sev: Int) -> Color {
        switch sev { case 2: return NS.red; case 1: return NS.amber; default: return NS.green }
    }

    /// Scored by the shared `ConnectionHealth` model — the same one behind
    /// the Gateway Latency tile's label, so the two can't disagree.
    private var assessment: ConnectionHealth.Assessment {
        let stats = mon.latencyStats
        let recentAlerts = alerts.recentEvents.filter {
            Date().timeIntervalSince($0.date) < 3600
        }.count
        return ConnectionHealth.assess(avgMs: stats.avg, jitterMs: stats.jitter,
                                       lossPct: stats.lossPct, samples: stats.sampleCount,
                                       wifiQuality: wifiQuality, recentAlerts: recentAlerts,
                                       trailingTimeouts: stats.trailingTimeouts)
    }
    /// Green for Good and above, amber for Fair, red below — matches the grade.
    private var scoreColor: Color {
        guard let s = assessment.score else { return NS.text3 }
        if s >= 75 { return NS.green }
        if s >= 50 { return NS.amber }
        return NS.red
    }
    private var cleanForText: String {
        guard let last = alerts.recentEvents.first else { return "CLEAN ALL DAY" }
        let s = Int(Date().timeIntervalSince(last.date))
        if s < 60 { return "LAST ALERT: \(s)s AGO" }
        if s < 3600 { return "CLEAN FOR \(s/60)m" }
        return "CLEAN FOR \(s/3600)h \((s%3600)/60)m"
    }
}

// Helper — treat any AlertEvent's severeThreshold conservatively. Not stored
// on the AlertEvent model, so we approximate by metric type.
private extension AlertMetric {
    var severeThreshold: Double? {
        switch self {
        case .latencyMs:      return 150
        case .packetLoss:     return 5
        case .jitterMs:       return 30
        case .retransmitRate: return 3
        case .dnsLatencyMs:   return 100
        }
    }
}

// ─── FAVORITES — kept from v1.5.1, unchanged
private struct SBFavoritesTile: View {
    @ObservedObject private var favs = FavoritesManager.shared
    @ObservedObject private var themeMgr = ThemeManager.shared
    @State private var showAdd = false
    @State private var newHost = ""
    @State private var newLabel = ""
    @State private var hoveredID: UUID? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if favs.items.isEmpty {
                emptyState
            } else {
                ForEach(favs.items.prefix(6)) { fav in
                    let st = favs.status[fav.id]
                    let hist = favs.history[fav.id] ?? []
                    let hovered = hoveredID == fav.id
                    HStack(spacing: 10) {
                        Circle().fill(color(for: st)).frame(width: 9, height: 9)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: fav.label)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(NS.text1)
                                .lineLimit(1)
                            Text(verbatim: fav.host)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(NS.text3)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        if hist.count >= 2 {
                            MiniSparkline(values: hist, color: color(for: st))
                                .frame(width: 70, height: 22)
                        }
                        Text(verbatim: rttText(st))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(color(for: st))
                            .frame(minWidth: 48, alignment: .trailing)
                        Button {
                            favs.remove(fav.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 18, height: 18)
                                .background(Circle().fill(NS.red))
                        }
                        .buttonStyle(.plain)
                        .opacity(hovered ? 1 : 0)
                        .help("Remove from Favorites")
                    }
                    .contentShape(Rectangle())
                    .onHover { isInside in hoveredID = isInside ? fav.id : nil }
                    .hostMenu(fav.host)
                }
                Spacer(minLength: 0)
                addButton
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .popover(isPresented: $showAdd, arrowEdge: .bottom) { addPopover }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "star.slash").font(.system(size: 36)).foregroundStyle(NS.text4)
            Text("No favorites yet").font(.system(size: 14, weight: .semibold)).foregroundStyle(NS.text2)
            addButton.padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var addButton: some View {
        Button { showAdd = true } label: {
            Label("Add favorite", systemImage: "plus")
                .font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(.borderedProminent).controlSize(.small).tint(NS.amber)
    }
    private var addPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add Favorite").font(.system(size: 12, weight: .semibold))
            TextField("Label (e.g. Home router)", text: $newLabel).textFieldStyle(.roundedBorder).frame(width: 240)
            TextField("Host or IP (e.g. 192.168.1.1)", text: $newHost).textFieldStyle(.roundedBorder).frame(width: 240)
                .onSubmit { commit() }
            HStack {
                Spacer()
                Button("Cancel") { showAdd = false }.controlSize(.small)
                Button("Add") { commit() }.buttonStyle(.borderedProminent).controlSize(.small).tint(NS.amber)
                    .disabled(newHost.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
    }
    private func commit() {
        let host = newHost.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        favs.add(label: newLabel.isEmpty ? nil : newLabel, host: host)
        newHost = ""; newLabel = ""; showAdd = false
    }
    private func color(for st: FavoriteStatus?) -> Color {
        switch st?.state {
        case .ok:   return NS.green
        case .slow: return NS.amber
        case .bad:  return NS.red
        default:    return NS.text4
        }
    }
    private func rttText(_ st: FavoriteStatus?) -> String {
        if let ms = st?.rttMs { return String(format: "%.0f ms", ms) }
        if st?.state == .bad { return "down" }
        return "—"
    }
}

// ─── GATEWAY LATENCY — ring gauge + sparkline + min/max/avg/jitter/loss
private struct SBLatencyTile: View {
    @ObservedObject private var mon = MenuBarMonitor.shared
    @ObservedObject private var themeMgr = ThemeManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    RingGauge(progress: ringFraction, lineWidth: 8, color: ringColor)
                    VStack(spacing: 0) {
                        Text(verbatim: ringNumber)
                            .font(.system(size: 26, weight: .heavy, design: .monospaced))
                            .foregroundStyle(ringColor)
                            .lineLimit(1).minimumScaleFactor(0.6)
                        Text("ms").font(.system(size: 10)).foregroundStyle(NS.text3)
                    }
                }
                .frame(width: 100, height: 100)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        Circle().fill(stateColor).frame(width: 6, height: 6)
                        Text(verbatim: stateLabel)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(stateColor)
                    }
                    AreaSparkline(mon.latencyHistory, color: ringColor)
                        .frame(height: 34)
                    Text(verbatim: "\(mon.latencyHistory.count) samples · \(spanText)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(NS.text4)
                }
            }
            HStack(spacing: 14) {
                statCell("Min",    mon.latencyStats.min.map { String(format: "%.0f", $0) } ?? "—", NS.green)
                statCell("Avg",    mon.latencyStats.avg.map { String(format: "%.0f", $0) } ?? "—", NS.text1)
                statCell("Max",    mon.latencyStats.max.map { String(format: "%.0f", $0) } ?? "—", NS.text1)
                statCell("Jitter", mon.latencyStats.jitter.map { String(format: "%.1f", $0) } ?? "—", NS.text1)
                statCell("Loss",   String(format: "%.0f%%", mon.latencyStats.lossPct), lossColor)
            }
            .padding(.top, 6)
            .overlay(Divider().background(NS.border), alignment: .top)
        }
    }

    private func statCell(_ k: String, _ v: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k).font(.system(size: 9, weight: .bold)).tracking(0.5).foregroundStyle(NS.text3)
            Text(verbatim: v).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var ringNumber: String {
        if let ms = mon.gatewayLatencyMs { return "\(Int(ms))" }
        return "—"
    }
    private var ringFraction: Double {
        guard let ms = mon.gatewayLatencyMs else { return 0 }
        return min(ms / 200, 1)   // ring fills as latency approaches 200ms
    }
    /// Judged on the whole sample window with the same costs as the System
    /// Health score. It used to classify only the latest single ping, which
    /// could read "Healthy" beside a 50 ms average and 64 ms of jitter.
    /// Same value the menu bar dot is colored from.
    private var gatewayState: ConnectionHealth.GatewayState { mon.gatewayState }
    private var ringColor: Color {
        if mon.health == .offline { return NS.red }
        switch gatewayState {
        case .healthy:                 return NS.green
        case .slow, .unstable:         return NS.amber
        case .degraded, .notResponding: return NS.red
        case .measuring:               return NS.text3
        }
    }
    private var stateColor: Color { ringColor }
    private var stateLabel: String {
        if mon.health == .offline { return "Offline" }
        switch gatewayState {
        case .healthy:       return "Healthy · gateway"
        case .slow:          return "Slow · gateway"
        case .unstable:      return "Unstable · gateway"
        case .degraded:      return "Degraded · gateway"
        case .notResponding: return "Not responding"
        case .measuring:     return "Checking…"
        }
    }
    private var lossColor: Color {
        mon.latencyStats.lossPct > 0 ? NS.red : NS.green
    }
    private var spanText: String {
        let n = mon.latencyHistory.count
        let seconds = n * 10 // 10s cadence
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60) min"
    }
}

// ─── SPEED TEST — big numbers + history sparkline + Run Now
private struct SBSpeedTestTile: View {
    @ObservedObject private var history = SpeedTestHistoryStore.shared
    @ObservedObject private var themeMgr = ThemeManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let last = history.results.first {
                VStack(alignment: .leading, spacing: 6) {
                    speedRow("DOWNLOAD", String(format: "%.0f", last.download), "Mbps", NS.green)
                    speedRow("UPLOAD",   String(format: "%.0f", last.upload),   "Mbps", NS.blue)
                    speedRow("PING",     String(format: "%.0f", last.ping),     "ms",   NS.amber)
                }
                if history.results.count >= 2 {
                    AreaSparkline(history.results.prefix(20).reversed().map { $0.download as Double? },
                                  color: NS.green)
                        .frame(height: 32)
                }
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: last.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(NS.text3)
                        if let avg = averageDownload {
                            let delta = last.download - avg
                            let pct = avg > 0 ? (delta / avg) * 100 : 0
                            Text(verbatim: String(format: "%@%.0f%% vs 7d avg", pct >= 0 ? "↑ " : "↓ ", abs(pct)))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(pct >= 0 ? NS.green : NS.red)
                        }
                    }
                    Spacer()
                    Button {
                        runSpeedTest()
                    } label: {
                        Label("Run Now", systemImage: "play.fill")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small).tint(NS.amber)
                }
                .padding(.top, 6)
                .overlay(Divider().background(NS.border), alignment: .top)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "speedometer").font(.system(size: 40)).foregroundStyle(NS.text4)
                    Text("No speed tests yet")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(NS.text2)
                    Button("Run first test") { runSpeedTest() }
                        .buttonStyle(.borderedProminent).controlSize(.small).tint(NS.amber)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// "Run Now" has to actually run a test. The speed-test logic lives inside
    /// `SpeedTestView` (as @State + private methods), so the tile can't drive
    /// it directly — instead it hands off with the autostart sentinel and the
    /// destination view kicks the test off on appear.
    ///
    /// Board handling differs by mode: the in-window overlay is covering the
    /// very tab we're navigating to, so it must come down first. A detached
    /// board lives in its own window (often a second monitor), so it stays up
    /// and we just drive the main window.
    private func runSpeedTest() {
        if !StatusBoardManager.shared.isDetached {
            StatusBoardManager.shared.isPresented = false
        }
        ToolHandoff.shared.send(ToolHandoff.autostartToken, to: .speedTest)
    }
    private func speedRow(_ lbl: String, _ v: String, _ u: String, _ color: Color) -> some View {
        HStack(alignment: .lastTextBaseline) {
            Text(lbl).font(.system(size: 9, weight: .bold)).tracking(0.5).foregroundStyle(NS.text3)
            Spacer()
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(verbatim: v)
                    .font(.system(size: 20, weight: .heavy, design: .monospaced))
                    .foregroundStyle(color)
                Text(u).font(.system(size: 9)).foregroundStyle(NS.text3)
            }
        }
    }
    private var averageDownload: Double? {
        let recent = history.results.prefix(20).map(\.download)
        guard recent.count >= 3 else { return nil }
        return recent.reduce(0, +) / Double(recent.count)
    }
}

// ─── DNS LATENCY — bar chart per resolver
private struct SBDNSLatencyTile: View {
    @ObservedObject private var dns = DNSLatencyMonitor.shared
    @ObservedObject private var themeMgr = ThemeManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(dns.resolvers) { r in
                let ms = dns.results[r.id]
                let failed = dns.failed.contains(r.id)
                HStack(spacing: 9) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(NS.text1)
                        Text(r.ip.isEmpty ? "—" : r.ip)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(NS.text3)
                    }
                    .frame(width: 96, alignment: .leading)
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(NS.bg3)
                            .frame(height: 8)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(barColor(ms: ms, failed: failed))
                            .frame(width: barWidth(ms: ms), height: 8)
                    }
                    Text(verbatim: valText(ms: ms, failed: failed))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(barColor(ms: ms, failed: failed))
                        .frame(minWidth: 52, alignment: .trailing)
                }
            }
            Spacer(minLength: 0)
        }
    }
    private func barWidth(ms: Double?) -> CGFloat {
        guard let ms else { return 0 }
        // 200ms fills the bar visually — anything worse pins at 100%
        return min(CGFloat(ms / 200) * 200, 200)
    }
    private func barColor(ms: Double?, failed: Bool) -> Color {
        if failed || ms == nil { return NS.red }
        if let ms { if ms < 30 { return NS.green }; if ms < 80 { return NS.amber }; return NS.red }
        return NS.text3
    }
    private func valText(ms: Double?, failed: Bool) -> String {
        if failed || ms == nil { return "fail" }
        return String(format: "%.0f ms", ms!)
    }
}

// ─── SYSTEM — uptime, CPU, memory, battery
private struct SBSystemTile: View {
    @ObservedObject private var sys = SystemStatsMonitor.shared
    @ObservedObject private var themeMgr = ThemeManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("MAC UPTIME").font(.system(size: 9, weight: .bold)).tracking(0.5).foregroundStyle(NS.text3)
                Text(verbatim: uptimeStr)
                    .font(.system(size: 20, weight: .heavy, design: .monospaced))
                    .foregroundStyle(NS.text1)
            }
            .padding(.bottom, 4)
            .overlay(Divider().background(NS.border), alignment: .bottom)
            sysRow("CPU", sys.cpuPct, "\(Int(sys.cpuPct.rounded()))%", cpuColor)
            sysRow("Memory", memPct, memText, memColor)
            sysRow("Battery",
                   sys.batteryPct.map { Double($0) } ?? 0,
                   sys.batteryPct == nil ? "no battery" : batteryText,
                   batteryColor)
            Spacer(minLength: 0)
        }
    }
    private func sysRow(_ k: String, _ pct: Double, _ vText: String, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Text(k).font(.system(size: 10, weight: .bold)).tracking(0.5).foregroundStyle(NS.text3).frame(width: 62, alignment: .leading)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(NS.bg3).frame(height: 6)
                RoundedRectangle(cornerRadius: 3).fill(color).frame(width: max(0, min(1, pct / 100)) * 200, height: 6)
            }
            .frame(maxWidth: .infinity)
            Text(verbatim: vText).font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(NS.text1).frame(minWidth: 82, alignment: .trailing)
        }
    }
    private var uptimeStr: String {
        let s = Int(sys.uptimeSeconds)
        let days = s / 86400
        let hrs = (s % 86400) / 3600
        let mins = (s % 3600) / 60
        if days > 0 { return "\(days)d \(hrs)h \(mins)m" }
        if hrs > 0 { return "\(hrs)h \(mins)m" }
        return "\(mins)m"
    }
    private var cpuColor: Color {
        if sys.cpuPct < 30 { return NS.green }
        if sys.cpuPct < 70 { return NS.amber }
        return NS.red
    }
    private var memPct: Double {
        guard sys.memTotalBytes > 0 else { return 0 }
        return Double(sys.memUsedBytes) / Double(sys.memTotalBytes) * 100
    }
    private var memText: String {
        guard sys.memTotalBytes > 0 else { return "—" }
        return "\(ByteFormat.size(sys.memUsedBytes)) / \(ByteFormat.size(sys.memTotalBytes))"
    }
    private var memColor: Color {
        if memPct < 60 { return NS.green }
        if memPct < 85 { return NS.amber }
        return NS.red
    }
    private var batteryText: String {
        let mark = sys.batteryCharging ? "⚡" : ""
        return "\(sys.batteryPct ?? 0)% \(mark)".trimmingCharacters(in: .whitespaces)
    }
    private var batteryColor: Color {
        guard let p = sys.batteryPct else { return NS.text4 }
        if p > 40 { return NS.green }
        if p > 15 { return NS.amber }
        return NS.red
    }
}

// ─── TOP TALKERS — per-process bandwidth via nettop
private struct SBTopTalkersTile: View {
    @ObservedObject private var tt = TopTalkersMonitor.shared
    @ObservedObject private var themeMgr = ThemeManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let note = tt.errorNote {
                Text(note).font(.system(size: 10)).foregroundStyle(NS.amber)
                    .padding(.vertical, 4)
            }
            if tt.talkers.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "hourglass").font(.system(size: 32)).foregroundStyle(NS.text4)
                    Text("Sampling processes…")
                        .font(.system(size: 12)).foregroundStyle(NS.text3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ForEach(tt.talkers) { t in
                    talkerRow(t)
                }
                Spacer(minLength: 0)
            }
        }
    }
    private func talkerRow(_ t: TopTalkersMonitor.Talker) -> some View {
        let maxRate = tt.talkers.map { max($0.rxRate, $0.txRate) }.max() ?? 1
        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: t.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(NS.text1)
                    .lineLimit(1)
                Text(verbatim: "PID \(t.pid)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(NS.text3)
            }
            .frame(width: 128, alignment: .leading)
            VStack(spacing: 2) {
                bar(rate: t.rxRate, max: maxRate, color: NS.green, label: "↓")
                bar(rate: t.txRate, max: maxRate, color: NS.blue,  label: "↑")
            }
        }
    }
    private func bar(rate: Double, max maxRate: Double, color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 9, design: .monospaced)).foregroundStyle(NS.text3).frame(width: 12)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(NS.bg3).frame(height: 6)
                RoundedRectangle(cornerRadius: 2).fill(color)
                    .frame(width: maxRate > 0 ? CGFloat(rate / maxRate) * 160 : 0, height: 6)
            }
            .frame(maxWidth: .infinity)
            Text(verbatim: ByteFormat.rate(UInt64(rate)))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(NS.text2)
                .frame(minWidth: 66, alignment: .trailing)
        }
    }
}

// MARK: - Add Tile sheet

struct AddStatusTileSheet: View {
    @ObservedObject var layout: StatusBoardLayout
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add tile to Status Board")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(NS.text3)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(NS.bg0)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(NS.border), alignment: .bottom)

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 10)], spacing: 10) {
                    ForEach(StatusTileKind.allCases) { kind in
                        Button {
                            if !layout.isPinned(kind) { layout.add(kind) }
                        } label: {
                            HStack(spacing: 11) {
                                Image(systemName: kind.icon)
                                    .font(.system(size: 13))
                                    .foregroundStyle(NS.amber)
                                    .frame(width: 26, height: 26)
                                    .background(NS.bg3)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(kind.title)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(NS.text1)
                                    Text(kind.desc)
                                        .font(.system(size: 10))
                                        .foregroundStyle(NS.text3)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                if layout.isPinned(kind) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 12))
                                        .foregroundStyle(NS.green)
                                }
                            }
                            .padding(11)
                            .background(NS.bg3)
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(NS.border))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .opacity(layout.isPinned(kind) ? 0.55 : 1.0)
                        .disabled(layout.isPinned(kind))
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 560, height: 380)
        .background(NS.bg1)
    }
}
