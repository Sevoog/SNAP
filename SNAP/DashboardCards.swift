// DashboardCards.swift
// SNAP — Customizable Dashboard (v1.5.0)
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian. All rights reserved.
//
// Lets the user pin tools onto the Dashboard as cards. Three buckets:
//   Functional — full mini form + results inline (Ping, Lookup, Subnet, BGP, Port Scan)
//   Live       — auto-refreshing snapshot (Bandwidth, Wi-Fi, Alerts)
//   Launcher   — tile that opens the full tab (Network Map, Packet Capture, etc.)
//
// Layout is persisted to UserDefaults. The hero (ConnectionSummaryCard) is fixed.

import SwiftUI
import Network
import Darwin
import CoreWLAN
import UniformTypeIdentifiers

// MARK: - Card kind

enum DashCardKind: String {
    case functional, live, launcher

    var label: String {
        switch self {
        case .functional: "FUNCTIONAL"
        case .live:       "LIVE"
        case .launcher:   "LAUNCHER"
        }
    }

    var color: Color {
        switch self {
        case .functional: NS.green
        case .live:       NS.blue
        case .launcher:   NS.purple
        }
    }
}

// MARK: - Catalog

struct DashCardSpec: Identifiable, Hashable {
    let id: SNAPTab
    let title: String
    let icon: String
    let kind: DashCardKind
    let category: String   // "Diagnostics" / "Tools" / "Monitoring" / "Advanced"
    let desc: String

    static let catalog: [DashCardSpec] = [
        // Diagnostics — functional
        .init(id: .ping,           title: "Ping",           icon: "dot.radiowaves.left.and.right",
              kind: .functional, category: "Diagnostics", desc: "Quick pings against a target host"),
        .init(id: .lookup,         title: "DNS Lookup",     icon: "magnifyingglass",
              kind: .functional, category: "Diagnostics", desc: "Resolve a hostname (A / AAAA)"),
        .init(id: .portScan,       title: "Port Scan",      icon: "circle.grid.3x3",
              kind: .functional, category: "Diagnostics", desc: "Probe common ports"),
        .init(id: .traceroute,     title: "Traceroute",     icon: "arrow.up.right.circle",
              kind: .functional, category: "Diagnostics", desc: "Hop-by-hop path discovery"),
        .init(id: .geoIP,          title: "GeoIP",          icon: "mappin.and.ellipse",
              kind: .functional, category: "Diagnostics", desc: "Country / city / ASN for an IP"),
        // Diagnostics — launcher
        .init(id: .mtuDiscovery,   title: "MTU Discovery",  icon: "ruler",
              kind: .launcher,   category: "Diagnostics", desc: "Find the path MTU with DF binary search"),
        .init(id: .mtr,            title: "MTR",            icon: "chart.line.uptrend.xyaxis",
              kind: .launcher,   category: "Diagnostics", desc: "Traceroute + continuous per-hop ping"),

        // Tools — functional
        .init(id: .subnet,         title: "Subnet Calc",    icon: "number",
              kind: .functional, category: "Tools",       desc: "CIDR / netmask math"),
        .init(id: .bgp,            title: "BGP/ASN",        icon: "globe.americas",
              kind: .functional, category: "Tools",       desc: "AS lookup via Team Cymru"),
        .init(id: .whois,          title: "Whois",          icon: "info.bubble",
              kind: .functional, category: "Tools",       desc: "Domain registration lookup"),
        .init(id: .http,           title: "HTTP Probe",     icon: "globe",
              kind: .functional, category: "Tools",       desc: "Send a request, see status + timing"),
        .init(id: .wakeOnLAN,      title: "Wake-on-LAN",    icon: "bolt.fill",
              kind: .functional, category: "Tools",       desc: "Send a magic packet to a MAC"),
        // Tools — launcher
        .init(id: .ssl,            title: "SSL/TLS",        icon: "lock.shield",
              kind: .launcher,   category: "Tools",       desc: "Cert chain, ciphers, grade"),

        // Monitoring (live)
        .init(id: .bandwidth,      title: "Bandwidth",      icon: "chart.line.uptrend.xyaxis",
              kind: .live,       category: "Monitoring",  desc: "Live RX/TX + sparkline"),
        .init(id: .wifi,           title: "Wi-Fi",          icon: "wifi",
              kind: .live,       category: "Monitoring",  desc: "Current SSID, channel, RSSI"),
        // Alerts re-uses the bandwidth tab as its destination (it's owned by AlertManager).
        .init(id: .interfaceStats, title: "Recent Alerts",  icon: "bell.fill",
              kind: .live,       category: "Monitoring",  desc: "Threshold alert events"),
        // Monitoring — launcher
        .init(id: .syslog,         title: "Syslog",         icon: "doc.text.below.ecg",
              kind: .launcher,   category: "Monitoring",  desc: "UDP syslog receiver"),

        // Advanced (launchers)
        .init(id: .networkMap,     title: "Network Map",    icon: "circle.hexagongrid.fill",
              kind: .launcher,   category: "Advanced",    desc: "Topology of devices on the LAN"),
        .init(id: .packetCapture,  title: "Packet Capture", icon: "doc.text.magnifyingglass",
              kind: .launcher,   category: "Advanced",    desc: "tcpdump-style inspector"),
        .init(id: .bulkDiscovery,  title: "Bulk Discovery", icon: "square.grid.3x3.fill",
              kind: .launcher,   category: "Advanced",    desc: "CIDR-wide asset inventory"),
        .init(id: .unifi,          title: "UniFi",          icon: "circle.dashed",
              kind: .launcher,   category: "Advanced",    desc: "Controller device list"),
        .init(id: .snmp,           title: "SNMP",           icon: "antenna.radiowaves.left.and.right",
              kind: .launcher,   category: "Advanced",    desc: "v2c query tool"),
        .init(id: .speedTest,      title: "Speed Test",     icon: "speedometer",
              kind: .launcher,   category: "Monitoring",  desc: "Last result + run again"),
        .init(id: .connections,    title: "Connections",    icon: "arrow.left.arrow.right",
              kind: .launcher,   category: "Monitoring",  desc: "Active TCP/UDP sockets"),
    ]

