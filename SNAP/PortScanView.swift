// PortScanView.swift
// SNAP — Port Scanner Tab
// Created by Sevag Bardakjian

import SwiftUI
import Network

struct PortResult: Identifiable, Hashable {
    let id = UUID()
    static func == (lhs: PortResult, rhs: PortResult) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    var port: Int
    var service: String
    var status: PortStatus
    var banner: String = ""

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
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass.circle").foregroundStyle(.blue)
                TextField("Hostname or IP", text: $host)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                HistoryMenuButton(key: .portScan) { host = $0 }
                Text("Preset:").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $preset) {
                    ForEach(PortPreset.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .frame(width: 160)
                .onChange(of: preset) { newPreset in
                    if newPreset != .custom { portRange = newPreset.ports }
                }
                Text("Ports:").font(.caption).foregroundStyle(.secondary)
                TextField("e.g. 1-1024 or 22,80,443", text: $portRange)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .onChange(of: portRange) { _ in preset = .custom }
                Text("Timeout(s):").font(.caption).foregroundStyle(.secondary)
                TextField("", text: $timeout)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 50)
                Toggle("Open only", isOn: $onlyOpen)
                    .toggleStyle(.checkbox)
                Spacer()
                if !results.isEmpty {
                    ToolActionBar("Port-Scan",
                                  text: { "Port scan \(host)\n\nport\tservice\tstatus\tbanner\n" + results.sorted { $0.port < $1.port }.map { "\($0.port)\t\($0.service)\t\($0.status.rawValue)\t\($0.banner)" }.joined(separator: "\n") },
                                  csv: { "port,service,status,banner\n" + results.sorted { $0.port < $1.port }.map { "\($0.port),\(csvEscape($0.service)),\($0.status.rawValue),\(csvEscape($0.banner))" }.joined(separator: "\n") })
                }
                if isRunning {
                    Button("Stop") { scanTask?.cancel(); isRunning = false }
                        .buttonStyle(.bordered).tint(.red)
                    ProgressView(value: progress)
                        .frame(width: 80)
                    Text("\(scannedCount)/\(totalCount)").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Button("Scan") { startScan() }
                        .buttonStyle(.borderedProminent)
                        .disabled(host.isEmpty)
                        .keyboardShortcut(.return)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(NS.bg0)

            Divider()

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
                }.width(100)
                TableColumn("Banner") { r in
                    Text(r.banner).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .navigationTitle("Port Scan")
        // Tab switching recreates this view — cancel the scan instead of
        // letting it probe up to 65k ports with no UI handle left to stop it
        .onDisappear { scanTask?.cancel(); isRunning = false }
        .consumeHandoff(for: .portScan) { host = $0 }
    }

    private func statusColor(_ s: PortResult.PortStatus) -> Color {
        switch s {
        case .open:     return .green
        case .closed:   return .red
        case .filtered: return .orange
        case .scanning: return .blue
        }
    }

    private func startScan() {
        let v = host.trimmingCharacters(in: .whitespaces)
        if !v.isEmpty { ToolHistory.shared.add(.portScan, v) }
        results = []
        isRunning = true
        progress = 0

        let ports = parsePorts(portRange)
        totalCount = ports.count
        scannedCount = 0
        let timeoutSecs = Double(timeout) ?? 1.0
        let targetHost = host

        scanTask = Task {
            await withTaskGroup(of: PortResult.self) { group in
                let semaphore = AsyncSemaphore(limit: 100)
                for port in ports {
                    await semaphore.wait()
                    group.addTask {
                        defer { Task { await semaphore.signal() } }
                        return await self.checkPort(host: targetHost, port: port, timeout: timeoutSecs)
                    }
                }
                for await result in group {
                    guard !Task.isCancelled else { break }
                    await MainActor.run {
                        results.append(result)
                        results.sort { $0.port < $1.port }
                        scannedCount += 1
                        progress = Double(scannedCount) / Double(totalCount)
                    }
                }
            }
            await MainActor.run { isRunning = false }
        }
    }

    private func checkPort(host: String, port: Int, timeout: Double) async -> PortResult {
        let service = commonServices[port] ?? ""
        // Use a class-based token to safely share 'resolved' state across concurrent closures
        final class ResolvedToken: @unchecked Sendable { var value = false }
        return await withCheckedContinuation { cont in
            let conn = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(integerLiteral: UInt16(port)),
                using: .tcp
            )
            let token = ResolvedToken()
            let q = DispatchQueue(label: "port.\(port)")
            conn.stateUpdateHandler = { state in
                q.async {
                    guard !token.value else { return }
                    switch state {
                    case .ready:
                        token.value = true
                        conn.cancel()
                        cont.resume(returning: PortResult(port: port, service: service, status: .open))
                    case .failed, .cancelled:
                        token.value = true
                        // cancel() is required teardown even after .failed —
                        // the connection otherwise retains its handler forever
                        conn.cancel()
                        cont.resume(returning: PortResult(port: port, service: service, status: .closed))
                    default: break
                    }
                }
            }
            conn.start(queue: q)
            q.asyncAfter(deadline: .now() + timeout) {
                guard !token.value else { return }
                token.value = true
                conn.cancel()
                cont.resume(returning: PortResult(port: port, service: service, status: .filtered))
            }
        }
    }

    private func parsePorts(_ str: String) -> [Int] {
        var ports = Set<Int>()
        for part in str.split(separator: ",") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("-") {
                let bounds = trimmed.split(separator: "-")
                if bounds.count == 2, let lo = Int(bounds[0]), let hi = Int(bounds[1]) {
                    // Clamp both ends and skip reversed ranges — `8080-80`
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
