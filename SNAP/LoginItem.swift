// LoginItem.swift
// SNAP: Open at Login (v1.5.8)
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md
//
// SNAP as a login item, through ServiceManagement. macOS keeps the setting
// (System Settings > General > Login Items & Extensions), and people can turn
// it off there, so SNAP reads it back from macOS instead of storing its own copy.

import AppKit
import ServiceManagement

@MainActor
final class LoginItem: ObservableObject {
    static let shared = LoginItem()

    @Published private(set) var isEnabled = false

    private init() {
        refresh()
        // Pick up a change made in System Settings when SNAP comes back to the front.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            let alert = NSAlert()
            alert.messageText = on ? "SNAP couldn't add itself to your login items" : "SNAP couldn't remove itself from your login items"
            alert.informativeText = "\(error.localizedDescription)\n\nYou can change this in System Settings > General > Login Items & Extensions."
            alert.addButton(withTitle: "Open Login Items")
            alert.addButton(withTitle: "OK")
            if alert.runModal() == .alertFirstButtonReturn { SMAppService.openSystemSettingsLoginItems() }
        }
        refresh()
        if on && SMAppService.mainApp.status == .requiresApproval {
            let alert = NSAlert()
            alert.messageText = "Allow SNAP to open at login"
            alert.informativeText = "macOS needs your approval. Turn on SNAP in System Settings > General > Login Items & Extensions."
            alert.addButton(withTitle: "Open Login Items")
            alert.addButton(withTitle: "Not Now")
            if alert.runModal() == .alertFirstButtonReturn { SMAppService.openSystemSettingsLoginItems() }
        }
    }
}
