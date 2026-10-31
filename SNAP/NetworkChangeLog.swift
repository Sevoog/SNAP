// NetworkChangeLog.swift
// SNAP: Network change log (v1.5.8)
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md
//
// A timestamped list of changes to the Mac's network: connecting and
// disconnecting, Wi-Fi networks, the interface in use, its IPv4 address, the
// router, DNS servers, and VPN tunnels. It reads local state only (getifaddrs,
// the dynamic store, CoreWLAN) every 10 s and 3 s after macOS reports a path
// change, so it sends nothing over the network. The newest 500 entries are
// kept in Application Support/SNAP/network-changes.json.

import SwiftUI
import AppKit
import Network
import CoreWLAN
import Darwin

// MARK: - Snapshot

/// The Mac's network at one moment.
struct NetworkSnapshot: Equatable {
    /// The interface carrying the default route, e.g. "en0" or "utun4".
    var interface: String?
    /// That interface's IPv4 address.
    var address: String?
    var router: String?
    var dns: [String] = []
    /// The Wi-Fi network, while Wi-Fi has an address. Nil without Location access.
    var ssid: String?
    /// The Wi-Fi interface's name, e.g. "en0".
    var wifiInterface: String?
    /// VPN tunnels with an IPv4 address: name to address.
    var vpns: [String: String] = [:]

    var isConnected: Bool { router != nil || address != nil }

    static func current() -> NetworkSnapshot {
        let route = RouteInfo.defaultIPv4()
        var s = NetworkSnapshot(interface: route.interface, router: route.gateway, dns: DNSInfo.systemResolvers())
        let wifi = CWWiFiClient.shared().interface()
        s.wifiInterface = wifi?.interfaceName

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return s }
        defer { freeifaddrs(ifaddr) }
        var wifiHasAddress = false
        var ptr = ifaddr
        while let ifa = ptr {
            ptr = ifa.pointee.ifa_next
            guard let sa = ifa.pointee.ifa_addr, Int32(sa.pointee.sa_family) == AF_INET else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            var sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
            let ip = String(cString: buf)
            if name == s.interface, s.address == nil { s.address = ip }
            if name == s.wifiInterface { wifiHasAddress = true }
            if name.hasPrefix("utun"), ip != "127.0.0.1" { s.vpns[name] = ip }
        }
        if wifiHasAddress { s.ssid = wifi?.ssid() }
        return s
    }
}

// MARK: - Change

