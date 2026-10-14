// AlertManager.swift
// SNAP — Threshold alerts for Bandwidth Monitor
// Created by Sevag Bardakjian
// Copyright © 2025 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md
//
// Watches Bandwidth Monitor samples and fires a macOS UserNotification when a
// metric crosses a user-configured threshold for N consecutive samples. The
// "N consecutive" gate avoids noise from single-sample spikes.

import Foundation
import UserNotifications
import AppKit
import SwiftUI

// MARK: - Threshold model

enum AlertMetric: String, CaseIterable, Identifiable, Codable {
    case latencyMs
    case packetLoss
    case jitterMs
    case retransmitRate
    case dnsLatencyMs

    var id: String { rawValue }
    var label: String {
        switch self {
        case .latencyMs:      return "Latency"
        case .packetLoss:     return "Packet Loss"
        case .jitterMs:       return "Jitter"
        case .retransmitRate: return "TCP Retransmits"
        case .dnsLatencyMs:   return "DNS Latency"
        }
    }
    var unit: String {
        switch self {
        case .latencyMs, .jitterMs, .dnsLatencyMs: return "ms"
        case .packetLoss, .retransmitRate:         return "%"
        }
    }
}

struct AlertThreshold: Identifiable, Hashable, Codable {
    var id = UUID()
    var metric: AlertMetric
    var value: Double
    var consecutiveSamples: Int     // require this many in a row before alerting
    var enabled: Bool = true

    static let defaults: [AlertThreshold] = [
        AlertThreshold(metric: .latencyMs,      value: 150,  consecutiveSamples: 3),
        AlertThreshold(metric: .packetLoss,     value: 5,    consecutiveSamples: 2),
        AlertThreshold(metric: .jitterMs,       value: 30,   consecutiveSamples: 3),
        AlertThreshold(metric: .retransmitRate, value: 2,    consecutiveSamples: 3),
        AlertThreshold(metric: .dnsLatencyMs,   value: 250,  consecutiveSamples: 2),
    ]
}

// MARK: - AlertManager

@MainActor
final class AlertManager: ObservableObject {
    static let shared = AlertManager()

    @Published var thresholds: [AlertThreshold] = []
    @Published var notificationsEnabled: Bool = true
    @Published var recentEvents: [AlertEvent] = []

    private var consecutive: [UUID: Int] = [:]    // running count per threshold
    private var lastFiredAt: [UUID: Date] = [:]   // for cooldown
    private let cooldown: TimeInterval = 60       // don't re-fire same alert within 60s

    private let defaultsKey = "snap.alertThresholds.v1"
    private let enabledKey  = "snap.alertNotificationsEnabled.v1"

    private init() {
        load()
        requestPermissionIfNeeded()
    }

    // MARK: Persistence

    private func load() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let stored = try? JSONDecoder().decode([AlertThreshold].self, from: data) {
            thresholds = stored
        } else {
            thresholds = AlertThreshold.defaults
        }
        if UserDefaults.standard.object(forKey: enabledKey) != nil {
            notificationsEnabled = UserDefaults.standard.bool(forKey: enabledKey)
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(thresholds) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        UserDefaults.standard.set(notificationsEnabled, forKey: enabledKey)
    }

    func resetToDefaults() {
        thresholds = AlertThreshold.defaults
        save()
    }

    // MARK: Permission

    private func requestPermissionIfNeeded() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    // MARK: Evaluation
    //
    // Called from BandwidthMonitor whenever a fresh metrics snapshot is available.
    // `currentValues` maps every supported metric to its current reading.

    func evaluate(_ currentValues: [AlertMetric: Double]) {
        guard notificationsEnabled else { return }
        for t in thresholds where t.enabled {
            guard let v = currentValues[t.metric] else { continue }
            let exceeded = v >= t.value
            if exceeded {
                let now = (consecutive[t.id] ?? 0) + 1
                consecutive[t.id] = now
                if now >= t.consecutiveSamples {
                    fire(threshold: t, value: v)
                    consecutive[t.id] = 0
                }
            } else {
                consecutive[t.id] = 0
            }
        }
    }

