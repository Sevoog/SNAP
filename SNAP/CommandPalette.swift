// CommandPalette.swift
// SNAP — ⌘K fuzzy launcher + quick actions
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian. All rights reserved.
//
// Press ⌘K from anywhere in SNAP to open a Spotlight-style modal. Categorized
// list of every tool, every theme, and the common actions. Type to filter.
// Special pattern parsing: `ping HOST`, `lookup HOST`, `trace HOST`, `scan HOST`,
// `whois DOMAIN` execute the action inline without leaving the bar.

import SwiftUI

// MARK: - Manager

@MainActor
final class CommandPaletteManager: ObservableObject {
    static let shared = CommandPaletteManager()
    @Published var isPresented = false
    private init() {}
    func toggle() { isPresented.toggle() }
}

// MARK: - Command model

struct PaletteCommand: Identifiable {
    enum Kind { case nav, theme, action, run }

    let id = UUID()
    let section: String
    let icon: String
    let title: String
    let subtitle: String
    let kind: Kind
    let perform: @MainActor () -> Void
}

extension PaletteCommand.Kind {
    var label: String {
        switch self {
        case .nav: "NAV"; case .theme: "THEME"; case .action: "ACTION"; case .run: "RUN"
        }
    }
    var color: Color {
        switch self {
        case .nav:    NS.blue
        case .theme:  NS.amber
        case .action: NS.purple
        case .run:    NS.green
        }
    }
}

// MARK: - Registry builder

enum CommandRegistry {
    /// Builds the full command list given the live bindings/managers.
    static func build(selectedTab: Binding<SNAPTab>,
                      themeMgr: ThemeManager) -> [PaletteCommand] {
        var out: [PaletteCommand] = []

        // Navigation — every tab the user can land on.
        for tab in SNAPTab.allCases where tab != .dashboard {
            out.append(.init(section: "Tools", icon: tab.icon,
                             title: tab.rawValue,
                             subtitle: "Open the \(tab.rawValue) tab",
                             kind: .nav) {
                selectedTab.wrappedValue = tab
            })
        }
        // Dashboard itself.
        out.insert(.init(section: "Tools", icon: SNAPTab.dashboard.icon,
                         title: "Dashboard",
                         subtitle: "Go to the customizable dashboard",
                         kind: .nav) {
            selectedTab.wrappedValue = .dashboard
        }, at: 0)

        // Themes.
        for theme in Theme.all {
            out.append(.init(section: "Themes", icon: "paintbrush.fill",
                             title: "Switch to \(theme.name)",
                             subtitle: "\(theme.group) theme",
                             kind: .theme) {
                themeMgr.select(theme)
            })
        }

        // Actions.
        out.append(.init(section: "Actions", icon: "tv",
                         title: "Enter Status Board",
                         subtitle: "Full-screen ambient display · ⌘⇧B",
                         kind: .action) {
            StatusBoardManager.shared.isPresented = true
        })
        out.append(.init(section: "Actions", icon: "doc.text",
                         title: "Save Session Report…",
                         subtitle: "⌘⇧R · HTML snapshot of network state",
                         kind: .action) {
            NotificationCenter.default.post(name: .exportSessionReport, object: nil)
        })
        out.append(.init(section: "Actions", icon: "questionmark.circle",
                         title: "Quick Tour",
                         subtitle: "Re-open the welcome walkthrough",
                         kind: .action) {
            OnboardingManager.shared.show()
        })

        return out
    }

    /// Parses the query for "ping HOST" / "lookup HOST" / etc. and prepends a
    /// "run inline" command if matched. Returns nil if no match.
    static func inlineRun(for query: String) -> PaletteCommand? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        let verb = parts[0].lowercased()
        let host = String(parts[1]).trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return nil }

        let mapping: [String: (SNAPTab, String)] = [
            "ping":       (.ping,       "Run Ping against"),
            "lookup":     (.lookup,     "DNS Lookup of"),
            "dns":        (.lookup,     "DNS Lookup of"),
            "trace":      (.traceroute, "Traceroute to"),
            "traceroute": (.traceroute, "Traceroute to"),
            "scan":       (.portScan,   "Port Scan of"),
            "whois":      (.whois,      "Whois of"),
            "geo":        (.geoIP,      "GeoIP of"),
            "geoip":      (.geoIP,      "GeoIP of"),
            "bgp":        (.bgp,        "BGP/ASN lookup of"),
            "http":       (.http,       "HTTP probe of"),
        ]
        guard let (tab, prefix) = mapping[verb] else { return nil }
        return .init(section: "Run", icon: "play.fill",
                     title: "\(verb.capitalized) \(host)",
                     subtitle: "\(prefix) \(host)",
                     kind: .run) {
            ToolHandoff.shared.send(host, to: tab)
        }
    }
}