    static func spec(for tab: SNAPTab) -> DashCardSpec? {
        catalog.first { $0.id == tab }
    }
}

// MARK: - Layout (persisted to UserDefaults)

@MainActor
final class DashboardLayout: ObservableObject {
    static let shared = DashboardLayout()
    private let key = "com.bardaklabs.snap.dashboardLayout.v1"

    @Published var pinned: [SNAPTab] = []

    static let defaultLayout: [SNAPTab] = [
        .bandwidth, .wifi, .interfaceStats, .networkMap, .speedTest
    ]

    private init() { load() }

    func load() {
        if let raw = UserDefaults.standard.array(forKey: key) as? [String], !raw.isEmpty {
            pinned = raw.compactMap { SNAPTab(rawValue: $0) }
                        .filter { DashCardSpec.spec(for: $0) != nil }
        } else {
            pinned = Self.defaultLayout
        }
    }

    private func save() {
        UserDefaults.standard.set(pinned.map { $0.rawValue }, forKey: key)
    }

    func add(_ tab: SNAPTab) {
        guard !pinned.contains(tab), DashCardSpec.spec(for: tab) != nil else { return }
        pinned.append(tab); save()
    }

    func remove(_ tab: SNAPTab) {
        pinned.removeAll { $0 == tab }; save()
    }

    func move(_ tab: SNAPTab, to targetIdx: Int) {
        guard let fromIdx = pinned.firstIndex(of: tab) else { return }
        let bounded = max(0, min(targetIdx, pinned.count - 1))
        guard fromIdx != bounded else { return }
        let item = pinned.remove(at: fromIdx)
        pinned.insert(item, at: bounded)
        save()
    }

    func reset() {
        pinned = Self.defaultLayout; save()
    }

    func isPinned(_ tab: SNAPTab) -> Bool { pinned.contains(tab) }
}

// MARK: - Card chrome

struct DashCardChrome<Content: View>: View {
    let spec: DashCardSpec
    let editing: Bool
    let onRemove: () -> Void
    let content: () -> Content
    @ObservedObject private var themeMgr = ThemeManager.shared

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack(spacing: 7) {
                    Image(systemName: spec.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(NS.text2)
                        .frame(width: 16)
                    Text(spec.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(NS.text1)
                    Spacer()
                    if !editing {
                        HStack(spacing: 5) {
                            if spec.kind == .live { LivePulse() }
                            Text(spec.kind.label)
                                .font(.system(size: 8, weight: .bold))
                                .tracking(0.4)
                                .foregroundStyle(spec.kind.color)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)

                content()
                    .padding(.horizontal, 12)
                    .padding(.bottom, 11)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(NS.bg2)
            .overlay(
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(editing ? NS.amber.opacity(0.7) : NS.border, style: StrokeStyle(lineWidth: 1, dash: editing ? [4, 3] : []))
            )
            .clipShape(RoundedRectangle(cornerRadius: 11))

            if editing {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(NS.red))
                }
                .buttonStyle(.plain)
                .padding(7)
                .help("Remove from Dashboard")
            }
        }
    }
}

private struct LivePulse: View {
    @State private var on = false
    var body: some View {
        Circle()
            .fill(NS.green)
            .frame(width: 6, height: 6)
            .opacity(on ? 1.0 : 0.35)
            .scaleEffect(on ? 1.0 : 0.85)
            .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

// MARK: - Card body builder (dispatches by spec)

struct DashCardBody: View {
    let spec: DashCardSpec
    @Binding var selectedTab: SNAPTab
    let bwMonitor: BandwidthDashMonitor
    let mapModel: NetworkMapModel
    @ObservedObject private var themeMgr = ThemeManager.shared

    var body: some View {
        switch spec.id {
        // Functional
        case .ping:           PingDashCard()
        case .lookup:         LookupDashCard()
        case .portScan:       PortScanDashCard()
        case .subnet:         SubnetDashCard()
        case .bgp:            BGPDashCard()
        case .traceroute:     TracerouteDashCard()
        case .geoIP:          GeoIPDashCard()
        case .whois:          WhoisDashCard()
        case .http:           HTTPDashCard()
        case .wakeOnLAN:      WoLDashCard()

        // Live
        case .bandwidth:      BandwidthDashCard(monitor: bwMonitor, selectedTab: $selectedTab)
        case .wifi:           WiFiDashCard(selectedTab: $selectedTab)
        case .interfaceStats: AlertsDashCard(selectedTab: $selectedTab)

        // Launchers
        case .networkMap:     LauncherCardBody(spec: spec, selectedTab: $selectedTab) {
                                  NetworkMapPreview(model: mapModel)
                              }
        case .packetCapture:  LauncherCardBody(spec: spec, selectedTab: $selectedTab) {
                                  LauncherTagline("Capture and inspect live packets")
                              }
        case .bulkDiscovery:  LauncherCardBody(spec: spec, selectedTab: $selectedTab) {
                                  LauncherTagline("Scan a subnet and inventory every host")
                              }
        case .unifi:          LauncherCardBody(spec: spec, selectedTab: $selectedTab) {
                                  LauncherTagline("Read controller device list")
                              }
        case .snmp:           LauncherCardBody(spec: spec, selectedTab: $selectedTab) {
                                  LauncherTagline("Walk system + interfaces via SNMP v2c")
                              }
        case .ssl:            LauncherCardBody(spec: spec, selectedTab: $selectedTab) {
                                  LauncherTagline("TLS handshake, cert chain, cipher grade")
                              }
        case .mtuDiscovery:   LauncherCardBody(spec: spec, selectedTab: $selectedTab) {
                                  LauncherTagline("Find path MTU via DF-bit binary search")
                              }
        case .mtr:            LauncherCardBody(spec: spec, selectedTab: $selectedTab) {
                                  LauncherTagline("Traceroute + continuous per-hop ping")
                              }
        case .syslog:         LauncherCardBody(spec: spec, selectedTab: $selectedTab) {
                                  LauncherTagline("UDP syslog receiver — open to start")
                              }
        case .speedTest:      SpeedTestDashCard(selectedTab: $selectedTab)
        case .connections:    LauncherCardBody(spec: spec, selectedTab: $selectedTab) {
                                  LauncherTagline("Live TCP/UDP socket table")
                              }
        default:              Text("—").foregroundStyle(NS.text3)
        }
    }
}

// MARK: - Launcher helpers

private struct LauncherCardBody<Content: View>: View {
    let spec: DashCardSpec
    @Binding var selectedTab: SNAPTab
    let content: () -> Content
    @ObservedObject private var themeMgr = ThemeManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Spacer()
                Text("Open \(spec.title) ›")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.4)
                    .foregroundStyle(NS.amber)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { selectedTab = spec.id }
    }
}

