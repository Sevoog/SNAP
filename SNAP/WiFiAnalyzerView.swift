// WiFiAnalyzerView.swift
// SNAP — WiFi Analyzer (v1.4.2 revamp)
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md
//
// A professional, root-free WiFi analyzer modeled on WiFi Explorer: Scanner
// (the sandboxed App Store build) — i.e. everything achievable through public
// CoreWLAN, no privileged helper, no raw 802.11 frame capture.
//
// Layout: a sortable networks table on top, a tabbed graph panel below
// (Network Details / Signal Strength / 2.4 GHz / 5 GHz / 6 GHz / Channels),
// with a persistent color-coding that ties every view together.
//
// CoreWLAN honesty notes (what we can and can't read for *scanned* APs):
//   • Available: SSID, BSSID, RSSI, noise/SNR, channel, width, band,
//     security (incl. WPA3 / Enterprise), supported PHY modes → mode +
//     generation, country code, beacon interval.
//   • NOT available without raw IE access: max PHY rate, spatial streams,
//     channel utilization, PMF flag. We infer PMF from WPA3 and omit the
//     rest. 802.11be (Wi-Fi 7) isn't reported by current public CoreWLAN,
//     so the ceiling is Wi-Fi 6 / 6E.

import SwiftUI
import CoreWLAN

// MARK: - Band

enum WiFiBand: Int, CaseIterable {
    case twoGHz = 0, fiveGHz, sixGHz, unknown

    var label: String {
        switch self {
        case .twoGHz: return "2.4 GHz"
        case .fiveGHz: return "5 GHz"
        case .sixGHz: return "6 GHz"
        case .unknown: return "—"
        }
    }
    var shortLabel: String {
        switch self {
        case .twoGHz: return "2.4"
        case .fiveGHz: return "5"
        case .sixGHz: return "6"
        case .unknown: return "?"
        }
    }
    /// Channel center frequency in MHz.
    func centerFreq(_ ch: Int) -> Int {
        switch self {
        case .twoGHz: return 2412 + (ch - 1) * 5
        case .fiveGHz: return 5000 + ch * 5
        case .sixGHz: return 5950 + ch * 5
        case .unknown: return 0
        }
    }
    static func from(_ b: CWChannelBand) -> WiFiBand {
        switch b {
        case .band2GHz: return .twoGHz
        case .band5GHz: return .fiveGHz
        default: return b.rawValue == 3 ? .sixGHz : .unknown
        }
    }
}

// MARK: - Network model

struct WiFiNetwork: Identifiable, Hashable {
    /// Stable identity. BSSID when present; falls back to SSID+band+channel
    /// for hidden APs that don't report one. Must be unique per row — a
    /// duplicate id corrupts ForEach / LazyVStack layout.
    var id: String { (bssid.isEmpty || bssid == "—") ? "\(ssid)|\(band.rawValue)|\(channel)" : bssid }
    var ssid: String
    var bssid: String
    var vendor: String
    var rssi: Int
    var noise: Int
    var channel: Int
    var band: WiFiBand
    var widthMHz: Int
    var security: String
    var isEnterprise: Bool
    var pmf: Bool
    var generation: String      // "Wi-Fi 6E" etc.
    var modeString: String      // "a/n/ac/ax"
    var countryCode: String
    var beacon: Int
    var isConnected: Bool
    var colorIndex: Int
    var lastSeen: Date

    var snr: Int { rssi - noise }
    var centerFreq: Int { band.centerFreq(channel) }
    var color: Color { WiFiPalette.color(colorIndex) }

    /// Warning flags surfaced in the table + status bar.
    var flags: [(String, Color)] {
        var f: [(String, Color)] = []
        if security == "Open" || security.hasPrefix("WEP") { f.append(("Not secure", NS.red)) }
        if band == .twoGHz && widthMHz >= 40 { f.append(("40 MHz/2.4", NS.amber)) }
        return f
    }
}

enum WiFiPalette {
    static let colors: [Color] = [
        NS.amber, NS.blue,
        NS.green, Color(red: 0.749, green: 0.353, blue: 0.949),
        NS.red, Color(red: 0.392, green: 0.823, blue: 1.0),
        Color(red: 1.0, green: 0.839, blue: 0.039), Color(red: 1.0, green: 0.392, blue: 0.51),
        Color(red: 0.369, green: 0.361, blue: 0.902), Color(red: 0.675, green: 0.557, blue: 0.408),
        Color(red: 0.196, green: 0.843, blue: 0.294), Color(red: 0.4, green: 0.831, blue: 0.812),
    ]
    static func color(_ i: Int) -> Color { colors[((i % colors.count) + colors.count) % colors.count] }
}

func rssiColor(_ r: Int) -> Color { r >= -55 ? NS.green : (r >= -70 ? NS.amber : NS.red) }

// MARK: - Model

@MainActor
final class WiFiAnalyzerModel: ObservableObject {
    @Published var networks: [WiFiNetwork] = []
    @Published var connected: WiFiNetwork?
    @Published var isScanning = false
    @Published var error = ""
    @Published var liveOn = false
    @Published var lastScan: Date?

    /// Per-BSSID RSSI history (most recent last), capped.
    @Published var rssiHistory: [String: [Double]] = [:]
    private let historyCap = 60

    private var colorMap: [String: Int] = [:]
    private var nextColor = 0
    private var liveTimer: Timer?

    deinit {
        // The run loop retains a repeating Timer — without this it keeps
        // firing (as no-ops) after the model is gone
        liveTimer?.invalidate()
    }

    func stopLive() {
        liveTimer?.invalidate(); liveTimer = nil
        liveOn = false
    }

    /// Pause Live while the tab is in the background, without switching it
    /// off. Each scan briefly takes the Wi-Fi radio off-channel, which would
    /// skew a ping or speed test running in another tab.
    func suspendLive() {
        liveTimer?.invalidate(); liveTimer = nil
    }

    /// Resume Live on return, if it was on.
    func resumeLive() {
        guard liveOn, liveTimer == nil else { return }
        liveTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
        scan()
    }

