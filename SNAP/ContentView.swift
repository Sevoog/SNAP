// ContentView.swift
// SNAP — Dark Command Centre UI
// Created by Sevag Bardakjian
// Copyright © 2025-2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md

import SwiftUI
import Darwin
import UniformTypeIdentifiers
// SidebarFooter exposes a `Timer.publish(…).autoconnect()` property, whose
// type (Publishers.Autoconnect) comes from Combine. Without the explicit
// import the compiler warns that the type isn't visible in this file.
import Combine

// MARK: - Design Tokens

// All NS tokens forward to the currently selected Theme. As long as the top-
// level view (ContentView, MenuBarView) observes ThemeManager, a theme switch
// re-evaluates every body in the hierarchy and the new colors propagate.
struct NS {
    static var bg0:       Color { ThemeManager.shared.current.bg0 }
    static var bg1:       Color { ThemeManager.shared.current.bg1 }
    static var bg2:       Color { ThemeManager.shared.current.bg2 }
    static var bg3:       Color { ThemeManager.shared.current.bg3 }
    static var border:    Color { ThemeManager.shared.current.border }
    static var borderMid: Color { ThemeManager.shared.current.borderMid }
    static var amber:     Color { ThemeManager.shared.current.amber }
    static var green:     Color { ThemeManager.shared.current.green }
    static var blue:      Color { ThemeManager.shared.current.blue }
    static var red:       Color { ThemeManager.shared.current.red }
    static var purple:    Color { ThemeManager.shared.current.purple }
    static var text1:     Color { ThemeManager.shared.current.text1 }
    static var text2:     Color { ThemeManager.shared.current.text2 }
    static var text3:     Color { ThemeManager.shared.current.text3 }
    static var text4:     Color { ThemeManager.shared.current.text4 }
    /// E-ink theme: show state with shape, not hue (see `Theme.inkCues`).
    static var inkCues:   Bool  { ThemeManager.shared.current.inkCues }
    /// Color e-ink: draw those cues in the muted semantic colors.
    static var inkColors: Bool  { ThemeManager.shared.current.inkColors }
    /// Icon / label color on an `amber` fill.
    static var onAmber:   Color { ThemeManager.shared.current.onAmber }
}

// MARK: - Tab Definition