private struct LauncherTagline: View {
    let text: String
    @ObservedObject private var themeMgr = ThemeManager.shared
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(NS.text3)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct NetworkMapPreview: View {
    @ObservedObject var model: NetworkMapModel
    @ObservedObject private var themeMgr = ThemeManager.shared
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(NS.bg3)
                    .frame(width: 70, height: 44)
                Image(systemName: "circle.hexagongrid.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(NS.purple.opacity(0.85))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(model.devices.count) devices")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(NS.text1)
                Text("Last scan persisted")
                    .font(.system(size: 10))
                    .foregroundStyle(NS.text3)
            }
            Spacer()
        }
    }
}

// MARK: - Add Tools sheet

struct AddToolsSheet: View {
    @ObservedObject var layout: DashboardLayout
    @Environment(\.dismiss) private var dismiss

    private var grouped: [(String, [DashCardSpec])] {
        let cats = ["Diagnostics", "Tools", "Monitoring", "Advanced"]
        return cats.map { c in (c, DashCardSpec.catalog.filter { $0.category == c }) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add tools to Dashboard")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(NS.text3)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(NS.bg0)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(NS.border), alignment: .bottom)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(grouped, id: \.0) { (cat, specs) in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(cat.uppercased())
                                .font(.system(size: 10, weight: .bold))
                                .tracking(0.5)
                                .foregroundStyle(NS.text3)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 8)], spacing: 8) {
                                ForEach(specs) { spec in
                                    AddToolRow(spec: spec, added: layout.isPinned(spec.id)) {
                                        if !layout.isPinned(spec.id) { layout.add(spec.id) }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 680, height: 520)
        .background(NS.bg1)
    }
}

private struct AddToolRow: View {
    let spec: DashCardSpec
    let added: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: spec.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(NS.text2)
                    .frame(width: 22, height: 22)
                    .background(NS.bg3)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                VStack(alignment: .leading, spacing: 1) {
                    Text(spec.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(NS.text1)
                    Text(spec.desc).font(.system(size: 10)).foregroundStyle(NS.text3).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(spec.kind.label)
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.3)
                    .foregroundStyle(spec.kind.color)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(spec.kind.color.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                if added {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(NS.green)
                }
            }
            .padding(10)
            .background(NS.bg3)
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(NS.border))
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .opacity(added ? 0.55 : 1.0)
        .help(added ? "Already on Dashboard" : "Add to Dashboard")
    }
}

// MARK: - Functional card: Ping

private struct PingDashCard: View {
    @State private var host = "1.1.1.1"
    @State private var lines: [(seq: Int, ms: Double?)] = []
    @State private var summary = "—"
    @State private var running = false
    @State private var process: Process?
    @ObservedObject private var themeMgr = ThemeManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                TextField("hostname or IP", text: $host)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(NS.bg3)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(NS.border))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .onSubmit { if !running { start() } else { stop() } }
                HistoryMenuButton(key: .ping) { host = $0 }
                Button(running ? "Stop" : "Ping") { running ? stop() : start() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .tint(NS.amber)
            }
            Text(summary)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(NS.text3)
            VStack(alignment: .leading, spacing: 1) {
                ForEach(lines.suffix(5), id: \.seq) { l in
                    HStack(spacing: 6) {
                        Image(systemName: l.ms == nil ? "xmark" : "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(l.ms == nil ? NS.red : NS.green)
                            .frame(width: 8)
                        Text(verbatim: "seq \(l.seq)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(NS.text3)
                        if let ms = l.ms {
                            Text(String(format: "%.1f ms", ms))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(NS.text2)
                        } else {
                            Text("timeout").font(.system(size: 9)).foregroundStyle(NS.red.opacity(0.85))
                        }
                    }
                }
                if lines.isEmpty {
                    Text("No samples yet.")
                        .font(.system(size: 10))
                        .foregroundStyle(NS.text4)
                        .padding(.top, 2)
                }
            }
        }
    }

    private func start() {
        let target = host.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return }
        ToolHistory.shared.add(.ping, target)
        lines.removeAll()
        summary = "running…"
        running = true
        let p = Process()
        p.launchPath = "/sbin/ping"
        p.arguments = ["-c", "5", "-W", "1500", target]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let handle = pipe.fileHandleForReading

        var buffer = ""
        var seq = 0
        var rtts: [Double] = []
        var lost = 0

        handle.readabilityHandler = { fh in
            let data = fh.availableData
            if data.isEmpty { return }
            buffer += String(data: data, encoding: .utf8) ?? ""
            while let nl = buffer.firstIndex(of: "\n") {
                let line = String(buffer[..<nl])
                buffer.removeSubrange(...nl)
                if let rtt = Self.parseRTT(line) {
                    seq += 1; rtts.append(rtt)
                    DispatchQueue.main.async {
                        lines.append((seq: seq, ms: rtt))
                    }
                } else if line.contains("Request timeout") {
                    seq += 1; lost += 1
                    DispatchQueue.main.async {
                        lines.append((seq: seq, ms: nil))
                    }
                }
            }
        }

        p.terminationHandler = { _ in
            handle.readabilityHandler = nil
            let avg = rtts.isEmpty ? 0 : rtts.reduce(0, +) / Double(rtts.count)
            let totalSent = max(seq, rtts.count + lost)
            let loss = totalSent == 0 ? 0 : Int(Double(lost) / Double(totalSent) * 100)
            DispatchQueue.main.async {
                summary = String(format: "sent %d  recv %d  loss %d%%  avg %.1f ms",
                                 totalSent, rtts.count, loss, avg)
                running = false
                process = nil
            }
        }

        do {
            try p.run()
            process = p
        } catch {
            summary = "failed to launch ping"; running = false
        }
    }

    private func stop() {
        process?.terminate()
        process = nil
        running = false
    }

    private static func parseRTT(_ line: String) -> Double? {
        // "64 bytes from 1.1.1.1: icmp_seq=0 ttl=58 time=11.834 ms"
        guard let r = line.range(of: "time=") else { return nil }
        let tail = line[r.upperBound...]
        let token = tail.split(separator: " ").first ?? ""
        return Double(token)
    }
}

