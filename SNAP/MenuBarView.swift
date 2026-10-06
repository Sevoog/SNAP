// MenuBarView.swift
// SNAP v1.2 — Live Menu Bar Monitor
// Created by Sevag Bardakjian

import SwiftUI
import AppKit
import Network
import Darwin
import CoreWLAN

// MARK: - Match the hosting NSWindow's appearance to the theme
// (The menu bar popover's window doesn't pick up the app-wide setting on
// its own; this used to force dark for every theme.)

private struct AppearanceEnforcer: NSViewRepresentable {
    let name: NSAppearance.Name
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        let name = self.name
        DispatchQueue.main.async { v.window?.appearance = NSAppearance(named: name) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.appearance = NSAppearance(named: name)
    }
}

// MARK: - Live bandwidth monitor (samples continuously in background)

final class MenuBarMonitor: ObservableObject {
    static let shared = MenuBarMonitor()

    @Published var rxRate: Double = 0
    @Published var txRate: Double = 0
    @Published var rxStr: String = "0 KB/s"
    @Published var txStr: String = "0 KB/s"
    @Published var peakRx: Double = 0
    @Published var peakTx: Double = 0
    @Published var rxHistory: [Double] = Array(repeating: 0, count: 30)
    @Published var txHistory: [Double] = Array(repeating: 0, count: 30)
    @Published var isOnline: Bool = true
    @Published var activeInterface: String = "en0"

    // Network health — derived from a periodic gateway ping (every 10 s),
    // judged over the whole history window by the shared `ConnectionHealth`
    // model, so the dot always matches the Gateway Latency tile.
    enum Health { case unknown, good, warn, bad, offline }
    @Published var health: Health = .unknown
    @Published var gatewayState: ConnectionHealth.GatewayState = .measuring
    @Published var gatewayLatencyMs: Double?
    // Rolling latency history for the Gateway Latency tile's sparkline +
    // min/max/avg/jitter/loss stats. Timeouts stored as nil so we can
    // compute loss %.
    @Published var latencyHistory: [Double?] = []
    static let latencyHistoryMax = 30

    private var timer: Timer?
    private var healthTimer: Timer?
    private var lastRx: UInt64 = 0
    private var lastTx: UInt64 = 0
    private var lastTime = Date()
    private var pathMonitor = NWPathMonitor()
    private let sampleQueue = DispatchQueue(label: "snap.menubar.sample", qos: .utility)
    private let healthQueue = DispatchQueue(label: "snap.menubar.health", qos: .utility)
    private var isSampling = false

    private init() {
        // Seed initial byte counts synchronously so the first timer tick
        // has valid prevRx/prevTx to delta against — avoids first sample being 0.
        // Use en0 as default; detectPrimaryInterface runs async to refine it.
        let initialIface = "en0"
        let (seedRx, seedTx) = MenuBarMonitor.readBytes(iface: initialIface)
        lastRx = seedRx
        lastTx = seedTx
        lastTime = Date()

        // Detect the real active interface in background and re-seed if different
        sampleQueue.async { [weak self] in
            let iface = MenuBarMonitor.detectPrimaryInterface()
            let (rx, tx) = MenuBarMonitor.readBytes(iface: iface)
            DispatchQueue.main.async {
                self?.activeInterface = iface
                // Re-seed with correct interface so delta is valid from next tick
                self?.lastRx = rx
                self?.lastTx = tx
                self?.lastTime = Date()
            }
        }

        // Timer on main runloop — .common fires even during menu tracking
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.sample()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        pathMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async { self?.isOnline = path.status == .satisfied }
        }
        pathMonitor.start(queue: .global())