    func scan() {
        isScanning = true
        error = ""
        // Resolve and use the CWInterface entirely inside the background block.
        // `scanForNetworks` is designed to be called off the main thread, and
        // keeping the (non-Sendable) interface local avoids capturing it across
        // the concurrency boundary or round-tripping through `main.sync`.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            guard let iface = CWWiFiClient.shared().interface() else {
                DispatchQueue.main.async { self.error = "No WiFi interface found"; self.isScanning = false }
                return
            }
            do {
                let results = try iface.scanForNetworks(withSSID: nil)
                let connSSID = iface.ssid()
                let parsed = results.compactMap { Self.parse($0, connectedSSID: connSSID) }
                DispatchQueue.main.async { self.apply(parsed) }
            } catch {
                DispatchQueue.main.async { self.handle(error); self.isScanning = false }
            }
        }
    }

    func toggleLive() {
        liveOn.toggle()
        liveTimer?.invalidate(); liveTimer = nil
        if liveOn {
            // macOS throttles scanForNetworks; ~5s is throttle-safe.
            liveTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.scan() }
            }
            scan()
        }
    }

    private func apply(_ parsed: [WiFiNetwork]) {
        // Dedup by identity (CoreWLAN can return duplicate sightings), keeping
        // the strongest. Duplicate ForEach ids otherwise corrupt the layout.
        var unique: [String: WiFiNetwork] = [:]
        for n in parsed {
            if let e = unique[n.id], e.rssi >= n.rssi { continue }
            unique[n.id] = n
        }
        // Assign / reuse a stable color per identity.
        var list = unique.values.map { net -> WiFiNetwork in
            var n = net
            if let c = colorMap[n.id] { n.colorIndex = c }
            else { colorMap[n.id] = nextColor; n.colorIndex = nextColor; nextColor += 1 }
            return n
        }
        // Append to RSSI history (keyed by identity).
        for n in list {
            var h = rssiHistory[n.id] ?? []
            h.append(Double(n.rssi))
            if h.count > historyCap { h.removeFirst(h.count - historyCap) }
            rssiHistory[n.id] = h
        }
        list.sort { $0.rssi > $1.rssi }
        networks = list
        connected = list.first(where: { $0.isConnected })
        lastScan = Date()
        isScanning = false
        if list.isEmpty {
            error = "No networks found. Check System Settings → Privacy & Security → Location Services → SNAP"
        }
    }

    private func handle(_ error: Error) {
        let m = error.localizedDescription
        if m.contains("not authorized") || m.contains("denied") || m.contains("-3") {
            self.error = "Location Services denied. Enable in System Settings → Privacy & Security → Location Services → SNAP"
        } else if m.contains("not supported") || m.contains("-4") {
            self.error = "WiFi scanning not supported on this Mac"
        } else if m.contains("power") || m.contains("off") {
            self.error = "WiFi is turned off — enable it first"
        } else {
            self.error = "Scan error: \(m)"
        }
    }

    // MARK: Parse one CWNetwork

    nonisolated private static func parse(_ n: CWNetwork, connectedSSID: String?) -> WiFiNetwork? {
        guard let ssid = n.ssid, let ch = n.wlanChannel else {
            // Hidden network or no channel — still record if we have a BSSID.
            guard let bssid = n.bssid else { return nil }
            return WiFiNetwork(ssid: "(hidden)", bssid: bssid, vendor: OUIDatabase.lookup(bssid) ?? "—",
                               rssi: n.rssiValue, noise: n.noiseMeasurement, channel: 0, band: .unknown,
                               widthMHz: 20, security: "—", isEnterprise: false, pmf: false,
                               generation: "—", modeString: "—", countryCode: n.countryCode ?? "",
                               beacon: n.beaconInterval, isConnected: false, colorIndex: 0, lastSeen: Date())
        }
        let band = WiFiBand.from(ch.channelBand)
        let width: Int = {
            switch ch.channelWidth {
            case .width20MHz: return 20
            case .width40MHz: return 40
            case .width80MHz: return 80
            case .width160MHz: return 160
            default: return 20
            }
        }()
        let (sec, ent) = security(n)
        let bssid = n.bssid ?? "—"
        return WiFiNetwork(
            ssid: ssid, bssid: bssid,
            vendor: OUIDatabase.lookup(bssid) ?? "—",
            rssi: n.rssiValue, noise: n.noiseMeasurement,
            channel: ch.channelNumber, band: band, widthMHz: width,
            security: sec, isEnterprise: ent, pmf: sec.hasPrefix("WPA3"),
            generation: generation(n, band: band), modeString: modeString(n),
            countryCode: n.countryCode ?? "", beacon: n.beaconInterval,
            isConnected: ssid == connectedSSID, colorIndex: 0, lastSeen: Date())
    }

    nonisolated private static func security(_ n: CWNetwork) -> (String, Bool) {
        if n.supportsSecurity(.wpa3Enterprise) { return ("WPA3-Ent", true) }
        if n.supportsSecurity(.wpa3Personal)   { return ("WPA3 (SAE)", false) }
        if n.supportsSecurity(.wpa2Enterprise) { return ("WPA2-Ent", true) }
        if n.supportsSecurity(.wpa2Personal)   { return ("WPA2 (PSK)", false) }
        if n.supportsSecurity(.wpaPersonal)    { return ("WPA", false) }
        if n.supportsSecurity(.dynamicWEP) { return ("WEP", false) }
        return ("Open", false)
    }

    nonisolated private static func modeString(_ n: CWNetwork) -> String {
        var m: [String] = []
        if n.supportsPHYMode(.mode11a) { m.append("a") }
        if n.supportsPHYMode(.mode11b) { m.append("b") }
        if n.supportsPHYMode(.mode11g) { m.append("g") }
        if n.supportsPHYMode(.mode11n) { m.append("n") }
        if n.supportsPHYMode(.mode11ac) { m.append("ac") }
        if n.supportsPHYMode(.mode11ax) { m.append("ax") }
        return m.isEmpty ? "—" : m.joined(separator: "/")
    }

    nonisolated private static func generation(_ n: CWNetwork, band: WiFiBand) -> String {
        if n.supportsPHYMode(.mode11ax) { return band == .sixGHz ? "Wi-Fi 6E" : "Wi-Fi 6" }
        if n.supportsPHYMode(.mode11ac) { return "Wi-Fi 5" }
        if n.supportsPHYMode(.mode11n)  { return "Wi-Fi 4" }
        return "Legacy"
    }

    // MARK: Export

    func exportText() -> String {
        var s = "WiFi scan — \(networks.count) networks"
        if let t = lastScan { s += " · \(t.formatted())" }
        s += "\n\nNetwork\tBSSID\tVendor\tRSSI\tBand\tCh\tWidth\tMode\tGen\tSecurity\tCC\n"
        for n in networks {
            s += "\(n.ssid)\t\(n.bssid)\t\(n.vendor)\t\(n.rssi)\t\(n.band.shortLabel)G\t\(n.channel)\t\(n.widthMHz)MHz\t802.11\(n.modeString)\t\(n.generation)\t\(n.security)\t\(n.countryCode)\n"
        }
        return s
    }
    func exportCSV() -> String {
        var s = "network,bssid,vendor,rssi_dbm,band_ghz,channel,width_mhz,mode,generation,security,pmf,country,noise_dbm,snr_db\n"
        for n in networks {
            let cells = [n.ssid, n.bssid, n.vendor, "\(n.rssi)", n.band.shortLabel, "\(n.channel)",
                         "\(n.widthMHz)", "802.11\(n.modeString)", n.generation, n.security,
                         n.pmf ? "yes" : "no", n.countryCode, "\(n.noise)", "\(n.snr)"]
            s += cells.map(csvEscape).joined(separator: ",") + "\n"
        }
        return s
    }
    func exportJSON() -> String {
        let items = networks.map { n -> [String: Any] in
            ["ssid": n.ssid, "bssid": n.bssid, "vendor": n.vendor, "rssi": n.rssi,
             "band": n.band.label, "channel": n.channel, "width_mhz": n.widthMHz,
             "mode": "802.11\(n.modeString)", "generation": n.generation,
             "security": n.security, "pmf": n.pmf, "country": n.countryCode,
             "noise": n.noise, "snr": n.snr]
        }
        let payload: [String: Any] = ["captured_at": ISO8601DateFormatter().string(from: Date()),
                                      "networks": items]
        guard let d = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: d, encoding: .utf8) else { return "{}" }
        return str
    }
}