struct NetworkChange: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case started, connected, disconnected, wifi, interface, address, router, dns, vpnUp, vpnDown

        var title: String {
            switch self {
            case .started:      return "SNAP started"
            case .connected:    return "Connected"
            case .disconnected: return "Disconnected"
            case .wifi:         return "Wi-Fi"
            case .interface:    return "Interface"
            case .address:      return "IP address"
            case .router:       return "Router"
            case .dns:          return "DNS"
            case .vpnUp:        return "VPN up"
            case .vpnDown:      return "VPN down"
            }
        }

        var icon: String {
            switch self {
            case .started:      return "play.circle"
            case .connected:    return "checkmark.circle"
            case .disconnected: return "xmark.circle"
            case .wifi:         return "wifi"
            case .interface:    return "cable.connector"
            case .address:      return "number"
            case .router:       return "arrow.triangle.swap"
            case .dns:          return "person.crop.circle"
            case .vpnUp:        return "lock.shield"
            case .vpnDown:      return "lock.open"
            }
        }

        /// Losing the network or a VPN reads as a warning.
        var isWarning: Bool { self == .disconnected || self == .vpnDown }
    }

    var id = UUID()
    let date: Date
    let kind: Kind
    let text: String

    /// What changed between two snapshots, in reading order. With no earlier
    /// snapshot (SNAP just started), one entry describing where things stand.
    static func changes(from old: NetworkSnapshot?, to new: NetworkSnapshot) -> [(Kind, String)] {
        guard let old else {
            return [(.started, new.isConnected ? describe(new) : "Offline")]
        }
        // VPN entries first: a tunnel coming or going is usually why DNS changed.
        var out: [(Kind, String)] = []
        for name in new.vpns.keys.sorted() where old.vpns[name] != new.vpns[name] {
            out.append((.vpnUp, "\(name), \(new.vpns[name] ?? "")"))
        }
        for name in old.vpns.keys.sorted() where new.vpns[name] == nil {
            out.append((.vpnDown, name))
        }

        if old.isConnected && !new.isConnected {
            out.append((.disconnected, old.ssid.map { "Left Wi-Fi \(quoted($0))" } ?? "No network"))
        } else if !old.isConnected && new.isConnected {
            out.append((.connected, describe(new)))
        } else if new.isConnected {
            // A VPN that takes the default route changes the interface, address,
            // and router too; its own VPN entry below covers that.
            let tunnel = isTunnel(old.interface) || isTunnel(new.interface)
            if let a = old.ssid, let b = new.ssid, a != b {
                out.append((.wifi, "Switched to \(quoted(b)) (was \(quoted(a)))\(addressing(new))"))
            } else if !tunnel && old.interface != new.interface {
                out.append((.interface, "Now using \(describe(new)) (was \(label(old)))"))
            } else if !tunnel {
                if old.address != new.address {
                    out.append((.address, "\(new.address ?? "None") (was \(old.address ?? "none"))"))
                }
                if old.router != new.router {
                    out.append((.router, "\(new.router ?? "None") (was \(old.router ?? "none"))"))
                }
            }
            if old.dns != new.dns {
                out.append((.dns, "\(list(new.dns)) (was \(list(old.dns)))"))
            }
        }
        return out
    }

    private static func isTunnel(_ name: String?) -> Bool { name?.hasPrefix("utun") == true }
    private static func quoted(_ s: String) -> String { "\u{201C}\(s)\u{201D}" }
    private static func list(_ dns: [String]) -> String { dns.isEmpty ? "none" : dns.joined(separator: ", ") }

    /// "Wi-Fi “Home” (en0)", "Wi-Fi (en0)" without Location access, or "en5".
    private static func label(_ s: NetworkSnapshot) -> String {
        guard let name = s.interface else { return "no interface" }
        guard name == s.wifiInterface else { return name }
        return s.ssid.map { "Wi-Fi \(quoted($0)) (\(name))" } ?? "Wi-Fi (\(name))"
    }

    /// ": 192.168.1.20, router 192.168.1.1", or "" with neither.
    private static func addressing(_ s: NetworkSnapshot, lead: String = ": ") -> String {
        var parts: [String] = []
        if let a = s.address { parts.append(a) }
        if let r = s.router { parts.append("router \(r)") }
        return parts.isEmpty ? "" : lead + parts.joined(separator: ", ")
    }

    /// "Wi-Fi “Home” (en0), 192.168.1.20, router 192.168.1.1"
    private static func describe(_ s: NetworkSnapshot) -> String {
        label(s) + addressing(s, lead: ", ")
    }
}

// MARK: - Log

@MainActor
final class NetworkChangeLog: ObservableObject {
    /// The test host doesn't keep a file, so tests never touch the real log.
    static let shared = NetworkChangeLog(file: AppInfo.isRunningTests ? nil : defaultFile)
    static let limit = 500