        // Periodic gateway ping for the menu bar health dot.
        let ht = Timer(timeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.pingHealth()
        }
        RunLoop.main.add(ht, forMode: .common)
        healthTimer = ht
        // Kick off the first health check after a short delay so it doesn't
        // race the path monitor and the route lookup.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.pingHealth()
        }
    }

    // MARK: Health probe

    private func pingHealth() {
        guard isOnline else {
            self.health = .offline
            self.gatewayLatencyMs = nil
            return
        }
        healthQueue.async { [weak self] in
            guard let self else { return }
            guard let gw = RouteInfo.defaultGateway() else {
                DispatchQueue.main.async {
                    self.health = .unknown
                    self.gatewayLatencyMs = nil
                }
                return
            }
            let ms = Self.singlePing(host: gw)
            DispatchQueue.main.async {
                self.gatewayLatencyMs = ms
                // Roll the history buffer — nil samples represent timeouts and
                // are preserved (unlike Favorites history) so we can compute
                // loss % for the tile.
                self.latencyHistory.append(ms)
                if self.latencyHistory.count > Self.latencyHistoryMax {
                    self.latencyHistory.removeFirst(self.latencyHistory.count - Self.latencyHistoryMax)
                }
                // Judge the window, not this one ping. It used to be `ms < 40`
                // → green, and any single dropped ping → red.
                let s = self.latencyStats
                self.gatewayState = ConnectionHealth.gatewayState(
                    avgMs: s.avg, jitterMs: s.jitter, lossPct: s.lossPct,
                    samples: s.sampleCount, trailingTimeouts: s.trailingTimeouts)
                self.health = self.isOnline ? Self.dotHealth(self.gatewayState) : .offline
            }
        }
    }

    /// Aggregates of the latency history — used by the Gateway Latency and
    /// System Health tiles and the menu bar dot.
    struct LatencyStats {
        let min: Double?
        let avg: Double?
        let max: Double?
        let jitter: Double?
        let lossPct: Double  // 0…100
        let sampleCount: Int
        /// Timeouts in a row at the end of the history — the "down right
        /// now" signal (see `ConnectionHealth.outageTimeouts`).
        let trailingTimeouts: Int

        init(history all: [Double?]) {
            let hits = all.compactMap { $0 }
            sampleCount = all.count
            lossPct = all.isEmpty ? 0 : Double(all.count - hits.count) / Double(all.count) * 100
            trailingTimeouts = all.reversed().prefix { $0 == nil }.count
            guard !hits.isEmpty else {
                min = nil; avg = nil; max = nil; jitter = nil
                return
            }
            let mean = hits.reduce(0, +) / Double(hits.count)
            min = hits.min()
            max = hits.max()
            avg = mean
            // Mean absolute deviation as a light jitter proxy.
            jitter = hits.map { abs($0 - mean) }.reduce(0, +) / Double(hits.count)
        }
    }

    var latencyStats: LatencyStats { LatencyStats(history: latencyHistory) }

    /// Dot color bucket for a gateway state (offline is decided separately).
    static func dotHealth(_ state: ConnectionHealth.GatewayState) -> Health {
        switch state {
        case .measuring:               return .unknown
        case .healthy:                 return .good
        case .slow, .unstable:         return .warn
        case .degraded, .notResponding: return .bad
        }
    }

    /// Synchronous one-shot ping. Returns nil if no response.
    private static func singlePing(host: String) -> Double? {
        let p = Process()
        p.launchPath = "/sbin/ping"
        p.arguments = ["-c", "1", "-W", "1000", host]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8),
              let r = text.range(of: "time=") else { return nil }
        let tail = text[r.upperBound...]
        let token = tail.split(separator: " ").first ?? ""
        return Double(token)
    }

    private func sample() {
        guard !isSampling else { return }
        isSampling = true
        let iface   = activeInterface
        let prevRx  = lastRx
        let prevTx  = lastTx
        let prevTime = lastTime

        // Do the blocking netstat call off the main thread
        sampleQueue.async { [weak self] in
            let (rx, tx) = MenuBarMonitor.readBytes(iface: iface)
            let now = Date()
            let elapsed = now.timeIntervalSince(prevTime)
            guard elapsed > 0 else {
                DispatchQueue.main.async { self?.isSampling = false }
                return
            }
            let rxDelta = rx >= prevRx ? rx - prevRx : 0
            let txDelta = tx >= prevTx ? tx - prevTx : 0
            let rxR = Double(rxDelta) / elapsed
            let txR = Double(txDelta) / elapsed

            DispatchQueue.main.async {
                guard let s = self else { return }
                s.rxRate = rxR
                s.txRate = txR
                s.rxStr  = MenuBarMonitor.formatRate(rxR)
                s.txStr  = MenuBarMonitor.formatRate(txR)
                s.peakRx = Swift.max(s.peakRx, rxR)
                s.peakTx = Swift.max(s.peakTx, txR)
                s.rxHistory.removeFirst()
                s.rxHistory.append(rxR)
                s.txHistory.removeFirst()
                s.txHistory.append(txR)
                s.lastRx = rx
                s.lastTx = tx
                s.lastTime = now
                s.isSampling = false
            }
        }
    }

    static func readBytes(iface: String) -> (UInt64, UInt64) {
        // Use getifaddrs directly — same syscall macOS uses internally,
        // no process spawning, no string parsing, no column alignment issues.
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return (0, 0) }
        defer { freeifaddrs(ifaddr) }

        var ptr = ifaddr
        while let ifa = ptr {
            let name = String(cString: ifa.pointee.ifa_name)
            // AF_LINK gives us the link-layer data struct with byte counters
            if name == iface,
               let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_LINK),
               let data = ifa.pointee.ifa_data {
                let ifdata = data.assumingMemoryBound(to: if_data.self).pointee
                return (UInt64(ifdata.ifi_ibytes), UInt64(ifdata.ifi_obytes))
            }
            ptr = ifa.pointee.ifa_next
        }
        return (0, 0)
    }

    // Detect the interface carrying the most traffic using getifaddrs
    static func detectPrimaryInterface() -> String {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return "en0" }
        defer { freeifaddrs(ifaddr) }

        var best = "en0"
        var bestBytes: UInt64 = 0
        var ptr = ifaddr
        while let ifa = ptr {
            let name = String(cString: ifa.pointee.ifa_name)
            // Only consider en* interfaces (skip lo, utun, gif, stf, bridge)
            if name.hasPrefix("en"),
               let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_LINK),
               let data = ifa.pointee.ifa_data {
                let ifdata = data.assumingMemoryBound(to: if_data.self).pointee
                let total = UInt64(ifdata.ifi_ibytes) + UInt64(ifdata.ifi_obytes)
                if total > bestBytes { bestBytes = total; best = name }
            }
            ptr = ifa.pointee.ifa_next
        }
        return best
    }

    static func formatRate(_ bps: Double) -> String {
        if bps >= 1_000_000 { return String(format: "%.1f MB/s", bps / 1_000_000) }
        if bps >= 1_000     { return String(format: "%.0f KB/s", bps / 1_000) }
        return String(format: "%.0f B/s", Swift.max(0, bps))
    }

    func formatRate(_ bps: Double) -> String { MenuBarMonitor.formatRate(bps) }

    func formatPeak(_ bps: Double) -> String {
        bps == 0 ? "—" : formatRate(bps)
    }
}

