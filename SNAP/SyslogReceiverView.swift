// SyslogReceiverView.swift
// SNAP — Syslog Receiver (UDP, RFC 3164 + RFC 5424)
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
//
// Binds a UDP listener and receives syslog messages from network gear.
// Point your switch / firewall / router at `<your-IP>:<port>` and watch
// events stream in live.
//
// Notes on the port:
//   • Standard syslog is UDP/514 — binding requires root on macOS.
//   • The default here is 5140 (unprivileged) so the listener "just works".
//     Configure your device to send to 5140, or run SNAP with sudo to bind
//     514 directly. We surface a clear error if the bind fails.
//
// Parser handles both RFC 3164 (`<PRI>MMM dd HH:mm:ss host tag: msg`) and
// RFC 5424 (`<PRI>VERSION ISOTS host app procid msgid sd msg`). Anything
// we can't structurally parse is still shown — just with most fields blank.

import SwiftUI
import Network

// MARK: - Model types

struct SyslogEntry: Identifiable, Hashable {
    let id = UUID()
    let receivedAt: Date
    let sourceIP: String
    let facility: SyslogFacility
    let severity: SyslogSeverity
    let timestamp: String
    let host: String
    let tag: String
    let message: String
    let rawLine: String
}

enum SyslogSeverity: Int, CaseIterable, Comparable {
    case emergency = 0
    case alert     = 1
    case critical  = 2
    case error     = 3
    case warning   = 4
    case notice    = 5
    case info      = 6
    case debug     = 7

    static func < (l: SyslogSeverity, r: SyslogSeverity) -> Bool { l.rawValue < r.rawValue }

    var label: String {
        switch self {
        case .emergency: return "emerg"
        case .alert:     return "alert"
        case .critical:  return "crit"
        case .error:     return "err"
        case .warning:   return "warn"
        case .notice:    return "notice"
        case .info:      return "info"
        case .debug:     return "debug"
        }
    }

    var color: Color {
        switch self {
        case .emergency, .alert, .critical: return NS.red
        case .error:                        return NS.red.opacity(0.8)
        case .warning:                      return NS.amber
        case .notice:                       return NS.blue
        case .info:                         return NS.text2
        case .debug:                        return NS.text3
        }
    }
}

enum SyslogFacility: Int {
    case kern = 0, user = 1, mail = 2, daemon = 3, auth = 4, syslog = 5
    case lpr = 6, news = 7, uucp = 8, cron = 9, authpriv = 10, ftp = 11
    case local0 = 16, local1 = 17, local2 = 18, local3 = 19
    case local4 = 20, local5 = 21, local6 = 22, local7 = 23
    case other = -1

    var label: String {
        switch self {
        case .kern:     return "kern"
        case .user:     return "user"
        case .mail:     return "mail"
        case .daemon:   return "daemon"
        case .auth:     return "auth"
        case .syslog:   return "syslog"
        case .lpr:      return "lpr"
        case .news:     return "news"
        case .uucp:     return "uucp"
        case .cron:     return "cron"
        case .authpriv: return "authpriv"
        case .ftp:      return "ftp"
        case .local0:   return "local0"
        case .local1:   return "local1"
        case .local2:   return "local2"
        case .local3:   return "local3"
        case .local4:   return "local4"
        case .local5:   return "local5"
        case .local6:   return "local6"
        case .local7:   return "local7"
        case .other:    return "—"
        }
    }
}

// MARK: - Receiver

@MainActor
final class SyslogReceiverModel: ObservableObject {
    @Published var port: String = "5140"
    @Published var entries: [SyslogEntry] = []
    @Published var isListening = false
    @Published var isPaused = false
    @Published var errorMessage: String?
    @Published var receivedCount: Int = 0
    @Published var minSeverity: SyslogSeverity = .debug
    @Published var facilityFilter: SyslogFacility? = nil
    @Published var hostFilter: String = ""
    @Published var autoScroll: Bool = true

    /// Hard cap on retained rows to keep memory bounded for long sessions.
    private let maxRetained = 5000

    private var listener: NWListener?
    private var connections: [NWConnection] = []

    deinit {
        // Backstop if the model deallocates while listening — cancel() is
        // the documented teardown for Network.framework objects
        listener?.cancel()
        for c in connections { c.cancel() }
    }

    var filtered: [SyslogEntry] {
        entries.filter { e in
            if e.severity > minSeverity { return false }
            if let f = facilityFilter, e.facility != f { return false }
            if !hostFilter.isEmpty,
               !e.sourceIP.localizedCaseInsensitiveContains(hostFilter),
               !e.host.localizedCaseInsensitiveContains(hostFilter) { return false }
            return true
        }
    }

