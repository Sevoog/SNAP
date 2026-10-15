// Themes.swift
// SNAP — Themed appearance system (v1.5.0)
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md
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

    /// E-ink: the palette is grayscale, so views that adopt the e-ink cues
    /// (`StatusDot`, `statusPill`, `MiniSparkline(ink:)`, the sidebar
    /// selection, the Dashboard cards) show state with shape instead of hue:
    /// filled / ringed / hollow dots, inverted or dashed chips, solid vs.
    /// dashed lines. Off for every other theme.
    var inkCues: Bool = false

    /// Color e-ink: draw those cues in the theme's muted semantic colors
    /// instead of ink. Only meaningful with `inkCues`.
    var inkColors: Bool = false

    /// Icons and labels drawn on an accent (`amber`) fill, like the app logo
    /// tile. Near-black suits the bright accents; the e-ink accents are dark,
    /// so they use paper.
    var onAmber: Color = Color(red: 0.11, green: 0.11, blue: 0.11)

    var colorScheme: ColorScheme { isLight ? .light : .dark }
    var appearanceName: NSAppearance.Name { isLight ? .aqua : .darkAqua }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (a: Theme, b: Theme) -> Bool { a.id == b.id }
}

// MARK: - Catalog (12 themes)

extension Theme {

    static let all: [Theme] = [
        midnight, daylight,
        nord, solarized, tokyo, dracula,
        matrix, cyberpunk, deex, synthwave,
        eink, einkColor
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

extension Theme {

    // ----- E-ink -----
    //
    // Paper and ink, with the shape cues on (see `inkCues`). Semantic hues
    // become gray levels: problems (red) are darkest, healthy (green) and TX
    // (blue) are quieter, the brand accent is ink.

    static let eink = Theme(
        id: "eink", name: "E-ink", group: "E-ink",
        bg0: hex(0xe8e6df), bg1: hex(0xdedcd4), bg2: hex(0xf2f0ea), bg3: hex(0xf7f5f0),
        border: Color.black.opacity(0.30), borderMid: Color.black.opacity(0.45),
        text1: hex(0x151515), text2: hex(0x3d3c39), text3: hex(0x6e6c67), text4: hex(0xb8b6ae),
        amber: hex(0x151515),
        green: hex(0x5a5853),
        blue:  hex(0x75736d),
        red:   hex(0x000000),
        purple: hex(0x4a4844),
        isLight: true,
        inkCues: true,
        onAmber: hex(0xf2f0ea)
    )

    /// Color e-ink (Kaleido-style): same paper and ink, muted pigments for
    /// the semantics, and the same shape cues drawn in those colors.
    static let einkColor = Theme(
        id: "einkColor", name: "Color e-ink", group: "E-ink",
        bg0: hex(0xe7e3d8), bg1: hex(0xddd9cd), bg2: hex(0xf1eee6), bg3: hex(0xf7f5ef),
        border: Color.black.opacity(0.28), borderMid: Color.black.opacity(0.42),
        text1: hex(0x1c1b19), text2: hex(0x3f3d39), text3: hex(0x6e6b64), text4: hex(0xbab5a8),
        amber: hex(0x9c6b1f),
        green: hex(0x5b7a4b),
        blue:  hex(0x4d6a86),
        red:   hex(0xa9533f),
        purple: hex(0x7a6386),
        isLight: true,
        inkCues: true,
        inkColors: true,
        onAmber: hex(0xf1eee6)
    )
}

// MARK: - E-ink cues

/// Health of a status indicator, for themes that can't rely on hue.
enum StatusLevel { case good, warn, bad, unknown }

/// A status dot. Normal themes: a filled dot in `color`. E-ink: the shape
/// carries the meaning (filled = good, ringed = degraded, hollow = down,
/// faint ring = unknown), drawn in the current foreground style so it also
/// works inside an inverted chip.
struct StatusDot: View {
    let level: StatusLevel
    let color: Color
    var size: CGFloat = 7
    @ObservedObject private var themeMgr = ThemeManager.shared

    var body: some View {
        if themeMgr.current.inkCues {
            let ink = themeMgr.current.inkColors ? AnyShapeStyle(color) : AnyShapeStyle(.foreground)
            switch level {
            case .good:
                Circle().fill(ink).frame(width: size, height: size)
            case .warn:
                ZStack {
                    Circle().strokeBorder(ink, lineWidth: 1.2)
                    Circle().fill(ink).frame(width: size * 0.4, height: size * 0.4)
                }
                .frame(width: size, height: size)
            case .bad:
                Circle().strokeBorder(ink, lineWidth: 1.2).frame(width: size, height: size)
            case .unknown:
                Circle().strokeBorder(NS.text4, lineWidth: 1).frame(width: size, height: size)
            }
        } else {
            Circle().fill(color).frame(width: size, height: size)
        }
    }
}

private struct StatusPillModifier: ViewModifier {
    let level: StatusLevel
    let color: Color
    @ObservedObject private var themeMgr = ThemeManager.shared

    func body(content: Content) -> some View {
        if themeMgr.current.inkColors {
            // Color e-ink: outlined in the status color, dashed when bad.
            switch level {
            case .good, .warn:
                content.foregroundStyle(color).overlay(Capsule().strokeBorder(color, lineWidth: 1))
            case .bad, .unknown:
                content.foregroundStyle(color)
                    .overlay(Capsule().strokeBorder(color, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            }
        } else if themeMgr.current.inkCues {
            switch level {
            case .good:
                content.foregroundStyle(NS.bg2).background(Capsule().fill(NS.text1))
            case .warn:
                content.foregroundStyle(NS.text1).overlay(Capsule().strokeBorder(NS.text1, lineWidth: 1))
            case .bad, .unknown:
                content.foregroundStyle(NS.text1)
                    .overlay(Capsule().strokeBorder(NS.text1, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            }
        } else {
            content.foregroundStyle(color).background(Capsule().fill(color.opacity(0.10)))
        }
    }
}

extension View {
    /// Status capsule. Normal themes: `color` text on a 10% tint of it.
    /// E-ink: inverted (good), outlined (warn) or dashed (bad / unknown).
    func statusPill(_ level: StatusLevel, color: Color) -> some View {
        modifier(StatusPillModifier(level: level, color: color))
    }
}

/// How a chart series is drawn in e-ink themes: `.primary` is a solid line
/// over hatching, `.secondary` a dashed line with no fill.
enum InkSeries { case primary, secondary }

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
            ForEach(["Built-in", "Developer", "Themed", "E-ink"], id: \.self) { group in
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

// MARK: - Contrast

/// WCAG contrast math for theme colors, so small text can be checked (and
/// nudged) against the surface it actually sits on in every theme.
enum ThemeContrast {
    private typealias RGB = (r: Double, g: Double, b: Double)

    private static func rgba(_ c: Color) -> (RGB, Double) {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? .black
        return ((Double(n.redComponent), Double(n.greenComponent), Double(n.blueComponent)),
                Double(n.alphaComponent))
    }

    /// `fg` as it shows on `bg` (translucent colors blended in).
    private static func composite(_ fg: Color, on bg: Color) -> RGB {
        let (f, a) = rgba(fg)
        let (b, _) = rgba(bg)
        return (f.r * a + b.r * (1 - a), f.g * a + b.g * (1 - a), f.b * a + b.b * (1 - a))
    }

    private static func luminance(_ c: RGB) -> Double {
        func ch(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b)
    }

    private static func ratio(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Contrast of `fg` on `bg`, 1 to 21. Small text needs 4.5, icons and
    /// field borders 3.
    static func ratio(_ fg: Color, on bg: Color) -> Double {
        let (b, _) = rgba(bg)
        return ratio(composite(fg, on: bg), b)
    }

    /// `top` laid over `base`, as one opaque color (a tinted badge background).
    static func flatten(_ top: Color, over base: Color) -> Color {
        let c = composite(top, on: base)
        return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: 1)
    }

    /// `color` if it already reaches `minimum` on `bg`; otherwise the same hue
    /// blended toward `toward` (the theme's primary text) just far enough.
    static func readable(_ color: Color, on bg: Color, toward: Color, minimum: Double = 4.5) -> Color {
        let (b, _) = rgba(bg)
        let start = composite(color, on: bg)
        if ratio(start, b) >= minimum { return color }
        let end = composite(toward, on: bg)
        for step in 1...10 {
            let t = Double(step) / 10
            let mixed: RGB = (start.r + (end.r - start.r) * t,
                              start.g + (end.g - start.g) * t,
                              start.b + (end.b - start.b) * t)
            if ratio(mixed, b) >= minimum || step == 10 {
                return Color(.sRGB, red: mixed.r, green: mixed.g, blue: mixed.b, opacity: 1)
            }
        }
        return toward
    }
}