// MARK: - Functional card: DNS Lookup

private struct LookupDashCard: View {
    @State private var host = "cloudflare.com"
    @State private var rtype = "A"
    @State private var rows: [(String, String)] = []
    @State private var note = ""
    @State private var running = false
    @ObservedObject private var themeMgr = ThemeManager.shared

    private let types = ["A", "AAAA"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                TextField("domain", text: $host)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(NS.bg3)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(NS.border))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .onSubmit { resolve() }
                Picker("", selection: $rtype) {
                    ForEach(types, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 60)
                HistoryMenuButton(key: .lookup) { host = $0 }
                Button(running ? "…" : "Resolve") { resolve() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .tint(NS.amber)
                    .disabled(running)
            }
            if !note.isEmpty {
                Text(note)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(NS.text3)
            }
            VStack(alignment: .leading, spacing: 1) {
                ForEach(rows.prefix(6), id: \.0) { (typ, val) in
                    HStack(spacing: 6) {
                        Text(typ)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(NS.blue)
                            .frame(width: 32, alignment: .leading)
                        Text(val)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(NS.text2)
                    }
                }
                if rows.isEmpty && note.isEmpty {
                    Text("No results yet.")
                        .font(.system(size: 10))
                        .foregroundStyle(NS.text4)
                }
            }
        }
    }

    private func resolve() {
        let target = host.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return }
        ToolHistory.shared.add(.lookup, target)
        rows.removeAll(); note = ""; running = true
        let want = rtype
        DispatchQueue.global(qos: .userInitiated).async {
            var results: [(String, String)] = []
            var hints = addrinfo(ai_flags: 0,
                                 ai_family: want == "AAAA" ? AF_INET6 : AF_INET,
                                 ai_socktype: SOCK_STREAM,
                                 ai_protocol: IPPROTO_TCP,
                                 ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
            var info: UnsafeMutablePointer<addrinfo>?
            let rv = getaddrinfo(target, nil, &hints, &info)
            defer { if info != nil { freeaddrinfo(info) } }
            if rv == 0, var node = info {
                while true {
                    var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let n = getnameinfo(node.pointee.ai_addr, node.pointee.ai_addrlen,
                                        &buf, socklen_t(buf.count),
                                        nil, 0, NI_NUMERICHOST)
                    if n == 0 {
                        let addr = String(cString: buf)
                        results.append((want, addr))
                    }
                    if let nxt = node.pointee.ai_next { node = nxt } else { break }
                }
            }
            DispatchQueue.main.async {
                if results.isEmpty {
                    note = "no \(want) records"
                }
                // dedup
                var seen = Set<String>()
                rows = results.filter { seen.insert($0.1).inserted }
                running = false
            }
        }
    }
}

// MARK: - Functional card: Port Scan

private struct PortScanDashCard: View {
    @State private var host = "192.168.1.1"
    @State private var results: [(Int, Bool)] = []
    @State private var running = false
    @ObservedObject private var themeMgr = ThemeManager.shared
    private let ports = [22, 80, 443, 53, 161, 8080, 8443]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                TextField("host", text: $host)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(NS.bg3)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(NS.border))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .onSubmit { scan() }
                HistoryMenuButton(key: .portScan) { host = $0 }
                Button(running ? "…" : "Scan") { scan() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .tint(NS.amber)
                    .disabled(running)
            }
            Text("Common ports: 22 / 80 / 443 / 53 / 161 / 8080 / 8443")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(NS.text3)
            VStack(alignment: .leading, spacing: 1) {
                ForEach(results, id: \.0) { (port, open) in
                    HStack(spacing: 6) {
                        Circle().fill(open ? NS.green : NS.text4)
                            .frame(width: 6, height: 6)
                        Text(verbatim: "\(port)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(open ? NS.text1 : NS.text4)
                            .frame(width: 36, alignment: .leading)
                        Text(open ? "open" : "closed/filtered")
                            .font(.system(size: 9))
                            .foregroundStyle(open ? NS.green : NS.text4)
                    }
                }
                if results.isEmpty {
                    Text("Idle.").font(.system(size: 10)).foregroundStyle(NS.text4)
                }
            }
        }
    }

    private func scan() {
        let target = host.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return }
        ToolHistory.shared.add(.portScan, target)
        running = true; results.removeAll()
        let endpoints = ports.map { ($0, NWEndpoint.Host(target)) }
        var done = 0
        for (port, h) in endpoints {
            let conn = NWConnection(host: h, port: NWEndpoint.Port(integerLiteral: UInt16(port)), using: .tcp)
            var resolved = false
            let lock = NSLock()
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + 0.8)
            timer.setEventHandler {
                lock.lock(); let alreadyDone = resolved; if !alreadyDone { resolved = true }
                lock.unlock()
                if !alreadyDone {
                    conn.cancel()
                    DispatchQueue.main.async {
                        results.append((port, false)); results.sort { $0.0 < $1.0 }
                        done += 1; if done == endpoints.count { running = false }
                    }
                }
                timer.cancel()
            }
            timer.resume()
            conn.stateUpdateHandler = { st in
                lock.lock(); let already = resolved
                lock.unlock()
                switch st {
                case .ready:
                    if !already {
                        lock.lock(); resolved = true; lock.unlock()
                        timer.cancel()
                        conn.cancel()
                        DispatchQueue.main.async {
                            results.append((port, true)); results.sort { $0.0 < $1.0 }
                            done += 1; if done == endpoints.count { running = false }
                        }
                    }
                case .failed, .cancelled:
                    if !already {
                        lock.lock(); resolved = true; lock.unlock()
                        timer.cancel()
                        DispatchQueue.main.async {
                            results.append((port, false)); results.sort { $0.0 < $1.0 }
                            done += 1; if done == endpoints.count { running = false }
                        }
                    }
                default: break
                }
            }
            conn.start(queue: .global())
        }
    }
}