// MARK: - Sort + tabs

enum WiFiTab: String, CaseIterable, Identifiable {
    case details = "Network Details", signal = "Signal Strength"
    case b24 = "2.4 GHz", b5 = "5 GHz", b6 = "6 GHz", channels = "Channels"
    var id: String { rawValue }
}

// MARK: - Root view

struct WiFiAnalyzerView: View {
    @StateObject private var model = WiFiAnalyzerModel()
    @State private var selectedID: String?
    @State private var bandFilter: WiFiBand?          // nil = all
    @State private var search = ""
    @State private var sortOrder: [KeyPathComparator<WiFiNetwork>] = [KeyPathComparator(\.rssi, order: .reverse)]
    @State private var tab: WiFiTab = .details
    @State private var bottomHeight: CGFloat = 300
    @State private var dragStartHeight: CGFloat?

    private var selected: WiFiNetwork? {
        model.networks.first { $0.id == selectedID } ?? model.connected ?? model.networks.first
    }

    private var visible: [WiFiNetwork] {
        var a = model.networks
        if let b = bandFilter { a = a.filter { $0.band == b } }
        if !search.isEmpty {
            a = a.filter { ($0.ssid + $0.bssid + $0.vendor).localizedCaseInsensitiveContains(search) }
        }
        return a.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if !model.error.isEmpty { errorBanner }
            if let c = model.connected { connectedBanner(c) }
            WiFiTableView(networks: visible, selectedID: $selectedID, sortOrder: $sortOrder)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            resizeDivider
            bottomPanel
                .frame(height: bottomHeight)
            statusBar
        }
        .tabNavigationTitle(.wifi)
        // Tabs stay alive in the background now: pause the 5 s live radio
        // scan while hidden (each scan disturbs Wi-Fi for every other tool)
        // and resume it on return. A real teardown still stops it.
        .onDisappear { model.stopLive() }
        .onTabVisibilityChange(shown: { model.resumeLive() },
                               hidden: { model.suspendLive() })
        .onAppear { if model.networks.isEmpty { model.scan() } }
        .onReceive(NotificationCenter.default.publisher(for: .locationPermissionChanged)) { _ in model.scan() }
    }

    // MARK: Toolbar

    // One row when there's room; narrow windows move the filter field and
    // band picker to a second row so Live / Scan never clip.
    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                toolbarTitle
                Spacer()
                searchField.frame(width: 160)
                bandPicker
                toolbarActions
            }
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    toolbarTitle
                    Spacer()
                    toolbarActions
                }
                HStack(spacing: 10) {
                    searchField.frame(minWidth: 120, maxWidth: .infinity)
                    bandPicker
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(NS.bg0)
    }

    private var toolbarTitle: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi").foregroundStyle(NS.blue)
            Text("WiFi Analyzer").font(.system(size: 13, weight: .semibold)).foregroundStyle(NS.text1)
                .fixedSize()
        }
    }

    private var searchField: some View {
        TextField("Filter networks…", text: $search).textFieldStyle(.roundedBorder)
    }

    private var bandPicker: some View {
        Picker("", selection: $bandFilter) {
            Text("All").tag(WiFiBand?.none)
            Text("2.4").tag(WiFiBand?.some(.twoGHz))
            Text("5").tag(WiFiBand?.some(.fiveGHz))
            Text("6").tag(WiFiBand?.some(.sixGHz))
        }
        .pickerStyle(.segmented).frame(width: 180)
    }

    private var toolbarActions: some View {
        HStack(spacing: 10) {
            ToolActionBar("WiFi", text: { model.exportText() },
                          csv: { model.exportCSV() }, json: { model.exportJSON() })
                .fixedSize()
            Button(action: { model.toggleLive() }) {
                HStack(spacing: 5) {
                    Circle().fill(model.liveOn ? NS.green : NS.text4).frame(width: 7, height: 7)
                    Text("Live")
                }
            }
            .buttonStyle(.bordered)
            .tint(model.liveOn ? .green : nil)
            .fixedSize()
            // The hidden Scan keeps its width reserved while the spinner
            // shows, so the toolbar doesn't shift (or re-wrap) every scan.
            ZStack {
                Button("Scan") {}.buttonStyle(.borderedProminent).hidden().accessibilityHidden(true)
                if model.isScanning { ProgressView().controlSize(.small) }
                else {
                    Button("Scan") { model.scan() }.buttonStyle(.borderedProminent).keyboardShortcut(.return)
                }
            }
            .fixedSize()
        }
    }

    private var errorBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(model.error).foregroundStyle(.orange).font(.system(size: 12, weight: .semibold))
            Spacer()
            Button("Open Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
            }.font(.caption).buttonStyle(.bordered)
        }
        .padding(10).background(Color.orange.opacity(0.08))
    }

    private func connectedBanner(_ c: WiFiNetwork) -> some View {
        let dot = Circle().fill(NS.green).frame(width: 8, height: 8)
        let name = Text("Connected: \(c.ssid)").font(.system(size: 12, weight: .semibold)).foregroundStyle(NS.green)
            .lineLimit(1)
        let radio = Text("Ch \(c.channel) · \(c.widthMHz) MHz · \(c.generation) · \(c.security)")
            .font(.system(size: 11, design: .monospaced)).foregroundStyle(NS.text2).lineLimit(1)
        let signal = Text("\(c.rssi) dBm · SNR \(c.snr)")
            .font(.system(size: 11, design: .monospaced)).foregroundStyle(rssiColor(c.rssi)).fixedSize()
        // The radio details drop under the SSID when one row won't fit.
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { dot; name; radio; signal; Spacer() }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 10) { dot; name }
                HStack(spacing: 10) { radio; signal }.padding(.leading, 18)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16).padding(.vertical, 7).background(NS.green.opacity(0.08))
    }

    private var resizeDivider: some View {
        ZStack {
            Rectangle().fill(NS.bg1).frame(height: 8)
            RoundedRectangle(cornerRadius: 2).fill(NS.text4).frame(width: 38, height: 3)
        }
        .overlay(alignment: .top) { Rectangle().fill(NS.border).frame(height: 0.5) }
        .contentShape(Rectangle())
        .onHover { inside in if inside { NSCursor.resizeUpDown.set() } else { NSCursor.arrow.set() } }
        .gesture(
            DragGesture()
                .onChanged { v in
                    let start = dragStartHeight ?? bottomHeight
                    if dragStartHeight == nil { dragStartHeight = bottomHeight }
                    bottomHeight = min(620, max(170, start - v.translation.height))
                }
                .onEnded { _ in dragStartHeight = nil }
        )
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            Text("Networks found: \(model.networks.count), displayed: \(visible.count)")
                .font(.system(size: 11)).foregroundStyle(NS.text3)
            Spacer()
            statusFlag("Not secure", NS.red)
            statusFlag("40 MHz in 2.4 GHz", NS.amber)
            if let t = model.lastScan {
                Text(t.formatted(date: .omitted, time: .standard))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(NS.text3)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 5).background(NS.bg0)
    }
    private func statusFlag(_ t: String, _ c: Color) -> some View {
        HStack(spacing: 5) { RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 9, height: 9)
            Text(t).font(.system(size: 11)).foregroundStyle(NS.text3) }
    }

    // MARK: Bottom panel

    private var bottomPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(WiFiTab.allCases) { t in
                    Button(action: { tab = t }) {
                        Text(t.rawValue)
                            .font(.system(size: 12, weight: tab == t ? .semibold : .regular))
                            .foregroundStyle(tab == t ? NS.amber : NS.text2)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .overlay(alignment: .bottom) {
                                if tab == t { Rectangle().fill(NS.amber).frame(height: 2) }
                            }
                    }.buttonStyle(.plain)
                }
                Spacer()
            }
            .background(NS.bg0)
            Divider()
            Group {
                switch tab {
                case .details:  WiFiDetailsView(net: selected)
                case .signal:   WiFiSignalView(networks: visible, selected: selected, history: model.rssiHistory, selectID: { selectedID = $0 })
                case .b24:      WiFiSpectrumView(band: .twoGHz, networks: bandNets(.twoGHz), selected: selected, selectID: { selectedID = $0 })
                case .b5:       WiFiSpectrumView(band: .fiveGHz, networks: bandNets(.fiveGHz), selected: selected, selectID: { selectedID = $0 })
                case .b6:       WiFiSpectrumView(band: .sixGHz, networks: bandNets(.sixGHz), selected: selected, selectID: { selectedID = $0 })
                case .channels: WiFiChannelsView(networks: model.networks, bandFilter: bandFilter, selectID: { selectedID = $0 })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(NS.bg1)
        }
    }
    private func bandNets(_ b: WiFiBand) -> [WiFiNetwork] { model.networks.filter { $0.band == b } }
}

