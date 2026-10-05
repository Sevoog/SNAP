// HostContextMenu.swift
// SNAP — Right-click menu shared by every view that shows a host or IP
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
//
// Attach via `.hostMenu(host)`. The menu offers Copy, send-to-tool actions
// (Ping / Traceroute / Port Scan / Lookup / Whois), and "Find in Network Map"
// / "Add to Favorites". Tab navigation is routed via `ToolHandoff.shared`
// so call sites don't need a `selectedTab` binding plumbed through.

import SwiftUI
import AppKit

struct HostContextMenu: ViewModifier {
    let host: String
    @ObservedObject private var favs = FavoritesManager.shared

    func body(content: Content) -> some View {
        // Without an explicit content shape SwiftUI only registers right-clicks
        // on the rendered text/glyph area, so clicks just outside the text miss.
        // A transparent Rectangle hit-test fills the full bounds of the wrapped
        // view so the menu fires anywhere the cursor visually sits on the row.
        content
            .contentShape(Rectangle())
            .contextMenu {
            Text(verbatim: host)
                .foregroundStyle(NS.amber)
                .font(.system(size: 11, design: .monospaced))

            Divider()

            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(host, forType: .string)
            } label: { Label("Copy", systemImage: "doc.on.doc") }

            Divider()

            Button {
                ToolHandoff.shared.send(host, to: .ping)
            } label: { Label("Send to Ping", systemImage: "dot.radiowaves.left.and.right") }

            Button {
                ToolHandoff.shared.send(host, to: .traceroute)
            } label: { Label("Send to Traceroute", systemImage: "arrow.up.right.circle") }

            Button {
                ToolHandoff.shared.send(host, to: .portScan)
            } label: { Label("Send to Port Scan", systemImage: "circle.grid.3x3") }

            Button {
                ToolHandoff.shared.send(host, to: .lookup)
            } label: { Label("Lookup DNS", systemImage: "magnifyingglass") }

            Button {
                ToolHandoff.shared.send(host, to: .whois)
            } label: { Label("Whois", systemImage: "info.bubble") }

            Divider()

            Button {
                ToolHandoff.shared.goto(.networkMap)
            } label: { Label("Find in Network Map", systemImage: "circle.hexagongrid.fill") }

            if favs.contains(host: host) {
                Button {
                    if let id = favs.items.first(where: {
                        $0.host.caseInsensitiveCompare(host) == .orderedSame
                    })?.id {
                        favs.remove(id)
                    }
                } label: { Label("Remove from Favorites", systemImage: "star.slash") }
            } else {
                Button {
                    favs.add(host: host)
                } label: { Label("Add to Favorites", systemImage: "star") }
            }
        }
    }
}

extension View {
    /// Adds the standard SNAP host context menu. Tab nav is routed via
    /// `ToolHandoff.shared`, so call sites don't need a `selectedTab` binding.
    func hostMenu(_ host: String) -> some View {
        modifier(HostContextMenu(host: host))
    }
}
