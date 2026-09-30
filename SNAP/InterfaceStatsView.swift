// InterfaceStatsView.swift
// SNAP — Interface Stats (full rewrite in v1.2.4)
// Created by Sevag Bardakjian
// Copyright © 2025 Sevag Bardakjian. All rights reserved.
//
// Replaces the previous netstat-shell-out version with:
//   • Single sortable Table over getifaddrs (sub-millisecond, no process spawn)
//   • Filter chips (All / Up / Ethernet / Wi-Fi / VPN / Loopback / Other)
//   • Search box (name, friendly, MAC, IP)
//   • Live mode: per-row 60s sparklines for RX + TX so you can compare
//     every interface's traffic at a glance without switching pages
//   • Right-side detail panel with bigger chart + interface metadata
//   • CSV / JSON export consistent with the rest of the app
//   • "Active route" badge inline on the gateway-carrying interface

import SwiftUI
import Darwin

// MARK: - Model

@MainActor
final class InterfaceStatsModel: ObservableObject {
    @Published var infos: [InterfaceInfo] = []
    @Published var activeRoute: String? = nil
    @Published var liveByName: [String: LiveData] = [:]
    @Published var isLive: Bool = false
    @Published var search: String = ""
    @Published var filter: Filter = .all
    @Published var lastRefresh: Date? = nil

    struct LiveData: Hashable {
        var rxBps: Double = 0
        var txBps: Double = 0
        var rxHistory: [Double] = []   // last 60 seconds, newest at end
        var txHistory: [Double] = []
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all      = "All"
        case up       = "Up"
        case ethernet = "Ethernet"
        case wifi     = "Wi-Fi"
        case vpn      = "VPN"
        case loopback = "Loopback"
        case other    = "Other"
        var id: String { rawValue }

        func matches(_ iface: InterfaceInfo) -> Bool {
            switch self {
            case .all:      return true
            case .up:       return iface.isUp
            case .ethernet: return iface.mediaType == .ethernet
            case .wifi:     return iface.mediaType == .wifi
            case .vpn:      return [.vpn, .ipsec, .ppp].contains(iface.mediaType)
            case .loopback: return iface.mediaType == .loopback
            case .other:    return [.bridge, .awdl, .llw, .other].contains(iface.mediaType)
            }
        }
    }

    private var prevCounters: [String: (rx: UInt64, tx: UInt64)] = [:]
    private var timer: Timer?

    func refresh() {
        let (ifaces, active) = NetworkInfoProvider.getInterfaces()
        infos = ifaces
        activeRoute = active
        lastRefresh = Date()
        for i in ifaces {
            if liveByName[i.name] == nil { liveByName[i.name] = LiveData() }
            if let t = i.traffic { prevCounters[i.name] = (t.rxBytes, t.txBytes) }
        }
    }

