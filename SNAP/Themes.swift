// Themes.swift
// SNAP — Themed appearance system (v1.5.0)
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
//
// The `NS` palette in ContentView.swift now forwards to ThemeManager.shared.current,
// so changing the active theme cascades to every view that already uses NS tokens.
// New themes only need to be registered in `Theme.all`.

import SwiftUI
import AppKit

// MARK: - Theme model

struct Theme: Identifiable, Hashable {
    let id: String          // stable key, used in UserDefaults
    let name: String        // human-readable
    let group: String       // shown as section header in the picker

    // Surfaces
    let bg0: Color          // window background
    let bg1: Color          // deepest fill (sidebar / hero base)
    let bg2: Color          // card surface
    let bg3: Color          // elevated / hover surface
    let border: Color
    let borderMid: Color

    // Text
    let text1: Color        // primary
    let text2: Color        // secondary
    let text3: Color        // tertiary / captions
    let text4: Color        // hairlines / disabled

    // Semantics
    let amber: Color        // brand accent (was always amber in v1.4.x)
    let green: Color        // success / RX
    let blue: Color         // info / TX
    let red: Color          // danger
    let purple: Color       // special / launcher tag

    /// Light surfaces. Drives the window appearance so system controls
    /// (tables, lists, text fields, pickers) and `.secondary` text render for
    /// a light background. Before v1.5.4 the app forced dark mode for every
    /// theme, so Daylight showed dark tables and near-invisible gray labels.
    var isLight: Bool = false

    var colorScheme: ColorScheme { isLight ? .light : .dark }
    var appearanceName: NSAppearance.Name { isLight ? .aqua : .darkAqua }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (a: Theme, b: Theme) -> Bool { a.id == b.id }
}

// MARK: - Catalog (10 themes, matching the POC)

extension Theme {

    static let all: [Theme] = [
        midnight, daylight,
        nord, solarized, tokyo, dracula,
        matrix, cyberpunk, deex, synthwave
    ]

    static func byId(_ id: String) -> Theme? { all.first { $0.id == id } }

    // ----- Built-in -----

    static let midnight = Theme(
        id: "midnight", name: "Midnight (default)", group: "Built-in",
        bg0: c(0.039, 0.039, 0.059), bg1: c(0.024, 0.024, 0.039),
        bg2: c(0.051, 0.051, 0.082), bg3: c(0.067, 0.067, 0.094),
        border: Color.white.opacity(0.06), borderMid: Color.white.opacity(0.04),
        text1: Color.white.opacity(0.88), text2: Color.white.opacity(0.45),
        text3: Color.white.opacity(0.22), text4: Color.white.opacity(0.12),
        amber: c(1.0, 0.584, 0.0),
        green: c(0.188, 0.820, 0.345),
        blue:  c(0.039, 0.518, 1.0),
        red:   c(1.0, 0.271, 0.227),
        purple: c(0.749, 0.353, 0.949)
    )

    static let daylight = Theme(
        id: "daylight", name: "Daylight", group: "Built-in",
        bg0: hex(0xdfe2e8), bg1: hex(0xd2d6dd), bg2: .white, bg3: hex(0xf8f8fa),
        border: Color.black.opacity(0.14), borderMid: Color.black.opacity(0.22),
        text1: hex(0x1d1d1f), text2: hex(0x3a3a3c), text3: hex(0x6e6e73), text4: hex(0xc7c7cc),
        amber: hex(0xff9500),
        green: hex(0x248a3d),
        blue:  hex(0x0066cc),
        red:   hex(0xd70015),
        purple: hex(0xaf52de),
        isLight: true
    )

    // ----- Developer -----

    static let nord = Theme(
        id: "nord", name: "Nord", group: "Developer",
        bg0: hex(0x2e3440), bg1: hex(0x272b35), bg2: hex(0x3b4252), bg3: hex(0x434c5e),
        border: hex(0xd8dee9).opacity(0.10), borderMid: hex(0xd8dee9).opacity(0.16),
        text1: hex(0xeceff4), text2: hex(0xd8dee9), text3: hex(0x81a1c1), text4: hex(0x4c566a),
        amber: hex(0x88c0d0),
        green: hex(0xa3be8c),
        blue:  hex(0x5e81ac),
        red:   hex(0xbf616a),
        purple: hex(0xb48ead)
    )

    static let solarized = Theme(
        id: "solarized", name: "Solarized Dark", group: "Developer",
        bg0: hex(0x002b36), bg1: hex(0x001f27), bg2: hex(0x073642), bg3: hex(0x0a4351),
        border: hex(0xeee8d5).opacity(0.10), borderMid: hex(0xeee8d5).opacity(0.16),
        text1: hex(0xfdf6e3), text2: hex(0x93a1a1), text3: hex(0x657b83), text4: hex(0x586e75),
        amber: hex(0xcb4b16),
        green: hex(0x859900),
        blue:  hex(0x268bd2),
        red:   hex(0xdc322f),
        purple: hex(0x6c71c4)
    )

    static let tokyo = Theme(
        id: "tokyo", name: "Tokyo Night", group: "Developer",
        bg0: hex(0x1a1b26), bg1: hex(0x15161e), bg2: hex(0x24283b), bg3: hex(0x2f3449),
        border: hex(0xc0caf5).opacity(0.07), borderMid: hex(0xc0caf5).opacity(0.13),
        text1: hex(0xc0caf5), text2: hex(0xa9b1d6), text3: hex(0x7982a9), text4: hex(0x414868),
        amber: hex(0xbb9af7),
        green: hex(0x9ece6a),
        blue:  hex(0x7aa2f7),
        red:   hex(0xf7768e),
        purple: hex(0xbb9af7)
    )