// MARK: - Functional card: Subnet Calc

private struct SubnetDashCard: View {
    @State private var input = "192.168.1.0/24"
    @ObservedObject private var themeMgr = ThemeManager.shared

    var body: some View {
        let info = Self.compute(input)
        VStack(alignment: .leading, spacing: 8) {
            TextField("IP/CIDR", text: $input)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(NS.bg3)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(NS.border))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            if let i = info {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                    row("Network", i.network)
                    row("Mask",    i.mask)
                    row("Broadcast", i.broadcast)
                    row("Hosts",  i.hosts)
                }
            } else {
                Text("Enter an IPv4 address with /CIDR prefix.")
                    .font(.system(size: 10)).foregroundStyle(NS.text4)
            }
        }
    }

    @ViewBuilder private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).font(.system(size: 10)).foregroundStyle(NS.text3)
            Text(v).font(.system(size: 10, design: .monospaced)).foregroundStyle(NS.text1)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    struct Info { let network, mask, broadcast, hosts: String }

    static func compute(_ cidr: String) -> Info? {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2,
              let prefix = Int(parts[1]), (0...32).contains(prefix) else { return nil }
        let octets = parts[0].split(separator: ".").compactMap { UInt32($0) }
        guard octets.count == 4, octets.allSatisfy({ $0 < 256 }) else { return nil }
        let ip = (octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3]
        let mask: UInt32 = prefix == 0 ? 0 : (UInt32.max << (32 - prefix))
        let network = ip & mask
        let broadcast = network | ~mask
        let total = prefix == 32 ? 1 : (prefix == 31 ? 2 : Int(broadcast - network + 1))
        let hostCount = prefix >= 31 ? total : max(0, total - 2)
        return Info(
            network: fmt(network),
            mask: fmt(mask),
            broadcast: prefix >= 31 ? "—" : fmt(broadcast),
            hosts: "\(hostCount)"
        )
    }

    static func fmt(_ ip: UInt32) -> String {
        "\((ip >> 24) & 0xff).\((ip >> 16) & 0xff).\((ip >> 8) & 0xff).\(ip & 0xff)"
    }
}

// MARK: - Functional card: BGP/ASN

private struct BGPDashCard: View {
    @StateObject private var model = BGPLookupModel()
    @ObservedObject private var themeMgr = ThemeManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                TextField("IP", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(NS.bg3)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(NS.border))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .onSubmit { runBGPLookup() }
                HistoryMenuButton(key: .bgp) { model.query = $0 }
                Button(model.isRunning ? "…" : "Lookup") { runBGPLookup() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .tint(NS.amber)
                    .disabled(model.isRunning)
            }
            if let r = model.result {
                Text(verbatim: "AS\(r.asn)")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundStyle(NS.amber)
                Text(r.asName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(NS.text2)
                    .lineLimit(2)
                Text("\(r.prefix) · \(r.country.isEmpty ? "—" : r.country) · \(r.registry.isEmpty ? "—" : r.registry)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(NS.text3)
            } else if let err = model.errorMessage {
                Text(err).font(.system(size: 10)).foregroundStyle(NS.red)
            } else {
                Text("Enter an IPv4 address.")
                    .font(.system(size: 10)).foregroundStyle(NS.text4)
            }
        }
    }

    private func runBGPLookup() {
        let v = model.query.trimmingCharacters(in: .whitespaces)
        if !v.isEmpty { ToolHistory.shared.add(.bgp, v) }
        model.lookup()
    }
}

// MARK: - Live card: Bandwidth

private struct BandwidthDashCard: View {
    @ObservedObject var monitor: BandwidthDashMonitor
    @Binding var selectedTab: SNAPTab
    @ObservedObject private var themeMgr = ThemeManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 22) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("RX").font(.system(size: 9)).foregroundStyle(NS.text3)
                    Text(monitor.rxRateStr)
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .foregroundStyle(NS.green)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("TX").font(.system(size: 9)).foregroundStyle(NS.text3)
                    Text(monitor.txRateStr)
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .foregroundStyle(NS.blue)
                }
                Spacer()
                Button("Open ›") { selectedTab = .bandwidth }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .tint(NS.amber)
            }
            HStack(spacing: 0) {
                MiniSparkline(values: monitor.rxHistory, color: NS.green)
                MiniSparkline(values: monitor.txHistory, color: NS.blue)
            }
            .frame(height: 56)
        }
    }
}

// MARK: - Live card: Wi-Fi

