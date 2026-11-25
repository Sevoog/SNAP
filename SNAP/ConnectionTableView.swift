// ConnectionTableView.swift
// SNAP — Active Connections Table
// Created by Sevag Bardakjian
// Copyright © 2025-2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md

import SwiftUI
import Darwin

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
    /// netstat cut the address short and SNAP couldn't read the full one
    /// (the socket belongs to a process run by another user, like root)
    var localCut = false
    var remoteCut = false
}

final class ConnectionTableModel: ObservableObject {
    @Published var connections: [Connection] = []
    @Published var isLoading = false
    @Published var filterState = "All"
    @Published var searchText = ""
    @Published var autoRefresh = false
    // Set when netstat couldn't run or printed nothing we recognize
    @Published var loadError: String?
    /// Set when the list came from SNAP's own read, not netstat
    @Published var sourceNote: String?
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
            var netstat = self.runNetstat()
            // macOS 27 can give SNAP's own netstat an empty list; launchd's
            // run of it gets the full one, as Terminal does
            if netstat.map({ Self.parseNetstat($0).isEmpty }) ?? true,
               let viaLaunchd = await Shell.runViaLaunchd("/usr/sbin/netstat", args: ["-anv", "-p", "tcp"]),
               !Self.parseNetstat(viaLaunchd).isEmpty {
                netstat = viaLaunchd
            }
            let result = Self.read(netstat: netstat)
            await MainActor.run {
                self.connections = result.rows
                self.sourceNote = result.note
                self.loadError = result.error
                self.isLoading = false
            }
        }
    }

    /// The rows to show, from netstat when it lists anything. macOS 27 can
    /// give SNAP's netstat an empty list (headers only), which used to show
    /// as a blank table with no explanation; then the list comes from
    /// SNAP's own read of the sockets of apps running as you.
    static func read(netstat: String?,
                                 ownConnections: () -> [Connection] = { SocketTable.connections() })
        -> (rows: [Connection], note: String?, error: String?) {
        let fromNetstat = netstat.map(parseNetstat) ?? []
        if !fromNetstat.isEmpty { return (fillInIPv6(fromNetstat), nil, nil) }
        let own = ownConnections()
        if !own.isEmpty { return (own, WithheldLists.connectionsLimitedNote, nil) }
        if netstat == nil {
            return ([], nil, "SNAP couldn't read the connection list from macOS. Click Refresh to try again.")
        }
        return ([], nil, WithheldLists.connectionsMessage)
    }

    /// netstat's output, or nil if it couldn't run or exited with an error.
    private func runNetstat() -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        task.arguments = ["-anv", "-p", "tcp"]
        let pipe = Pipe()
        task.standardOutput = pipe
        do { try task.run() } catch { return nil }
        // Drain the pipe before waiting — netstat output can exceed the pipe
        // buffer, and waiting first deadlocks both processes (see Shell.run)
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        task.waitUntilExit()
        guard task.terminationStatus == 0, out.contains("Proto") else { return nil }
        return out
    }

    /// Parses `netstat -anv -p tcp`. Columns are located from the header line
    /// (macOS: Proto Recv-Q Send-Q Local Foreign (state) rxbytes txbytes rhiwat
    /// shiwat process:pid state options ...). The process name can contain
    /// spaces ("Claude Helper:7515"), so process:pid is everything between the
    /// fixed columns before it and the fixed columns after it.
    static func parseNetstat(_ out: String) -> [Connection] {
        let lines = out.components(separatedBy: "\n")
        // Header columns, with the two-word address titles counted as one each
        var processIndex: Int?
        var trailingColumns = 0
        if let header = lines.first(where: { $0.hasPrefix("Proto") }) {
            let cols = header.replacingOccurrences(of: "Local Address", with: "Local")
                .replacingOccurrences(of: "Foreign Address", with: "Foreign")
                .split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if let i = cols.firstIndex(of: "process:pid") {
                processIndex = i
                trailingColumns = cols.count - i - 1
            }
        }

        var results: [Connection] = []
        for line in lines {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 6 else { continue }
            let proto = parts[0]
            guard proto.hasPrefix("tcp") else { continue }
            let local = splitAddrPort(parts[3])
            let remote = splitAddrPort(parts[4])
            let state = parts[5]
            var pid = "", process = ""
            if let pi = processIndex, parts.count - trailingColumns > pi {
                let field = parts[pi..<(parts.count - trailingColumns)].joined(separator: " ")
                if let colon = field.lastIndex(of: ":"), Int(field[field.index(after: colon)...]) != nil {
                    process = field[..<colon].trimmingCharacters(in: .whitespaces)
                    pid = String(field[field.index(after: colon)...])
                }
            }
            results.append(Connection(
                proto: proto,
                localAddr: local.0, localPort: local.1,
                remoteAddr: remote.0, remotePort: remote.1,
                state: state, pid: pid, process: process
            ))
        }
        return results
    }

    /// netstat prints at most this many characters of an IPv6 address in
    /// this view, with or without -W, so a longer one comes out cut short
    /// ("fe80::cd18:d9fb:").
    static let netstatIPv6Width = 16

    /// Replaces IPv6 addresses netstat cut short with the full ones from
    /// the kernel's socket list, matched by ports and by the part of the
    /// address netstat did print. The process netstat names is checked
    /// first; a socket handed to a helper process (a VPN or system service)
    /// is found by checking every process. Sockets of processes run by
    /// another user can't be read; those keep netstat's text, marked cut.
    static func fillInIPv6(_ rows: [Connection]) -> [Connection] {
        let mayBeCut = { (c: Connection, addr: String) in
            c.proto.hasSuffix("6") && addr.count >= netstatIPv6Width
        }
        let needs = rows.filter { mayBeCut($0, $0.localAddr) || mayBeCut($0, $0.remoteAddr) }
        guard !needs.isEmpty else { return rows }

        func match(_ c: Connection, in sockets: [SocketTable.Socket]) -> SocketTable.Socket? {
            guard let lp = UInt16(c.localPort), let rp = UInt16(c.remotePort) else { return nil }
            let fits = { (full: String, shown: String, cut: Bool) in
                cut ? full.hasPrefix(shown) : true
            }
            let candidates = sockets.filter {
                $0.localPort == lp && $0.remotePort == rp &&
                fits($0.local, c.localAddr, mayBeCut(c, c.localAddr)) &&
                fits($0.remote, c.remoteAddr, mayBeCut(c, c.remoteAddr))
            }
            return candidates.first { String($0.pid) == c.pid } ?? candidates.first
        }

        let named = SocketTable.tcp6(pids: Set(needs.compactMap { Int32($0.pid) }))
        var everyone: [SocketTable.Socket]?   // read only if some row needs it
        return rows.map { c in
            var c = c
            let local = mayBeCut(c, c.localAddr), remote = mayBeCut(c, c.remoteAddr)
            guard local || remote else { return c }
            var found = match(c, in: named)
            if found == nil {
                if everyone == nil { everyone = SocketTable.tcp6(pids: SocketTable.allPIDs()) }
                found = match(c, in: everyone ?? [])
            }
            if let found {
                if local { c.localAddr = found.local }
                if remote { c.remoteAddr = found.remote }
            } else {
                c.localCut = local
                c.remoteCut = remote
            }
            return c
        }
    }

    func startAutoRefresh() {
        autoRefresh = true
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.load() }
    }
    func stopAutoRefresh() {
        timer?.invalidate(); timer = nil; autoRefresh = false
    }

    private static func splitAddrPort(_ s: String) -> (String, String) {
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
            // One row when it fits; otherwise the refresh controls wrap to a second row
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    Image(systemName: "list.bullet.rectangle").foregroundStyle(.blue)
                    searchField.frame(width: 240)
                    statePicker
                    autoRefreshToggle
                    Spacer()
                    refreshControls
                }
                VStack(spacing: 8) {
                    HStack(spacing: 12) {
                        Image(systemName: "list.bullet.rectangle").foregroundStyle(.blue)
                        searchField.frame(maxWidth: .infinity)
                        statePicker
                    }
                    HStack(spacing: 12) {
                        autoRefreshToggle
                        Spacer()
                        refreshControls
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(NS.bg0)

            Divider()

            if let note = model.sourceNote {
                WithheldNotice(text: note)
                Divider()
            }

            if let err = model.loadError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(NS.amber)
                    Text(err).font(.system(size: 12)).foregroundStyle(NS.text1)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(NS.amber.opacity(0.08))
                Divider()
            }

            Table(model.filtered) {
                TableColumn("Proto") { c in
                    Text(c.proto).font(.caption.monospaced())
                        .foregroundStyle(c.proto.contains("6") ? .purple : .blue)
                }.width(50)
                TableColumn("Local Address") { c in
                    addressCell(c.localAddr, port: c.localPort, cut: c.localCut, menuHost: c.localAddr)
                }
                TableColumn("Remote Address") { c in
                    addressCell(c.remoteAddr == "*" ? "Any" : c.remoteAddr, port: c.remotePort,
                                cut: c.remoteCut,
                                menuHost: c.remoteAddr == "*" ? (c.localCut ? nil : c.localAddr) : c.remoteAddr)
                }
                TableColumn("State") { c in
                    Text(c.state)
                        .font(.caption.monospaced())
                        .foregroundStyle(stateColor(c.state))
                        .padding(2)
                        .background(stateColor(c.state).opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }.width(120)
                TableColumn("Process") { c in
                    Text(c.process).font(.caption).lineLimit(1)
                }.width(min: 80, ideal: 120)
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

    private var searchField: some View {
        TextField("Filter by host/process/state...", text: $model.searchText)
            .textFieldStyle(.roundedBorder)
    }

    private var statePicker: some View {
        Picker("State", selection: $model.filterState) {
            ForEach(model.allStates, id: \.self) { s in Text(s).tag(s) }
        }
        .frame(width: 130)
    }

    private var autoRefreshToggle: some View {
        Toggle("Auto-refresh (3s)", isOn: Binding(
            get: { model.autoRefresh },
            set: { if $0 { model.startAutoRefresh() } else { model.stopAutoRefresh() } }
        ))
        .toggleStyle(.checkbox).font(.caption)
        .fixedSize()
    }

    // Copy/Export, the spinner and the count keep their slots while hidden or
    // changing, so filtering or an auto-refresh tick never reflows the toolbar
    @ViewBuilder
    private var refreshControls: some View {
        ToolActionBar("Connections",
                      text: { "proto\tlocal\tremote\tstate\tpid\tprocess\n" + model.filtered.map { "\($0.proto)\t\($0.localAddr):\($0.localPort)\t\($0.remoteAddr):\($0.remotePort)\t\($0.state)\t\($0.pid)\t\($0.process)" }.joined(separator: "\n") },
                      csv: { "proto,local_addr,local_port,remote_addr,remote_port,state,pid,process\n" + model.filtered.map { "\($0.proto),\($0.localAddr),\($0.localPort),\($0.remoteAddr),\($0.remotePort),\($0.state),\($0.pid),\(csvEscape($0.process))" }.joined(separator: "\n") })
            .opacity(model.filtered.isEmpty ? 0 : 1)
            .disabled(model.filtered.isEmpty)
            .accessibilityHidden(model.filtered.isEmpty)
        ProgressView().controlSize(.small)
            .opacity(model.isLoading ? 1 : 0)
            .accessibilityHidden(!model.isLoading)
        Button("Refresh") { model.load() }
            .buttonStyle(.bordered)
            .keyboardShortcut("r", modifiers: .command)
            .fixedSize()
        ZStack(alignment: .leading) {
            Text("0000 connections").hidden()
            Text("\(model.filtered.count) connections")
        }
        .font(.caption2).foregroundStyle(.secondary)
        .fixedSize()
    }

    /// An address and port. A cut-short address ends in "…" and has no
    /// host menu, since Ping or Copy would get the wrong address.
    @ViewBuilder
    private func addressCell(_ addr: String, port: String, cut: Bool, menuHost: String?) -> some View {
        let stack = VStack(alignment: .leading, spacing: 1) {
            Text(cut ? addr + "…" : addr).font(.caption.monospaced())
            Text(":\(port)").font(.caption2.monospaced()).foregroundStyle(.secondary)
        }
        if cut {
            stack.help("macOS shortened this address, and SNAP can't read the full one because another user (such as root) owns the connection.")
        } else if let menuHost {
            stack.hostMenu(menuHost)
        } else {
            stack
        }
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

// MARK: - Full IPv6 addresses from the kernel

/// Reads TCP-over-IPv6 sockets with libproc, the same per-process socket
/// info Activity Monitor and lsof use. No root needed for your own
/// processes; other users' processes are skipped.
enum SocketTable {
    struct Socket {
        let pid: Int32
        let localPort: UInt16
        let remotePort: UInt16
        let local: String
        let remote: String
        /// "tcp4", "tcp6", or "tcp46" (a dual-stack socket), as netstat says
        let proto: String
        let state: String
    }

    /// Every process ID on this Mac.
    static func allPIDs() -> Set<Int32> {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(n) * 2)   // room to grow
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        return Set(pids.prefix(Int(max(got, 0))).filter { $0 > 0 })
    }

    /// TCP-over-IPv6 sockets (including dual-stack ones) of `pids`.
    static func tcp6(pids: Set<Int32>) -> [Socket] {
        tcp(pids: pids).filter { $0.proto.hasSuffix("6") }
    }

    /// Every TCP socket of apps running as you, as table rows: the same
    /// columns netstat fills, with the process name from the kernel.
    /// Duplicates (one socket shared by several file descriptors or
    /// processes) are listed once.
    static func connections(pids: Set<Int32> = allPIDs()) -> [Connection] {
        var seen = Set<String>()
        var rows: [Connection] = []
        for sock in tcp(pids: pids) {
            let key = "\(sock.pid)|\(sock.proto)|\(sock.local)|\(sock.localPort)|\(sock.remote)|\(sock.remotePort)"
            guard seen.insert(key).inserted else { continue }
            rows.append(Connection(proto: sock.proto,
                                   localAddr: sock.local, localPort: String(sock.localPort),
                                   remoteAddr: sock.remote,
                                   remotePort: sock.remotePort == 0 ? "*" : String(sock.remotePort),
                                   state: sock.state, pid: String(sock.pid),
                                   process: processName(sock.pid)))
        }
        // Steady order, so auto-refresh doesn't shuffle the table
        return rows.sorted {
            ($0.process.lowercased(), Int($0.pid) ?? 0, Int($0.localPort) ?? 0)
                < ($1.process.lowercased(), Int($1.pid) ?? 0, Int($1.localPort) ?? 0)
        }
    }

    static func processName(_ pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        return proc_name(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : ""
    }

    /// netstat's names for the kernel's TCP states (TCPS_CLOSED = 0 ...).
    static func stateName(_ state: Int32) -> String {
        let names = ["CLOSED", "LISTEN", "SYN_SENT", "SYN_RCVD", "ESTABLISHED", "CLOSE_WAIT",
                     "FIN_WAIT_1", "CLOSING", "LAST_ACK", "FIN_WAIT_2", "TIME_WAIT"]
        return names.indices.contains(Int(state)) ? names[Int(state)] : "state \(state)"
    }

    static func tcp(pids: Set<Int32>) -> [Socket] {
        var out: [Socket] = []
        for pid in pids {
            let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard size > 0 else { continue }
            let stride = MemoryLayout<proc_fdinfo>.stride
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride)
            let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, size)
            guard got > 0 else { continue }
            for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
                var info = socket_fdinfo()
                let infoSize = Int32(MemoryLayout<socket_fdinfo>.size)
                guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, infoSize) == infoSize,
                      info.psi.soi_kind == SOCKINFO_TCP else { continue }
                let tcpInfo = info.psi.soi_proto.pri_tcp
                let ini = tcpInfo.tcpsi_ini
                let v4 = ini.insi_vflag & UInt8(INI_IPV4) != 0
                let v6 = ini.insi_vflag & UInt8(INI_IPV6) != 0
                guard v4 || v6 else { continue }
                let local: String, remote: String
                if v6 {
                    let ifindex = UInt32(ini.insi_v6.in6_ifindex)
                    local = text(ini.insi_laddr.ina_6, ifindex: ifindex)
                    remote = text(ini.insi_faddr.ina_6, ifindex: ifindex)
                } else {
                    local = text(ini.insi_laddr.ina_46.i46a_addr4)
                    remote = text(ini.insi_faddr.ina_46.i46a_addr4)
                }
                out.append(Socket(pid: pid,
                                  localPort: UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport)),
                                  remotePort: UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_fport)),
                                  local: local, remote: remote,
                                  proto: v4 && v6 ? "tcp46" : v6 ? "tcp6" : "tcp4",
                                  state: stateName(tcpInfo.tcpsi_state)))
            }
        }
        return out
    }

    /// An IPv4 address as netstat writes it: "*" for any address.
    static func text(_ address: in_addr) -> String {
        guard address.s_addr != 0 else { return "*" }
        var a = address
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count)) != nil else { return "" }
        return String(cString: buf)
    }

    /// An IPv6 address as netstat would write it in full. The kernel keeps
    /// a link-local address's interface inside bytes 2-3 of the address;
    /// it's moved to the "%en0" suffix.
    static func text(_ address: in6_addr, ifindex: UInt32) -> String {
        var a = address
        var scope: UInt32 = 0
        withUnsafeMutableBytes(of: &a) { b in
            guard b[0] == 0xfe, b[1] & 0xc0 == 0x80 else { return }
            let embedded = UInt32(b[2]) << 8 | UInt32(b[3])
            scope = embedded != 0 ? embedded : ifindex
            b[2] = 0; b[3] = 0
        }
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &a, &buf, socklen_t(buf.count)) != nil else { return "" }
        var s = String(cString: buf)
        if s == "::" { return "*" }     // any address, as netstat writes it
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        if scope != 0, if_indextoname(scope, &name) != nil { s += "%" + String(cString: name) }
        return s
    }
}
