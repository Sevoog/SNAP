// StatusBoardWindow.swift
// SNAP — Detached Status Board window (v1.5.x)
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
//
// Spawns a separate `NSWindow` containing the same `StatusBoardView`. Used
// for the "throw it on a spare monitor" workflow — if a secondary screen is
// connected the window opens there fullscreen; otherwise it opens centered
// on the main screen at 1200×800. Closing the window flips the manager back
// to the in-window mode (or, if neither is wanted, to dismissed).

import SwiftUI
import AppKit

@MainActor
final class StatusBoardWindowController: NSObject, NSWindowDelegate {
    static let shared = StatusBoardWindowController()
    private var window: NSWindow?
    private var monitor: BandwidthDashMonitor?

    var isOpen: Bool { window != nil }

    /// Opens a new detached Status Board window. If one's already open,
    /// brings it to front instead.
    func open() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            return
        }
        let bw = BandwidthDashMonitor()
        bw.start()
        monitor = bw

        let view = StatusBoardView(bwMonitor: bw)
        let host = NSHostingView(rootView: view)

        // Target rect: secondary screen if connected, else centered on main.
        let target: NSRect
        if let second = NSScreen.screens.first(where: { $0 != NSScreen.main }) {
            target = second.frame
        } else if let main = NSScreen.main {
            let w: CGFloat = 1200, h: CGFloat = 800
            target = NSRect(x: main.frame.midX - w/2,
                            y: main.frame.midY - h/2,
                            width: w, height: h)
        } else {
            target = NSRect(x: 0, y: 0, width: 1200, height: 800)
        }

        let win = NSWindow(
            contentRect: target,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "SNAP Status Board"
        win.contentView = host
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenPrimary]
        win.makeKeyAndOrderFront(nil)

        // If a secondary screen exists, jump to fullscreen on it.
        if NSScreen.screens.count > 1 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                win.toggleFullScreen(nil)
            }
        }

        window = win
    }

    /// Closes the detached window (if any).
    func close() {
        guard let w = window else { return }
        w.close()
        // windowWillClose handles cleanup.
    }

    // MARK: NSWindowDelegate

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.monitor?.stop()
            self.monitor = nil
            self.window = nil
            StatusBoardManager.shared.detachedWindowDidClose()
        }
    }
}