enum SNAPTab: String, CaseIterable, Identifiable {
    case dashboard       = "Dashboard"
    case info            = "Network Info"
    case ping            = "Ping"
    case lookup          = "Lookup"
    case dnsPropagation  = "DNS Propagation"
    case dnsBenchmark    = "DNS Benchmark"
    case traceroute      = "Traceroute"
    case visualTrace     = "Visual Trace"
    case geoIP           = "GeoIP Lookup"
    case portScan        = "Port Scan"
    case whois           = "Whois"
    case fingerprint     = "Fingerprint"
    case bonjour         = "Bonjour"
    case wakeOnLAN       = "Wake-on-LAN"
    case subnet          = "Subnet Calc"
    case ssl             = "SSL/TLS"
    case http            = "HTTP Probe"
    case bandwidth       = "Bandwidth"
    case interfaceStats  = "Interface Stats"
    case connections     = "Connections"
    case speedTest       = "Speed Test"
    case wifi            = "WiFi Analyzer"
    case multiHost       = "Multi-Host"
    case networkMap      = "Network Map"
    case packetCapture   = "Packet Capture"
    case mtuDiscovery    = "MTU Discovery"
    case captivePortal   = "Network Health"
    case dhcpLease       = "DHCP Leases"
    case arpTable        = "ARP Table"
    case mtr             = "MTR"
    case snmp            = "SNMP"
    case routingHello    = "Routing Hello"
    case syslog          = "Syslog"
    case bgp             = "BGP/ASN"
    case unifi           = "UniFi"
    case bulkDiscovery   = "Bulk Discovery"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .dashboard:       return "rectangle.3.group"
        case .info:            return "info.circle"
        case .ping:            return "dot.radiowaves.left.and.right"
        case .lookup:          return "magnifyingglass"
        case .dnsPropagation:  return "globe.americas"
        case .dnsBenchmark:    return "stopwatch"
        case .traceroute:      return "arrow.triangle.branch"
        case .visualTrace:     return "map"
        case .portScan:        return "magnifyingglass.circle"
        case .whois:           return "person.text.rectangle"
        case .fingerprint:     return "person.badge.key"
        case .bonjour:         return "network.badge.shield.half.filled"
        case .wakeOnLAN:       return "power.circle"
        case .subnet:          return "number.circle"
        case .ssl:             return "lock.shield"
        case .http:            return "globe.badge.chevron.backward"
        case .bandwidth:       return "chart.bar"
        case .interfaceStats:  return "chart.line.uptrend.xyaxis"
        case .connections:     return "list.bullet.rectangle"
        case .speedTest:       return "speedometer"
        case .wifi:            return "wifi"
        case .multiHost:       return "server.rack"
        case .networkMap:      return "map.circle"
        case .packetCapture:   return "doc.text.magnifyingglass"
        case .geoIP:           return "globe.americas.fill"
        case .mtuDiscovery:    return "arrow.left.and.right.square"
        case .captivePortal:   return "stethoscope"
        case .dhcpLease:       return "doc.text.below.ecg"
        case .arpTable:        return "antenna.radiowaves.left.and.right"
        case .mtr:             return "point.3.connected.trianglepath.dotted"
        case .snmp:            return "rectangle.connected.to.line.below"
        case .routingHello:    return "wave.3.right"
        case .syslog:          return "tray.full"
        case .bgp:             return "arrow.triangle.branch"
        case .unifi:           return "antenna.radiowaves.left.and.right.circle"
        case .bulkDiscovery:   return "square.grid.3x3.fill.square"
        }
    }

    var category: TabCategory {
        switch self {
        case .dashboard:
            return .overview
        // Day-to-day "something is wrong, help me find it" — interactive
        // troubleshooting against a specific target.
        case .info, .ping, .lookup, .traceroute, .visualTrace, .geoIP, .portScan,
             .mtuDiscovery, .captivePortal, .mtr:
            return .diagnostics
        // Standalone utilities — lookups, calculators, magic packets,
        // passive system info. Not "troubleshoot a host", just produce
        // output from input.
        case .bonjour, .wakeOnLAN, .subnet, .ssl, .http,
             .dhcpLease, .arpTable, .whois, .bgp:
            return .tools
        // Live continuous data displays.
        case .bandwidth, .interfaceStats, .connections, .speedTest, .wifi,
             .syslog:
            return .monitoring
        // Power-user features: deep scans, multi-target comparisons,
        // packet-level work, DNS reconnaissance, enterprise probes.
        case .multiHost, .networkMap, .packetCapture,
             .dnsPropagation, .dnsBenchmark, .fingerprint,
             .snmp, .routingHello, .unifi, .bulkDiscovery:
            return .advanced
        }
    }

    enum TabCategory: String, CaseIterable {
        case overview    = "Overview"
        case diagnostics = "Diagnostics"
        case tools       = "Tools"
        case monitoring  = "Monitoring"
        case advanced    = "Advanced"
    }
}

// MARK: - Tab lifecycle

private struct ActiveTabKey: EnvironmentKey { static let defaultValue = true }

extension EnvironmentValues {
    /// False while this tool's tab is open in the background. Tabs stay
    /// alive after you switch away (see `ContentView.detailView`), so
    /// `.onDisappear` no longer fires on a tab switch.
    var isActiveTab: Bool {
        get { self[ActiveTabKey.self] }
        set { self[ActiveTabKey.self] = newValue }
    }
}

private struct ActiveTabTitleKey: EnvironmentKey { static let defaultValue: String? = nil }

extension EnvironmentValues {
    /// Window title of the tab on screen. nil outside the tab system.
    var activeTabTitle: String? {
        get { self[ActiveTabTitleKey.self] }
        set { self[ActiveTabTitleKey.self] = newValue }
    }
}

extension View {
    /// The window title for a tab. Use instead of `.navigationTitle`.
    ///
    /// Hidden tabs stay alive (see `ContentView.detailView`), and SwiftUI
    /// still reads their titles: the first opened tab in `SNAPTab` order
    /// wins, so after visiting Network Info every later tab, and the
    /// Dashboard, was titled "Network Info". Here a hidden tab reports the
    /// on-screen tab's title instead of its own, so every tab agrees.
    func tabNavigationTitle(_ tab: SNAPTab) -> some View {
        modifier(TabTitleModifier(tab: tab))
    }

    /// For automatic work a tab does while on screen — polling, live Wi-Fi
    /// scans, reloading a snapshot: `hidden` runs when the user switches to
    /// another tab, `shown` when they come back. Work the user started (a
    /// ping, a scan, a capture) should not use this; it's meant to keep
    /// running in the background.
    func onTabVisibilityChange(shown: @escaping () -> Void,
                               hidden: @escaping () -> Void = {}) -> some View {
        modifier(TabVisibilityModifier(shown: shown, hidden: hidden))
    }
}