    static var defaultFile: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("SNAP", isDirectory: true).appendingPathComponent("network-changes.json")
    }

    /// Newest first.
    @Published private(set) var entries: [NetworkChange] = []
    private var last: NetworkSnapshot?
    private let file: URL?

    private let queue = DispatchQueue(label: "snap.network-changes", qos: .utility)
    private var pathMonitor: NWPathMonitor?
    private var timer: Timer?
    private var pending: DispatchWorkItem?

    init(file: URL?) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            entries = (try? decoder.decode([NetworkChange].self, from: data)) ?? []
        }
    }

    func record(_ snapshot: NetworkSnapshot, at date: Date = Date()) {
        let found = NetworkChange.changes(from: last, to: snapshot)
        last = snapshot
        guard !found.isEmpty else { return }
        // Newest first overall; changes found together keep their reading order.
        entries.insert(contentsOf: found.map { NetworkChange(date: date, kind: $0.0, text: $0.1) }, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func save() {
        guard let file else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    // MARK: Watching

    /// Samples now, every 10 s, and 3 s after each path change (long enough
    /// for DHCP and DNS to settle, so one change isn't logged as several).
    func start() {
        guard pathMonitor == nil else { return }
        sample()
        let t = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.sampleSoon() }
        }
        monitor.start(queue: queue)
        pathMonitor = monitor
    }

    private func sampleSoon() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.sample() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func sample() {
        queue.async { [weak self] in
            let snapshot = NetworkSnapshot.current()
            DispatchQueue.main.async { self?.record(snapshot) }
        }
    }

    // MARK: Export

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    func exportText() -> String {
        var s = "SNAP network changes\n\n"
        for e in entries { s += "\(Self.stamp.string(from: e.date))\t\(e.kind.title)\t\(e.text)\n" }
        return s
    }

    func exportCSV() -> String {
        func field(_ v: String) -> String { "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var s = "time,event,details\n"
        for e in entries { s += "\(Self.stamp.string(from: e.date)),\(field(e.kind.title)),\(field(e.text))\n" }
        return s
    }

    func exportJSON() -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let rows = entries.map { ["time": ISO8601DateFormatter().string(from: $0.date), "event": $0.kind.rawValue, "details": $0.text] }
        return (try? encoder.encode(rows)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
}

// MARK: - Window

@MainActor
final class NetworkChangeLogWindow: NSObject, NSWindowDelegate {
    static let shared = NetworkChangeLogWindow()
    private var window: NSWindow?

    func open() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = window { w.makeKeyAndOrderFront(nil); return }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
                           styleMask: [.titled, .closable, .resizable, .miniaturizable],
                           backing: .buffered, defer: false)
        win.title = "Network Change Log"
        win.contentView = NSHostingView(rootView: NetworkChangeLogView())
        win.contentMinSize = NSSize(width: 520, height: 280)
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()
        win.setFrameAutosaveName("NetworkChangeLog")
        win.makeKeyAndOrderFront(nil)
        window = win
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in self.window = nil }
    }
}

struct NetworkChangeLogView: View {
    @ObservedObject private var log = NetworkChangeLog.shared
    @State private var confirmClear = false

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMdjmmss")
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(NS.blue)
                Text("Network Change Log").font(.headline).foregroundStyle(NS.text1)
                Text("\(log.entries.count) of \(NetworkChangeLog.limit) kept")
                    .font(.caption).foregroundStyle(NS.text3)
                Spacer()
                ToolActionBar("Network Changes", text: { log.exportText() },
                              csv: { log.exportCSV() }, json: { log.exportJSON() })
                    .fixedSize()
                    .disabled(log.entries.isEmpty)
                Button("Clear…") { confirmClear = true }
                    .disabled(log.entries.isEmpty)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(NS.bg0)

            Divider()

            if log.entries.isEmpty {
                EmptyStateView(title: "No changes yet", systemImage: "clock.arrow.circlepath",
                               description: "SNAP adds an entry when your network, router, DNS servers, or VPN changes.")
            } else {
                Table(log.entries) {
                    TableColumn("Time") { e in
                        Text(Self.time.string(from: e.date)).font(.system(.caption, design: .monospaced))
                    }.width(min: 110, ideal: 130)
                    TableColumn("Event") { e in
                        Label(e.kind.title, systemImage: e.kind.icon)
                            .font(.caption)
                            .foregroundStyle(e.kind.isWarning
                                             ? ThemeContrast.readable(NS.amber, on: NS.bg1, toward: NS.text1) : NS.text1)
                    }.width(min: 100, ideal: 110)
                    TableColumn("Details") { e in
                        Text(e.text).font(.caption).textSelection(.enabled).help(e.text)
                    }.width(min: 200, ideal: 480)
                }
            }

            Divider()
            Text("Read from your Mac every 10 s; nothing is sent over the network. Kept on this Mac only.")
                .font(.caption2).foregroundStyle(NS.text3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 6)
                .background(NS.bg0)
        }
        .background(NS.bg1)
        .confirmationDialog("Clear the network change log?", isPresented: $confirmClear) {
            Button("Clear Log", role: .destructive) { log.clear() }
        } message: {
            Text("This deletes all \(log.entries.count) entries. It can't be undone.")
        }
    }
}