// MARK: - Networks table

struct WiFiTableView: View {
    let networks: [WiFiNetwork]
    @Binding var selectedID: String?
    @Binding var sortOrder: [KeyPathComparator<WiFiNetwork>]

    var body: some View {
        // SwiftUI Table caps at 10 columns: the color swatch is folded into
        // Signal, and Mode is shown as a subtitle under Generation.
        Table(networks, selection: $selectedID, sortOrder: $sortOrder) {
            TableColumn("Signal", value: \.rssi) { n in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(n.color).frame(width: 4, height: 18)
                    signalBar(n.rssi)
                    Text("\(n.rssi)").font(.system(size: 11, design: .monospaced)).foregroundStyle(rssiColor(n.rssi))
                }
            }.width(98)
            TableColumn("Network", value: \.ssid) { n in
                HStack(spacing: 5) {
                    Text(n.ssid).font(.system(size: 12, weight: .semibold)).foregroundStyle(NS.text1).lineLimit(1)
                    if n.isConnected { Circle().fill(NS.green).frame(width: 6, height: 6) }
                }
            }.width(min: 120, ideal: 160)
            TableColumn("Vendor", value: \.vendor) { n in
                Text(n.vendor).font(.system(size: 11)).foregroundStyle(NS.blue).lineLimit(1)
            }.width(110)
            TableColumn("BSSID") { n in
                Text(n.bssid).font(.system(size: 11, design: .monospaced)).foregroundStyle(NS.text3)
            }.width(128)
            TableColumn("Band") { n in
                Text("\(n.band.shortLabel)G").font(.system(size: 11)).foregroundStyle(NS.text2)
            }.width(42)
            TableColumn("Ch", value: \.channel) { n in
                Text("\(n.channel)").font(.system(size: 11, design: .monospaced)).foregroundStyle(NS.text1)
            }.width(38)
            TableColumn("Width", value: \.widthMHz) { n in
                Text("\(n.widthMHz)MHz").font(.system(size: 11)).foregroundStyle(NS.text2)
            }.width(58)
            TableColumn("Generation") { n in
                VStack(alignment: .leading, spacing: 1) {
                    Text(n.generation).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(n.generation.contains("6") ? NS.green : NS.text2)
                    Text("802.11\(n.modeString)").font(.system(size: 9, design: .monospaced)).foregroundStyle(NS.text3)
                }
            }.width(80)
            TableColumn("Security", value: \.security) { n in securityBadge(n) }.width(94)
            TableColumn("Flags") { n in
                HStack(spacing: 3) {
                    ForEach(Array(n.flags.enumerated()), id: \.offset) { _, f in
                        Text(f.0).font(.system(size: 9, weight: .semibold)).foregroundStyle(f.1)
                            .padding(.horizontal, 5).padding(.vertical, 1).background(f.1.opacity(0.16)).cornerRadius(4)
                    }
                }
            }
        }
        .background(NS.bg0)
    }

    private func signalBar(_ rssi: Int) -> some View {
        let pct = max(0.05, min(1.0, Double(100 + rssi) / 70.0))
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3).fill(NS.bg3).frame(width: 46, height: 7)
            RoundedRectangle(cornerRadius: 3).fill(rssiColor(rssi)).frame(width: 46 * pct, height: 7)
        }
    }
    private func securityBadge(_ n: WiFiNetwork) -> some View {
        let c: Color = n.security.hasPrefix("WPA3") ? NS.green
            : n.isEnterprise ? Color(red: 0.749, green: 0.353, blue: 0.949)
            : n.security.hasPrefix("WPA2") ? NS.blue
            : (n.security == "Open" || n.security.hasPrefix("WEP")) ? NS.red : NS.text2
        return Text(n.security).font(.system(size: 10, weight: .semibold)).foregroundStyle(c)
            .padding(.horizontal, 6).padding(.vertical, 1).background(c.opacity(0.15)).cornerRadius(5)
    }
}

// MARK: - Network Details tab