    func startLive() {
        guard !isLive else { return }
        isLive = true
        // Reset prev so the first tick doesn't show a massive spike
        for i in infos {
            if let t = i.traffic { prevCounters[i.name] = (t.rxBytes, t.txBytes) }
        }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopLive() {
        timer?.invalidate(); timer = nil
        isLive = false
    }

    private func tick() {
        let snap = NetworkInfoProvider.snapshotLive()
        for s in snap {
            guard let t = s.traffic else { continue }
            let rxDelta: Double
            let txDelta: Double
            if let p = prevCounters[s.name] {
                rxDelta = Double(t.rxBytes &- p.rx)
                txDelta = Double(t.txBytes &- p.tx)
            } else {
                rxDelta = 0; txDelta = 0
            }
            prevCounters[s.name] = (t.rxBytes, t.txBytes)

            var live = liveByName[s.name] ?? LiveData()
            live.rxBps = rxDelta
            live.txBps = txDelta
            live.rxHistory.append(rxDelta)
            live.txHistory.append(txDelta)
            if live.rxHistory.count > 60 { live.rxHistory.removeFirst() }
            if live.txHistory.count > 60 { live.txHistory.removeFirst() }
            liveByName[s.name] = live

            // Keep cumulative counters fresh on InterfaceInfo so totals update
            if let idx = infos.firstIndex(where: { $0.name == s.name }) {
                var i = infos[idx]
                i.traffic = t
                i.isUp = s.isUp
                infos[idx] = i
            }
        }
    }

    var filtered: [InterfaceInfo] {
        var arr = infos.filter { filter.matches($0) }
        if !search.isEmpty {
            let s = search.lowercased()
            arr = arr.filter {
                $0.name.lowercased().contains(s) ||
                $0.displayName.lowercased().contains(s) ||
                $0.macAddress.lowercased().contains(s) ||
                $0.ipv4Bindings.contains(where: { $0.ip.contains(s) })
            }
        }
        return arr
    }
}

// MARK: - InterfaceInfo sort helpers
//
// Table's sortOrder mechanism wants KeyPathComparator with Comparable
// values. The optional-Int / counter fields aren't directly Comparable,
// so we expose Comparable computed mirrors here.

extension InterfaceInfo {
    var totalRxBytes: UInt64 { traffic?.rxBytes ?? 0 }
    var totalTxBytes: UInt64 { traffic?.txBytes ?? 0 }
    var rxPackets:    UInt64 { traffic?.rxPackets ?? 0 }
    var txPackets:    UInt64 { traffic?.txPackets ?? 0 }
    var rxErrorCount: UInt32 { traffic?.rxErrors ?? 0 }
    var txErrorCount: UInt32 { traffic?.txErrors ?? 0 }
    var mtuSortable:  Int    { mtu ?? 0 }
    var ipv4Count:    Int    { ipv4Bindings.count }
}

// MARK: - View

struct InterfaceStatsView: View {
    @StateObject private var model = InterfaceStatsModel()
    @State private var selectedName: String? = nil
    @State private var sortOrder: [KeyPathComparator<InterfaceInfo>] = [
        KeyPathComparator(\.totalRxBytes, order: .reverse)
    ]

    private var sortedRows: [InterfaceInfo] {
        model.filtered.sorted(using: sortOrder)
    }

    private var selectedInterface: InterfaceInfo? {
        model.infos.first { $0.name == selectedName }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            filterBar
            Divider()
            HSplitView {
                table
                    .frame(minWidth: 520)
                detailContainer
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
            }
        }
        .navigationTitle("Interface Stats")
        .onAppear { if model.infos.isEmpty { model.refresh() } }
        .onDisappear { model.stopLive() }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: "chart.line.uptrend.xyaxis").foregroundStyle(.blue)
            Text("Interface Stats")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(NS.text1)

            if model.isLive {
                Circle().fill(NS.green).frame(width: 7, height: 7)
                    .opacity(0.85)
                Text("Live").font(.system(size: 11)).foregroundStyle(NS.green)
            } else if let t = model.lastRefresh {
                Text("refreshed \(t.formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 11)).foregroundStyle(NS.text3)
            }

            Spacer()

            ToolActionBar("Interface Stats",
                          text: { exportText() },
                          csv:  { exportCSV() },
                          json: { exportJSON() })

            if model.isLive {
                Button("Stop Live") { model.stopLive() }
                    .buttonStyle(.bordered)
                    .tint(.red)
            } else {
                Button("Live") { model.startLive() }
                    .buttonStyle(.bordered)
            }

            Button { model.refresh() } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("r", modifiers: .command)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(NS.bg0)
    }

    // MARK: Filter chip bar

