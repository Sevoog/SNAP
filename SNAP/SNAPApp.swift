// SNAPApp.swift
// SNAP — Advanced Network Analysis Platform for macOS
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md

import SwiftUI
import AppKit
import CoreLocation

// Single source of truth for the version shown anywhere in the UI —
// reads MARKETING_VERSION via Info.plist, so a bump in the project
// settings propagates everywhere (the menu bar and session reports
// once shipped a stale hardcoded "v1.2.4").
enum AppInfo {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
}

@main
struct SNAPApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, idealWidth: 1100, minHeight: 620, idealHeight: 720)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About SNAP") {
                    appDelegate.showAbout()
                }
            }
            CommandGroup(after: .newItem) {
                Button("Save Session Report…") {
                    NotificationCenter.default.post(name: .exportSessionReport, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .help) {
                Button("SNAP Help") {
                    if let url = URL(string: "https://github.com/Sevoog/SNAP") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .keyboardShortcut("?", modifiers: .command)
            }
            CommandGroup(after: .help) {
                Button("Quick Tour…") {
                    OnboardingManager.shared.show()
                }
            }
            CommandMenu("Appearance") {
                let grouped = Dictionary(grouping: Theme.all, by: \.group)
                ForEach(["Built-in", "Developer", "Themed", "E-ink"], id: \.self) { group in
                    if let themes = grouped[group] {
                        Section(group) {
                            ForEach(themes) { theme in
                                Button(theme.name) {
                                    ThemeManager.shared.select(theme)
                                }
                            }
                        }
                    }
                }
            }
        }

        MenuBarExtra {
            MenuBarView()
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate, CLLocationManagerDelegate {
    // Strong reference required — CLLocationManager deallocates if stored as local var
    private var locationManager: CLLocationManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        ThemeManager.shared.applyAppearance()  // light/dark AppKit chrome to match the theme
        requestLocationPermission()
        _ = MenuBarMonitor.shared  // start background bandwidth sampling immediately
        OUIDatabase.preload()      // warm the 39k-entry IEEE registry off-thread
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // MARK: Location permission
    private func requestLocationPermission() {
        let lm = CLLocationManager()
        lm.delegate = self
        locationManager = lm
        if lm.authorizationStatus == .notDetermined {
            lm.requestWhenInUseAuthorization()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .locationPermissionChanged, object: nil)
        }
    }

    // MARK: About panel
    func showAbout() {
        Self.makeAboutAlert().runModal()
    }

    static func makeAboutAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "SNAP"
        alert.informativeText = """
        Version \(AppInfo.version)
        Sev's Network Analysis Platform for macOS

        Created by Sevag Bardakjian
        Copyright © 2025–2026 Sevag Bardakjian

        SNAP is free software, licensed under the GNU GPL v3, and comes with ABSOLUTELY NO WARRANTY.

        Built with SwiftUI for macOS \(Bundle.main.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String ?? "14.0")+.
        Supports Intel and Apple Silicon.
        """
        alert.alertStyle = .informational
        alert.accessoryView = aboutLinks()
        alert.addButton(withTitle: "OK")
        return alert
    }

    /// Clickable links under the About text. NSAlert's informative text is
    /// plain, so they live in an accessory text view.
    static func aboutLinks() -> NSView {
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let links: [(label: String, title: String, url: String)] = [
            ("Source code and license: ", "github.com/Sevoog/SNAP", "https://github.com/Sevoog/SNAP"),
            ("Website: ", "sevag.ai", "https://sevag.ai"),
        ]
        let text = NSMutableAttributedString()
        for (i, link) in links.enumerated() {
            if i > 0 { text.append(NSAttributedString(string: "\n", attributes: [.font: font])) }
            text.append(NSAttributedString(string: link.label,
                                           attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
            if let url = URL(string: link.url) {
                text.append(NSAttributedString(string: link.title, attributes: [.font: font, .link: url]))
            }
        }
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 280, height: 34))
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textStorage?.setAttributedString(text)
        return view
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let refreshData               = Notification.Name("refreshData")
    static let locationPermissionChanged = Notification.Name("locationPermissionChanged")
}

// MARK: - Menu bar label with heartbeat dot

struct MenuBarLabel: View {
    @ObservedObject private var mon = MenuBarMonitor.shared

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "network")
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
        }
        .help(tooltip)
    }

    private var dotColor: Color {
        switch mon.health {
        case .good:    return Color(red: 0.188, green: 0.820, blue: 0.345) // green
        case .warn:    return Color(red: 1.0, green: 0.584, blue: 0.0)     // amber
        case .bad:     return Color(red: 1.0, green: 0.271, blue: 0.227)   // red
        case .offline: return Color(white: 0.4)
        case .unknown: return Color(white: 0.55)
        }
    }

    /// Names the state and why, from the same model as the Status Board's
    /// Gateway Latency tile — e.g. "SNAP · Gateway unstable · Jitter 20 ms ·
    /// No packet loss (5 ms gw)".
    private var tooltip: String {
        if mon.health == .offline { return "SNAP · Offline" }
        let s = mon.latencyStats
        let why = ConnectionHealth.assess(avgMs: s.avg, jitterMs: s.jitter, lossPct: s.lossPct,
                                          samples: s.sampleCount, wifiQuality: nil,
                                          recentAlerts: 0, trailingTimeouts: s.trailingTimeouts).summary
        switch mon.gatewayState {
        case .measuring:     return "SNAP · Checking…"
        case .healthy:       return "SNAP · Network healthy · \(why) (\(latency))"
        case .slow:          return "SNAP · Gateway slow · \(why) (\(latency))"
        case .unstable:      return "SNAP · Gateway unstable · \(why) (\(latency))"
        case .degraded:      return "SNAP · Gateway degraded · \(why) (\(latency))"
        case .notResponding: return "SNAP · Router not responding"
        }
    }

    private var latency: String {
        guard let ms = mon.gatewayLatencyMs else { return "—" }
        return String(format: "%.0f ms gw", ms)
    }
}
