// SNAPApp.swift
// SNAP — Advanced Network Analysis Platform for macOS
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian. All rights reserved.

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

// Swaps identity-revealing live data (hostname, MAC, public IP, Wi-Fi SSID)
// for fixed placeholder values, for taking screenshots/recordings without
// exposing personal network details. Toggle with `-demoMode` or
// SNAP_DEMO_MODE=1; everything else in the app behaves exactly as normal.
enum DemoMode {
    static let isActive: Bool = {
        ProcessInfo.processInfo.arguments.contains("-demoMode")
        || ProcessInfo.processInfo.environment["SNAP_DEMO_MODE"] == "1"
    }()

    static let hostname = "MacBook-Pro.local"
    static let macAddress = "de:ad:be:ef:ca:fe"
    static let publicIPv4 = "203.0.113.42" // RFC 5737 TEST-NET-3, reserved for documentation
    static let ssid = "Home-5G"

    // ipwho.is-shaped fields for the Status Board's public IP chip
    static let ip = "203.0.113.42"
    static let isp = "Example Networks"
    static let asn = "AS65001" // RFC 5398, reserved for documentation/private use
    static let city = "Springfield"
    static let country = "United States"
    static let countryCode = "US"
    static let flagEmoji = "🇺🇸"
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
            CommandGroup(after: .help) {
                Button("Quick Tour…") {
                    OnboardingManager.shared.show()
                }
            }
            CommandMenu("Appearance") {
                let grouped = Dictionary(grouping: Theme.all, by: \.group)
                ForEach(["Built-in", "Developer", "Themed"], id: \.self) { group in
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
        let alert = NSAlert()
        alert.messageText = "SNAP"
        alert.informativeText = """
        Version \(AppInfo.version)
        Advanced Network Analysis Platform for macOS

        Created by Sevag Bardakjian
        Copyright © 2026 Sevag Bardakjian. All rights reserved.

        Inspired by the classic macOS Network Analysis Platform.
        Built with SwiftUI for macOS 13+.
        Supports Intel and Apple Silicon.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
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

    private var tooltip: String {
        switch mon.health {
        case .good:    return "SNAP · Network healthy (\(latency))"
        case .warn:    return "SNAP · Network slow (\(latency))"
        case .bad:     return "SNAP · Network degraded (\(latency))"
        case .offline: return "SNAP · Offline"
        case .unknown: return "SNAP · Checking…"
        }
    }

    private var latency: String {
        guard let ms = mon.gatewayLatencyMs else { return "—" }
        return String(format: "%.0f ms gw", ms)
    }
}
