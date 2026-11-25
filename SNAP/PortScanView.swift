// PortScanView.swift
// SNAP — Port Scanner Tab
// Created by Sevag Bardakjian
// Copyright © 2025-2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md

import SwiftUI
import Network

struct PortResult: Identifiable, Hashable {
    let id = UUID()
    static func == (lhs: PortResult, rhs: PortResult) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    var port: Int
    var service: String
    var status: PortStatus

    enum PortStatus: String { case open = "Open", closed = "Closed", filtered = "Filtered", scanning = "Scanning..." }
}

struct PortScanView: View {
    @State private var host = ""
    @State private var portRange = "1-1024"
    @State private var timeout = "1.0"
    @State private var onlyOpen = true
    @State private var results: [PortResult] = []
    @State private var isRunning = false
    @State private var progress = 0.0
    @State private var scannedCount = 0
    @State private var totalCount = 0
    @State private var scanTask: Task<Void, Never>?
    // Identifies the current scan, so a stopped scan's late results can't
    // land in the next one's table
    @State private var runID = UUID()
    @State private var errorMessage: String?

    private var displayResults: [PortResult] {
        onlyOpen ? results.filter { $0.status == .open } : results
    }

    private let commonServices: [Int: String] = [
        21: "FTP", 22: "SSH", 23: "Telnet", 25: "SMTP", 53: "DNS",
        80: "HTTP", 110: "POP3", 143: "IMAP", 443: "HTTPS", 445: "SMB",
        3306: "MySQL", 3389: "RDP", 5432: "PostgreSQL", 5900: "VNC",
        6379: "Redis", 8080: "HTTP-Alt", 8443: "HTTPS-Alt", 27017: "MongoDB",
        993: "IMAPS", 995: "POP3S", 587: "SMTP-TLS", 465: "SMTPS",
        389: "LDAP", 636: "LDAPS", 161: "SNMP", 162: "SNMP-Trap",
        1433: "MSSQL", 1521: "Oracle", 2049: "NFS", 111: "RPC",
        548: "AFP", 631: "IPP", 5353: "mDNS", 67: "DHCP", 68: "DHCP",
        69: "TFTP", 123: "NTP", 179: "BGP", 514: "Syslog",
        // Enterprise mgmt-plane ports (v1.3)
        4443: "HTTPS-Mgmt",
        830: "NETCONF", 5985: "WinRM-HTTP", 5986: "WinRM-HTTPS",
        9100: "JetDirect", 902: "vSphere", 49: "TACACS+",
        1812: "RADIUS-Auth", 1813: "RADIUS-Acct",
    ]

    // MARK: - Port presets

    private enum PortPreset: String, CaseIterable, Identifiable {
        case custom         = "Custom"
        case common         = "Common (1-1024)"
        case web            = "Web"
        case databases      = "Databases"
        case enterprise     = "Network Equipment"
        case windows        = "Windows / AD"
        case mac            = "Mac / Apple"
        var id: String { rawValue }

        var ports: String {
            switch self {
            case .custom:     return ""
            case .common:     return "1-1024"
            case .web:        return "80,443,8080,8443,4443,8000,8888"
            // SSH, Telnet, HTTP/S, mgmt HTTPS, SNMP (v2c+trap), Syslog, NETCONF,
            // ssh-alt, JetDirect, vSphere, NetBIOS-mgmt, RADIUS, TACACS+
            case .enterprise: return "22,23,80,161,162,443,514,830,902,1812,1813,2222,3389,4443,8443,9100,49,4786"
            case .windows:    return "53,88,135,139,389,445,464,636,3268,3269,3389,5985,5986"
            case .mac:        return "22,80,88,443,445,548,623,631,3283,3689,5009,5353,5900,7000,8770,49152-49154"
            case .databases:  return "1433,1521,3306,5432,5984,6379,7000,7001,8086,9042,9200,9300,11211,27017"
            }
        }
    }
    @State private var preset: PortPreset = .custom

    var body: some View {
        VStack(spacing: 0) {
            // One row when the window is wide; narrow windows put the target and
            // Scan on the first row and the scan options on a second row
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    targetIcon
                    hostField.frame(width: 220)
                    HistoryMenuButton(key: .portScan) { host = $0 }
                    scanOptions(portsMin: 200, portsMax: 200)
                    Spacer()
                    scanActions
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        targetIcon
                        hostField.frame(minWidth: 120, maxWidth: .infinity)
                        HistoryMenuButton(key: .portScan) { host = $0 }
                        scanActions
                    }
                    HStack(spacing: 12) {
                        scanOptions(portsMin: 100, portsMax: .infinity)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(NS.bg0)
            .onChange(of: preset) { _, newPreset in
                if newPreset != .custom { portRange = newPreset.ports }
            }
            .onChange(of: portRange) { preset = .custom }

            Divider()

            if let errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(NS.amber)
                    Text(errorMessage).font(.caption).foregroundStyle(NS.text1)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 6)
                .background(NS.bg3)
                Divider()
            }