struct WiFiDetailsView: View {
    let net: WiFiNetwork?
    var body: some View {
        if let n = net {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 2).fill(n.color).frame(width: 5, height: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(n.ssid).font(.system(size: 15, weight: .bold)).foregroundStyle(NS.text1)
                            Text("\(n.bssid) · \(n.vendor)").font(.system(size: 11, design: .monospaced)).foregroundStyle(NS.text3)
                        }
                        Spacer()
                        Text("\(n.rssi)").font(.system(size: 22, weight: .bold, design: .monospaced)).foregroundColor(rssiColor(n.rssi))
                            + Text(" dBm").font(.system(size: 11)).foregroundColor(NS.text3)
                    }
                    HStack(alignment: .top, spacing: 26) {
                        col("Radio", [("Band", n.band.label), ("Channel", "\(n.channel)"),
                                      ("Width", "\(n.widthMHz) MHz"), ("Mode", "802.11\(n.modeString)"),
                                      ("Generation", n.generation)])
                        col("Signal", [("RSSI", "\(n.rssi) dBm"), ("Noise", "\(n.noise) dBm"),
                                       ("SNR", "\(n.snr) dB"), ("Beacon", "\(n.beacon) ms")])
                        col("Security & Identity", [("Protocol", n.security),
                                                    ("PMF", n.pmf ? "✓ (WPA3)" : "—"),
                                                    ("Country", n.countryCode.isEmpty ? "—" : n.countryCode),
                                                    ("Hidden", n.ssid == "(hidden)" ? "Yes" : "No")])
                    }
                }.padding(16)
            }
        } else {
            EmptyStateView(title: "No selection", systemImage: "wifi", description: "Select a network in the table above.")
        }
    }
    private func col(_ title: String, _ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 10, weight: .bold)).foregroundStyle(NS.amber)
                .textCase(.uppercase).padding(.bottom, 6)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                HStack { Text(r.0).font(.system(size: 12)).foregroundStyle(NS.text3)
                    Spacer()
                    Text(r.1).font(.system(size: 12, design: .monospaced)).foregroundStyle(NS.text1) }
                .padding(.vertical, 4)
                .overlay(alignment: .bottom) { Rectangle().fill(NS.borderMid).frame(height: 0.5) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Signal Strength tab

struct WiFiSignalView: View {
    let networks: [WiFiNetwork]
    let selected: WiFiNetwork?
    let history: [String: [Double]]
    let selectID: (String) -> Void

    /// The strongest ~15 networks (plus the selected one), to keep the
    /// chart legible instead of a 25-line tangle.
    private var shown: [WiFiNetwork] {
        var s = Array(networks.sorted { $0.rssi > $1.rssi }.prefix(15))
        if let sel = selected, !s.contains(where: { $0.id == sel.id }),
           networks.contains(where: { $0.id == sel.id }) { s.append(sel) }
        return s
    }
    private var hasSeries: Bool { shown.contains { (history[$0.id]?.count ?? 0) >= 2 } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if hasSeries {
                    Canvas { ctx, size in drawSignal(ctx, size) }
                        .frame(height: 240).padding(.horizontal, 14).padding(.top, 12)
                    if let s = selected { WiFiStatStrip.signal(s, history: history[s.id] ?? []) }
                    legend.padding(.horizontal, 14).padding(.bottom, 10)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "waveform.path.ecg").font(.system(size: 30)).foregroundStyle(NS.text3)
                        Text("Collecting RSSI samples…")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(NS.text2)
                        Text("Signal-over-time needs at least two scans. Press Scan again, or turn on Live to plot continuously.")
                            .font(.system(size: 11)).foregroundStyle(NS.text3)
                            .multilineTextAlignment(.center).frame(maxWidth: 360)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 50)
                }
            }
        }
    }

    private var legend: some View {
        FlowLayoutWiFi(spacing: 11) {
            ForEach(shown) { n in
                Button { selectID(n.id) } label: {
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(n.color).frame(width: 14, height: 3)
                        Text(n.ssid).font(.system(size: 11, weight: n.id == selected?.id ? .bold : .regular))
                            .foregroundStyle(n.id == selected?.id ? n.color : NS.text2)
                        Text("\(n.rssi)").font(.system(size: 11, design: .monospaced)).foregroundStyle(NS.text3)
                    }
                }.buttonStyle(.plain)
            }
        }
    }

    private func drawSignal(_ ctx: GraphicsContext, _ size: CGSize) {
        let padL: CGFloat = 8, padB: CGFloat = 18, padT: CGFloat = 8, padR: CGFloat = 56
        // Auto-scale Y to the data range (±5 dB padding), clamped to -30…-95,
        // so stable signals still show their real variation.
        let allVals = shown.flatMap { history[$0.id] ?? [] }
        let dataMin = allVals.min() ?? -90, dataMax = allVals.max() ?? -40
        let lo = max(-95, dataMin - 5), hi = min(-30, dataMax + 5)
        let span = max(8, hi - lo)
        func y(_ r: Double) -> CGFloat { padT + CGFloat((hi - min(hi, max(lo, r))) / span) * (size.height - padT - padB) }
        func x(_ i: Int, _ n: Int) -> CGFloat { padL + CGFloat(n <= 1 ? 0 : Double(i) / Double(n - 1)) * (size.width - padL - padR) }

        let plot = CGRect(x: padL, y: padT, width: size.width - padL - padR, height: size.height - padT - padB)
        // Soft signal-quality wash: strong (green) at top → weak (red) at bottom.
        ctx.fill(Path(plot), with: .linearGradient(
            Gradient(colors: [NS.green.opacity(0.10), NS.amber.opacity(0.05), NS.red.opacity(0.09)]),
            startPoint: CGPoint(x: 0, y: plot.minY), endPoint: CGPoint(x: 0, y: plot.maxY)))

        // Lines — selected drawn last (on top) with glow + downward fill.
        let ordered = shown.sorted { ($0.id == selected?.id ? 1 : 0) < ($1.id == selected?.id ? 1 : 0) }
        for n in ordered {
            guard let h = history[n.id], h.count > 1 else { continue }
            let isSel = n.id == selected?.id
            let pts = h.enumerated().map { CGPoint(x: x($0.offset, h.count), y: y($0.element)) }
            let path = smoothPath(pts)
            if isSel {
                var fill = path
                fill.addLine(to: CGPoint(x: pts.last!.x, y: plot.maxY))
                fill.addLine(to: CGPoint(x: pts.first!.x, y: plot.maxY))
                fill.closeSubpath()
                ctx.fill(fill, with: .linearGradient(Gradient(colors: [n.color.opacity(0.28), n.color.opacity(0.02)]),
                          startPoint: CGPoint(x: 0, y: plot.minY), endPoint: CGPoint(x: 0, y: plot.maxY)))
                ctx.stroke(path, with: .color(n.color.opacity(0.35)), lineWidth: 8)        // glow
            }
            ctx.stroke(path, with: .color(n.color.opacity(isSel ? 1 : 0.6)), lineWidth: isSel ? 2.6 : 1.3)
            if let last = pts.last {
                let r: CGFloat = isSel ? 4 : 2.5
                ctx.fill(Path(ellipseIn: CGRect(x: last.x - r, y: last.y - r, width: r * 2, height: r * 2)), with: .color(n.color))
            }
        }
        // Value pill for the selected network, at its line's right edge.
        if let sel = selected, let h = history[sel.id], h.count > 1, let v = h.last {
            let lx = x(h.count - 1, h.count), ly = y(v)
            let pill = CGRect(x: lx + 8, y: ly - 9, width: 42, height: 18)
            ctx.fill(Path(roundedRect: pill, cornerRadius: 5), with: .color(sel.color))
            ctx.draw(Text("\(Int(v))").font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(red: 0.04, green: 0.04, blue: 0.06)),
                     at: CGPoint(x: pill.midX, y: pill.midY))
        }
        // Time axis labels.
        ctx.draw(Text("−60s").font(.system(size: 9, design: .monospaced)).foregroundColor(NS.text3),
                 at: CGPoint(x: padL + 2, y: size.height - 6), anchor: .leading)
        ctx.draw(Text("now").font(.system(size: 9, design: .monospaced)).foregroundColor(NS.text3),
                 at: CGPoint(x: size.width - padR - 4, y: size.height - 6), anchor: .trailing)
    }
}

// MARK: - Spectrum tab