private struct TabTitleModifier: ViewModifier {
    let tab: SNAPTab
    @Environment(\.isActiveTab) private var isActive
    @Environment(\.activeTabTitle) private var activeTitle

    func body(content: Content) -> some View {
        content.navigationTitle(isActive ? tab.windowTitle : (activeTitle ?? tab.windowTitle))
    }
}

extension SNAPTab {
    /// The window title while this tab is on screen.
    var windowTitle: String {
        switch self {
        case .dashboard: return "SNAP"
        case .info: return "Network Info"
        case .ping: return "Ping"
        case .lookup: return "DNS Lookup"
        case .dnsPropagation: return "DNS Propagation"
        case .dnsBenchmark: return "DNS Benchmark"
        case .traceroute: return "Traceroute"
        case .visualTrace: return "Visual Trace Route"
        case .portScan: return "Port Scan"
        case .whois: return "Whois"
        case .fingerprint: return "Fingerprint"
        case .bonjour: return "Bonjour Browser"
        case .wakeOnLAN: return "Wake-on-LAN"
        case .subnet: return "Subnet Calculator"
        case .ssl: return "SSL/TLS Checker"
        case .http: return "HTTP/HTTPS Probe"
        case .bandwidth: return "Bandwidth Monitor"
        case .interfaceStats: return "Interface Stats"
        case .connections: return "Active Connections"
        case .speedTest: return "Speed Test"
        case .wifi: return "WiFi Analyzer"
        case .multiHost: return "Multi-Host Compare"
        case .networkMap: return "Network Map"
        case .packetCapture: return "Packet Capture"
        case .geoIP: return "GeoIP Lookup"
        case .mtuDiscovery: return "MTU Discovery"
        case .captivePortal: return "Network Health"
        case .dhcpLease: return "DHCP Leases"
        case .arpTable: return "ARP Table"
        case .mtr: return "MTR"
        case .snmp: return "SNMP"
        case .routingHello: return "Routing Hello"
        case .syslog: return "Syslog"
        case .bgp: return "BGP/ASN Lookup"
        case .unifi: return "UniFi"
        case .bulkDiscovery: return "Bulk Discovery"
        }
    }
}

private struct TabVisibilityModifier: ViewModifier {
    @Environment(\.isActiveTab) private var isActive
    let shown: () -> Void
    let hidden: () -> Void

    func body(content: Content) -> some View {
        content.onChange(of: isActive) { active in
            if active { shown() } else { hidden() }
        }
    }
}

// MARK: - Root Content View

struct ContentView: View {
    @State private var selectedTab: SNAPTab = .dashboard
    /// Tabs opened so far. They stay alive, hidden, after you switch away —
    /// see `detailView`.
    @State private var openedTabs: Set<SNAPTab> = []
    @State private var searchText = ""
    @ObservedObject private var themeMgr = ThemeManager.shared
    @ObservedObject private var onboarding = OnboardingManager.shared
    @ObservedObject private var palette = CommandPaletteManager.shared
    @ObservedObject private var statusBoard = StatusBoardManager.shared
    @ObservedObject private var handoff = ToolHandoff.shared
    @StateObject private var statusBoardBW = BandwidthDashMonitor()

