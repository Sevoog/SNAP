// StatusBoardView.swift
// SNAP — Fullscreen ambient display (#6 from the v1.5.x combo)
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
//
// A kiosk-style overlay you can throw on a spare monitor: big bandwidth
// sparkline, current Wi-Fi RSSI, recent-alerts panel, and a live clock.
//
// Triggered via the Dashboard toolbar's "Status Board" button or the
// `⌘⇧B` shortcut wired in SNAPApp. Esc dismisses.

import SwiftUI
import CoreWLAN

@MainActor
final class StatusBoardManager: ObservableObject {
    static let shared = StatusBoardManager()
    @Published var isPresented = false {
        didSet { updateLiveDataCadence() }
    }
    @Published private(set) var isDetached = false {
        didSet { updateLiveDataCadence() }
    }

    private init() {}

    /// `⌘⇧B` and the toolbar button hit this — flips between hidden and the
    /// in-window overlay. Closes the detached window first if open.
    func toggle() {
        if isDetached {
            StatusBoardWindowController.shared.close()
        }
        isPresented.toggle()
    }

    /// "Detach to window" button. Hides the in-window overlay and spawns a
    /// real NSWindow (placed on the secondary screen if one's connected).
    func detach() {
        isPresented = false
        StatusBoardWindowController.shared.open()
        isDetached = true
    }

    /// "Attach back" — closes the detached window and re-opens the overlay.
    func attach() {
        StatusBoardWindowController.shared.close()
        isPresented = true
    }

    /// Called by the window controller when its NSWindow closes.
    func detachedWindowDidClose() {
        isDetached = false
    }

    /// Tighten the Favorites ping cadence to 10 s while the board is visible
    /// (in-window OR detached), relax back to 30 s once it closes. Keeps the
    /// sparklines feeling live without burning pings when nobody's looking.
    private func updateLiveDataCadence() {
        FavoritesManager.shared.setRefreshMode(active: isPresented || isDetached)
    }
}

