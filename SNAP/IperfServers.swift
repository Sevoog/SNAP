// IperfServers.swift
// SNAP: Saved and recent iPerf3 servers (v1.5.8)
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md
//
// Servers you save with a name, plus the last few you tested (read from the
// LAN test history, so clearing that history clears them too). Saved servers
// show as chips under the toolbar; before a test, the empty pane lists saved
// and recent servers as cards. The last server you ran a test against is
// filled in when the iPerf3 pane opens.

import SwiftUI

struct IperfServer: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var host: String
    var port: String

    var address: String { "\(host):\(port)" }
    /// The name, or the address while the name is blank (mid-edit in Manage).
    var displayName: String {
        name.trimmingCharacters(in: .whitespaces).isEmpty ? host : name
    }
}

/// A server from the LAN test history that isn't saved.
struct IperfRecentServer: Equatable {
    let host: String
    let port: String
    let lastTested: Date
    var address: String { "\(host):\(port)" }
}

@MainActor
final class IperfServerStore: ObservableObject {
    static let shared = IperfServerStore()

    static let savedKey = "com.sevagbardakjian.snap.iperf.savedServers"
    static let lastKey = "com.sevagbardakjian.snap.iperf.lastServer"
    static let recentLimit = 5

    @Published private(set) var saved: [IperfServer] = []
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.savedKey),
           let decoded = try? JSONDecoder().decode([IperfServer].self, from: data) {
            saved = decoded
        }
    }

    /// Saves a server, or renames it if that address is already saved. A
    /// blank name uses the address.
    func save(name: String, host: String, port: String) {
        let host = host.trimmingCharacters(in: .whitespaces)
        let port = Self.port(port)
        guard !host.isEmpty else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let name = trimmed.isEmpty ? host : trimmed
        if let i = saved.firstIndex(where: { Self.same($0, host, port) }) {
            saved[i].name = name
        } else {
            saved.append(IperfServer(name: name, host: host, port: port))
        }
        persist()
    }

    /// Stores the text as typed, so the field can be cleared and retyped;
    /// a blank name shows the address instead.
    func rename(_ id: UUID, to name: String) {
        guard let i = saved.firstIndex(where: { $0.id == id }) else { return }
        saved[i].name = name
        persist()
    }

    func remove(_ id: UUID) {
        saved.removeAll { $0.id == id }
        persist()
    }

    func isSaved(host: String, port: String) -> Bool {
        saved.contains { Self.same($0, host.trimmingCharacters(in: .whitespaces), Self.port(port)) }
    }

    /// The last tested servers that aren't saved, newest first, one per address.
    func recent(from history: [IperfHistoryEntry]) -> [IperfRecentServer] {
        var seen = Set<String>()
        var out: [IperfRecentServer] = []
        for e in history {
            let port = Self.port(e.port)
            let key = "\(e.server.lowercased()):\(port)"
            guard !isSaved(host: e.server, port: port), seen.insert(key).inserted else { continue }
            out.append(IperfRecentServer(host: e.server, port: port, lastTested: e.date))
            if out.count == Self.recentLimit { break }
        }
        return out
    }

    // MARK: Last server

    func recordUse(host: String, port: String) {
        defaults.set(["host": host.trimmingCharacters(in: .whitespaces), "port": Self.port(port)], forKey: Self.lastKey)
    }

    var lastUsed: (host: String, port: String)? {
        guard let d = defaults.dictionary(forKey: Self.lastKey) as? [String: String],
              let host = d["host"], !host.isEmpty else { return nil }
        return (host, d["port"] ?? "5201")
    }

    // MARK: Helpers

    /// iperf3's default port when the field is blank.
    static func port(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "5201" : t
    }

    private static func same(_ s: IperfServer, _ host: String, _ port: String) -> Bool {
        s.host.caseInsensitiveCompare(host) == .orderedSame && s.port == port
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: Self.savedKey) }
    }
}

// MARK: - Chips

/// Saved servers as one-click chips under the toolbar, with Save and Manage.
/// The chip matching the fields is highlighted.
struct IperfServerChips: View {
    @ObservedObject var store: IperfServerStore
    let current: (host: String, port: String)
    let disabled: Bool
    let onPick: (String, String) -> Void
    let onSave: () -> Void
    let onRename: (IperfServer) -> Void
    let onManage: () -> Void