    var body: some View {
        HStack(spacing: 0) {
            // Icon rail (far left)
            IconRail(selectedTab: $selectedTab)

            // Sidebar
            DarkSidebar(selectedTab: $selectedTab, searchText: $searchText)

            // Main content area
            ZStack {
                NS.bg0.ignoresSafeArea()
                detailView
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NS.bg0)
        // Follows the theme (was hard-coded .dark, which broke Daylight's
        // tables, text fields, and secondary text).
        .preferredColorScheme(themeMgr.current.colorScheme)
        .onReceive(NotificationCenter.default.publisher(for: .exportSessionReport)) { _ in
            SessionReporter.writeReport()
        }
        .onChange(of: handoff.requestedTab) { newTab in
            if let newTab {
                selectedTab = newTab
                handoff.clearRequestedTab()
            }
        }
        .sheet(isPresented: $onboarding.isPresented) {
            OnboardingView()
        }
        .overlay {
            // ⌘K command bar (#10) — modal overlay with blurred backdrop.
            if palette.isPresented {
                ZStack {
                    Color.black.opacity(0.45)
                        .ignoresSafeArea()
                        .onTapGesture { palette.isPresented = false }
                    CommandPaletteView(selectedTab: $selectedTab)
                        .padding(.top, 100)
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                }
                .transition(.opacity)
            }
        }
        .overlay {
            // Status Board (#6) — fullscreen takeover.
            if statusBoard.isPresented {
                StatusBoardView(bwMonitor: statusBoardBW)
                    .transition(.opacity)
                    .ignoresSafeArea()
            }
        }
        .animation(.easeInOut(duration: 0.18), value: palette.isPresented)
        .animation(.easeInOut(duration: 0.22), value: statusBoard.isPresented)
        // Global keyboard shortcuts. Hidden buttons in a Group, opacity 0,
        // so the shortcuts fire from anywhere without stealing focus.
        .background(
            Group {
                Button("") { palette.toggle() }
                    .keyboardShortcut("k", modifiers: .command)
                Button("") { statusBoard.toggle() }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
            }
            .opacity(0)
        )
    }

    /// Every tab opened this session stays mounted, hidden when it isn't
    /// selected, so work you started — a ping, a scan, a capture — keeps
    /// running, and inputs and results are still there when you come back.
    /// (Before v1.5.4 switching tabs destroyed the tool, which stopped and
    /// cleared it.) Automatic background work pauses while hidden via
    /// `onTabVisibilityChange`.
    private var detailView: some View {
        ZStack {
            ForEach(SNAPTab.allCases.filter { openedTabs.contains($0) || $0 == selectedTab }) { tab in
                let active = tab == selectedTab
                toolView(for: tab)
                    .opacity(active ? 1 : 0)
                    .allowsHitTesting(active)
                    // Disabled while hidden so a hidden tab's keyboard
                    // shortcuts (Return-to-scan, etc.) can't fire from here.
                    .disabled(!active)
                    .accessibilityHidden(!active)
                    .zIndex(active ? 1 : 0)
                    .environment(\.isActiveTab, active)
            }
        }
        .environment(\.activeTabTitle, selectedTab.windowTitle)
        .onAppear { openedTabs.insert(selectedTab) }
        .onChange(of: selectedTab) { openedTabs.insert($0) }
    }

    @ViewBuilder
    private func toolView(for tab: SNAPTab) -> some View {
        switch tab {
        case .dashboard:       DashboardView(selectedTab: $selectedTab)
        case .info:            InfoView()
        case .ping:            PingView()
        case .lookup:          LookupView()
        case .dnsPropagation:  DNSPropagationView()
        case .dnsBenchmark:    DNSBenchmarkView()
        case .traceroute:      TracerouteView()
        case .visualTrace:     VisualTraceRouteView()
        case .portScan:        PortScanView()
        case .whois:           WhoisView()
        case .fingerprint:     FingerprintView()
        case .bonjour:         BonjourView()
        case .wakeOnLAN:       WakeOnLANView()
        case .subnet:          SubnetCalculatorView()
        case .ssl:             SSLCheckerView()
        case .http:            HTTPProbeView()
        case .bandwidth:       BandwidthMonitorView()
        case .interfaceStats:  InterfaceStatsView()
        case .connections:     ConnectionTableView()
        case .speedTest:       SpeedTestView()
        case .wifi:            WiFiAnalyzerView()
        case .multiHost:       MultiHostCompareView()
        case .networkMap:      NetworkMapView()
        case .packetCapture:   PacketCaptureView()
        case .geoIP:           GeoIPView()
        case .mtuDiscovery:    MTUDiscoveryView()
        case .captivePortal:   CaptivePortalView()
        case .dhcpLease:       DHCPLeaseView()
        case .arpTable:        ARPTableView()
        case .mtr:             MTRView()
        case .snmp:            SNMPView()
        case .routingHello:    RoutingHelloView()
        case .syslog:          SyslogReceiverView()
        case .bgp:             BGPLookupView()
        case .unifi:           UniFiControllerView()
        case .bulkDiscovery:   BulkDiscoveryView()
        }
    }
}

// MARK: - Icon Rail

struct IconRail: View {
    @Binding var selectedTab: SNAPTab
    @ObservedObject private var themeMgr = ThemeManager.shared

    // Groups of tabs shown as icon-only buttons in the rail
    private let railGroups: [[SNAPTab]] = [
        [.dashboard],
        [.info, .ping, .lookup, .traceroute, .visualTrace],
        [.bandwidth, .wifi, .packetCapture],
        [.networkMap, .multiHost]
    ]