private struct WiFiDashCard: View {
    @Binding var selectedTab: SNAPTab
    @State private var ssid = "—"
    @State private var rssi: Int = 0
    @State private var channel: String = "—"
    @State private var band: String = "—"
    @State private var timer: Timer?
    @ObservedObject private var themeMgr = ThemeManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(ssid)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Text("\(channel) · \(band)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(NS.text3)
            HStack(alignment: .bottom, spacing: 5) {
                Text(verbatim: rssi == 0 ? "—" : "\(rssi)")
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundStyle(rssiColor)
                Text("dBm")
                    .font(.system(size: 10))
                    .foregroundStyle(NS.text3)
                    .padding(.bottom, 4)
                Spacer()
                HStack(alignment: .bottom, spacing: 2) {
                    bar(height: 5,  on: rssi > -90)
                    bar(height: 8,  on: rssi > -75)
                    bar(height: 11, on: rssi > -65)
                    bar(height: 14, on: rssi > -55)
                }
                .padding(.bottom, 4)
            }
            .padding(.top, 2)
            HStack {
                Spacer()
                Button("Open ›") { selectedTab = .wifi }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .tint(NS.amber)
            }
        }
        .onAppear { refresh(); start() }
        .onDisappear { timer?.invalidate(); timer = nil }
    }

    private var rssiColor: Color {
        if rssi == 0 { return NS.text3 }
        if rssi > -60 { return NS.green }
        if rssi > -75 { return NS.amber }
        return NS.red
    }

    private func bar(height: CGFloat, on: Bool) -> some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(on ? NS.green : NS.text4)
            .frame(width: 6, height: height)
    }

    private func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            refresh()
        }
    }

    private func refresh() {
        DispatchQueue.global(qos: .utility).async {
            guard let i = CWWiFiClient.shared().interface() else {
                DispatchQueue.main.async { ssid = "Not associated" }
                return
            }
            let s = DemoMode.isActive ? DemoMode.ssid : (i.ssid() ?? "Hidden")
            let r = i.rssiValue()
            let ch = i.wlanChannel()?.channelNumber ?? 0
            let widthRaw = i.wlanChannel()?.channelWidth.rawValue ?? 0
            let widthLbl = ["20","40","80","160","320"][min(widthRaw, 4)]
            let bandLbl: String = {
                guard let cb = i.wlanChannel()?.channelBand else { return "Wi-Fi" }
                switch cb {
                case .band2GHz: return "2.4 GHz · \(widthLbl) MHz"
                case .band5GHz: return "5 GHz · \(widthLbl) MHz"
                case .band6GHz, .bandUnknown: return "6 GHz · \(widthLbl) MHz"
                @unknown default: return "Wi-Fi"
                }
            }()
            let chStr = "Ch \(ch)"
            DispatchQueue.main.async {
                ssid = s; rssi = r; channel = chStr; band = bandLbl
            }
        }
    }
}

// MARK: - Live card: Recent Alerts

private struct AlertsDashCard: View {
    @ObservedObject private var alerts = AlertManager.shared
    @ObservedObject private var themeMgr = ThemeManager.shared
    @Binding var selectedTab: SNAPTab

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if alerts.recentEvents.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(NS.green)
                    Text("No alerts")
                        .font(.system(size: 11))
                        .foregroundStyle(NS.text2)
                    Text("Bandwidth thresholds will surface here.")
                        .font(.system(size: 9))
                        .foregroundStyle(NS.text3)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            } else {
                ForEach(alerts.recentEvents.prefix(4)) { ev in
                    HStack(spacing: 6) {
                        Text(ev.date.formatted(date: .omitted, time: .standard))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(NS.text3)
                            .frame(width: 66, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ev.metric.label)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(NS.amber)
                            Text(String(format: "%.1f %@", ev.value, ev.metric.unit))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(NS.text2)
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("Open ›") { selectedTab = .bandwidth }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .tint(NS.amber)
                }
            }
        }
    }
}

// MARK: - Launcher card: Speed Test (compact with last result)

private struct SpeedTestDashCard: View {
    @ObservedObject private var history = SpeedTestHistoryStore.shared
    @ObservedObject private var themeMgr = ThemeManager.shared
    @Binding var selectedTab: SNAPTab

    var body: some View {
        VStack(alignment: .center, spacing: 4) {
            if let last = history.results.first {
                Text(String(format: "%.0f ↓", last.download))
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundStyle(NS.amber)
                Text(String(format: "%.0f ↑ Mbps · %.0f ms",
                            last.upload, last.ping))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(NS.text3)
            } else {
                Text("No result yet")
                    .font(.system(size: 11)).foregroundStyle(NS.text3)
                    .padding(.vertical, 6)
            }
            Button("Run ›") { selectedTab = .speedTest }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .tint(NS.amber)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { selectedTab = .speedTest }
    }
}

// MARK: - Functional card: Traceroute

private struct TracerouteDashCard: View {
    @State private var host = "github.com"
    @State private var hops: [String] = []
    @State private var summary = "—"
    @State private var running = false
    @State private var process: Process?
    @ObservedObject private var themeMgr = ThemeManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                TextField("hostname or IP", text: $host)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(NS.bg3)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(NS.border))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .onSubmit { running ? stop() : start() }
                HistoryMenuButton(key: .traceroute) { host = $0 }
                Button(running ? "Stop" : "Trace") { running ? stop() : start() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .tint(NS.amber)
            }
            Text(summary)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(NS.text3)
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(hops.prefix(6).enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(NS.text2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if hops.isEmpty && !running {
                    Text("No hops yet.")
                        .font(.system(size: 10))
                        .foregroundStyle(NS.text4)
                }
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        let target = host.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return }
        ToolHistory.shared.add(.traceroute, target)
        hops.removeAll(); summary = "tracing…"; running = true
        let p = Process()
        p.launchPath = "/usr/sbin/traceroute"
        p.arguments = ["-n", "-w", "1", "-q", "1", "-m", "12", target]
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        let handle = pipe.fileHandleForReading
        var buffer = ""
        handle.readabilityHandler = { fh in
            let data = fh.availableData
            if data.isEmpty { return }
            buffer += String(data: data, encoding: .utf8) ?? ""
            while let nl = buffer.firstIndex(of: "\n") {
                let line = String(buffer[..<nl]).trimmingCharacters(in: .whitespaces)
                buffer.removeSubrange(...nl)
                if line.isEmpty || line.hasPrefix("traceroute") { continue }
                DispatchQueue.main.async {
                    hops.append(line)
                    summary = "\(hops.count) hop\(hops.count == 1 ? "" : "s")"
                }
            }
        }
        p.terminationHandler = { _ in
            handle.readabilityHandler = nil
            DispatchQueue.main.async {
                running = false; process = nil
                if hops.isEmpty { summary = "no response" }
            }
        }
        do { try p.run(); process = p } catch { summary = "failed to launch"; running = false }
    }

    private func stop() {
        process?.terminate(); process = nil; running = false
    }
}

// MARK: - Functional card: GeoIP