            // Summary bar
            if !results.isEmpty {
                HStack(spacing: 16) {
                    let openCount = results.filter { $0.status == .open }.count
                    Text("\(openCount) open").foregroundStyle(.green).font(.caption.bold())
                    Text("\(results.count - openCount) closed/filtered").foregroundStyle(.secondary).font(.caption)
                    if isRunning {
                        Text("Scanning...").foregroundStyle(.blue).font(.caption)
                    } else {
                        Text("Scan complete").foregroundStyle(.secondary).font(.caption)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 6)
                .background(NS.bg3)
                Divider()
            }

            Table(displayResults) {
                TableColumn("Port") { r in
                    Text("\(r.port)")
                        .font(.caption.monospaced())
                        .foregroundStyle(r.status == .open ? .primary : .secondary)
                }.width(60)
                TableColumn("Service") { r in
                    Text(r.service).font(.caption)
                }.width(100)
                TableColumn("Status") { r in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(statusColor(r.status))
                            .frame(width: 8, height: 8)
                        Text(r.status.rawValue)
                            .font(.caption)
                            .foregroundStyle(statusColor(r.status))
                    }
                }
            }
        }
        .tabNavigationTitle(.portScan)
        // Runs when the window closes (tabs now stay alive across switches) — cancel the scan instead of
        // letting it probe up to 65k ports with no UI handle left to stop it
        .onDisappear { stopScan() }
        .consumeHandoff(for: .portScan) { host = $0 }
    }

    // MARK: - Toolbar pieces (shared by the one-row and two-row layouts)

    private var targetIcon: some View {
        Image(systemName: "magnifyingglass.circle").foregroundStyle(.blue)
    }

    private var hostField: some View {
        TextField("Hostname or IP", text: $host)
            .textFieldStyle(.roundedBorder)
            .onSubmit(submitScan)
    }

    private func optionLabel(_ title: String) -> some View {
        Text(title).font(.caption).foregroundStyle(.secondary).fixedSize()
    }

    @ViewBuilder
    private func scanOptions(portsMin: CGFloat, portsMax: CGFloat) -> some View {
        optionLabel("Preset:")
        Picker("", selection: $preset) {
            ForEach(PortPreset.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.menu)
        .frame(width: 160)
        optionLabel("Ports:")
        TextField("e.g. 1-1024 or 22,80,443", text: $portRange)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: portsMin, maxWidth: portsMax)
            .onSubmit(submitScan)
        optionLabel("Timeout(s):")
        TextField("", text: $timeout)
            .textFieldStyle(.roundedBorder)
            .frame(width: 50)
            .onSubmit(submitScan)
        Toggle("Open only", isOn: $onlyOpen)
            .toggleStyle(.checkbox)
            .fixedSize()
    }

    @ViewBuilder
    private var scanActions: some View {
        if !results.isEmpty {
            ToolActionBar("Port-Scan",
                          text: { "Port scan \(host)\n\nport\tservice\tstatus\n" + results.sorted { $0.port < $1.port }.map { "\($0.port)\t\($0.service)\t\($0.status.rawValue)" }.joined(separator: "\n") },
                          csv: { "port,service,status\n" + results.sorted { $0.port < $1.port }.map { "\($0.port),\(csvEscape($0.service)),\($0.status.rawValue)" }.joined(separator: "\n") })
                .fixedSize()
        }
        if isRunning {
            Button("Stop") { stopScan() }
                .buttonStyle(.bordered).tint(.red)
                .fixedSize()
            ProgressView(value: progress)
                .frame(width: 80)
            Text("\(scannedCount)/\(totalCount)").font(.caption2).foregroundStyle(.secondary)
                .fixedSize()
        } else {
            Button("Scan") { startScan() }
                .buttonStyle(.borderedProminent)
                .disabled(host.isEmpty)
                .keyboardShortcut(.return)
                .fixedSize()
        }
    }

    private func statusColor(_ s: PortResult.PortStatus) -> Color {
        switch s {
        case .open:     return .green
        case .closed:   return .red
        case .filtered: return .orange
        case .scanning: return .blue
        }
    }

    /// Return in a toolbar field: same conditions as the Scan button.
    private func submitScan() {
        if !isRunning && !host.isEmpty { startScan() }
    }

    private func stopScan() {
        runID = UUID()  // drop anything the stopped scan still delivers
        scanTask?.cancel()
        scanTask = nil
        isRunning = false
    }

    private func startScan() {
        let v = host.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return }
        ToolHistory.shared.add(.portScan, v)
        results = []
        errorMessage = nil
        progress = 0
        scannedCount = 0

        let ports = PortScan.parsePorts(portRange)
        guard !ports.isEmpty else {
            totalCount = 0
            errorMessage = "Enter ports like 22,80,443 or a range like 1-1024."
            return
        }
        // Zero or less would mark every port Filtered at once.
        guard let timeoutSecs = Double(timeout.trimmingCharacters(in: .whitespaces)),
              timeoutSecs >= 0.1, timeoutSecs <= 30 else {
            totalCount = 0
            errorMessage = "Enter a timeout from 0.1 to 30 seconds."
            return
        }
        totalCount = ports.count
        isRunning = true
        let services = commonServices
        let id = UUID()
        runID = id

        scanTask = Task {
            // Resolve once up front. An unknown name used to fail every
            // connection, so every port read "Closed".
            guard let address = await PortScan.resolve(v) else {
                guard runID == id else { return }
                errorMessage = "Couldn't find \(v). Check the spelling or use its IP address."
                isRunning = false
                return
            }
            guard runID == id else { return }

            // Sliding window: start the first batch, then one more each time
            // a probe finishes, so results show up as they come in
            await withTaskGroup(of: PortResult.self) { group in
                var next = 0
                func enqueue() {
                    let port = ports[next]
                    let service = services[port] ?? ""
                    next += 1
                    group.addTask {
                        let status = await PortScan.probe(host: address, port: port, timeout: timeoutSecs)
                        return PortResult(port: port, service: service, status: status)
                    }
                }
                while next < min(PortScan.maxConcurrent, ports.count) { enqueue() }
                while let result = await group.next() {
                    guard !Task.isCancelled, runID == id else { group.cancelAll(); break }
                    results.insert(result, at: PortScan.insertionIndex(of: result.port, in: results))
                    scannedCount += 1
                    progress = Double(scannedCount) / Double(totalCount)
                    if next < ports.count { enqueue() }
                }
            }
            if runID == id { isRunning = false }
        }
    }
}

