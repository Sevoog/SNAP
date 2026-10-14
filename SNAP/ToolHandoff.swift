// ToolHandoff.swift
// SNAP — Cross-tool host handoff + per-tool input history
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md
//
// Two small singletons that power the "Send to Ping/Traceroute/..." right-click
// menus, the ⌘K command bar's `ping HOST` inline actions, and the recent-inputs
// dropdown on every functional dashboard card.
//
//   • ToolHandoff — staging area for "switch to tab X and pre-fill its input
//     with this value." Consumed by the destination tool on .onAppear.
//   • ToolHistory — bounded ring buffer of recent input values per tool,
//     persisted to UserDefaults.

import Foundation
import SwiftUI

// MARK: - Handoff

@MainActor
final class ToolHandoff: ObservableObject {
    static let shared = ToolHandoff()

    /// (target tab, prefill value). Consumers wipe this after they read it.
    @Published var pending: (tab: SNAPTab, value: String)?

    /// Set when something wants to navigate; ContentView observes this and
    /// updates its `selectedTab` state, then clears the slot.
    @Published var requestedTab: SNAPTab?

    private init() {}

    /// Stages a handoff and asks the UI to switch tabs.
    func send(_ value: String, to tab: SNAPTab) {
        pending = (tab, value)
        requestedTab = tab
    }

    /// Switches to a tab without a pre-fill value.
    func goto(_ tab: SNAPTab) {
        requestedTab = tab
    }

    /// Sentinel handoff value meaning "navigate here and immediately start,"
    /// as opposed to the usual "navigate here and pre-fill this host." Used by
    /// the Status Board's Speed Test tile so its "Run Now" button actually
    /// runs a test rather than just switching tabs.
    static let autostartToken = "__snap.autostart__"

    /// Called by a tool view on .onAppear. If there's a pending handoff
    /// addressed to this tool, returns the value and clears the slot.
    func consume(for tab: SNAPTab) -> String? {
        guard let p = pending, p.tab == tab else { return nil }
        pending = nil
        return p.value
    }

    func clearRequestedTab() { requestedTab = nil }
}

// MARK: - History

enum ToolHistoryKey: String, CaseIterable {
    case ping, lookup, whois, http, geoIP, bgp, traceroute, portScan
}

final class ToolHistory {
    static let shared = ToolHistory()
    private let max = 10
    private let prefix = "com.bardaklabs.snap.history.v1."

    private init() {}

    func add(_ key: ToolHistoryKey, _ value: String) {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return }
        var list = recent(key).filter { $0.caseInsensitiveCompare(v) != .orderedSame }
        list.insert(v, at: 0)
        if list.count > max { list = Array(list.prefix(max)) }
        UserDefaults.standard.set(list, forKey: prefix + key.rawValue)
    }

    func recent(_ key: ToolHistoryKey) -> [String] {
        UserDefaults.standard.stringArray(forKey: prefix + key.rawValue) ?? []
    }

    func clear(_ key: ToolHistoryKey) {
        UserDefaults.standard.removeObject(forKey: prefix + key.rawValue)
    }
}

// MARK: - View modifier: consume a pending handoff on appear

struct ConsumeHandoffModifier: ViewModifier {
    let tab: SNAPTab
    let onValue: (String) -> Void
    @ObservedObject private var handoff = ToolHandoff.shared

    func body(content: Content) -> some View {
        content
            // Covers the common case: the destination view is mounted fresh
            // when the tab switches.
            .onAppear { tryConsume() }
            // Covers the case where the destination tab is ALREADY selected,
            // so the view never re-appears — e.g. sitting on the Speed Test
            // tab, opening the Status Board over it, and hitting "Run Now".
            // `consume` nils `pending`, so a repeat send to the same tab still
            // registers as a change here.
            .onChange(of: handoff.pending?.tab) { _ in tryConsume() }
    }

    private func tryConsume() {
        if let v = ToolHandoff.shared.consume(for: tab) {
            onValue(v)
        }
    }
}

extension View {
    /// On appear, if `ToolHandoff` has a pending value for this tab, calls
    /// `set(value)` and clears the slot. Use to pre-fill a tool's input
    /// when the user right-clicks a host elsewhere and chooses "Send to X".
    func consumeHandoff(for tab: SNAPTab, set: @escaping (String) -> Void) -> some View {
        modifier(ConsumeHandoffModifier(tab: tab, onValue: set))
    }
}

// MARK: - History dropdown (Menu) used on dashboard input rows

struct HistoryMenuButton: View {
    let key: ToolHistoryKey
    let onPick: (String) -> Void

    var body: some View {
        Menu {
            let items = ToolHistory.shared.recent(key)
            if items.isEmpty {
                Text("No recent values").foregroundStyle(NS.text3)
            } else {
                Section("Recent") {
                    ForEach(items, id: \.self) { v in
                        Button(v) { onPick(v) }
                    }
                }
                Divider()
                Button("Clear history", role: .destructive) {
                    ToolHistory.shared.clear(key)
                }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 11))
                .foregroundStyle(NS.text3)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Recent inputs")
    }
}
