// ConnectionTableView.swift
// SNAP — Active Connections Table
// Created by Sevag Bardakjian

import SwiftUI

struct Connection: Identifiable , Hashable {
    let id = UUID()
    static func == (lhs: Connection, rhs: Connection) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    var proto: String
    var localAddr: String
    var localPort: String
    var remoteAddr: String
    var remotePort: String
    var state: String
    var pid: String
    var process: String
}

final class ConnectionTableModel: ObservableObject {
    @Published var connections: [Connection] = []
    @Published var isLoading = false
    @Published var filterState = "All"
    @Published var searchText = ""
    @Published var autoRefresh = false
    private var timer: Timer?

    var filtered: [Connection] {
        connections.filter { c in
            (filterState == "All" || c.state == filterState) &&
            (searchText.isEmpty ||
             c.remoteAddr.contains(searchText) ||
             c.localAddr.contains(searchText) ||
             c.process.localizedCaseInsensitiveContains(searchText) ||
             c.state.localizedCaseInsensitiveContains(searchText))
        }
    }

    var allStates: [String] {
        ["All"] + Array(Set(connections.map { $0.state })).sorted()
    }

    func load() {
        guard !isLoading else { return }  // auto-refresh can tick faster than netstat returns
        isLoading = true
        Task {
            // Build results off-main-actor then hand to MainActor — no captured var mutation
            let parsed: [Connection] = self.parseNetstat()
            await MainActor.run {
                self.connections = parsed
                self.isLoading = false
            }
        }
    }

    private func parseNetstat() -> [Connection] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        task.arguments = ["-anv", "-p", "tcp"]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        // Drain the pipe before waiting — netstat output can exceed the pipe
        // buffer, and waiting first deadlocks both processes (see Shell.run)
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        task.waitUntilExit()

        var results: [Connection] = []
        for line in out.components(separatedBy: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 6 else { continue }
            let proto = parts[0]
            guard proto.hasPrefix("tcp") else { continue }
            let local = splitAddrPort(parts[3])
            let remote = splitAddrPort(parts[4])
            let state = parts.count > 5 ? parts[5] : "-"
            let pid = parts.count > 8 ? parts[8] : ""
            results.append(Connection(
                proto: proto,
                localAddr: local.0, localPort: local.1,
                remoteAddr: remote.0, remotePort: remote.1,
                state: state, pid: pid, process: ""
            ))
        }
        return results
    }

    func startAutoRefresh() {
        autoRefresh = true
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.load() }
    }
    func stopAutoRefresh() {
        timer?.invalidate(); timer = nil; autoRefresh = false
    }

    private func splitAddrPort(_ s: String) -> (String, String) {
        if s.hasPrefix("[") { // IPv6
            if let close = s.lastIndex(of: "]"), s.indices.contains(s.index(after: close)) {
                let addr = String(s[s.index(after: s.startIndex)..<close])
                let port = String(s[s.index(s.index(after: close), offsetBy: 1)...])
                return (addr, port)
            }
        }
        if let dot = s.lastIndex(of: ".") {
            return (String(s[..<dot]), String(s[s.index(after: dot)...]))
        }
        return (s, "")
    }
}

struct ConnectionTableView: View {
    @StateObject private var model = ConnectionTableModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "list.bullet.rectangle").foregroundStyle(.blue)
                TextField("Filter by host/process/state...", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                Picker("State", selection: $model.filterState) {
                    ForEach(model.allStates, id: \.self) { s in Text(s).tag(s) }
                }
                .frame(width: 130)
                Toggle("Auto-refresh (3s)", isOn: Binding(
                    get: { model.autoRefresh },
                    set: { if $0 { model.startAutoRefresh() } else { model.stopAutoRefresh() } }
                ))
                .toggleStyle(.checkbox).font(.caption)
                Spacer()
                if !model.filtered.isEmpty {
                    ToolActionBar("Connections",
                                  text: { "proto\tlocal\tremote\tstate\tpid\tprocess\n" + model.filtered.map { "\($0.proto)\t\($0.localAddr):\($0.localPort)\t\($0.remoteAddr):\($0.remotePort)\t\($0.state)\t\($0.pid)\t\($0.process)" }.joined(separator: "\n") },
                                  csv: { "proto,local_addr,local_port,remote_addr,remote_port,state,pid,process\n" + model.filtered.map { "\($0.proto),\($0.localAddr),\($0.localPort),\($0.remoteAddr),\($0.remotePort),\($0.state),\($0.pid),\(csvEscape($0.process))" }.joined(separator: "\n") })
                }
                if model.isLoading { ProgressView().controlSize(.small) }
                Button("Refresh") { model.load() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut("r", modifiers: .command)
                Text("\(model.filtered.count) connections").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(NS.bg0)

            Divider()

            Table(model.filtered) {
                TableColumn("Proto") { c in
                    Text(c.proto).font(.caption.monospaced())
                        .foregroundStyle(c.proto.contains("6") ? .purple : .blue)
                }.width(50)
                TableColumn("Local Address") { c in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.localAddr).font(.caption.monospaced())
                        Text(":\(c.localPort)").font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                    .hostMenu(c.localAddr)
                }
                TableColumn("Remote Address") { c in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.remoteAddr == "*" ? "Any" : c.remoteAddr).font(.caption.monospaced())
                        Text(":\(c.remotePort)").font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                    .hostMenu(c.remoteAddr == "*" ? c.localAddr : c.remoteAddr)
                }
                TableColumn("State") { c in
                    Text(c.state)
                        .font(.caption.monospaced())
                        .foregroundStyle(stateColor(c.state))
                        .padding(2)
                        .background(stateColor(c.state).opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }.width(120)
                TableColumn("PID") { c in
                    Text(c.pid).font(.caption.monospaced()).foregroundStyle(.secondary)
                }.width(50)
            }
        }
        .tabNavigationTitle(.connections)
        .onAppear { model.load() }
        .onDisappear { model.stopAutoRefresh() }
        // Auto-refresh (if you turned it on) keeps running in the background;
        // otherwise take a fresh snapshot on return, as opening the tab did.
        .onTabVisibilityChange(shown: { if !model.autoRefresh { model.load() } })
    }

    private func stateColor(_ state: String) -> Color {
        switch state.uppercased() {
        case "ESTABLISHED": return .green
        case "LISTEN":      return .blue
        case "TIME_WAIT":   return .orange
        case "CLOSE_WAIT":  return .yellow
        case "SYN_SENT":    return .teal
        case "FIN_WAIT_1", "FIN_WAIT_2": return .red
        default:            return .gray
        }
    }
}