struct StatusBoardView: View {
    @ObservedObject private var mgr = StatusBoardManager.shared
    @ObservedObject private var themeMgr = ThemeManager.shared
    @ObservedObject private var layout = StatusBoardLayout.shared
    @ObservedObject var bwMonitor: BandwidthDashMonitor
    @ObservedObject private var alerts = AlertManager.shared
    @State private var now = Date()
    @State private var clock: Timer?
    @State private var editing = false
    @State private var showAddSheet = false
    @State private var draggingTile: StatusTileKind? = nil

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm:ss"; return f
    }()
    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .full; return f
    }()

    var body: some View {
        ZStack {
            NS.bg0.ignoresSafeArea()

            VStack(spacing: 24) {
                header
                if layout.tiles.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 360, maximum: .infinity), spacing: 20)],
                        alignment: .leading,
                        spacing: 20
                    ) {
                        ForEach(layout.tiles, id: \.self) { kind in
                            StatusTileChrome(kind: kind, editing: editing,
                                             onRemove: { layout.remove(kind) }) {
                                StatusTileBody(kind: kind, bwMonitor: bwMonitor)
                            }
                            .frame(minHeight: 220, maxHeight: 320)
                            .opacity(draggingTile == kind ? 0.4 : 1.0)
                            .tileDraggableWhenEditing(editing,
                                                      kind: kind,
                                                      layout: layout,
                                                      draggingTile: $draggingTile)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        }
                    }
                    .animation(.easeInOut(duration: 0.18), value: layout.tiles)
                    .animation(.easeInOut(duration: 0.18), value: editing)
                    Spacer(minLength: 0)
                }
            }
            .padding(38)
            .sheet(isPresented: $showAddSheet) {
                AddStatusTileSheet(layout: layout)
            }

            // Exit hint pinned bottom-right. In the in-window overlay we also
            // surface a "Detach to window" action; the detached window doesn't
            // show that button (closing the window dismisses).
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    if mgr.isPresented {
                        Button {
                            mgr.detach()
                        } label: {
                            Label("Detach to window", systemImage: "macwindow.on.rectangle")
                                .font(.system(size: 11))
                                .padding(.horizontal, 11).padding(.vertical, 6)
                                .background(NS.bg2)
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(NS.border))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .foregroundStyle(NS.text2)
                        }
                        .buttonStyle(.plain)
                        .help("Open the Status Board in a separate window (jumps to a second monitor if one's connected)")
                    }
                    Button {
                        dismissBoard()
                    } label: {
                        Label("Exit Status Board · Esc", systemImage: "rectangle.portrait.and.arrow.right")
                            .font(.system(size: 11))
                            .padding(.horizontal, 11).padding(.vertical, 6)
                            .background(NS.bg2)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(NS.border))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(NS.text2)
                    }
                    .buttonStyle(.plain)
                }
                .padding(16)
            }
        }
        .onAppear {
            now = Date()
            clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                Task { @MainActor in now = Date() }
            }
            bwMonitor.start()
        }
        .onDisappear {
            clock?.invalidate(); clock = nil
        }
        .background(
            Button("") { dismissBoard() }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
        )
    }

    /// Exits whichever Status Board mode is currently active. The in-window
    /// overlay just flips `isPresented`; the detached window has to close its
    /// NSWindow (the manager's `isDetached` flag clears via the window
    /// delegate's willClose callback).
    private func dismissBoard() {
        if mgr.isDetached {
            StatusBoardWindowController.shared.close()
        }
        mgr.isPresented = false
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 16) {
            // Real app icon (matches OnboardingView's Welcome slide).
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 44, height: 44)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 9).fill(NS.amber).frame(width: 36, height: 36)
                    Image(systemName: "scope")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Color(red: 0.11, green: 0.11, blue: 0.11))
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: "SNAP Status Board")
                    .font(.system(size: 26, weight: .bold))
                HStack(spacing: 8) {
                    Text(verbatim: Self.dateFmt.string(from: now))
                        .font(.system(size: 12)).foregroundStyle(NS.text3)
                    PublicIPChip()
                }
            }
            Spacer()
            editControls
            VStack(alignment: .trailing, spacing: 0) {
                Text(verbatim: Self.timeFmt.string(from: now))
                    .font(.system(size: 36, weight: .heavy, design: .monospaced))
                    .foregroundStyle(NS.amber)
                Text(verbatim: "v\(AppInfo.version)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(NS.text4)
            }
        }
    }

    @ViewBuilder private var editControls: some View {
        ThemePicker()

        Button {
            showAddSheet = true
        } label: {
            Label("Add Tile", systemImage: "plus")
                .font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(NS.amber)

        Toggle(isOn: $editing) {
            Label("Edit", systemImage: "pencil")
                .font(.system(size: 11))
        }
        .toggleStyle(.button)
        .controlSize(.small)
        .tint(NS.amber)
    }

    // MARK: empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "square.dashed")
                .font(.system(size: 50))
                .foregroundStyle(NS.text4)
            Text("No tiles pinned")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(NS.text2)
            Text("Click + Add Tile to choose what to display.")
                .font(.system(size: 12))
                .foregroundStyle(NS.text3)
            Button("Add Tile") { showAddSheet = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .tint(NS.amber)
                .padding(.top, 6)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - WiFi snapshot helper (kept light — no listener / no live updates)

enum StatusBoardWiFi {
    struct Info {
        let ssid: String; let rssi: Int; let band: String
        /// BSD name (e.g. "en0") — lets the health score tell whether Wi-Fi
        /// is actually carrying the default route.
        let iface: String?
        // Live link details for the tile's detail grid; nil when CoreWLAN
        // doesn't report them (e.g. not associated). These replace values
        // that were hard-coded from the v1.5.2 mockup.
        let noise: Int?
        let txRateMbps: Double?
        let security: String?
        /// Open or WEP — effectively unencrypted.
        let securityInsecure: Bool
        let standard: String?

        /// Signal-to-noise ratio in dB, when both readings exist.
        var snr: Int? {
            guard rssi != 0, let n = noise else { return nil }
            return rssi - n
        }
    }
    static func read() -> Info? {
        guard let i = CWWiFiClient.shared().interface() else { return nil }
        let s = i.ssid() ?? "Hidden"
        let r = i.rssiValue()
        let ch = i.wlanChannel()?.channelNumber ?? 0
        let widthRaw = i.wlanChannel()?.channelWidth.rawValue ?? 0
        let w = ["20","40","80","160","320"][min(widthRaw, 4)]
        let band: String = {
            guard let cb = i.wlanChannel()?.channelBand else { return "Wi-Fi" }
            switch cb {
            case .band2GHz: return "2.4 GHz · ch \(ch) · \(w) MHz"
            case .band5GHz: return "5 GHz · ch \(ch) · \(w) MHz"
            case .band6GHz, .bandUnknown: return "6 GHz · ch \(ch) · \(w) MHz"
            @unknown default: return "Wi-Fi · ch \(ch)"
            }
        }()
        let associated = r != 0
        let noise = i.noiseMeasurement()
        let tx = i.transmitRate()
        let sec = i.security()
        return Info(ssid: s, rssi: r, band: band, iface: i.interfaceName,
                    noise: associated && noise != 0 ? noise : nil,
                    txRateMbps: associated && tx > 0 ? tx : nil,
                    security: associated ? sec.snapLabel : nil,
                    securityInsecure: associated && [.none, .WEP, .dynamicWEP].contains(sec),
                    standard: associated
                        ? standard(i.activePHYMode(), sixGHz: i.wlanChannel()?.channelBand == .band6GHz)
                        : nil)
    }

    /// Marketing name for the active PHY mode; 802.11ax on 6 GHz is Wi-Fi 6E.
    static func standard(_ mode: CWPHYMode, sixGHz: Bool) -> String? {
        switch mode {
        case .mode11ax: return sixGHz ? "Wi-Fi 6E" : "Wi-Fi 6"
        case .mode11ac: return "Wi-Fi 5"
        case .mode11n:  return "Wi-Fi 4"
        case .mode11a:  return "802.11a"
        case .mode11g:  return "802.11g"
        case .mode11b:  return "802.11b"
        case .modeNone: return nil
        default:
            // 802.11be (raw 7) by value, so this builds on SDKs that predate
            // its Swift name.
            return mode.rawValue == 7 ? "Wi-Fi 7" : nil
        }
    }
}

extension CWSecurity {
    /// Display name shared by the Dashboard hero card and the Status Board
    /// Wi-Fi tile, so the two always agree.
    var snapLabel: String {
        switch self {
        case .none:               return "Open"
        case .WEP:                return "WEP"
        case .wpaPersonal:        return "WPA"
        case .wpaPersonalMixed:   return "WPA/WPA2"
        case .wpa2Personal:       return "WPA2"
        case .personal:           return "Personal"
        case .dynamicWEP:         return "Dynamic WEP"
        case .wpaEnterprise:      return "WPA Enterprise"
        case .wpaEnterpriseMixed: return "WPA/WPA2 Enterprise"
        case .wpa2Enterprise:     return "WPA2 Enterprise"
        case .enterprise:         return "Enterprise"
        case .wpa3Personal:       return "WPA3"
        case .wpa3Enterprise:     return "WPA3 Enterprise"
        case .wpa3Transition:     return "WPA2/WPA3"
        default:
            // OWE (14) and OWE Transition (15) by value, so this builds on
            // SDKs that predate their Swift names.
            switch rawValue {
            case 14: return "OWE"
            case 15: return "OWE Transition"
            default: return "Unknown"
            }
        }
    }
}

// MARK: - Public IP chip (header)

/// Minimized Public IP indicator — used to be its own tile in the v1.5.2
/// design brainstorm; per feedback, moved to the header sub-line where it
/// stays visible always without eating a tile slot.
struct PublicIPChip: View {
    @ObservedObject private var pub = PublicIPMonitor.shared
    @ObservedObject private var themeMgr = ThemeManager.shared

    var body: some View {
        if let ip = pub.ip {
            HStack(spacing: 6) {
                if let flag = pub.flagEmoji, !flag.isEmpty {
                    Text(flag).font(.system(size: 13))
                }
                Text(verbatim: ip)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(NS.text2)
                if let asn = pub.asn {
                    Text(verbatim: "· \(asn)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(NS.text3)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(NS.bg2)
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(NS.border))
            .clipShape(Capsule())
            .help(pub.isp.map { "Public IP · \($0)" } ?? "Public IP")
            .hostMenu(ip)
        } else {
            HStack(spacing: 6) {
                Image(systemName: "globe")
                    .font(.system(size: 10))
                    .foregroundStyle(NS.text3)
                Text("Public IP…")
                    .font(.system(size: 10))
                    .foregroundStyle(NS.text3)
            }
            .padding(.horizontal, 8).padding(.vertical, 2)
        }
    }
}