    var body: some View {
        VStack(spacing: 0) {
            // App logo
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(NS.amber)
                    .frame(width: 32, height: 32)
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(NS.onAmber)
            }
            .padding(.bottom, 14)

            ForEach(Array(railGroups.enumerated()), id: \.offset) { gIdx, group in
                if gIdx > 0 {
                    Divider()
                        .background(NS.border)
                        .frame(width: 26)
                        .padding(.vertical, 5)
                }
                ForEach(group, id: \.self) { tab in
                    RailButton(tab: tab, isSelected: selectedTab == tab) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedTab = tab
                        }
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, 12)
        .frame(width: 54)
        .background(NS.bg1)
        .overlay(alignment: .trailing) {
            Rectangle().fill(NS.border).frame(width: 0.5)
        }
    }
}

struct RailButton: View {
    let tab: SNAPTab
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false
    @ObservedObject private var themeMgr = ThemeManager.shared

    var body: some View {
        let ink = themeMgr.current.inkCues
        Button(action: action) {
            Image(systemName: tab.icon)
                .font(.system(size: 15))
                .foregroundStyle(isSelected ? (ink ? (themeMgr.current.inkColors ? NS.amber : NS.bg2) : NS.amber)
                                            : (isHovered ? NS.text1 : NS.text3))
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? (ink ? NS.text1 : NS.amber.opacity(0.12))
                                         : (isHovered ? NS.text1.opacity(0.04) : Color.clear))
                )
        }
        .buttonStyle(.plain)
        .help(tab.rawValue)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Dark Sidebar

struct DarkSidebar: View {
    @Binding var selectedTab: SNAPTab
    @Binding var searchText: String
    @ObservedObject private var themeMgr = ThemeManager.shared

    private var filteredCategories: [(SNAPTab.TabCategory, [SNAPTab])] {
        let tabs = searchText.isEmpty
            ? SNAPTab.allCases
            : SNAPTab.allCases.filter { $0.rawValue.localizedCaseInsensitiveContains(searchText) }

        if !searchText.isEmpty {
            return [(.overview, tabs)]
        }

        return SNAPTab.TabCategory.allCases.compactMap { cat in
            let t = tabs.filter { $0.category == cat }
            return t.isEmpty ? nil : (cat, t)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 2) {
                Text("SNAP")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(NS.text1)
                Text("Network Analysis Platform · v\(AppInfo.version)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(NS.text3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // Search
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(NS.text3)
                TextField("", text: $searchText)
                    .font(.system(size: 11))
                    .foregroundStyle(NS.text2)
                    .textFieldStyle(.plain)
                    .placeholder(when: searchText.isEmpty) {
                        Text("Search tools…")
                            .font(.system(size: 11))
                            .foregroundStyle(NS.text4)
                    }
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(NS.text3)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(NS.text1.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(NS.border, lineWidth: 0.5))
            .padding(.horizontal, 10)
            .padding(.bottom, 6)

            Rectangle().fill(NS.border).frame(height: 0.5)

            // Nav list
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredCategories, id: \.0) { cat, tabs in
                        if cat != .overview || searchText.isEmpty {
                            Text(cat.rawValue.uppercased())
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(NS.text3)
                                .tracking(1.2)
                                .padding(.horizontal, 14)
                                .padding(.top, 14)
                                .padding(.bottom, 4)
                        }
                        ForEach(tabs) { tab in
                            DarkNavRow(tab: tab, isSelected: selectedTab == tab) {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    selectedTab = tab
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 12)
            }

            Rectangle().fill(NS.border).frame(height: 0.5)

            // Footer — connectivity status + About
            SidebarFooter()
        }
        .frame(width: 196)
        .background(NS.bg2)
        .overlay(alignment: .trailing) {
            Rectangle().fill(NS.border).frame(width: 0.5)
        }
    }
}

// MARK: - Sidebar Footer

struct SidebarFooter: View {
    @State private var isOnline = true
    @State private var showAbout = false
    @State private var pingMs: String = "—"
    @ObservedObject private var themeMgr = ThemeManager.shared