struct WiFiSpectrumView: View {
    let band: WiFiBand
    let networks: [WiFiNetwork]
    let selected: WiFiNetwork?
    let selectID: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if networks.isEmpty {
                    Text("No \(band.label) networks detected.")
                        .font(.system(size: 12)).foregroundStyle(NS.text3)
                        .frame(maxWidth: .infinity).padding(40)
                } else {
                    SpectrumCanvas(band: band, networks: networks, selected: selected, selectID: selectID)
                        .frame(height: 255).padding(.horizontal, 14).padding(.top, 12)
                    WiFiStatStrip.spectrum(selected, band: band, all: networks)
                    Text("Rectangles = real channel width · curve peak = signal")
                        .font(.system(size: 10)).foregroundStyle(NS.text4).padding(.horizontal, 14).padding(.bottom, 10)
                }
            }
        }
    }
}

struct SpectrumCanvas: View {
    let band: WiFiBand
    let networks: [WiFiNetwork]
    let selected: WiFiNetwork?
    let selectID: (String) -> Void

    var body: some View {
        Canvas { ctx, size in draw(ctx, size) }
            .contentShape(Rectangle())
            .onTapGesture { loc in tap(loc) }
    }

    private var freqRange: (Int, Int) {
        guard !networks.isEmpty else { return (2400, 2500) }
        // Fit the axis to the actual envelope extent (channel edges, not just
        // centers) with a proportional margin, so the spectrum fills the chart
        // width instead of clustering in the middle behind fixed padding.
        let left = networks.map { $0.centerFreq - $0.widthMHz / 2 }.min()!
        let right = networks.map { $0.centerFreq + $0.widthMHz / 2 }.max()!
        let margin = max(12, (right - left) / 6)
        return (left - margin, right + margin)
    }
    private func xFor(_ f: Int, _ w: CGFloat) -> CGFloat {
        let (fmin, fmax) = freqRange; let padL: CGFloat = 34, padR: CGFloat = 8
        return padL + CGFloat(Double(f - fmin) / Double(max(1, fmax - fmin))) * (w - padL - padR)
    }
    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let padB: CGFloat = 24, padT: CGFloat = 14
        func y(_ r: Int) -> CGFloat { padT + CGFloat((Double(-max(-95, min(-30, r))) - 30) / 65.0) * (size.height - padT - padB) }
        for d in [-30, -50, -70, -90] {
            var p = Path(); p.move(to: CGPoint(x: 34, y: y(d))); p.addLine(to: CGPoint(x: size.width - 8, y: y(d)))
            ctx.stroke(p, with: .color(.white.opacity(0.05)), lineWidth: 1)
            ctx.draw(Text("\(d)").font(.system(size: 9, design: .monospaced)).foregroundColor(NS.text3), at: CGPoint(x: 12, y: y(d)))
        }
        for n in networks {
            let isSel = n.id == selected?.id
            let c = n.centerFreq, hw = n.widthMHz / 2 + 3
            let x0 = xFor(c - hw, size.width), x1 = xFor(c + hw, size.width), xc = xFor(c, size.width)
            let yb = y(-95), yp = y(n.rssi)
            // width box
            ctx.fill(Path(CGRect(x: x0, y: yp, width: x1 - x0, height: yb - yp)), with: .color(n.color.opacity(isSel ? 0.2 : 0.08)))
            ctx.stroke(Path(CGRect(x: x0, y: yp, width: x1 - x0, height: yb - yp)), with: .color(n.color.opacity(isSel ? 0.95 : 0.5)), lineWidth: isSel ? 2 : 1)
            // bell
            var bell = Path(); bell.move(to: CGPoint(x: x0, y: yb))
            bell.addCurve(to: CGPoint(x: xc, y: yp), control1: CGPoint(x: (x0 + xc) / 2, y: yb), control2: CGPoint(x: (x0 + xc) / 2, y: yp))
            bell.addCurve(to: CGPoint(x: x1, y: yb), control1: CGPoint(x: (xc + x1) / 2, y: yp), control2: CGPoint(x: (xc + x1) / 2, y: yb))
            ctx.stroke(bell, with: .color(n.color.opacity(0.85)), lineWidth: isSel ? 2 : 1.2)
            ctx.draw(Text(n.ssid).font(.system(size: 10, weight: .semibold)).foregroundColor(n.color), at: CGPoint(x: xc, y: yp - 8))
            ctx.draw(Text("\(n.channel)").font(.system(size: 9, design: .monospaced)).foregroundColor(NS.text3), at: CGPoint(x: xc, y: size.height - 8))
        }
    }
    private func tap(_ loc: CGPoint) {
        // pick nearest network center by x
        guard !networks.isEmpty else { return }
        let w: CGFloat = 900 // approximate; Canvas tap uses view coords — use proportion
        _ = w
        let nearest = networks.min(by: { abs(xForView($0, loc) - loc.x) < abs(xForView($1, loc) - loc.x) })
        if let n = nearest { selectID(n.id) }
    }
    private func xForView(_ n: WiFiNetwork, _ loc: CGPoint) -> CGFloat {
        // Use the actual width from the tap context isn't available; approximate with a wide canvas.
        xFor(n.centerFreq, 900)
    }
}

// MARK: - Channels tab

struct ChannelSel: Identifiable { let id = UUID(); let band: WiFiBand; let ch: Int }

struct WiFiChannelsView: View {
    let networks: [WiFiNetwork]
    let bandFilter: WiFiBand?
    let selectID: (String) -> Void
    @State private var selectedChannel: ChannelSel?

    private struct SubBand { let name: String; let dfs: Bool; let chs: [Int] }
    private struct BandDef { let band: WiFiBand; let label: String; let subs: [SubBand]; let reco: [Int]? }