// MARK: - Wi-Fi info helper

struct WiFiInfo {
    var ssid: String = "—"
    var rssi: Int = 0
    var channel: Int = 0
    var band: String = "—"
    var txRate: Double = 0
    var security: String = "—"

    static func current() -> WiFiInfo {
        guard let iface = CWWiFiClient.shared().interface() else { return WiFiInfo() }
        var info = WiFiInfo()
        info.ssid = iface.ssid() ?? "—"
        info.rssi = iface.rssiValue()
        if let ch = iface.wlanChannel() {
            info.channel = ch.channelNumber
            info.band = ch.channelBand == .band2GHz ? "2.4 GHz" : ch.channelBand == .band5GHz ? "5 GHz" : "6 GHz"
        }
        info.txRate = iface.transmitRate()
        // Map security type to short label
        switch iface.security() {
        case .wpa3Personal, .wpa3Enterprise: info.security = "WPA3"
        case .wpa2Personal, .wpa2Enterprise: info.security = "WPA2"
        case .wpaPersonal, .wpaEnterprise:   info.security = "WPA"
        case .dynamicWEP:                           info.security = "WEP"
        case .none:                          info.security = "Open"
        default:                             info.security = "—"
        }
        return info
    }
}

// MARK: - Network detail helper (gateway, DNS)

struct NetworkDetail {
    var gateway: String = "—"
    var dnsServers: [String] = []
    var vpnInterfaces: [(name: String, ip: String)] = []