    let timer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    var body: some View {
        Button {
            showAbout = true
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(isOnline ? NS.green : NS.red)
                    .frame(width: 5, height: 5)
                    .animation(.easeInOut(duration: 0.3), value: isOnline)

                VStack(alignment: .leading, spacing: 1) {
                    Text(isOnline ? "Online" : "Offline")
                        .font(.system(size: 10))
                        .foregroundStyle(isOnline ? NS.green : NS.red)
                    if isOnline && pingMs != "—" {
                        Text("\(pingMs) ms")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(NS.text4)
                    }
                }

                Spacer()

                Text("v\(AppInfo.version)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(NS.text4)

                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(NS.text3)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showAbout) {
            AboutSheet()
        }
        .onAppear { checkConnectivity() }
        .onReceive(timer) { _ in checkConnectivity() }
    }

    private func checkConnectivity() {
        Task {
            // Try multiple lightweight endpoints — accept any 2xx response
            let candidates = [
                "https://www.apple.com/library/test/success.html",
                "https://www.cloudflare.com/cdn-cgi/trace",
                "https://www.google.com/generate_204",
            ]
            for urlStr in candidates {
                guard let url = URL(string: urlStr) else { continue }
                var req = URLRequest(url: url)
                req.httpMethod = "GET"
                req.timeoutInterval = 5
                req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                let t0 = Date()
                if let (_, resp) = try? await URLSession.shared.data(for: req),
                   let code = (resp as? HTTPURLResponse)?.statusCode,
                   (200...299).contains(code) {
                    let ms = Int(Date().timeIntervalSince(t0) * 1000)
                    await MainActor.run {
                        self.isOnline = true
                        self.pingMs = "\(ms)"
                    }
                    return
                }
            }
            // All failed
            await MainActor.run { self.isOnline = false; self.pingMs = "—" }
        }
    }
}

// MARK: - About Sheet

struct AboutSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var themeMgr = ThemeManager.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(NS.text3)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 4)

            VStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(NS.amber)
                        .frame(width: 72, height: 72)
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(NS.onAmber)
                }

                VStack(spacing: 4) {
                    Text("SNAP")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(NS.text1)
                    Text("Sev's Network Analysis Platform")
                        .font(.system(size: 12))
                        .foregroundStyle(NS.text3)
                    Text("Version \(AppInfo.version)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(NS.text4)
                        .padding(.top, 2)
                }

                Divider().background(NS.border)

                VStack(spacing: 8) {
                    aboutRow(icon: "person.fill",    label: "Developer", value: "Sevag Bardakjian")
                    // Read from the built app (LSMinimumSystemVersion = the
                    // deployment target) so it can't drift from reality again.
                    aboutRow(icon: "laptopcomputer", label: "Platform",
                             value: "macOS \(Bundle.main.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String ?? "14.0")+")
                    aboutRow(icon: "cpu",            label: "Runtime",   value: "Swift · SwiftUI")
                }
                .padding(.horizontal, 24)

                Divider().background(NS.border)

                // GPL-3.0 "Appropriate Legal Notices": copyright, no warranty,
                // that it may be redistributed under the license, and where to
                // read the license.
                VStack(spacing: 4) {
                    Text("© 2025–2026 Sevag Bardakjian · GNU GPL v3")
                    Text("Free software with ABSOLUTELY NO WARRANTY. You may redistribute it under the terms of the GPL v3.")
                        .multilineTextAlignment(.center)
                    if let source = URL(string: "https://github.com/Sevoog/SNAP") {
                        Link("Source code and license", destination: source)
                            .foregroundStyle(NS.blue)
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(NS.text4)
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
        }
        .frame(width: 320)
        .background(NS.bg2)
        .preferredColorScheme(themeMgr.current.colorScheme)
    }

    private func aboutRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(NS.amber)
                .frame(width: 16)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(NS.text3)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(NS.text2)
        }
    }
}

struct DarkNavRow: View {
    let tab: SNAPTab
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false
    @ObservedObject private var themeMgr = ThemeManager.shared

    var body: some View {
        let ink = themeMgr.current.inkCues
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: tab.icon)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? (ink ? (themeMgr.current.inkColors ? NS.amber : NS.bg2) : NS.amber) : NS.text3)
                    .frame(width: 14)
                Text(tab.rawValue)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? (ink ? NS.bg2 : NS.amber) : NS.text2)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected
                          ? (ink ? NS.text1 : NS.amber.opacity(0.10))
                          : (isHovered ? NS.text1.opacity(0.03) : Color.clear))
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Dashboard View