    static let dracula = Theme(
        id: "dracula", name: "Dracula", group: "Developer",
        bg0: hex(0x282a36), bg1: hex(0x21222c), bg2: hex(0x343746), bg3: hex(0x44475a),
        border: hex(0xf8f8f2).opacity(0.07), borderMid: hex(0xf8f8f2).opacity(0.13),
        text1: hex(0xf8f8f2), text2: hex(0xbfbfb1), text3: hex(0x6272a4), text4: hex(0x44475a),
        amber: hex(0xbd93f9),
        green: hex(0x50fa7b),
        blue:  hex(0x8be9fd),
        red:   hex(0xff5555),
        purple: hex(0xff79c6)
    )

    // ----- Themed -----

    static let matrix = Theme(
        id: "matrix", name: "Matrix", group: "Themed",
        bg0: .black, bg1: hex(0x020402), bg2: hex(0x0a140a), bg3: hex(0x0f1f0f),
        border: hex(0x00ff41).opacity(0.15), borderMid: hex(0x00ff41).opacity(0.28),
        text1: hex(0xebf0e6), text2: hex(0x86b386), text3: hex(0x446644), text4: hex(0x1f3a1f),
        amber: hex(0x00ff41),
        green: hex(0x00ff41),
        blue:  hex(0x9be0d6),
        red:   hex(0xffaa33),
        purple: hex(0xaaff66)
    )

    static let cyberpunk = Theme(
        id: "cyberpunk", name: "Cyberpunk", group: "Themed",
        bg0: hex(0x0a0e1a), bg1: hex(0x06090f), bg2: hex(0x131826), bg3: hex(0x1c2335),
        border: hex(0x00f0ff).opacity(0.10), borderMid: hex(0xfcee0a).opacity(0.22),
        text1: hex(0xe2f4f4), text2: hex(0x8de2eb), text3: hex(0x4f7280), text4: hex(0x2a3a48),
        amber: hex(0xfcee0a),
        green: hex(0x00ff88),
        blue:  hex(0x05d9e8),
        red:   hex(0xff003c),
        purple: hex(0xf72585)
    )

    static let deex = Theme(
        id: "deex", name: "DeeX", group: "Themed",
        bg0: hex(0x1a130b), bg1: hex(0x100b06), bg2: hex(0x2a1f14), bg3: hex(0x3a2c1c),
        border: hex(0xd4af37).opacity(0.22), borderMid: hex(0xd4af37).opacity(0.36),
        text1: hex(0xfff0c8), text2: hex(0xd4a85a), text3: hex(0x8d6e3a), text4: hex(0x4a3520),
        amber: hex(0xe0b14a),
        green: hex(0xc0a23a),
        blue:  hex(0xe0c060),
        red:   hex(0xd0682a),
        purple: hex(0xf0c878)
    )

    static let synthwave = Theme(
        id: "synthwave", name: "Synthwave '84", group: "Themed",
        bg0: hex(0x241b2f), bg1: hex(0x1d1530), bg2: hex(0x2a2139), bg3: hex(0x34294a),
        border: hex(0xff7edb).opacity(0.10), borderMid: hex(0xff7edb).opacity(0.20),
        text1: hex(0xf8f8f2), text2: hex(0xb893ce), text3: hex(0x7c5fa5), text4: hex(0x4d3a5e),
        amber: hex(0xff7edb),
        green: hex(0x72f1b8),
        blue:  hex(0x03edf9),
        red:   hex(0xfe4450),
        purple: hex(0xf92aad)
    )
}

// Convenience constructors
private func c(_ r: Double, _ g: Double, _ b: Double) -> Color {
    Color(red: r, green: g, blue: b)
}
private func hex(_ rgb: UInt32) -> Color {
    Color(
        red:   Double((rgb >> 16) & 0xff) / 255.0,
        green: Double((rgb >> 8)  & 0xff) / 255.0,
        blue:  Double( rgb        & 0xff) / 255.0
    )
}

// MARK: - Manager

final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()
    private let key = "com.bardaklabs.snap.theme.v1"

    @Published var current: Theme

    private init() {
        let stored = UserDefaults.standard.string(forKey: key)
        self.current = (stored.flatMap(Theme.byId)) ?? .midnight
    }

    @MainActor
    func select(_ theme: Theme) {
        guard theme.id != current.id else { return }
        current = theme
        UserDefaults.standard.set(theme.id, forKey: key)
        applyAppearance()
    }

    /// Light or dark AppKit appearance for every window — main window,
    /// sheets, alerts, menus, the detached Status Board, the menu bar
    /// popover — to match the theme. Called at launch and on every switch.
    @MainActor
    func applyAppearance() {
        NSApp.appearance = NSAppearance(named: current.appearanceName)
    }
}

// MARK: - Picker UI (used in the Dashboard toolbar)

struct ThemePicker: View {
    @ObservedObject private var mgr = ThemeManager.shared

    var body: some View {
        Menu {
            let grouped = Dictionary(grouping: Theme.all, by: \.group)
            ForEach(["Built-in", "Developer", "Themed"], id: \.self) { group in
                if let themes = grouped[group] {
                    Section(group) {
                        ForEach(themes) { theme in
                            Button {
                                mgr.select(theme)
                            } label: {
                                HStack {
                                    Text(theme.name)
                                    if theme.id == mgr.current.id {
                                        Spacer()
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "paintbrush.fill")
                    .font(.system(size: 10))
                Text(mgr.current.name)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(NS.text3)
            }
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(NS.bg2)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(NS.border))
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Change theme")
    }
}