    private func defs() -> [BandDef] {
        func r(_ a: Int, _ b: Int, _ s: Int) -> [Int] { stride(from: a, through: b, by: s).map { $0 } }
        return [
            BandDef(band: .twoGHz, label: "2.4 GHz", subs: [SubBand(name: "ISM", dfs: false, chs: Array(1...13))], reco: [1, 6, 11]),
            BandDef(band: .fiveGHz, label: "5 GHz", subs: [
                SubBand(name: "U-NII-1", dfs: false, chs: [36, 40, 44, 48]),
                SubBand(name: "U-NII-2A", dfs: true, chs: [52, 56, 60, 64]),
                SubBand(name: "U-NII-2C", dfs: true, chs: r(100, 144, 4)),
                SubBand(name: "U-NII-3", dfs: false, chs: [149, 153, 157, 161, 165])], reco: nil),
            BandDef(band: .sixGHz, label: "6 GHz · Wi-Fi 6E", subs: [
                SubBand(name: "U-NII-5", dfs: false, chs: r(1, 93, 4)),
                SubBand(name: "U-NII-6", dfs: false, chs: r(97, 113, 4)),
                SubBand(name: "U-NII-7", dfs: false, chs: r(117, 185, 4)),
                SubBand(name: "U-NII-8", dfs: false, chs: r(189, 233, 4))], reco: nil),
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let s = selectedChannel {
                    ChannelDetailCard(sel: s, networks: networks) { selectedChannel = nil }
                }
                ForEach(Array(defs().enumerated()), id: \.offset) { _, def in
                    if bandFilter == nil || bandFilter == def.band { bandSection(def) }
                }
                legend.padding(.bottom, 8)
            }.padding(14)
        }
    }

    private func occ(_ band: WiFiBand, _ ch: Int) -> [WiFiNetwork] { networks.filter { $0.band == band && $0.channel == ch } }

    private func bandSection(_ def: BandDef) -> some View {
        let all = def.subs.flatMap { $0.chs }
        let inUse = all.filter { !occ(def.band, $0).isEmpty }.count
        let cand = def.reco ?? def.subs.filter { !$0.dfs }.flatMap { $0.chs }
        let best = cand.min(by: { occ(def.band, $0).count < occ(def.band, $1).count }) ?? cand.first ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(def.label).font(.system(size: 13, weight: .bold)).foregroundStyle(NS.text1)
                Text("\(all.count) channels · \(inUse) in use").font(.system(size: 10, design: .monospaced)).foregroundStyle(NS.text3)
                Spacer()
                Text("★ recommended: ch \(best)").font(.system(size: 10, weight: .semibold)).foregroundStyle(NS.green)
            }
            .padding(.bottom, 4).overlay(alignment: .bottom) { Rectangle().fill(NS.borderMid).frame(height: 0.5) }
            ForEach(Array(def.subs.enumerated()), id: \.offset) { _, sub in
                HStack(spacing: 7) {
                    Text("\(sub.name) · ch \(sub.chs.first ?? 0)–\(sub.chs.last ?? 0)").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(NS.text3).textCase(.uppercase)
                    if sub.dfs { Text("⚡ DFS").font(.system(size: 10, weight: .bold)).foregroundStyle(NS.amber) }
                }.padding(.top, 6)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 58), spacing: 6)], spacing: 6) {
                    ForEach(sub.chs, id: \.self) { ch in tile(def.band, ch, dfs: sub.dfs, best: best) }
                }
            }
        }
    }

    private func tile(_ band: WiFiBand, _ ch: Int, dfs: Bool, best: Int) -> some View {
        let nets = occ(band, ch)
        let top = nets.map { $0.rssi }.max()
        let isReco = ch == best
        let isSel = selectedChannel?.band == band && selectedChannel?.ch == ch
        return VStack(spacing: 3) {
            Text("\(ch)").font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(nets.isEmpty ? NS.text3 : NS.text1)
            if nets.isEmpty {
                Text("free").font(.system(size: 8)).foregroundStyle(NS.green)
            } else {
                HStack(spacing: 2) {
                    ForEach(nets.prefix(8)) { n in Circle().fill(n.color).frame(width: 6, height: 6) }
                }
                Text("\(nets.count) AP\(nets.count > 1 ? "s" : "")").font(.system(size: 8)).foregroundStyle(NS.text2)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(NS.bg3).frame(height: 3)
                    RoundedRectangle(cornerRadius: 2).fill(rssiColor(top ?? -90))
                        .frame(width: 40 * max(0.05, min(1, Double(100 + (top ?? -90)) / 70.0)), height: 3)
                }.frame(width: 40)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 62)
        .padding(.vertical, 6)
        .background(isSel ? NS.amber.opacity(0.14) : NS.bg2)
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(isSel ? NS.amber : (isReco ? NS.green : NS.border),
                          lineWidth: isSel ? 2 : (isReco ? 1.5 : 1)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .opacity(nets.isEmpty && !isSel ? 0.45 : 1)
        .overlay(alignment: .topTrailing) {
            if dfs { Text("DFS").font(.system(size: 7, weight: .bold)).foregroundStyle(NS.amber)
                .padding(.horizontal, 3).padding(.vertical, 1).background(NS.amber.opacity(0.16)).cornerRadius(3).padding(3) }
        }
        .overlay(alignment: .topLeading) { if isReco { Text("★").font(.system(size: 9)).foregroundStyle(NS.green).padding(3) } }
        .contentShape(Rectangle())
        .onTapGesture {
            if let strongest = nets.max(by: { $0.rssi < $1.rssi }) { selectID(strongest.id) }
            selectedChannel = ChannelSel(band: band, ch: ch)
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            Text("★ recommended").font(.system(size: 10)).foregroundStyle(NS.green)
            Text("⚡ DFS — radar-sensitive").font(.system(size: 10)).foregroundStyle(NS.amber)
            Text("dimmed = free").font(.system(size: 10)).foregroundStyle(NS.text3).opacity(0.6)
        }
    }
}

/// Inline channel-analysis card pinned at the top of the Channels tab.
/// (Replaces the old floating `.popover`, which macOS positioned far from
/// the tapped tile.)
struct ChannelDetailCard: View {
    let sel: ChannelSel
    let networks: [WiFiNetwork]
    let onClose: () -> Void

    private var freq: Int { sel.band.centerFreq(sel.ch) }
    private var sub: (String, Bool) { WiFiChannelInfo.subBand(sel.band, sel.ch) }
    private var co: [WiFiNetwork] { networks.filter { $0.band == sel.band && $0.channel == sel.ch }.sorted { $0.rssi > $1.rssi } }
    private var ov: [WiFiNetwork] {
        networks.filter { $0.band == sel.band && $0.channel != sel.ch && abs($0.centerFreq - freq) <= ($0.widthMHz / 2 + 10) }.sorted { $0.rssi > $1.rssi }
    }
    private var verdict: (String, Color) {
        let load = co.count * 2 + ov.count
        if co.isEmpty && ov.isEmpty { return ("✓ Clear — no APs detected", NS.green) }
        if load <= 2 { return ("✓ Light usage", NS.green) }
        if load <= 4 { return ("~ Moderate usage", NS.amber) }
        return ("⚠ Congested — consider another channel", NS.red)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Channel \(sel.ch)").font(.system(size: 16, weight: .bold)).foregroundStyle(NS.text1)
                Text(sel.band.label).font(.system(size: 11, design: .monospaced)).foregroundStyle(NS.text3)
                Text(verdict.0).font(.system(size: 12, weight: .semibold)).foregroundStyle(verdict.1)
                    .padding(.horizontal, 8).padding(.vertical, 3).background(verdict.1.opacity(0.14)).cornerRadius(6)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark.circle.fill").foregroundStyle(NS.text3) }
                    .buttonStyle(.plain)
            }
            Text("Center \(freq) MHz · \(sub.0)\(sub.1 ? " · DFS" : "") · 20 MHz span \(freq - 10)–\(freq + 10) MHz")
                .font(.system(size: 11)).foregroundStyle(NS.text2)