    private func fire(threshold: AlertThreshold, value: Double) {
        // Cooldown — avoid spam
        if let last = lastFiredAt[threshold.id], Date().timeIntervalSince(last) < cooldown { return }
        lastFiredAt[threshold.id] = Date()

        let title = "\(threshold.metric.label) threshold exceeded"
        let unit = threshold.metric.unit
        let body = String(format: "%@ is %.1f%@ (threshold %.1f%@) for %d samples.",
                          threshold.metric.label, value, unit,
                          threshold.value, unit,
                          threshold.consecutiveSamples)

        recentEvents.insert(AlertEvent(date: Date(), title: title, body: body,
                                       metric: threshold.metric, value: value), at: 0)
        if recentEvents.count > 30 { recentEvents.removeLast(recentEvents.count - 30) }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body  = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: "snap.alert.\(threshold.id)",
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    func clearEvents() {
        recentEvents.removeAll()
    }
}

// MARK: - Event log entry

struct AlertEvent: Identifiable, Hashable {
    let id = UUID()
    let date: Date
    let title: String
    let body:  String
    let metric: AlertMetric
    let value: Double
}

// MARK: - Settings panel
// Drop into any view that wants to expose threshold configuration.

struct AlertSettingsPanel: View {
    @ObservedObject var manager: AlertManager = .shared
    @State private var expanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded { body_ }
        }
        .background(NS.bg1)
    }

    private var header: some View {
        Button { expanded.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(NS.text3)
                Image(systemName: "bell.fill").foregroundStyle(NS.amber)
                Text("Alerts").font(.system(size: 12, weight: .semibold)).foregroundStyle(NS.text1)
                Spacer()
                Text("\(activeCount) active")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(NS.text3)
                Toggle("", isOn: $manager.notificationsEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .scaleEffect(0.75)
                    .frame(width: 36)
                    .onChange(of: manager.notificationsEnabled) { _ in manager.save() }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var activeCount: Int { manager.thresholds.filter { $0.enabled }.count }

    private var body_: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($manager.thresholds) { $t in
                HStack(spacing: 10) {
                    Toggle("", isOn: $t.enabled)
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .onChange(of: t.enabled) { _ in manager.save() }
                    Text(t.metric.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(NS.text2)
                        .frame(width: 110, alignment: .leading)
                    Text("≥").font(.system(size: 11)).foregroundStyle(NS.text3)
                    TextField("", value: $t.value, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                        .onSubmit { manager.save() }
                    Text(t.metric.unit).font(.system(size: 11)).foregroundStyle(NS.text3)
                    Text("for")
                        .font(.system(size: 11)).foregroundStyle(NS.text3)
                    Stepper("\(t.consecutiveSamples)", value: $t.consecutiveSamples, in: 1...10)
                        .frame(width: 100)
                        .onChange(of: t.consecutiveSamples) { _ in manager.save() }
                    Text("samples").font(.system(size: 11)).foregroundStyle(NS.text3)
                    Spacer()
                }
                .padding(.horizontal, 16)
            }

            if !manager.recentEvents.isEmpty {
                Divider().background(NS.borderMid).padding(.vertical, 6)
                HStack {
                    Text("Recent alerts").font(.system(size: 11, weight: .semibold)).foregroundStyle(NS.text2)
                    Spacer()
                    Button("Clear") { manager.clearEvents() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                }
                .padding(.horizontal, 16)
                ForEach(manager.recentEvents.prefix(5)) { ev in
                    HStack(spacing: 8) {
                        Text(ev.date.formatted(date: .omitted, time: .standard))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(NS.text3)
                            .frame(width: 70, alignment: .leading)
                        Text(ev.title).font(.system(size: 11)).foregroundStyle(NS.amber)
                        Text(ev.body).font(.system(size: 11)).foregroundStyle(NS.text3).lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                }
            }

            HStack {
                Spacer()
                Button("Reset to defaults") { manager.resetToDefaults() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
    }
}