// MARK: - Probing

/// The scan's pure parts and its probe, kept out of the view so tests can
/// reach them.
enum PortScan {
    /// Probes in flight at once.
    static let maxConcurrent = 100

    /// "22,80,443", "1-1024", or a mix. Out-of-range and malformed parts are
    /// skipped; the result is sorted with no duplicates.
    static func parsePorts(_ str: String) -> [Int] {
        var ports = Set<Int>()
        for part in str.split(separator: ",") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("-") {
                let bounds = trimmed.split(separator: "-")
                if bounds.count == 2,
                   let lo = Int(bounds[0].trimmingCharacters(in: .whitespaces)),
                   let hi = Int(bounds[1].trimmingCharacters(in: .whitespaces)) {
                    // Clamp both ends and skip reversed ranges: `8080-80`
                    // must not trap Range's lowerBound <= upperBound check
                    let l = max(1, lo), h = min(hi, 65535)
                    if l <= h { (l...h).forEach { ports.insert($0) } }
                }
            } else if let p = Int(trimmed), p > 0 && p <= 65535 {
                ports.insert(p)
            }
        }
        return ports.sorted()
    }

    /// Where `port` goes in `results` (sorted by port) to keep it sorted.
    static func insertionIndex(of port: Int, in results: [PortResult]) -> Int {
        var lo = 0, hi = results.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if results[mid].port < port { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// What a connection state says about the port, or nil to keep waiting.
    /// A refused connection arrives as `.waiting`, not `.failed` (the
    /// connection would retry it), which used to leave closed ports sitting
    /// until the timeout and then reading "Filtered".
    static func status(for state: NWConnection.State) -> PortResult.PortStatus? {
        switch state {
        case .ready:
            return .open
        case .waiting(let error):
            return isRefused(error) ? .closed : nil
        case .failed(let error):
            // Anything but a reset (no route, host down) means no answer
            return isRefused(error) ? .closed : .filtered
        default:
            return nil
        }
    }

    private static func isRefused(_ error: NWError) -> Bool {
        if case .posix(let code) = error { return code == .ECONNREFUSED || code == .ECONNRESET }
        return false
    }

    /// The address to scan, as text, or nil if the name doesn't resolve.
    static func resolve(_ host: String) async -> String? {
        await Task.detached { TCPPing.resolve(host, port: 80)?.display }.value
    }

    /// One TCP connect to `host` (an address from `resolve`). Cancelling the
    /// task cancels the connection, so Stop ends in-flight probes at once.
    static func probe(host: String, port: Int, timeout: Double) async -> PortResult.PortStatus {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return .filtered }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        // Shared by the state handler, the timeout and cancellation, so the
        // continuation resumes exactly once
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            func claim() -> Bool {
                lock.lock(); defer { lock.unlock() }
                if done { return false }
                done = true
                return true
            }
        }
        let once = Once()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<PortResult.PortStatus, Never>) in
                let finish: @Sendable (PortResult.PortStatus) -> Void = { s in
                    guard once.claim() else { return }
                    // cancel() is required teardown even after .failed;
                    // the connection otherwise retains its handler forever
                    conn.cancel()
                    cont.resume(returning: s)
                }
                if Task.isCancelled { finish(.filtered); return }
                let q = DispatchQueue(label: "port.\(port)")
                conn.stateUpdateHandler = { state in
                    if case .cancelled = state { finish(.filtered); return }
                    if let s = status(for: state) { finish(s) }
                }
                conn.start(queue: q)
                q.asyncAfter(deadline: .now() + timeout) { finish(.filtered) }
            }
        } onCancel: {
            conn.cancel()
        }
    }
}

// Simple async semaphore
actor AsyncSemaphore {
    private var count: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.count = limit }

    func wait() async {
        if count > 0 { count -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        if waiters.isEmpty { count += 1 }
        else { waiters.removeFirst().resume() }
    }
}