            HStack(alignment: .top, spacing: 20) {
                if !co.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        sec("Co-channel · direct contention (\(co.count))")
                        ForEach(co) { apRow($0, "\($0.widthMHz)MHz") }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if !ov.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        sec("Overlapping · adjacent interference (\(ov.count))")
                        ForEach(ov) { apRow($0, "ch\($0.channel)·\($0.widthMHz)MHz") }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if co.isEmpty && ov.isEmpty { note("No detected APs occupy or overlap this channel — good candidate.", NS.green) }
            if sub.1 { note("⚡ DFS channel. Radar-sensitive: an AP here must vacate on radar detection, causing brief client drops.", NS.amber) }
            if sel.band == .twoGHz { note("2.4 GHz channels overlap heavily — use 1, 6, or 11 only for non-overlapping coverage.", NS.text2) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NS.bg2)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(verdict.1.opacity(0.4)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
    private func sec(_ t: String) -> some View {
        Text(t).font(.system(size: 10, weight: .bold)).foregroundStyle(NS.text3).textCase(.uppercase)
    }
    private func apRow(_ n: WiFiNetwork, _ ex: String) -> some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 2).fill(n.color).frame(width: 3, height: 15)
            Text(n.ssid).font(.system(size: 11, weight: .semibold)).foregroundStyle(NS.text1).lineLimit(1)
            Text(n.vendor).font(.system(size: 10, design: .monospaced)).foregroundStyle(NS.text3).lineLimit(1)
            Spacer()
            Text("\(n.rssi)").font(.system(size: 11, design: .monospaced)).foregroundStyle(rssiColor(n.rssi))
            Text(ex).font(.system(size: 10, design: .monospaced)).foregroundStyle(NS.text3)
        }
    }
    private func note(_ t: String, _ c: Color) -> some View {
        Text(t).font(.system(size: 11)).foregroundStyle(c == NS.text2 ? NS.text2 : c)
            .fixedSize(horizontal: false, vertical: true)
            .padding(8).frame(maxWidth: .infinity, alignment: .leading).background(NS.bg3).cornerRadius(6)
    }
}

enum WiFiChannelInfo {
    static func subBand(_ band: WiFiBand, _ ch: Int) -> (String, Bool) {
        switch band {
        case .twoGHz: return ("ISM", false)
        case .fiveGHz:
            if ch <= 48 { return ("U-NII-1", false) }
            if ch <= 64 { return ("U-NII-2A", true) }
            if ch <= 144 { return ("U-NII-2C", true) }
            return ("U-NII-3", false)
        case .sixGHz:
            if ch <= 93 { return ("U-NII-5", false) }
            if ch <= 113 { return ("U-NII-6", false) }
            if ch <= 185 { return ("U-NII-7", false) }
            return ("U-NII-8", false)
        case .unknown: return ("—", false)
        }
    }
}

// MARK: - Stat strips (shared)

enum WiFiStatStrip {
    static func signal(_ n: WiFiNetwork, history h: [Double]) -> some View {
        let cur = Int(h.last ?? Double(n.rssi))
        let mn = Int(h.min() ?? Double(n.rssi)), mx = Int(h.max() ?? Double(n.rssi))
        let avg = h.isEmpty ? Double(n.rssi) : h.reduce(0, +) / Double(h.count)
        let std = h.isEmpty ? 0 : sqrt(h.reduce(0) { $0 + ($1 - avg) * ($1 - avg) } / Double(h.count))
        let recent = h.suffix(10).reduce(0, +) / Double(max(1, min(10, h.count)))
        let older = h.prefix(10).reduce(0, +) / Double(max(1, min(10, h.count)))
        let diff = recent - older
        let (trend, tcol): (String, Color) = diff > 1.5 ? ("↑ improving", NS.green) : diff < -1.5 ? ("↓ declining", NS.red) : ("→ stable", NS.text2)
        let qual = cur >= -55 ? "Excellent" : cur >= -67 ? "Good" : cur >= -75 ? "Fair" : "Weak"
        return strip(n, tiles: [("Current", "\(cur) dBm", rssiColor(cur)), ("Average", "\(Int(avg)) dBm", nil),
                                ("Min / Max", "\(mn) / \(mx)", nil), ("Jitter σ", String(format: "%.1f dB", std), nil),
                                ("SNR", "\(n.snr) dB", nil), ("Quality", qual, rssiColor(cur)), ("Trend", trend, tcol)])
    }
    static func spectrum(_ n: WiFiNetwork?, band: WiFiBand, all: [WiFiNetwork]) -> some View {
        Group {
            if let n = n, n.band == band {
                let co = all.filter { $0.id != n.id && $0.channel == n.channel }.count
                let ov = all.filter { $0.id != n.id && $0.channel != n.channel && abs($0.centerFreq - n.centerFreq) <= (max($0.widthMHz, n.widthMHz) / 2 + 10) }.count
                strip(n, tiles: [("Channel", "\(n.channel)", nil), ("Center", "\(n.centerFreq) MHz", nil),
                                 ("Width", "\(n.widthMHz) MHz", nil),
                                 ("Span", "\(n.centerFreq - n.widthMHz / 2)–\(n.centerFreq + n.widthMHz / 2)", nil),
                                 ("Co-channel", "\(co)", nil), ("Overlap", "\(ov)", ov > 0 ? NS.amber : nil),
                                 ("Mode", "802.11\(n.modeString)", nil), ("RSSI", "\(n.rssi) dBm", rssiColor(n.rssi))])
            } else {
                Text("Click a network in the chart above to see its details.")
                    .font(.system(size: 11)).foregroundStyle(NS.text3)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(NS.bg2).cornerRadius(9).padding(.horizontal, 14).padding(.top, 12)
            }
        }
    }
    private static func strip(_ n: WiFiNetwork, tiles: [(String, String, Color?)]) -> some View {
        HStack(alignment: .center, spacing: 22) {
            HStack(spacing: 11) {
                RoundedRectangle(cornerRadius: 2).fill(n.color).frame(width: 4, height: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(n.ssid).font(.system(size: 14, weight: .bold)).foregroundStyle(NS.text1).lineLimit(1)
                    Text("\(n.bssid) · \(n.vendor)").font(.system(size: 10, design: .monospaced)).foregroundStyle(NS.text3).lineLimit(1)
                }
            }.frame(minWidth: 180, alignment: .leading)
            FlowLayoutWiFi(spacing: 10) {
                ForEach(Array(tiles.enumerated()), id: \.offset) { _, t in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(t.0).font(.system(size: 9, weight: .medium)).foregroundStyle(NS.text3).textCase(.uppercase)
                        Text(t.1).font(.system(size: 14, weight: .bold, design: .monospaced)).foregroundStyle(t.2 ?? NS.text1).lineLimit(1)
                    }
                    .frame(minWidth: 72, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(NS.bg3).cornerRadius(8)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .background(NS.bg2).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(NS.border))
        .clipShape(RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 14).padding(.top, 12)
    }
}

// MARK: - Smooth path + simple flow layout

func smoothPath(_ pts: [CGPoint]) -> Path {
    var path = Path()
    guard let first = pts.first else { return path }
    path.move(to: first)
    for i in 0..<(pts.count - 1) {
        let a = pts[i], b = pts[i + 1], xc = (a.x + b.x) / 2
        path.addCurve(to: b, control1: CGPoint(x: xc, y: a.y), control2: CGPoint(x: xc, y: b.y))
    }
    return path
}

/// Minimal wrapping HStack for chips/legends.
struct FlowLayoutWiFi: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > maxW { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
        return CGSize(width: maxW == .infinity ? x : maxW, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxW = bounds.width
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.minX + maxW { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
    }
}
