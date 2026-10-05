// OnboardingView.swift
// SNAP — First-launch welcome tour (v1.5.0)
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
//
// Shown automatically on first launch (gated by a UserDefaults flag), and
// re-openable from the Help menu via "Quick Tour…". Five slides cover what
// SNAP is, the customizable Dashboard, the sidebar tool catalog, themes,
// and a handful of keyboard shortcuts.

import SwiftUI
import AppKit

// MARK: - Manager

final class OnboardingManager: ObservableObject {
    static let shared = OnboardingManager()
    private let key = "com.bardaklabs.snap.didOnboard.v1"

    @Published var isPresented = false

    private init() {
        // Open automatically on first launch only.
        if !UserDefaults.standard.bool(forKey: key) {
            DispatchQueue.main.async { self.isPresented = true }
        }
    }

    func show() { isPresented = true }

    func markSeen() {
        UserDefaults.standard.set(true, forKey: key)
        isPresented = false
    }
}

// MARK: - Sheet

struct OnboardingView: View {
    @ObservedObject private var mgr = OnboardingManager.shared
    @ObservedObject private var themeMgr = ThemeManager.shared
    @State private var slide = 1
    private let total = 5

    var body: some View {
        VStack(spacing: 0) {
            topBar
            content
            footer
        }
        .frame(width: 780, height: 480)
        .background(NS.bg2)
    }

    // MARK: top