// MARK: - The view

struct CommandPaletteView: View {
    @ObservedObject private var mgr = CommandPaletteManager.shared
    @ObservedObject private var themeMgr = ThemeManager.shared
    @Binding var selectedTab: SNAPTab

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var inputFocused: Bool

    private var allCommands: [PaletteCommand] {
        CommandRegistry.build(selectedTab: $selectedTab, themeMgr: themeMgr)
    }

    private var filtered: [PaletteCommand] {
        var list: [PaletteCommand] = []
        if let inline = CommandRegistry.inlineRun(for: query) {
            list.append(inline)
        }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty {
            list.append(contentsOf: allCommands)
        } else {
            list.append(contentsOf: allCommands.filter { c in
                c.title.lowercased().contains(q) || c.subtitle.lowercased().contains(q)
            })
        }
        return list
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundStyle(NS.text3)
                TextField("Search tools, run actions, switch theme…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($inputFocused)
                    .onChange(of: query) { _ in selectedIndex = 0 }
                    .onSubmit { execute() }
                Text(verbatim: "Esc")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(NS.text3)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(NS.bg3)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .padding(14)
            .overlay(Rectangle().fill(NS.border).frame(height: 1), alignment: .bottom)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let cmds = filtered
                        if cmds.isEmpty {
                            Text("No matches")
                                .font(.system(size: 12))
                                .foregroundStyle(NS.text3)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 30)
                        } else {
                            ForEach(Array(cmds.enumerated()), id: \.element.id) { idx, cmd in
                                if idx == 0 || cmds[idx - 1].section != cmd.section {
                                    Text(cmd.section.uppercased())
                                        .font(.system(size: 9, weight: .bold))
                                        .tracking(0.5)
                                        .foregroundStyle(NS.text3)
                                        .padding(.horizontal, 14)
                                        .padding(.top, 8).padding(.bottom, 3)
                                }
                                row(cmd, isSelected: idx == selectedIndex)
                                    .id(cmd.id)
                                    .onHover { hovering in
                                        if hovering { selectedIndex = idx }
                                    }
                                    .onTapGesture { selectedIndex = idx; execute() }
                            }
                        }
                    }
                }
                .frame(maxHeight: 380)
                .onChange(of: selectedIndex) { idx in
                    if idx < filtered.count {
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo(filtered[idx].id, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(width: 580)
        .background(NS.bg2)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(NS.borderMid))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.5), radius: 30, y: 14)
        .onAppear {
            query = ""
            selectedIndex = 0
            inputFocused = true
        }
        .background(
            // Hidden buttons for keyboard navigation.
            Group {
                Button("") { moveSel(1) }
                    .keyboardShortcut(.downArrow, modifiers: [])
                Button("") { moveSel(-1) }
                    .keyboardShortcut(.upArrow, modifiers: [])
                Button("") { mgr.isPresented = false }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .opacity(0)
        )
    }

    private func row(_ cmd: PaletteCommand, isSelected: Bool) -> some View {
        HStack(spacing: 11) {
            Image(systemName: cmd.icon)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? NS.amber : NS.text2)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: cmd.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(NS.text1)
                Text(verbatim: cmd.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(NS.text3)
                    .lineLimit(1)
            }
            Spacer()
            Text(cmd.kind.label)
                .font(.system(size: 9, weight: .bold))
                .tracking(0.4)
                .foregroundStyle(cmd.kind.color)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(cmd.kind.color.opacity(0.13))
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(isSelected ? NS.amber.opacity(0.10) : .clear)
        .overlay(
            Rectangle()
                .fill(isSelected ? NS.amber : .clear)
                .frame(width: 2),
            alignment: .leading
        )
    }

    private func moveSel(_ delta: Int) {
        let n = filtered.count
        guard n > 0 else { return }
        selectedIndex = (selectedIndex + delta + n) % n
    }

    private func execute() {
        let list = filtered
        guard selectedIndex >= 0, selectedIndex < list.count else { return }
        mgr.isPresented = false
        list[selectedIndex].perform()
    }
}