    func start() {
        guard !isListening else { return }
        errorMessage = nil
        guard let p = UInt16(port), let nwPort = NWEndpoint.Port(rawValue: p) else {
            errorMessage = "Invalid port"
            return
        }
        do {
            let l = try NWListener(using: .udp, on: nwPort)
            l.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.isListening = true
                    case .failed(let e):
                        self?.errorMessage = "Listener failed: \(e.localizedDescription)"
                        self?.isListening = false
                    case .cancelled:
                        self?.isListening = false
                    default: break
                    }
                }
            }
            l.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.attach(conn) }
            }
            l.start(queue: DispatchQueue.global(qos: .utility))
            listener = l
        } catch {
            errorMessage = "Could not bind UDP/\(p): \(error.localizedDescription) — try port 5140 if you don't have root."
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for c in connections { c.cancel() }
        connections.removeAll()
        isListening = false
    }

    func clear() {
        entries.removeAll()
        receivedCount = 0
    }

    private func attach(_ conn: NWConnection) {
        connections.append(conn)
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            switch state {
            case .failed, .cancelled:
                if let c = conn {
                    Task { @MainActor in
                        self?.connections.removeAll { $0 === c }
                    }
                }
            default: break
            }
        }
        conn.start(queue: DispatchQueue.global(qos: .utility))
        receiveLoop(conn)
    }

    nonisolated private func receiveLoop(_ conn: NWConnection) {
        conn.receiveMessage { [weak self, weak conn] data, _, _, error in
            if let data = data, !data.isEmpty {
                let src: String = {
                    if let ep = conn?.endpoint, case let .hostPort(host: host, port: _) = ep {
                        return "\(host)"
                    }
                    return "?"
                }()
                let line = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
                let entry = parseSyslog(line, sourceIP: src)
                Task { @MainActor in
                    guard let self = self else { return }
                    self.receivedCount += 1
                    if !self.isPaused {
                        self.entries.append(entry)
                        if self.entries.count > self.maxRetained {
                            self.entries.removeFirst(self.entries.count - self.maxRetained)
                        }
                    }
                }
            }
            // Only re-arm a healthy connection — a failed/cancelled one
            // completes immediately with an error, and re-arming it spins
            // the receive queue at 100% CPU
            if error == nil, let c = conn {
                self?.receiveLoop(c)
            } else {
                conn?.cancel()
            }
        }
    }

    // MARK: Export

    func exportText() -> String {
        var s = "Syslog receiver — port \(port), \(receivedCount) messages received\n\n"
        for e in entries {
            s += "[\(e.receivedAt.formatted(date: .omitted, time: .standard))] "
            s += "\(e.sourceIP) \(e.facility.label).\(e.severity.label) "
            if !e.host.isEmpty { s += "\(e.host) " }
            if !e.tag.isEmpty  { s += "\(e.tag) " }
            s += "\(e.message)\n"
        }
        return s
    }
}

// MARK: - Parser