    static func current() -> NetworkDetail {
        var d = NetworkDetail()

        // Gateway via SCDynamicStore (no `route` shell-out)
        if let gw = RouteInfo.defaultGateway() { d.gateway = gw }

        // DNS from /etc/resolv.conf
        if let resolv = try? String(contentsOfFile: "/etc/resolv.conf") {
            d.dnsServers = resolv.components(separatedBy: "\n")
                .filter { $0.hasPrefix("nameserver") }
                .compactMap { $0.components(separatedBy: " ").last }
        }

        // VPN tunnels (utun interfaces with assigned IPs)
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return d }
        defer { freeifaddrs(ifaddr) }
        var addr = ifaddr
        while let ifa = addr {
            let name = String(cString: ifa.pointee.ifa_name)
            if name.hasPrefix("utun"),
               let sa = ifa.pointee.ifa_addr, Int32(sa.pointee.sa_family) == AF_INET {
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
                let ip = String(cString: buf)
                if ip != "127.0.0.1" { d.vpnInterfaces.append((name: name, ip: ip)) }
            }
            addr = ifa.pointee.ifa_next
        }
        return d
    }
}

// MARK: - Main View

struct MenuBarView: View {
    @StateObject private var monitor = MenuBarMonitor.shared
    @ObservedObject private var themeMgr = ThemeManager.shared
    @State private var externalIP = "Loading…"
    @State private var interfaces: [(String, String)] = []
    @State private var wifiInfo = WiFiInfo()
    @State private var netDetail = NetworkDetail()
    @State private var isRefreshing = false
    @State private var quickHost = ""
    @State private var pingResult = ""
    @State private var dnsHost = ""
    @State private var dnsResult = ""
    @State private var wifiExpanded = true
    @State private var netExpanded = true
    @State private var vpnExpanded = true
    @State private var toolsExpanded = true

    // Computed so theme changes propagate (stored `let`s would freeze at init).
    private var bg0: Color { NS.bg0 }
    private var bg1: Color { NS.bg2 }
    private var bg2: Color { NS.bg3 }
    private var bg3: Color { NS.bg3.opacity(0.9) }