    private var hasHost: Bool { !current.host.trimmingCharacters(in: .whitespaces).isEmpty }
    private var currentSaved: Bool { store.isSaved(host: current.host, port: current.port) }

    var body: some View {
        HStack(spacing: 8) {
            Text("Saved:").font(.caption).foregroundStyle(NS.text2).fixedSize()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if store.saved.isEmpty {
                        Text("Save servers you test often: enter an address, then click Save.")
                            .font(.caption).foregroundStyle(NS.text3)
                    }
                    ForEach(store.saved) { s in
                        chip(s)
                    }
                }
                .padding(.vertical, 1)
            }
            Spacer(minLength: 4)
            Button { onSave() } label: { Label("Save", systemImage: "plus") }
                .controlSize(.small)
                .disabled(!hasHost || currentSaved)
                .help(currentSaved ? "This server is already saved" : "Save the server in the fields")
            if !store.saved.isEmpty {
                Button("Manage…") { onManage() }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
            }
        }
    }

    private func chip(_ s: IperfServer) -> some View {
        let selected = s.host.caseInsensitiveCompare(current.host.trimmingCharacters(in: .whitespaces)) == .orderedSame
            && s.port == IperfServerStore.port(current.port)
        return Button { onPick(s.host, s.port) } label: {
            Text(s.displayName)
                .font(.caption.weight(selected ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 3)
                .foregroundStyle(selected ? NS.text1 : NS.text2)
                .background(Capsule().fill(selected ? NS.blue.opacity(0.22) : NS.bg2))
                .overlay(Capsule().strokeBorder(selected ? NS.blue : NS.text3.opacity(0.45), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help("\(s.address)")
        .contextMenu {
            Button("Rename…") { onRename(s) }
            Button("Remove", role: .destructive) { store.remove(s.id) }
        }
    }
}

// MARK: - Cards (empty pane)

/// Saved and recent servers as cards, shown before a test runs.
struct IperfServerCards: View {
    @ObservedObject var store: IperfServerStore
    @ObservedObject var history: IperfHistoryStore
    let onPick: (String, String) -> Void

    var body: some View {
        let recent = store.recent(from: history.entries)
        if !store.saved.isEmpty || !recent.isEmpty {
            VStack(spacing: 8) {
                Text("Or pick a server:").font(.caption).foregroundStyle(NS.text2)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 220), spacing: 10)], spacing: 10) {
                    ForEach(store.saved) { s in
                        card(icon: "star.fill", title: s.displayName, detail: s.address) { onPick(s.host, s.port) }
                    }
                    ForEach(recent, id: \.address) { r in
                        card(icon: "clock", title: r.address,
                             detail: "Tested \(r.lastTested.formatted(.relative(presentation: .named)))") { onPick(r.host, r.port) }
                    }
                }
                .frame(maxWidth: 700)
            }
        }
    }

    private func card(icon: String, title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(icon == "star.fill" ? NS.amber : NS.text2)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.medium)).foregroundStyle(NS.text1).lineLimit(1)
                    Text(detail).font(.caption).foregroundStyle(NS.text2).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 8).fill(NS.bg2))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(NS.bg3, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Fill in \(title)")
    }
}

// MARK: - Manage sheet

struct IperfServerManager: View {
    @ObservedObject var store: IperfServerStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Saved iPerf3 Servers").font(.headline).foregroundStyle(NS.text1)
            if store.saved.isEmpty {
                Text("No saved servers.").font(.callout).foregroundStyle(NS.text2)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(store.saved) { s in
                            HStack(spacing: 10) {
                                TextField("Name", text: Binding(get: { s.name },
                                                                set: { store.rename(s.id, to: $0) }))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 180)
                                Text(s.address)
                                    .font(.system(.callout, design: .monospaced))
                                    .foregroundStyle(NS.text2)
                                    .textSelection(.enabled)
                                Spacer()
                                Button { store.remove(s.id) } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("Remove \(s.displayName)")
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
            HStack {
                Text("To add a server, enter its address and port, then click Save next to your saved servers.")
                    .font(.caption).foregroundStyle(NS.text3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(NS.bg1)
    }
}