struct DashboardView: View {
    @Binding var selectedTab: SNAPTab
    @StateObject private var bwMonitor = BandwidthDashMonitor()
    @StateObject private var mapModel = NetworkMapModel()
    @ObservedObject private var layout = DashboardLayout.shared
    @ObservedObject private var themeMgr = ThemeManager.shared
    @ObservedObject private var favs = FavoritesManager.shared
    @State private var editing = false
    @State private var showAddSheet = false
    @State private var draggingTab: SNAPTab? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                ConnectionSummaryCard()

                if !favs.items.isEmpty {
                    FavoritesStripView(selectedTab: $selectedTab)
                }

                pinnedHeader
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 280), spacing: 12)],
                    alignment: .leading,
                    spacing: 12
                ) {
                    ForEach(layout.pinned, id: \.self) { tab in
                        if let spec = DashCardSpec.spec(for: tab) {
                            DashCardChrome(spec: spec, editing: editing,
                                           onRemove: { layout.remove(tab) }) {
                                DashCardBody(spec: spec,
                                             selectedTab: $selectedTab,
                                             bwMonitor: bwMonitor,
                                             mapModel: mapModel)
                            }
                            .opacity(draggingTab == tab ? 0.4 : 1.0)
                            .draggableWhenEditing(editing,
                                                  tab: tab,
                                                  layout: layout,
                                                  draggingTab: $draggingTab)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        }
                    }
                }
                .animation(.easeInOut(duration: 0.18), value: layout.pinned)
                .animation(.easeInOut(duration: 0.18), value: editing)

                if layout.pinned.isEmpty {
                    emptyState
                }
            }
            .padding(14)
        }
        .background(NS.bg0)
        .onAppear {
            bwMonitor.start()
            mapModel.restoreLastScan()
        }
        .onDisappear { bwMonitor.stop() }
        // The Dashboard stays alive in the background; its live bandwidth
        // card only needs to sample while it's on screen.
        .onTabVisibilityChange(shown: { bwMonitor.start() },
                               hidden: { bwMonitor.stop() })
        .sheet(isPresented: $showAddSheet) {
            AddToolsSheet(layout: layout)
        }
    }

    private var pinnedHeader: some View {
        HStack(spacing: 10) {
            Text("PINNED TOOLS")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(NS.text3)
            Text(verbatim: "\(layout.pinned.count) of \(DashCardSpec.catalog.count)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(NS.text4)
            Spacer()
            Button {
                CommandPaletteManager.shared.isPresented = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "command")
                        .font(.system(size: 9))
                    Text("K · Quick Actions")
                        .font(.system(size: 10, design: .monospaced))
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .foregroundStyle(NS.text3)
                .background(NS.bg2)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(NS.border))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .help("Open Command Palette (⌘K)")
            Button {
                StatusBoardManager.shared.isPresented = true
            } label: {
                Label("Status Board", systemImage: "tv")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Full-screen ambient display (⌘⇧B)")
            ThemePicker()
            if editing {
                Button("Reset Layout") { layout.reset() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(NS.text2)
            }
            Toggle(isOn: $editing) {
                Label("Edit", systemImage: "pencil")
                    .font(.system(size: 11))
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .tint(NS.amber)
            Button { showAddSheet = true } label: {
                Label("Add Tools", systemImage: "plus")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(NS.amber)
        }
        .padding(.horizontal, 2)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.dashed")
                .font(.system(size: 28))
                .foregroundStyle(NS.text4)
            Text("No tools pinned")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(NS.text2)
            Text("Click + Add Tools to pin tools from the sidebar onto the Dashboard.")
                .font(.system(size: 11))
                .foregroundStyle(NS.text3)
                .multilineTextAlignment(.center)
            Button("Add Tools") { showAddSheet = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .tint(NS.amber)
                .padding(.top, 4)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background(NS.bg2)
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(NS.border, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

}

// MARK: - Sparkline

struct SparklineView: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            if values.count > 1 {
                let hi    = values.max() ?? 1
                let lo    = values.min() ?? 0
                let range = Swift.max(hi - lo, 0.001)
                let w     = geo.size.width / CGFloat(values.count - 1)
                let h     = geo.size.height

                Path { path in
                    for (i, v) in values.enumerated() {
                        let x = CGFloat(i) * w
                        let y = h - CGFloat((v - lo) / range) * h
                        if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

struct MiniSparkline: View {
    let values: [Double]
    let color: Color
    /// How to draw this series under an e-ink theme. nil = like any theme.
    var ink: InkSeries? = nil
    @ObservedObject private var themeMgr = ThemeManager.shared

    var body: some View {
        GeometryReader { geo in
            if values.count > 1 {
                let peak = Swift.max(values.max() ?? 1, 0.001)
                let w    = geo.size.width / CGFloat(values.count - 1)
                let h    = geo.size.height
                let points = values.enumerated().map { i, v in
                    CGPoint(x: CGFloat(i) * w, y: h - CGFloat(v / peak) * h * 0.9)
                }
                let area = Path { path in
                    path.move(to: CGPoint(x: 0, y: h))
                    points.forEach { path.addLine(to: $0) }
                    path.addLine(to: CGPoint(x: geo.size.width, y: h))
                    path.closeSubpath()
                }
                let line = Path { path in
                    path.move(to: points[0])
                    points.dropFirst().forEach { path.addLine(to: $0) }
                }

                let inkColor = themeMgr.current.inkColors ? color : NS.text1

                ZStack(alignment: .bottom) {
                    switch themeMgr.current.inkCues ? ink : nil {
                    case .primary:
                        // Solid ink line over diagonal hatching
                        Path { p in
                            var x: CGFloat = -h
                            while x < geo.size.width {
                                p.move(to: CGPoint(x: x, y: h))
                                p.addLine(to: CGPoint(x: x + h, y: 0))
                                x += 4
                            }
                        }
                        .stroke(inkColor.opacity(0.45), lineWidth: 0.7)
                        .mask(area)
                        line.stroke(inkColor, lineWidth: 1.5)
                    case .secondary:
                        // Dashed ink line, no fill
                        line.stroke(inkColor, style: StrokeStyle(lineWidth: 1.3, dash: [4, 3]))
                    case nil:
                        area.fill(color.opacity(0.08))
                        line.stroke(color, lineWidth: 1.5)
                    }
                }
            }
        }
    }
}

// MARK: - Bandwidth Dashboard Monitor (lightweight, for dashboard only)

final class BandwidthDashMonitor: ObservableObject {
    @Published var rxRateStr = "0 B/s"
    @Published var txRateStr = "0 B/s"
    @Published var rxHistory: [Double] = Array(repeating: 0, count: 30)
    @Published var txHistory: [Double] = Array(repeating: 0, count: 30)
    @Published var isRunning = false

    private var timer: Timer?
    private var lastRx: UInt64 = 0
    private var lastTx: UInt64 = 0
    private var lastTime = Date()

    func start() {
        guard !isRunning else { return }
        isRunning = true
        (lastRx, lastTx) = getBytes()
        lastTime = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.sample()
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil; isRunning = false
    }

    private func sample() {
        let now = Date()
        let (rx, tx) = getBytes()
        let elapsed = now.timeIntervalSince(lastTime)
        guard elapsed > 0 else { return }

        // Guard against counter wrap/reset
        let rxRate = rx >= lastRx ? Double(rx - lastRx) / elapsed : 0
        let txRate = tx >= lastTx ? Double(tx - lastTx) / elapsed : 0

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.rxRateStr = self.formatRate(rxRate)
            self.txRateStr = self.formatRate(txRate)
            self.rxHistory.append(rxRate); if self.rxHistory.count > 30 { self.rxHistory.removeFirst() }
            self.txHistory.append(txRate); if self.txHistory.count > 30 { self.txHistory.removeFirst() }
        }

        lastRx = rx; lastTx = tx; lastTime = now
    }

    private func getBytes() -> (UInt64, UInt64) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return (0, 0) }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let ifa = ptr {
            let name = String(cString: ifa.pointee.ifa_name)
            if name == "en0",
               let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_LINK),
               let data = ifa.pointee.ifa_data {
                let d = data.assumingMemoryBound(to: if_data.self).pointee
                return (UInt64(d.ifi_ibytes), UInt64(d.ifi_obytes))
            }
            ptr = ifa.pointee.ifa_next
        }
        return (0, 0)
    }

    private func formatRate(_ bps: Double) -> String {
        if bps < 1024 { return String(format: "%.0f B/s", bps) }
        if bps < 1024*1024 { return String(format: "%.1f KB/s", bps/1024) }
        return String(format: "%.2f MB/s", bps/1024/1024)
    }
}

// MARK: - View Extension: placeholder

extension View {
    func placeholder<Content: View>(when shouldShow: Bool, @ViewBuilder placeholder: () -> Content) -> some View {
        ZStack(alignment: .leading) {
            if shouldShow { placeholder() }
            self
        }
    }
}

#Preview {
    ContentView()
}