private struct GeoIPDashCard: View {
    @State private var ip = "8.8.8.8"
    @State private var country = ""
    @State private var city = ""
    @State private var isp = ""
    @State private var asn = ""
    @State private var note = ""
    @State private var running = false
    @ObservedObject private var themeMgr = ThemeManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                TextField("IP address", text: $ip)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(NS.bg3)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(NS.border))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .onSubmit { lookup() }
                HistoryMenuButton(key: .geoIP) { ip = $0 }
                Button(running ? "…" : "Lookup") { lookup() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .tint(NS.amber)
                    .disabled(running)
            }
            if !country.isEmpty || !city.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: city.isEmpty ? country : "\(city), \(country)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(NS.text1)
                    if !isp.isEmpty {
                        Text(verbatim: isp).font(.system(size: 11)).foregroundStyle(NS.text2).lineLimit(1)
                    }
                    if !asn.isEmpty {
                        Text(verbatim: asn).font(.system(size: 10, design: .monospaced)).foregroundStyle(NS.text3)
                    }
                }
            } else if !note.isEmpty {
                Text(note).font(.system(size: 10)).foregroundStyle(NS.red)
            } else {
                Text("Enter a public IPv4 address.")
                    .font(.system(size: 10)).foregroundStyle(NS.text4)
            }
        }
    }

    private func lookup() {
        let target = ip.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty, let url = URL(string: "http://ip-api.com/json/\(target)?fields=status,message,country,city,isp,as") else { return }
        ToolHistory.shared.add(.geoIP, target)
        running = true; country = ""; city = ""; isp = ""; asn = ""; note = ""
        URLSession.shared.dataTask(with: url) { data, _, err in
            DispatchQueue.main.async {
                running = false
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    note = err?.localizedDescription ?? "no response"; return
                }
                if (json["status"] as? String) != "success" {
                    note = (json["message"] as? String) ?? "lookup failed"; return
                }
                country = (json["country"] as? String) ?? ""
                city    = (json["city"]    as? String) ?? ""
                isp     = (json["isp"]     as? String) ?? ""
                asn     = (json["as"]      as? String) ?? ""
            }
        }.resume()
    }
}

// MARK: - Functional card: Whois

private struct WhoisDashCard: View {
    @State private var domain = "apple.com"
    @State private var lines: [String] = []
    @State private var running = false
    @State private var process: Process?
    @ObservedObject private var themeMgr = ThemeManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                TextField("domain", text: $domain)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(NS.bg3)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(NS.border))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .onSubmit { lookup() }
                HistoryMenuButton(key: .whois) { domain = $0 }
                Button(running ? "…" : "Lookup") { lookup() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .tint(NS.amber)
                    .disabled(running)
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.prefix(6).enumerated()), id: \.offset) { _, l in
                    Text(verbatim: l)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(NS.text2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if lines.isEmpty && !running {
                    Text("Enter a domain.")
                        .font(.system(size: 10))
                        .foregroundStyle(NS.text4)
                }
            }
        }
        .onDisappear { process?.terminate(); process = nil }
    }

    private func lookup() {
        let target = domain.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return }
        ToolHistory.shared.add(.whois, target)
        lines.removeAll(); running = true
        let p = Process()
        p.launchPath = "/usr/bin/whois"
        p.arguments = [target]
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        let handle = pipe.fileHandleForReading
        let interesting = ["Registrar:", "Registrar URL:", "Updated Date:", "Creation Date:",
                           "Registry Expiry Date:", "Registrar Registration Expiration Date:",
                           "Name Server:", "Domain Status:"]
        var collected: [String] = []
        p.terminationHandler = { _ in
            // Drain remaining buffer first.
            let data = handle.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            for ln in text.split(separator: "\n") {
                let s = ln.trimmingCharacters(in: .whitespaces)
                if interesting.contains(where: { s.hasPrefix($0) }) {
                    collected.append(s)
                }
            }
            DispatchQueue.main.async {
                lines = collected.isEmpty ? ["No registrar fields parsed — open the Whois tab for raw output."] : collected
                running = false; process = nil
            }
        }
        do { try p.run(); process = p } catch {
            DispatchQueue.main.async {
                lines = ["failed to launch whois"]; running = false
            }
        }
    }
}

// MARK: - Functional card: HTTP Probe

private struct HTTPDashCard: View {
    @State private var url = "https://api.github.com"
    @State private var status = 0
    @State private var elapsedMs = 0.0
    @State private var bytes = 0
    @State private var note = ""
    @State private var running = false
    @ObservedObject private var themeMgr = ThemeManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                TextField("URL", text: $url)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(NS.bg3)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(NS.border))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .onSubmit { send() }
                HistoryMenuButton(key: .http) { url = $0 }
                Button(running ? "…" : "Send") { send() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .tint(NS.amber)
                    .disabled(running)
            }
            if status > 0 {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(verbatim: "\(status)")
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundStyle(statusColor)
                    Text(String(format: "%.0f ms · %@", elapsedMs, byteStr(bytes)))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(NS.text3)
                }
            } else if !note.isEmpty {
                Text(note).font(.system(size: 10)).foregroundStyle(NS.red).lineLimit(2)
            } else {
                Text("Enter a URL.")
                    .font(.system(size: 10)).foregroundStyle(NS.text4)
            }
        }
    }

    private var statusColor: Color {
        switch status {
        case 200..<300: NS.green
        case 300..<400: NS.amber
        case 400..<600: NS.red
        default: NS.text2
        }
    }

    private func byteStr(_ n: Int) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return String(format: "%.1f KB", Double(n) / 1024) }
        return String(format: "%.1f MB", Double(n) / 1024 / 1024)
    }

    private func send() {
        let target = url.trimmingCharacters(in: .whitespaces)
        guard let u = URL(string: target) else { note = "invalid URL"; return }
        ToolHistory.shared.add(.http, target)
        running = true; status = 0; note = ""
        let start = Date()
        URLSession.shared.dataTask(with: u) { data, response, err in
            let elapsed = Date().timeIntervalSince(start) * 1000
            DispatchQueue.main.async {
                running = false
                if let http = response as? HTTPURLResponse {
                    status = http.statusCode
                    bytes = data?.count ?? 0
                    elapsedMs = elapsed
                } else if let err = err {
                    note = err.localizedDescription
                }
            }
        }.resume()
    }
}

// MARK: - Functional card: Wake-on-LAN