func parseSyslog(_ raw: String, sourceIP: String) -> SyslogEntry {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    var facility: SyslogFacility = .other
    var severity: SyslogSeverity = .info

    // <PRI>
    if s.hasPrefix("<"), let close = s.firstIndex(of: ">") {
        let priStr = s[s.index(after: s.startIndex)..<close]
        if let pri = Int(priStr) {
            let f = pri >> 3
            let sev = pri & 0x07
            facility = SyslogFacility(rawValue: f) ?? .other
            severity = SyslogSeverity(rawValue: sev) ?? .info
        }
        s = String(s[s.index(after: close)...])
    }

    // RFC 5424: starts with a version digit (1..) then space.
    // RFC 3164: starts with month abbrev.
    let tokens = s.split(separator: " ", maxSplits: 6, omittingEmptySubsequences: true).map(String.init)

    var timestamp = ""
    var host = ""
    var tag = ""
    var message = s

    let months: Set<String> = ["Jan","Feb","Mar","Apr","May","Jun",
                               "Jul","Aug","Sep","Oct","Nov","Dec"]

    if let first = tokens.first, let _ = Int(first), tokens.count >= 4 {
        // RFC 5424 form: VERSION TIMESTAMP HOSTNAME APP-NAME PROCID MSGID SD MSG
        timestamp = tokens.count > 1 ? tokens[1] : ""
        host = tokens.count > 2 ? tokens[2] : ""
        tag = tokens.count > 3 ? tokens[3] : ""
        // Tail is the freeform message.
        if tokens.count >= 7 {
            message = tokens[6]
        } else if tokens.count >= 5 {
            message = tokens[tokens.count - 1]
        }
    } else if tokens.count >= 4, months.contains(tokens[0]) {
        // RFC 3164: "Mmm dd HH:MM:SS host tag: message"
        timestamp = "\(tokens[0]) \(tokens[1]) \(tokens[2])"
        host = tokens[3]
        // Tag and message live in tokens[4...]; tag ends at first ':'.
        let remainder = tokens.dropFirst(4).joined(separator: " ")
        if let colon = remainder.firstIndex(of: ":") {
            tag = String(remainder[..<colon])
            message = String(remainder[remainder.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
        } else {
            message = remainder
        }
    } else {
        // Unrecognized format — keep the whole thing as the message so we
        // never drop content.
        message = s
    }

    return SyslogEntry(
        receivedAt: Date(),
        sourceIP: sourceIP,
        facility: facility,
        severity: severity,
        timestamp: timestamp,
        host: host,
        tag: tag,
        message: message,
        rawLine: raw
    )
}

// MARK: - View

struct SyslogReceiverView: View {
    @StateObject private var model = SyslogReceiverModel()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            filterBar
            Divider().background(NS.borderMid)
            if let err = model.errorMessage { errorBanner(err) }
            logTable
        }
        .tabNavigationTitle(.syslog)
        // Runs when the window closes (tabs now stay alive across switches) — stop the
        // listener instead of leaking the bound UDP socket
        .onDisappear { model.stop() }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: "tray.full")
                .foregroundStyle(NS.green)
            Text("Syslog receiver")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(NS.text1)
            Text("port:")
                .font(.system(size: 11)).foregroundStyle(NS.text3)
            TextField("", text: $model.port)
                .textFieldStyle(.roundedBorder)
                .frame(width: 60)
                .disabled(model.isListening)
            if model.isListening {
                Text("listening · \(model.receivedCount) msg")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(NS.text3)
            } else {
                Text("idle")
                    .font(.system(size: 11)).foregroundStyle(NS.text3)
            }
            Spacer()
            Toggle("Auto-scroll", isOn: $model.autoScroll)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
            ToolActionBar("Syslog", text: { model.exportText() })
            if model.isListening {
                Button(model.isPaused ? "Resume" : "Pause") {
                    model.isPaused.toggle()
                }
                .buttonStyle(.bordered)
                Button("Clear") { model.clear() }
                    .buttonStyle(.bordered)
                Button("Stop") { model.stop() }
                    .buttonStyle(.bordered).tint(.red)
            } else {
                Button("Start") { model.start() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(NS.bg0)
    }

    // MARK: Filter chips

    private var filterBar: some View {
        HStack(spacing: 8) {
            Text("min severity:")
                .font(.system(size: 11)).foregroundStyle(NS.text3)
            Picker("", selection: $model.minSeverity) {
                ForEach(SyslogSeverity.allCases, id: \.rawValue) {
                    Text($0.label).tag($0)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 100)

            Text("facility:")
                .font(.system(size: 11)).foregroundStyle(NS.text3)
            Picker("", selection: $model.facilityFilter) {
                Text("all").tag(SyslogFacility?.none)
                ForEach([SyslogFacility.kern, .auth, .authpriv, .daemon, .syslog, .user,
                         .local0, .local1, .local2, .local3, .local4, .local5, .local6, .local7],
                        id: \.rawValue) { f in
                    Text(f.label).tag(SyslogFacility?.some(f))
                }
            }
            .pickerStyle(.menu)
            .frame(width: 100)

            Text("host/src:")
                .font(.system(size: 11)).foregroundStyle(NS.text3)
            TextField("filter", text: $model.hostFilter)
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)

            Spacer()
            Text("\(model.filtered.count) shown")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(NS.text3)
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(NS.bg1)
    }

    private func errorBanner(_ s: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(NS.red)
            Text(s).font(.system(size: 11, design: .monospaced)).foregroundStyle(NS.text1)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(NS.red.opacity(0.08))
    }

    // MARK: Log table

    private var logTable: some View {
        Group {
            if model.entries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray").font(.system(size: 36)).foregroundStyle(NS.text3)
                    Text(model.isListening
                         ? "Listening on UDP/\(model.port). Point a device at this host."
                         : "Press Start to begin receiving.")
                        .font(.system(size: 12)).foregroundStyle(NS.text2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(model.filtered) { e in
                                row(e)
                                    .id(e.id)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 4)
                                    .background(NS.bg0)
                                Divider().background(NS.borderMid).opacity(0.5)
                            }
                        }
                    }
                    .onChange(of: model.filtered.count) { _ in
                        guard model.autoScroll, let last = model.filtered.last else { return }
                        withAnimation(.linear(duration: 0.05)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private func row(_ e: SyslogEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(e.receivedAt.formatted(date: .omitted, time: .standard))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(NS.text3)
                .frame(width: 80, alignment: .leading)
            Text(e.severity.label.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(e.severity.color)
                .frame(width: 50, alignment: .leading)
            Text(e.facility.label)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(NS.text3)
                .frame(width: 70, alignment: .leading)
            Text(e.sourceIP)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(NS.text2)
                .frame(width: 110, alignment: .leading)
            if !e.tag.isEmpty {
                Text(e.tag)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(NS.blue)
                    .frame(width: 110, alignment: .leading)
            } else if !e.host.isEmpty {
                Text(e.host)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(NS.text2)
                    .frame(width: 110, alignment: .leading)
            }
            Text(e.message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(NS.text1)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