    private var topBar: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(NS.amber).frame(width: 22, height: 22)
                Image(systemName: "scope")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color(red: 0.11, green: 0.11, blue: 0.11))
            }
            Text("WELCOME TOUR")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.3)
                .foregroundStyle(NS.text3)
            Spacer()
            Text(verbatim: "\(slide) / \(total)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(NS.text2)
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11))
                    .foregroundStyle(NS.text3)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Skip tour")
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(NS.bg1)
        .overlay(Rectangle().fill(NS.border).frame(height: 1), alignment: .bottom)
    }

    // MARK: content

    private var content: some View {
        HStack(spacing: 0) {
            visual
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    LinearGradient(colors: [NS.bg1, NS.bg3],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            copy
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(36)
        }
    }

    @ViewBuilder private var visual: some View {
        switch slide {
        case 1: WelcomeVisual()
        case 2: DashboardVisual()
        case 3: SidebarVisual()
        case 4: ThemesVisual()
        case 5: TipsVisual()
        default: EmptyView()
        }
    }

    @ViewBuilder private var copy: some View {
        switch slide {
        case 1:
            slideCopy(eyebrow: "Welcome",
                      title: "Sev's Network Analysis Platform",
                      body: "A dark, fast, sandboxless macOS network utility. Built for engineers and operators who need real answers, not browser tabs.",
                      sub: "38 tools · 0 dependencies · zero telemetry · all native Swift")

        case 2:
            slideCopy(eyebrow: "Your Dashboard",
                      title: "Pin the tools you use most",
                      body: "The Dashboard is a customizable grid. Drag in any of 24 tool cards in three flavors. Live monitors auto-refresh. Functional cards have inline forms. Launcher tiles open the full tool.",
                      bullets: [
                        "Click + Add Tools to pin from a categorized list.",
                        "Enter Edit Mode to drag cards around or remove them.",
                        "Layout persists across launches."
                      ])

        case 3:
            slideCopy(eyebrow: "The Sidebar",
                      title: "38 tools, organized by purpose",
                      body: "The left sidebar groups every tool by what you'd reach for it for. Search across all of them with the bar at the top, or pin the ones you use most to the Dashboard.",
                      bullets: [
                        "Diagnostics for troubleshooting a target host",
                        "Tools for calculators, lookups, utilities",
                        "Monitoring for keeping an eye on the connection",
                        "Advanced for Network Map, SNMP, UniFi, packet capture"
                      ])

        case 4:
            slideCopy(eyebrow: "Themes",
                      title: "Pick a vibe. 10 ship in v1.5.0.",
                      body: "App-wide color theming with instant propagation. Built-in (Midnight, Daylight), developer palettes (Nord, Solarized, Tokyo Night, Dracula), and themed (Matrix, Cyberpunk, DeeX, Synthwave '84).",
                      sub: "Switch anytime from the Appearance menu in the menu bar, or the paintbrush picker on the Dashboard toolbar.")

        case 5:
            slideCopy(eyebrow: "Pro Tips",
                      title: "You're set. A few shortcuts worth knowing.",
                      body: "SNAP rewards keyboard. Session reports capture interfaces, gateway, DNS, recent alerts, and external IP in one HTML file you can attach to a ticket.")

        default: EmptyView()
        }
    }

    private func slideCopy(eyebrow: String, title: String, body: String,
                           bullets: [String] = [], sub: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(eyebrow.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(NS.amber)
            Text(title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(NS.text1)
                .fixedSize(horizontal: false, vertical: true)
            Text(body)
                .font(.system(size: 13))
                .foregroundStyle(NS.text2)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            if !bullets.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(bullets, id: \.self) { b in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle().fill(NS.amber).frame(width: 4, height: 4)
                                .padding(.top, 5)
                            Text(b)
                                .font(.system(size: 12))
                                .foregroundStyle(NS.text2)
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if let sub {
                Text(sub)
                    .font(.system(size: 11))
                    .foregroundStyle(NS.text3)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
    }

    // MARK: footer

    private var footer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(1...total, id: \.self) { i in
                    Capsule()
                        .fill(i == slide ? NS.amber : NS.text4)
                        .frame(width: i == slide ? 22 : 7, height: 7)
                        .animation(.easeInOut(duration: 0.2), value: slide)
                        .onTapGesture { withAnimation { slide = i } }
                }
            }
            Spacer()
            if slide < total {
                Button("Skip tour") { dismiss() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(NS.text3)
            }
            if slide > 1 {
                Button("Back") { withAnimation { slide -= 1 } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Button(slide == total ? "Start using SNAP" : "Next") {
                if slide == total { dismiss() }
                else { withAnimation { slide += 1 } }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(NS.amber)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(NS.bg1)
        .overlay(Rectangle().fill(NS.border).frame(height: 1), alignment: .top)
    }

    private func dismiss() { mgr.markSeen() }
}

// MARK: - Per-slide visuals

private struct WelcomeVisual: View {
    var body: some View {
        VStack(spacing: 18) {
            // App icon at large size — pulled live from NSApp so per-theme icon
            // swaps (a future enhancement) would Just Work here.
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 140, height: 140)
                    .shadow(color: NS.amber.opacity(0.35), radius: 30, x: 0, y: 8)
            } else {
                RoundedRectangle(cornerRadius: 32)
                    .fill(NS.amber)
                    .frame(width: 140, height: 140)
                    .overlay(
                        Image(systemName: "scope")
                            .font(.system(size: 70, weight: .bold))
                            .foregroundStyle(Color(red: 0.11, green: 0.11, blue: 0.11))
                    )
            }
            Text("SNAP v\(AppInfo.version)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(NS.text3)
        }
        .padding(28)
    }
}

private struct DashboardVisual: View {
    var body: some View {
        VStack(spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2),
                      spacing: 8) {
                miniCard(title: "Bandwidth", tag: "LIVE", color: NS.blue) {
                    Text("12.4 MB/s")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(NS.amber)
                }
                miniCard(title: "Wi-Fi", tag: "LIVE", color: NS.blue) {
                    Text("−48 dBm")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(NS.green)
                }
                miniCard(title: "Ping", tag: "FUNCTIONAL", color: NS.green) {
                    Text("1.1.1.1 · 12 ms")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(NS.text3)
                }
                miniCard(title: "Network Map", tag: "LAUNCHER", color: NS.purple) {
                    Text("81 devices")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(NS.text3)
                }
            }
            .frame(width: 280)
            HStack {
                Text("4 of 24 pinned")
                    .font(.system(size: 9))
                    .foregroundStyle(NS.text3)
                Spacer()
                Text("+ Add Tools")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(NS.amber)
                    .foregroundStyle(Color(red: 0.11, green: 0.11, blue: 0.11))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(width: 280)
        }
    }

    @ViewBuilder private func miniCard<Body: View>(title: String, tag: String, color: Color,
                                                   @ViewBuilder body: () -> Body) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle().fill(NS.text3).frame(width: 5, height: 5)
                Text(title).font(.system(size: 8, weight: .semibold)).foregroundStyle(NS.text2)
                Spacer()
                Text(tag).font(.system(size: 7, weight: .bold)).tracking(0.3).foregroundStyle(color)
            }
            body()
        }
        .padding(8)
        .frame(height: 56, alignment: .topLeading)
        .background(NS.bg2)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(NS.border))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct SidebarVisual: View {
    private let cats: [(String, [String], String?)] = [
        ("Overview",    ["Dashboard"], "Dashboard"),
        ("Diagnostics", ["Ping", "Traceroute", "Visual Trace", "Port Scan", "MTR"], nil),
        ("Tools",       ["Subnet Calc", "SSL/TLS", "HTTP Probe"], nil),
        ("Advanced",    ["Network Map", "Packet Capture", "SNMP · UniFi"], nil),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(cats, id: \.0) { (name, items, active) in
                Text(name.uppercased())
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(NS.text3)
                    .padding(.top, 6)
                ForEach(items, id: \.self) { item in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(item == active ? NS.amber : NS.text4)
                            .frame(width: 5, height: 5)
                        Text(item)
                            .font(.system(size: 10))
                            .foregroundStyle(item == active ? NS.amber : NS.text2)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(item == active ? NS.amber.opacity(0.08) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
        }
        .padding(10)
        .frame(width: 200)
        .background(NS.bg2)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(NS.border))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct ThemesVisual: View {
    private struct Sample {
        let name: String
        let bg: Color
        let strip: [Color]
    }
    private let samples: [Sample] = [
        .init(name: "Midnight",  bg: Color(red: 0.039, green: 0.039, blue: 0.059),
              strip: [Color(red: 1.0, green: 0.584, blue: 0.0),
                      Color(red: 0.188, green: 0.820, blue: 0.345),
                      Color(red: 0.039, green: 0.518, blue: 1.0),
                      Color(red: 0.749, green: 0.353, blue: 0.949)]),
        .init(name: "Cyberpunk", bg: Color(red: 0.039, green: 0.055, blue: 0.102),
              strip: [Color(red: 0.988, green: 0.933, blue: 0.039),
                      Color(red: 0.020, green: 0.851, blue: 0.910),
                      Color(red: 0.969, green: 0.145, blue: 0.522),
                      Color(red: 0.0, green: 1.0, blue: 0.533)]),
        .init(name: "DeeX",      bg: Color(red: 0.102, green: 0.075, blue: 0.043),
              strip: [Color(red: 0.878, green: 0.694, blue: 0.290),
                      Color(red: 0.804, green: 0.498, blue: 0.196),
                      Color(red: 0.831, green: 0.686, blue: 0.216),
                      Color(red: 0.941, green: 0.784, blue: 0.471)]),
        .init(name: "Matrix",    bg: .black,
              strip: [Color(red: 0.0, green: 1.0, blue: 0.255),
                      Color(red: 0.608, green: 0.878, blue: 0.839),
                      Color(red: 1.0, green: 0.667, blue: 0.2),
                      Color(red: 0.667, green: 1.0, blue: 0.4)]),
    ]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2),
                  spacing: 10) {
            ForEach(samples, id: \.name) { s in
                VStack(spacing: 6) {
                    HStack(spacing: 3) {
                        ForEach(0..<s.strip.count, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(s.strip[i])
                                .frame(width: 14, height: 14)
                        }
                    }
                    Text(s.name)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(NS.text2)
                }
                .padding(9)
                .frame(maxWidth: .infinity)
                .background(s.bg)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(NS.border))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(width: 280)
    }
}

private struct TipsVisual: View {
    private let tips: [(String, String)] = [
        ("⌘K",          "Command Palette. Type a tool, theme, or 'ping HOST' to run inline."),
        ("⌘⇧B",         "Status Board. Fullscreen ambient display, detachable to a second monitor."),
        ("Right-click", "Any IP opens a menu: Send to Ping / Traceroute / Lookup / Favorites…"),
        ("★",            "Favorites strip on the Dashboard pins hosts you check often."),
        ("⌘⇧R",         "Save Session Report. HTML snapshot of network state."),
        ("Help",        "Quick Tour re-opens this walkthrough anytime."),
    ]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(tips, id: \.0) { (key, text) in
                HStack(alignment: .top, spacing: 10) {
                    Text(key)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(NS.amber)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(NS.bg3)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(NS.borderMid))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    Text(text)
                        .font(.system(size: 11))
                        .foregroundStyle(NS.text2)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(9)
                .background(NS.bg2)
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(NS.border))
                .clipShape(RoundedRectangle(cornerRadius: 7))
            }
        }
        .frame(width: 280)
    }
}