private struct WoLDashCard: View {
    @State private var mac = ""
    @State private var note = ""
    @State private var success = false
    @ObservedObject private var themeMgr = ThemeManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("MAC (aa:bb:cc:dd:ee:ff)", text: $mac)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(NS.bg3)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(NS.border))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .onSubmit { send() }
            Button {
                send()
            } label: {
                Label("Send Magic Packet", systemImage: "bolt.fill")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(NS.amber)

            if !note.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(success ? NS.green : NS.red)
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundStyle(success ? NS.text2 : NS.red)
                }
            } else {
                Text("Broadcasts UDP/9 magic packet on the LAN.")
                    .font(.system(size: 10))
                    .foregroundStyle(NS.text4)
            }
        }
    }

    private func send() {
        let raw = mac.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "-", with: ":")
        let parts = raw.split(separator: ":")
        guard parts.count == 6,
              let bytes = parts.map({ UInt8($0, radix: 16) }) as? [UInt8?],
              bytes.allSatisfy({ $0 != nil })
        else { note = "Invalid MAC address"; success = false; return }

        let mac6 = bytes.compactMap { $0 }
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet.append(contentsOf: mac6) }

        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { note = "socket() failed"; success = false; return }
        var enable: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &enable,
                   socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(9).bigEndian
        addr.sin_addr.s_addr = INADDR_BROADCAST.bigEndian
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                packet.withUnsafeBytes { buf in
                    sendto(sock, buf.baseAddress, packet.count, 0,
                           sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        close(sock)
        if rc > 0 {
            success = true
            note = "Sent \(rc) bytes to 255.255.255.255:9"
        } else {
            success = false
            note = "sendto failed (\(errno))"
        }
    }
}

// MARK: - Drag-to-reorder

extension View {
    /// Attaches `.onDrag` + `.onDrop` only when Edit Mode is on. Outside Edit
    /// Mode, the drag gesture isn't installed at all — important because an
    /// always-present `.onDrag` intercepts mouse-down events before child
    /// TextFields can receive focus, breaking input on the dashboard cards.
    @ViewBuilder
    func draggableWhenEditing(_ editing: Bool,
                              tab: SNAPTab,
                              layout: DashboardLayout,
                              draggingTab: Binding<SNAPTab?>) -> some View {
        if editing {
            self
                .onDrag {
                    draggingTab.wrappedValue = tab
                    return NSItemProvider(object: tab.rawValue as NSString)
                }
                .onDrop(of: [.plainText], delegate:
                    CardReorderDropDelegate(target: tab,
                                            layout: layout,
                                            draggingTab: draggingTab))
        } else {
            self
        }
    }
}


/// Swaps the dragged card past the target card as soon as it enters the target's
/// hit area. The whole grid rearranges live; the drop event itself just clears
/// the drag state.
struct CardReorderDropDelegate: DropDelegate {
    let target: SNAPTab
    let layout: DashboardLayout
    @Binding var draggingTab: SNAPTab?

    func dropEntered(info: DropInfo) {
        guard let from = draggingTab, from != target else { return }
        guard let targetIdx = layout.pinned.firstIndex(of: target) else { return }
        layout.move(from, to: targetIdx)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingTab = nil
        return true
    }
}

// MARK: - Favorites strip (always visible above the grid when non-empty)

/// A horizontally-scrollable list of pinned hosts. Each item shows label,
/// host, status dot, and last RTT. Tap an item to navigate to Ping with
/// the host pre-filled; right-click for full host menu.
struct FavoritesStripView: View {
    @Binding var selectedTab: SNAPTab
    @ObservedObject private var favs = FavoritesManager.shared
    @ObservedObject private var themeMgr = ThemeManager.shared
    @State private var showAddPopover = false
    @State private var newHost = ""
    @State private var newLabel = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "star.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(NS.amber)
                Text("FAVORITES")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(NS.text3)
                Text(verbatim: "\(favs.items.count) of \(FavoritesManager.maxFavorites)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(NS.text4)
                Spacer()
                Button {
                    showAddPopover = true
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(NS.amber)
                .popover(isPresented: $showAddPopover, arrowEdge: .top) {
                    addPopover
                }
            }
            .padding(.horizontal, 2)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(favs.items) { fav in
                        favRow(fav)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.bottom, 2)
            }
        }
    }

    @ViewBuilder private func favRow(_ fav: Favorite) -> some View {
        let st = favs.status[fav.id]
        Button {
            ToolHandoff.shared.send(fav.host, to: .ping)
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(dotColor(st))
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: fav.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(NS.text1)
                        .lineLimit(1)
                    Text(verbatim: fav.host)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(NS.text3)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if let st, let ms = st.rttMs {
                    Text(verbatim: String(format: "%.0f ms", ms))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(rttColor(st))
                } else if st?.state == .bad {
                    Text("timeout")
                        .font(.system(size: 9))
                        .foregroundStyle(NS.red)
                } else {
                    Text("—")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(NS.text4)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(width: 230)
            .background(NS.bg2)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(NS.border))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help("Click to Ping · right-click for actions")
        .hostMenu(fav.host)
    }

    private func dotColor(_ st: FavoriteStatus?) -> Color {
        switch st?.state {
        case .ok:   return NS.green
        case .slow: return NS.amber
        case .bad:  return NS.red
        default:    return NS.text4
        }
    }
    private func rttColor(_ st: FavoriteStatus) -> Color {
        switch st.state {
        case .ok:   return NS.green
        case .slow: return NS.amber
        case .bad:  return NS.red
        default:    return NS.text3
        }
    }

    private var addPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add Favorite")
                .font(.system(size: 12, weight: .semibold))
            TextField("Label (e.g. Home router)", text: $newLabel)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
            TextField("Host or IP (e.g. 192.168.1.1)", text: $newHost)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .onSubmit { commit() }
            HStack {
                Spacer()
                Button("Cancel") { showAddPopover = false }
                    .controlSize(.small)
                Button("Add") { commit() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(NS.amber)
                    .disabled(newHost.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
    }

    private func commit() {
        let host = newHost.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        favs.add(label: newLabel.isEmpty ? nil : newLabel, host: host)
        newHost = ""; newLabel = ""
        showAddPopover = false
    }
}