    /// Text and hairline color at a given strength: white on dark themes
    /// (the original design), black on Daylight. The backgrounds above
    /// already follow the theme, so the fixed white text this replaces
    /// vanished on Daylight's light surfaces.
    private func ink(_ alpha: Double) -> Color {
        themeMgr.current.isLight ? Color.black.opacity(alpha) : Color.white.opacity(alpha)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ratesRow
            sparklineRow
            if wifiInfo.ssid != "—" { wifiSection }
            networkSection
            if !netDetail.vpnInterfaces.isEmpty { vpnSection }
            quickToolsSection
            footer
        }
        .frame(width: 300)
        .background(bg0)
        .background(AppearanceEnforcer(name: themeMgr.current.appearanceName))
        .onAppear { refreshAll() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(NS.amber)
                    .frame(width: 26, height: 26)
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(red: 0.11, green: 0.11, blue: 0.11))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("SNAP").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ink(0.88))
                Text("Live Monitor").font(.system(size: 9))
                    .foregroundStyle(ink(0.3))
            }
            Spacer()
            HStack(spacing: 4) {
                Circle().fill(monitor.isOnline ? NS.green : NS.red)
                    .frame(width: 5, height: 5)
                Text(monitor.isOnline ? "Online" : "Offline")
                    .font(.system(size: 9))
                    .foregroundStyle(monitor.isOnline ? NS.green : NS.red)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(bg2)
    }

    // MARK: - Live rates

    private var ratesRow: some View {
        HStack(spacing: 0) {
            rateCell(label: "DOWNLOAD", value: monitor.rxStr,
                     peak: monitor.formatPeak(monitor.peakRx), color: NS.green)
            Divider().background(ink(0.05))
            rateCell(label: "UPLOAD", value: monitor.txStr,
                     peak: monitor.formatPeak(monitor.peakTx), color: NS.blue)
        }
        .background(bg1)
        .overlay(alignment: .bottom) {
            Rectangle().fill(ink(0.06)).frame(height: 0.5)
        }
    }

    private func rateCell(label: String, value: String, peak: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(ink(0.25))
            Text(value)
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .foregroundStyle(color)
            Text("peak \(peak)")
                .font(.system(size: 8))
                .foregroundStyle(ink(0.2))
        }
        .padding(.horizontal, 13).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Sparkline

    private var sparklineRow: some View {
        VStack(spacing: 0) {
            sparkBar(history: monitor.rxHistory, color: NS.green,
                     label: "↓ RX", rateStr: monitor.rxStr, isTop: true)
            Rectangle().fill(ink(0.04)).frame(height: 0.5)
            sparkBar(history: monitor.txHistory, color: NS.blue,
                     label: "↑ TX", rateStr: monitor.txStr, isTop: false)
        }
        .background(bg1)
        .overlay(alignment: .bottom) {
            Rectangle().fill(ink(0.06)).frame(height: 0.5)
        }
    }

    private func sparkBar(history: [Double], color: Color,
                           label: String, rateStr: String, isTop: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(ink(0.25))
                Text(rateStr)
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(color.opacity(0.8))
                Spacer()
                Text(isTop ? "\(monitor.activeInterface) · 2s" : "last 30 samples")
                    .font(.system(size: 8))
                    .foregroundStyle(ink(0.15))
            }
            GeometryReader { geo in
                let peakVal = Swift.max(1.0, history.max() ?? 1.0)
                let totalSpacing: CGFloat = 29 * 2
                let barW = (geo.size.width - totalSpacing) / 30
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(Array(history.enumerated()), id: \.offset) { i, v in
                        let ratio = CGFloat(v / peakVal)
                        let h: CGFloat = v > 0 ? Swift.max(3, ratio * 20) : 2
                        RoundedRectangle(cornerRadius: 1)
                            .fill(color.opacity(i == 29 ? 1.0 : (v > 0 ? 0.6 : 0.15)))
                            .frame(width: Swift.max(1, barW), height: h)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .frame(height: 22)
        }
        .padding(.horizontal, 13)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }

    // MARK: - Wi-Fi section

    private var wifiSection: some View {
        VStack(spacing: 0) {
            sectionHeader(
                label: "Wi-Fi",
                badge: wifiInfo.ssid != "—" ? "Connected" : nil,
                badgeColor: NS.green,
                trailing: "ch \(wifiInfo.channel) · \(wifiInfo.band)",
                expanded: $wifiExpanded
            )
            if wifiExpanded {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(wifiInfo.ssid)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(ink(0.85))
                        Spacer()
                        signalBars(rssi: wifiInfo.rssi)
                        Text(wifiInfo.security)
                            .font(.system(size: 8)).padding(.horizontal, 5).padding(.vertical, 2)
                            .background(NS.green.opacity(0.15)).cornerRadius(3)
                            .foregroundStyle(NS.green)
                    }
                    HStack(spacing: 16) {
                        infoCell(label: "RSSI", value: "\(wifiInfo.rssi) dBm",
                                 color: wifiInfo.rssi > -60 ? NS.green : wifiInfo.rssi > -75 ? NS.amber : NS.red)
                        infoCell(label: "TX RATE", value: "\(Int(wifiInfo.txRate)) Mbps",
                                 color: ink(0.75))
                    }
                }
                .padding(.horizontal, 13).padding(.vertical, 8)
                .background(bg0)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(ink(0.06)).frame(height: 0.5)
                }
            }
        }
    }

    // MARK: - Network section

    private var networkSection: some View {
        VStack(spacing: 0) {
            sectionHeader(label: "Network", badge: nil, badgeColor: .clear,
                          trailing: nil, expanded: $netExpanded)
            if netExpanded {
                VStack(spacing: 3) {
                    ForEach(interfaces, id: \.0) { (name, ip) in
                        netRow(icon: "antenna.radiowaves.left.and.right",
                               label: name == "en0" ? "Local (\(name))" : name,
                               value: ip, copyable: true)
                    }
                    netRow(icon: "globe", label: "External IP",
                           value: externalIP, copyable: true)
                    if netDetail.gateway != "—" {
                        netRow(icon: "arrow.triangle.swap", label: "Gateway",
                               value: netDetail.gateway, copyable: true)
                    }
                    if !netDetail.dnsServers.isEmpty {
                        netRow(icon: "person.crop.circle",
                               label: "DNS",
                               value: netDetail.dnsServers.prefix(2).joined(separator: ", "),
                               copyable: false)
                    }
                }
                .padding(.horizontal, 13).padding(.vertical, 8)
                .background(bg0)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(ink(0.06)).frame(height: 0.5)
                }
            }
        }
    }

    // MARK: - VPN section

    private var vpnSection: some View {
        VStack(spacing: 0) {
            sectionHeader(
                label: "VPN / Tunnels",
                badge: "\(netDetail.vpnInterfaces.count) active",
                badgeColor: NS.amber,
                trailing: nil,
                expanded: $vpnExpanded
            )
            if vpnExpanded {
                VStack(spacing: 5) {
                    ForEach(netDetail.vpnInterfaces, id: \.name) { vpn in
                        HStack(spacing: 7) {
                            Circle().fill(NS.amber).frame(width: 5, height: 5)
                            Text(vpn.name)
                                .font(.system(size: 10))
                                .foregroundStyle(ink(0.7))
                            Spacer()
                            Text(vpn.ip)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(ink(0.5))
                            Text("Active")
                                .font(.system(size: 8)).padding(.horizontal, 5).padding(.vertical, 2)
                                .background(NS.amber.opacity(0.12)).cornerRadius(3)
                                .foregroundStyle(NS.amber)
                        }
                    }
                }
                .padding(.horizontal, 13).padding(.vertical, 8)
                .background(bg0)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(ink(0.06)).frame(height: 0.5)
                }
            }
        }
    }

    // MARK: - Quick Tools section

    private var quickToolsSection: some View {
        VStack(spacing: 0) {
            sectionHeader(label: "Quick Tools", badge: nil, badgeColor: .clear,
                          trailing: nil, expanded: $toolsExpanded)
            if toolsExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    // Ping
                    toolLabel("PING")
                    HStack(spacing: 6) {
                        TextField("Host or IP", text: $quickHost)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(ink(0.75))
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(ink(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(ink(0.1), lineWidth: 0.5))
                        Button("Ping") { quickPing() }
                            .font(.system(size: 11))
                            .buttonStyle(.plain)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(ink(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(ink(0.12), lineWidth: 0.5))
                            .foregroundStyle(ink(0.65))
                            .disabled(quickHost.isEmpty)
                    }
                    if !pingResult.isEmpty {
                        Text(pingResult)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(pingResult.contains("ms") ? NS.green : NS.red)
                    }

                    // DNS
                    toolLabel("DNS LOOKUP")
                    HStack(spacing: 6) {
                        TextField("Domain", text: $dnsHost)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(ink(0.75))
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(ink(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(ink(0.1), lineWidth: 0.5))
                        Button("Look up") { quickDNS() }
                            .font(.system(size: 11))
                            .buttonStyle(.plain)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(ink(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(ink(0.12), lineWidth: 0.5))
                            .foregroundStyle(ink(0.65))
                            .disabled(dnsHost.isEmpty)
                    }
                    if !dnsResult.isEmpty {
                        Text(dnsResult)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(ink(0.5))
                            .lineLimit(3)
                    }
                }
                .padding(.horizontal, 13).padding(.vertical, 8)
                .background(bg0)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(ink(0.06)).frame(height: 0.5)
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button {
                NSWorkspace.shared.openApplication(
                    at: Bundle.main.bundleURL,
                    configuration: NSWorkspace.OpenConfiguration()
                )
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "network").font(.system(size: 10))
                    Text("Open SNAP").font(.system(size: 10))
                }
                .foregroundStyle(NS.blue)
            }
            .buttonStyle(.plain)

            Spacer()
            Text("v\(AppInfo.version)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(ink(0.18))
            Button { refreshAll() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundStyle(ink(isRefreshing ? 0.2 : 0.3))
            }
            .buttonStyle(.plain)
            .disabled(isRefreshing)
        }
        .padding(.horizontal, 13).padding(.vertical, 8)
        .background(bg2)
    }

    // MARK: - Reusable sub-views

    private func sectionHeader(label: String, badge: String?, badgeColor: Color,
                                trailing: String?, expanded: Binding<Bool>) -> some View {
        Button { withAnimation(.easeInOut(duration: 0.15)) { expanded.wrappedValue.toggle() } } label: {
            HStack(spacing: 6) {
                Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(ink(0.2))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ink(0.4))
                if let badge = badge {
                    Text(badge)
                        .font(.system(size: 8)).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(badgeColor.opacity(0.15)).cornerRadius(3)
                        .foregroundStyle(badgeColor)
                }
                Spacer()
                if let trailing = trailing {
                    Text(trailing)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(ink(0.2))
                }
            }
            .padding(.horizontal, 13).padding(.vertical, 7)
            .background(bg2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            Rectangle().fill(ink(0.06)).frame(height: 0.5)
        }
    }

    private func netRow(icon: String, label: String, value: String, copyable: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 10)).foregroundStyle(NS.blue).frame(width: 12)
            Text(label)
                .font(.system(size: 10)).foregroundStyle(ink(0.28))
                .frame(width: 76, alignment: .leading)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(ink(0.75))
                .textSelection(.enabled)
                .lineLimit(1)
            Spacer()
            if copyable {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 9)).foregroundStyle(ink(0.25))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
    }

    private func infoCell(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 8)).foregroundStyle(ink(0.22))
            Text(value).font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(color)
        }
    }

    private func signalBars(rssi: Int) -> some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach([4,7,10,13], id: \.self) { h in
                let active = rssi > -90 && (h == 4 || (rssi > -75 && h == 7) ||
                             (rssi > -65 && h == 10) || (rssi > -55 && h == 13))
                RoundedRectangle(cornerRadius: 1)
                    .fill(active ? NS.green : ink(0.15))
                    .frame(width: 3, height: CGFloat(h))
            }
        }
    }

    private func toolLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8, design: .monospaced))
            .foregroundStyle(ink(0.22))
    }

    // MARK: - Actions

    private func quickPing() {
        guard !quickHost.isEmpty else { return }
        pingResult = "Pinging…"
        Task {
            let out = await Shell.run("/sbin/ping", args: ["-c", "3", "-t", "5", quickHost])
            await MainActor.run {
                if let r = out.range(of: "min/avg/max"),
                   let eq = out[r.upperBound...].range(of: "=") {
                    let nums = String(out[eq.upperBound...]).trimmingCharacters(in: .whitespaces)
                    let parts = nums.components(separatedBy: "/")
                    if parts.count >= 2 {
                        pingResult = "avg \(parts[1].trimmingCharacters(in: .whitespaces)) ms · 0% loss"
                        return
                    }
                }
                pingResult = out.contains("100.0% packet loss") ? "No response (100% loss)" : "Failed"
            }
        }
    }

    private func quickDNS() {
        guard !dnsHost.isEmpty else { return }
        dnsResult = "Resolving…"
        Task {
            guard let url = URL(string: "https://1.1.1.1/dns-query?name=\(dnsHost)&type=A") else { return }
            var req = URLRequest(url: url)
            req.setValue("application/dns-json", forHTTPHeaderField: "Accept")
            if let (data, _) = try? await URLSession.shared.data(for: req),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let answers = json["Answer"] as? [[String: Any]] {
                let ips = answers.compactMap { $0["data"] as? String }
                await MainActor.run {
                    dnsResult = ips.isEmpty ? "No A records found" : ips.prefix(3).joined(separator: "\n")
                }
            } else {
                await MainActor.run { dnsResult = "Lookup failed" }
            }
        }
    }

    private func refreshAll() {
        isRefreshing = true
        wifiInfo = WiFiInfo.current()
        netDetail = NetworkDetail.current()
        loadLocalIPs()
        Task {
            await fetchExternalIP()
            await MainActor.run { isRefreshing = false }
        }
    }

    private func loadLocalIPs() {
        var ifaces: [(String, String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return }
        defer { freeifaddrs(ifaddr) }
        var addr = ifaddr
        while let ifa = addr {
            let name = String(cString: ifa.pointee.ifa_name)
            if let sa = ifa.pointee.ifa_addr,
               Int32(sa.pointee.sa_family) == AF_INET, name.hasPrefix("en") {
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
                let ip = String(cString: buf)
                if ip != "127.0.0.1" { ifaces.append((name, ip)) }
            }
            addr = ifa.pointee.ifa_next
        }
        interfaces = ifaces
    }

    @MainActor
    private func fetchExternalIP() async {
        guard let url = URL(string: "https://api.ipify.org") else { return }
        if let (data, _) = try? await URLSession.shared.data(from: url) {
            externalIP = String(data: data, encoding: .utf8) ?? "Unavailable"
        } else {
            externalIP = "Unavailable"
        }
    }
}

#Preview { MenuBarView() }