    private var filterBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11)).foregroundStyle(NS.text3)
                TextField("search name / MAC / IP", text: $model.search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
            ForEach(InterfaceStatsModel.Filter.allCases) { f in
                chip(f)
            }
            Spacer()
            Text("\(sortedRows.count) of \(model.infos.count)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(NS.text3)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(NS.bg1)
    }

    private func chip(_ f: InterfaceStatsModel.Filter) -> some View {
        let selected = model.filter == f
        return Button { model.filter = f } label: {
            Text(f.rawValue)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? NS.bg0 : NS.text2)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(selected ? NS.amber : NS.bg2))
        }
        .buttonStyle(.plain)
    }

    // MARK: Table

    private var table: some View {
        Table(sortedRows, selection: $selectedName, sortOrder: $sortOrder) {
            TableColumn("") { iface in
                HStack(spacing: 4) {
                    Circle()
                        .fill(iface.carrier == false ? NS.red : (iface.isUp ? NS.green : NS.text3))
                        .frame(width: 8, height: 8)
                    if model.activeRoute == iface.name {
                        Image(systemName: "arrow.up.forward.app.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(NS.amber)
                            .help("Carries the default route")
                    }
                }
            }
            .width(40)

            TableColumn("Interface", value: \.name) { iface in
                VStack(alignment: .leading, spacing: 1) {
                    Text(iface.name)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(NS.text1)
                    Text(iface.displayName)
                        .font(.system(size: 10))
                        .foregroundStyle(NS.text3)
                        .lineLimit(1)
                }
            }
            .width(min: 130, ideal: 160)

            TableColumn("Type") { iface in
                HStack(spacing: 4) {
                    Image(systemName: iface.mediaType.icon)
                        .font(.system(size: 10))
                        .foregroundStyle(NS.text3)
                    Text(iface.mediaType.rawValue)
                        .font(.system(size: 11))
                        .foregroundStyle(NS.text2)
                }
            }
            .width(110)

            TableColumn("MAC") { iface in
                Text(iface.macAddress)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(NS.text3)
                    .textSelection(.enabled)
            }
            .width(140)

            TableColumn("MTU", value: \.mtuSortable) { iface in
                Text(iface.mtu.map(String.init) ?? "—")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(NS.text2)
            }
            .width(60)

            TableColumn("Speed") { iface in
                Text(iface.linkSpeed ?? "—")
                    .font(.system(size: 11))
                    .foregroundStyle(NS.text2)
            }
            .width(90)

            TableColumn("RX bytes", value: \.totalRxBytes) { iface in
                Text(formatBytes(iface.totalRxBytes))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(NS.green)
            }
            .width(95)

            TableColumn("TX bytes", value: \.totalTxBytes) { iface in
                Text(formatBytes(iface.totalTxBytes))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(NS.blue)
            }
            .width(95)

            TableColumn("Errors") { iface in
                let total = iface.rxErrorCount + iface.txErrorCount
                Text(total == 0 ? "—" : "\(total)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(total == 0 ? NS.text3 : NS.red)
            }
            .width(60)

            TableColumn("Live (RX / TX)") { iface in
                let live = model.liveByName[iface.name]
                VStack(alignment: .leading, spacing: 1) {
                    liveRow(history: live?.rxHistory ?? [],
                            current: live?.rxBps ?? 0,
                            color: NS.green)
                    liveRow(history: live?.txHistory ?? [],
                            current: live?.txBps ?? 0,
                            color: NS.blue)
                }
            }
            .width(150)
        }
    }

    private func liveRow(history: [Double], current: Double, color: Color) -> some View {
        HStack(spacing: 6) {
            Sparkline(values: history, color: color)
                .frame(width: 60, height: 10)
            Text(model.isLive ? formatBps(current) : "—")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(model.isLive ? color : NS.text3)
                .lineLimit(1)
        }
    }

    // MARK: Detail pane

    /// Stable wrapper so HSplitView always sees the same view type on the
    /// right — selecting a row swaps the *inner* content, not the pane
    /// itself. Without this, SwiftUI re-allocates the split position each
    /// time you click a row and the detail pane balloons over the table.
    @ViewBuilder
    private var detailContainer: some View {
        Group {
            if let iface = selectedInterface {
                detailPane(iface)
            } else {
                EmptyStateView(title: "Select an interface",
                               systemImage: "chart.line.uptrend.xyaxis",
                               description: "Click a row to see traffic in detail.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NS.bg1)
    }

    @ViewBuilder
    private func detailPane(_ iface: InterfaceInfo) -> some View {
        let live = model.liveByName[iface.name]
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                detailHeader(iface)
                detailMetaCard(iface)
                detailTrafficCard(iface, live: live)
                detailChartCard(live: live)
            }
            .padding(14)
        }
        .background(NS.bg1)
    }

    private func detailHeader(_ iface: InterfaceInfo) -> some View {
        HStack(spacing: 10) {
            Image(systemName: iface.mediaType.icon)
                .font(.system(size: 22))
                .foregroundStyle(NS.amber)
                .frame(width: 34, height: 34)
                .background(NS.bg2)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(iface.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(NS.text1)
                Text("\(iface.mediaType.rawValue) · \(iface.isUp ? "up" : "down")")
                    .font(.system(size: 11))
                    .foregroundStyle(NS.text3)
            }
            Spacer()
            if model.activeRoute == iface.name {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.forward.app.fill").font(.system(size: 9))
                    Text("ACTIVE").font(.system(size: 9, weight: .bold)).tracking(0.5)
                }
                .foregroundStyle(NS.amber)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(NS.amber.opacity(0.10)))
            }
        }
    }

    private func detailMetaCard(_ iface: InterfaceInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Metadata")
            kv("MAC",     iface.macAddress)
            if let mtu = iface.mtu { kv("MTU",   "\(mtu)") }
            if let s = iface.linkSpeed {
                kv("Speed", iface.duplex.map { "\(s) · \($0)" } ?? s, mono: false)
            }
            if let c = iface.carrier {
                kv("Carrier", c ? "Active" : "No carrier", mono: false,
                   color: c ? NS.green : NS.red)
            }
            if !iface.ipv4Bindings.isEmpty {
                kv("IPv4",  iface.ipv4Bindings.map { $0.withCIDR }.joined(separator: ", "))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NS.bg2).cornerRadius(8)
    }

    private func detailTrafficCard(_ iface: InterfaceInfo, live: InterfaceStatsModel.LiveData?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Traffic since boot")
            HStack(spacing: 14) {
                trafficSide(label: "RX",
                            total: iface.totalRxBytes,
                            packets: iface.rxPackets,
                            errors: iface.rxErrorCount,
                            color: NS.green,
                            liveBps: live?.rxBps)
                Divider().frame(width: 0.5).background(NS.borderMid)
                trafficSide(label: "TX",
                            total: iface.totalTxBytes,
                            packets: iface.txPackets,
                            errors: iface.txErrorCount,
                            color: NS.blue,
                            liveBps: live?.txBps)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NS.bg2).cornerRadius(8)
    }

    private func trafficSide(label: String, total: UInt64, packets: UInt64,
                             errors: UInt32, color: Color, liveBps: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(label).font(.system(size: 10, weight: .bold)).foregroundStyle(color)
            }
            Text(formatBytes(total))
                .font(.system(size: 17, weight: .semibold, design: .monospaced))
                .foregroundStyle(NS.text1)
            Text("\(packets) packets")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(NS.text3)
            if errors > 0 {
                Text("\(errors) errors").font(.system(size: 10, design: .monospaced)).foregroundStyle(NS.red)
            }
            if let bps = liveBps, model.isLive {
                Text("live: \(formatBps(bps))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(color.opacity(0.85))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func detailChartCard(live: InterfaceStatsModel.LiveData?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Live throughput (60 s)")
            ZStack(alignment: .topLeading) {
                NS.bg0.cornerRadius(6)
                if let live = live, !live.rxHistory.isEmpty {
                    HStack(spacing: 0) {
                        Sparkline(values: live.rxHistory, color: NS.green)
                        Sparkline(values: live.txHistory, color: NS.blue)
                    }
                    .padding(8)
                } else {
                    Text("Press Live to start sampling.")
                        .font(.system(size: 11))
                        .foregroundStyle(NS.text3)
                        .padding(10)
                }
            }
            .frame(height: 110)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NS.bg2).cornerRadius(8)
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s.uppercased())
            .font(.system(size: 10, weight: .semibold)).tracking(0.5)
            .foregroundStyle(NS.text3)
    }

    private func kv(_ k: String, _ v: String, mono: Bool = true, color: Color = NS.text1) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).font(.system(size: 10)).foregroundStyle(NS.text3)
                .frame(width: 70, alignment: .leading)
            Text(v).font(.system(size: 11, design: mono ? .monospaced : .default))
                .foregroundStyle(color).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    // MARK: Formatting

    private func formatBytes(_ b: UInt64) -> String {
        let d = Double(b)
        if d < 1024 { return "\(b) B" }
        if d < 1024*1024 { return String(format: "%.1f KB", d/1024) }
        if d < 1024*1024*1024 { return String(format: "%.2f MB", d/1024/1024) }
        return String(format: "%.2f GB", d/1024/1024/1024)
    }

    private func formatBps(_ b: Double) -> String {
        if b < 1024 { return String(format: "%.0f B/s", b) }
        if b < 1024*1024 { return String(format: "%.1f KB/s", b/1024) }
        if b < 1024*1024*1024 { return String(format: "%.1f MB/s", b/1024/1024) }
        return String(format: "%.2f GB/s", b/1024/1024/1024)
    }

    // MARK: Export

    private func exportText() -> String {
        var out = "Interface Stats — \(model.lastRefresh?.formatted() ?? "n/a")\n"
        out += String(repeating: "—", count: 100) + "\n"
        for i in sortedRows {
            out += "[\(i.name)] \(i.displayName)  \(i.mediaType.rawValue)\n"
            out += "  MAC:    \(i.macAddress)   MTU: \(i.mtu.map(String.init) ?? "—")   Speed: \(i.linkSpeed ?? "—")\n"
            out += "  Status: \(i.isUp ? "up" : "down")\(i.carrier == false ? " (no carrier)" : "")\n"
            if !i.ipv4Bindings.isEmpty {
                out += "  IPv4:   \(i.ipv4Bindings.map { $0.withCIDR }.joined(separator: ", "))\n"
            }
            if let t = i.traffic {
                out += "  RX:     \(formatBytes(t.rxBytes))  /  \(t.rxPackets) pkt  /  \(t.rxErrors) err\n"
                out += "  TX:     \(formatBytes(t.txBytes))  /  \(t.txPackets) pkt  /  \(t.txErrors) err\n"
            }
        }
        return out
    }

    private func exportCSV() -> String {
        var out = "name,display_name,media_type,mac,mtu,speed,duplex,carrier,ipv4_count,is_up,rx_bytes,tx_bytes,rx_packets,tx_packets,rx_errors,tx_errors\n"
        for i in sortedRows {
            out += "\(i.name),\(i.displayName.replacingOccurrences(of: ",", with: " ")),\(i.mediaType.rawValue),\(i.macAddress),\(i.mtu.map(String.init) ?? ""),\(i.linkSpeed ?? ""),\(i.duplex ?? ""),\(i.carrier.map(String.init) ?? ""),\(i.ipv4Count),\(i.isUp),\(i.totalRxBytes),\(i.totalTxBytes),\(i.rxPackets),\(i.txPackets),\(i.rxErrorCount),\(i.txErrorCount)\n"
        }
        return out
    }

    private func exportJSON() -> String {
        let arr: [[String: Any]] = sortedRows.map { i in
            var d: [String: Any] = [
                "name": i.name,
                "display_name": i.displayName,
                "media_type": i.mediaType.rawValue,
                "mac": i.macAddress,
                "is_up": i.isUp,
                "ipv4": i.ipv4Bindings.map { ["ip": $0.ip, "cidr": $0.cidr] as [String: Any] },
                "ipv6": i.ipv6Bindings.map { ["ip": $0.ip, "scope": $0.scope] as [String: Any] },
            ]
            if let m = i.mtu        { d["mtu"] = m }
            if let s = i.linkSpeed  { d["link_speed"] = s }
            if let dup = i.duplex   { d["duplex"] = dup }
            if let c = i.carrier    { d["carrier"] = c }
            if let t = i.traffic {
                d["traffic"] = [
                    "rx_bytes": t.rxBytes, "tx_bytes": t.txBytes,
                    "rx_packets": t.rxPackets, "tx_packets": t.txPackets,
                    "rx_errors": t.rxErrors, "tx_errors": t.txErrors,
                ] as [String: Any]
            }
            return d
        }
        let payload: [String: Any] = [
            "tool": "Interface Stats",
            "exported_at": ISO8601DateFormatter().string(from: Date()),
            "active_route_interface": model.activeRoute as Any,
            "interfaces": arr,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}

// MARK: - Sparkline primitive

private struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let mx = max(values.max() ?? 1, 1)
            let n = values.count

            Path { p in
                guard n > 1 else { return }
                let xs = w / CGFloat(n - 1)
                for (i, v) in values.enumerated() {
                    let x = xs * CGFloat(i)
                    let y = h - (CGFloat(v / mx) * (h - 2)) - 1
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                    else      { p.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(color, lineWidth: 1)

            if n > 1 {
                // Soft area fill underneath for visual weight at small sizes
                Path { p in
                    let xs = w / CGFloat(n - 1)
                    p.move(to: CGPoint(x: 0, y: h))
                    for (i, v) in values.enumerated() {
                        let x = xs * CGFloat(i)
                        let y = h - (CGFloat(v / mx) * (h - 2)) - 1
                        p.addLine(to: CGPoint(x: x, y: y))
                    }
                    p.addLine(to: CGPoint(x: w, y: h))
                    p.closeSubpath()
                }
                .fill(color.opacity(0.15))
            }
        }
    }
}
