// BulkDiscoveryView.swift
// SNAP — Bulk subnet sweep + asset inventory
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md
//
// "Network Map but exhaustive": take a CIDR, sweep every host, then for
// each live host run port-scan + SNMP-public + reverse DNS + OUI in
// parallel. Builds an exportable asset inventory.
//
// Pipeline per /24:
//
//   1. Aliveness check — concurrent TCP-connect to common mgmt ports.
//      First ready/refused = alive (many enterprise gateways ignore
//      ICMP but accept TCP). ~1.5s for 256 hosts at 64-way concurrency.
//
//   2. Per-live-host probes in parallel (bounded 10-way concurrency):
//      • Reverse DNS via getnameinfo
//      • Port scan against the Network Equipment preset
//      • SNMP v2c GET of sysDescr / sysObjectID / sysName ("public")
//      • MAC + vendor from the system ARP cache
//
//   3. Vendor classifier (shared with FingerprintView) fuses every
//      signal into a single best-guess vendor + model + role.

import SwiftUI
import Network
import Darwin

// MARK: - Discovered asset

struct DiscoveredAsset: Identifiable, Hashable {
    let id: String                  // IPv4 address (unique per scan)
    var ip: String
    var mac: String?
    var hostname: String?
    var vendor: String?
    var model: String?
    var role: DeviceRole
    var openPorts: [Int]
    var sysName: String?
    var sysDescr: String?
    var sysObjectID: String?
    var lastSeen: Date
}

// MARK: - Model

@MainActor
final class BulkDiscoveryModel: ObservableObject {

    @Published var cidr: String = ""
    @Published var probeSNMP: Bool = true
    @Published var community: String = "public"
    @Published var includePortScan: Bool = true

    @Published var assets: [DiscoveredAsset] = []
    @Published var alive: Int = 0
    @Published var scanned: Int = 0
    @Published var total: Int = 0
    @Published var isRunning: Bool = false
    @Published var status: String = ""
    @Published var errorMessage: String?

    private var task: Task<Void, Never>?

    /// Bulk Discovery does far more per host than the Network Map (optional
    /// port scan + SNMP), so it keeps a lower ceiling: 8,192 addresses (a /19).
    nonisolated static let maxHosts = 8_192

    init() {
        // Default = this Mac's subnet, or its /24 if the subnet is bigger
        // (per-host work here is heavy). Deferred off the initializer so we
        // never publish `cidr` during the view-creation pass (the
        // "Publishing changes from within view updates" warning class).
        DispatchQueue.main.async { [weak self] in
            guard let self, self.cidr.isEmpty, let net = ScanRange.localNetwork() else { return }
            let prefix = Int(net.cidr.split(separator: "/").last ?? "") ?? 0
            self.cidr = prefix >= 24 ? net.cidr : net.slash24
        }
    }

    func start() {
        errorMessage = nil
        assets.removeAll()
        alive = 0
        scanned = 0
        // Same parser as the Network Map: CIDR, ranges, /24 shorthand, lists.
        let hosts: [String]
        switch ScanRange.parse(cidr, maxHosts: Self.maxHosts) {
        case .success(let range): hosts = range.addresses()
        case .failure(let e):
            errorMessage = e.message
            return
        }
        total = hosts.count
        isRunning = true
        status = "Sweeping \(total) hosts…"
        let snmp = probeSNMP
        let community = self.community
        let ports = includePortScan

        task = Task { [weak self] in
            guard let self = self else { return }
            await self.run(hosts: hosts, doSNMP: snmp, community: community, doPorts: ports)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
        status = "Cancelled"
    }

    private func run(hosts: [String],
                     doSNMP: Bool,
                     community: String,
                     doPorts: Bool) async {

        // Phase 1: aliveness sweep.
        let live = await aliveSweep(hosts)

        await MainActor.run {
            self.alive = live.count
            self.status = "Probing \(live.count) live host\(live.count == 1 ? "" : "s")…"
        }

        // Phase 2: per-host probes, bounded concurrency.
        let arpMap = readARPCache()
        let semaphore = AsyncSemaphore(limit: 12)

        await withTaskGroup(of: DiscoveredAsset.self) { group in
            for ip in live {
                if Task.isCancelled { break }
                await semaphore.wait()
                group.addTask { [weak self] in
                    defer { Task { await semaphore.signal() } }
                    return await self?.probe(ip: ip,
                                             arpMap: arpMap,
                                             doSNMP: doSNMP,
                                             community: community,
                                             doPorts: doPorts) ?? DiscoveredAsset(
                        id: ip, ip: ip, mac: nil, hostname: nil, vendor: nil,
                        model: nil, role: .unknown, openPorts: [],
                        sysName: nil, sysDescr: nil, sysObjectID: nil,
                        lastSeen: Date())
                }
            }
            for await a in group {
                if Task.isCancelled { break }
                await MainActor.run {
                    self.assets.append(a)
                    self.assets.sort { ipLessThan($0.ip, $1.ip) }
                }
            }
        }

        await MainActor.run {
            self.isRunning = false
            self.status = "Done · \(self.assets.count) asset\(self.assets.count == 1 ? "" : "s") inventoried"
        }
    }

    // MARK: - Phase 1 (aliveness)

    private static let alivePorts: [UInt16] = [80, 22, 443, 8443, 161, 445, 23]

    private func aliveSweep(_ hosts: [String]) async -> [String] {
        let sem = AsyncSemaphore(limit: 64)
        var alive: [String] = []

        await withTaskGroup(of: String?.self) { group in
            for host in hosts {
                if Task.isCancelled { break }
                await sem.wait()
                group.addTask {
                    defer { Task { await sem.signal() } }
                    let isAlive = await Self.tcpAlive(host: host, ports: Self.alivePorts, timeout: 0.8)
                    return isAlive ? host : nil
                }
            }
            // Results are consumed serially in this for-await loop, so no
            // explicit lock is needed around the local `alive` array.
            for await result in group {
                if Task.isCancelled { break }
                if let ip = result { alive.append(ip) }
                await MainActor.run { self.scanned += 1 }
            }
        }
        return alive
    }

    /// True if TCP-connect to *any* of the given ports completes within
    /// `timeout` (either ready or refused — both prove the host is reachable).
    private static func tcpAlive(host: String,
                                 ports: [UInt16],
                                 timeout: TimeInterval) async -> Bool {
        await withTaskGroup(of: Bool.self) { group -> Bool in
            for port in ports {
                group.addTask { await tcpConnectAttempt(host: host, port: port, timeout: timeout) }
            }
            for await r in group {
                if r { group.cancelAll(); return true }
            }
            return false
        }
    }

    private static func tcpConnectAttempt(host: String,
                                          port: UInt16,
                                          timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                cont.resume(returning: false); return
            }
            let conn = NWConnection(host: NWEndpoint.Host(host),
                                    port: nwPort,
                                    using: .tcp)
            // `resumed` is shared between the NW state handler queue and the
            // dispatch deadline closure; wrap it so a Sendable-safe local
            // closure can mutate it under the same lock.
            final class Box: @unchecked Sendable {
                let lock = NSLock()
                var resumed = false
            }
            let box = Box()
            let finish: @Sendable (Bool) -> Void = { r in
                box.lock.lock(); let done = box.resumed; box.resumed = true; box.lock.unlock()
                if done { return }
                conn.cancel()
                cont.resume(returning: r)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:           finish(true)
                case .failed(let e):
                    // ECONNREFUSED means the host is up but the port is closed.
                    if case .posix(let code) = e, code == .ECONNREFUSED { finish(true) }
                    else { finish(false) }
                case .cancelled:       finish(false)
                default: break
                }
            }
            conn.start(queue: DispatchQueue.global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    // MARK: - Phase 2 (per-host probe)

    private static let mgmtPortPreset: [Int] = [22, 23, 80, 161, 443, 514, 830, 902,
                                                4443, 8443, 9100]

    private func probe(ip: String,
                       arpMap: [String: String],
                       doSNMP: Bool,
                       community: String,
                       doPorts: Bool) async -> DiscoveredAsset {
        var asset = DiscoveredAsset(
            id: ip, ip: ip, mac: nil, hostname: nil, vendor: nil, model: nil,
            role: .unknown, openPorts: [], sysName: nil, sysDescr: nil,
            sysObjectID: nil, lastSeen: Date())

        // MAC + vendor + role from ARP cache + OUI registry.
        if let mac = arpMap[ip] {
            asset.mac = mac.uppercased()
            if let hint = OUIDatabase.roleHint(mac) {
                asset.vendor = hint.vendor
                if hint.role != .unknown { asset.role = hint.role }
            }
        }

        // Reverse DNS, port scan, and SNMP run in parallel.
        async let revHost: String? = reverseDNS(ip)
        async let openPorts: [Int] = doPorts ? scanMgmtPorts(ip) : []
        async let snmp: (descr: String?, name: String?, oid: String?, vendor: String?, model: String?, role: DeviceRole?) =
            doSNMP ? snmpProbe(ip: ip, community: community) : (nil, nil, nil, nil, nil, nil)

        let (rev, ports, s) = await (revHost, openPorts, snmp)
        asset.hostname = rev
        asset.openPorts = ports
        asset.sysDescr = s.descr
        asset.sysName  = s.name
        asset.sysObjectID = s.oid
        // SNMP-derived vendor wins over OUI-only inference.
        if let v = s.vendor { asset.vendor = v }
        if let m = s.model  { asset.model = m }
        if let r = s.role, r != .unknown { asset.role = r }

        return asset
    }

    private func reverseDNS(_ ip: String) async -> String? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                var hints = addrinfo()
                hints.ai_family   = AF_INET
                hints.ai_socktype = SOCK_STREAM
                var res: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(ip, nil, &hints, &res) == 0, let r = res else {
                    cont.resume(returning: nil); return
                }
                defer { freeaddrinfo(r) }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let rc = getnameinfo(r.pointee.ai_addr, r.pointee.ai_addrlen,
                                     &host, socklen_t(host.count),
                                     nil, 0, NI_NAMEREQD)
                cont.resume(returning: rc == 0 ? String(cString: host) : nil)
            }
        }
    }

    private func scanMgmtPorts(_ ip: String) async -> [Int] {
        await withTaskGroup(of: Int?.self) { group in
            for port in Self.mgmtPortPreset {
                group.addTask {
                    let alive = await Self.tcpConnectAttempt(
                        host: ip, port: UInt16(port), timeout: 0.8)
                    return alive ? port : nil
                }
            }
            var open: [Int] = []
            for await r in group { if let p = r { open.append(p) } }
            return open.sorted()
        }
    }

    private func snmpProbe(ip: String, community: String) async -> (descr: String?, name: String?, oid: String?, vendor: String?, model: String?, role: DeviceRole?) {
        let client = SNMPClient(host: ip,
                                community: community,
                                version: .v2c,
                                timeout: 1.5,
                                retries: 0)
        do {
            let vbs = try await client.get([SNMPOID.sysDescr,
                                            SNMPOID.sysObjectID,
                                            SNMPOID.sysName])
            let byOID = Dictionary(uniqueKeysWithValues: vbs.map { ($0.oid, $0.value) })
            let descr = byOID[SNMPOID.sysDescr]?.description
            let name  = byOID[SNMPOID.sysName]?.description
            var oidStr: String?
            var vendor: String?
            var model: String?
            var role: DeviceRole?
            if let v = byOID[SNMPOID.sysObjectID], case .oid(let o) = v {
                oidStr = o.description
                if let m = SysObjectIDDatabase.match(o) {
                    vendor = m.vendor
                    model = m.model
                    role = m.role
                }
            }
            return (descr, name, oidStr, vendor, model, role)
        } catch {
            return (nil, nil, nil, nil, nil, nil)
        }
    }

    // MARK: - Export

    func exportText() -> String {
        var s = "Bulk subnet discovery — \(cidr)\n"
        s += "\(alive) live host\(alive == 1 ? "" : "s") of \(total) scanned · \(assets.count) inventoried\n\n"
        s += "ip\tmac\thostname\tvendor\tmodel\trole\tports\tsysName\n"
        for a in assets {
            s += "\(a.ip)\t\(a.mac ?? "—")\t\(a.hostname ?? "—")\t"
            s += "\(a.vendor ?? "—")\t\(a.model ?? "—")\t\(a.role.rawValue)\t"
            s += "\(a.openPorts.map(String.init).joined(separator: ","))\t"
            s += "\(a.sysName ?? "—")\n"
        }
        return s
    }

    func exportCSV() -> String {
        var s = "ip,mac,hostname,vendor,model,role,open_ports,sys_name,sys_descr,sys_object_id\n"
        for a in assets {
            let cells: [String] = [
                a.ip, a.mac ?? "", a.hostname ?? "", a.vendor ?? "",
                a.model ?? "", a.role.rawValue,
                a.openPorts.map(String.init).joined(separator: ";"),
                a.sysName ?? "", a.sysDescr ?? "", a.sysObjectID ?? "",
            ]
            s += cells.map { csvEscape($0) }.joined(separator: ",") + "\n"
        }
        return s
    }

    func exportJSON() -> String {
        let payload: [String: Any] = [
            "cidr": cidr,
            "scanned": total,
            "alive": alive,
            "captured_at": ISO8601DateFormatter().string(from: Date()),
            "assets": assets.map { a in
                [
                    "ip": a.ip,
                    "mac": a.mac ?? "",
                    "hostname": a.hostname ?? "",
                    "vendor": a.vendor ?? "",
                    "model": a.model ?? "",
                    "role": a.role.rawValue,
                    "open_ports": a.openPorts,
                    "snmp_sys_name": a.sysName ?? "",
                    "snmp_sys_descr": a.sysDescr ?? "",
                    "snmp_sys_object_id": a.sysObjectID ?? "",
                ] as [String: Any]
            },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}

// MARK: - Helpers
// (CIDR / range expansion lives in ScanRange.swift, shared with the Network Map.)

private func ipLessThan(_ a: String, _ b: String) -> Bool {
    let ao = a.split(separator: ".").compactMap { UInt32($0) }
    let bo = b.split(separator: ".").compactMap { UInt32($0) }
    guard ao.count == 4, bo.count == 4 else { return a < b }
    let ai = (ao[0] << 24) | (ao[1] << 16) | (ao[2] << 8) | ao[3]
    let bi = (bo[0] << 24) | (bo[1] << 16) | (bo[2] << 8) | bo[3]
    return ai < bi
}

/// Read the system ARP cache by spawning `arp -an`. Falls back to an
/// empty map if the call fails. (Tech-debt note: SystemConfiguration's
/// `SCDynamicStore` would be a pure-Swift alternative; flagged as a
/// follow-up across the codebase.)
private func readARPCache() -> [String: String] {
    var map: [String: String] = [:]
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
    task.arguments = ["-an"]
    let pipe = Pipe()
    task.standardOutput = pipe
    try? task.run()
    // Drain the pipe before waiting — a large ARP cache can exceed the pipe
    // buffer, and waiting first deadlocks both processes (see Shell.run)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    let text = String(data: data, encoding: .utf8) ?? ""
    for line in text.split(separator: "\n") {
        // Format: ? (192.168.1.1) at 8c:85:90:aa:bb:cc on en0 ifscope [ethernet]
        guard let lp = line.firstIndex(of: "("),
              let rp = line.firstIndex(of: ")"),
              let at = line.range(of: " at ") else { continue }
        let ip = String(line[line.index(after: lp)..<rp])
        let after = line[at.upperBound...]
        let mac = after.split(separator: " ").first.map(String.init) ?? ""
        if !mac.contains("incomplete") && !mac.isEmpty {
            map[ip] = mac
        }
    }
    return map
}


// MARK: - View

struct BulkDiscoveryView: View {
    @StateObject private var model = BulkDiscoveryModel()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            configBar
            Divider().background(NS.borderMid)
            if let err = model.errorMessage { errorBanner(err) }
            progressBar
            results
        }
        .tabNavigationTitle(.bulkDiscovery)
        // Runs when the window closes (tabs now stay alive across switches) — cancel the
        // two-phase sweep instead of orphaning it
        .onDisappear { if model.isRunning { model.cancel() } }
    }

    private var toolbar: some View {
        // One row when it fits; narrow windows move the status line under the title
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                toolbarTitle
                statusText
                Spacer()
                toolbarActions
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 12) {
                    toolbarTitle
                    Spacer()
                    toolbarActions
                }
                statusText
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(NS.bg0)
    }

    @ViewBuilder
    private var toolbarTitle: some View {
        Image(systemName: "square.grid.3x3.fill.square").foregroundStyle(.cyan)
        Text("Bulk Subnet Discovery").font(.system(size: 13, weight: .semibold))
            .foregroundStyle(NS.text1)
            .fixedSize()
    }

    @ViewBuilder
    private var statusText: some View {
        if !model.status.isEmpty {
            Text(model.status).font(.system(size: 11, design: .monospaced))
                .foregroundStyle(NS.text3)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var toolbarActions: some View {
        if !model.assets.isEmpty {
            ToolActionBar("Bulk-Discovery",
                          text: { model.exportText() },
                          csv:  { model.exportCSV() },
                          json: { model.exportJSON() })
                .fixedSize()
        }
        if model.isRunning {
            Button("Stop") { model.cancel() }
                .buttonStyle(.bordered).tint(.red)
                .fixedSize()
            ProgressView().controlSize(.small)
        } else {
            Button("Start") { model.start() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
                .fixedSize()
        }
    }

    private var configBar: some View {
        // One row when it fits; narrow windows move the range hint to its own row
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                configControls
                Spacer()
                rangeHint
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    configControls
                    Spacer()
                }
                rangeHint
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(NS.bg1)
    }

    @ViewBuilder
    private var configControls: some View {
        Text("Range:").font(.system(size: 11)).foregroundStyle(NS.text3).fixedSize()
        TextField("192.168.1.0/24", text: $model.cidr)
            .textFieldStyle(.roundedBorder).frame(width: 200)
            .disabled(model.isRunning)
            .help("A subnet (10.0.0.0/22), a range (10.0.0.1-10.0.3.254 or 192.168.1.100-150), a /24 shorthand (192.168.1), or a single address — several separated by commas.")
        Toggle("Port scan", isOn: $model.includePortScan).toggleStyle(.checkbox).font(.system(size: 11))
            .fixedSize()
            .disabled(model.isRunning)
        Toggle("SNMP probe", isOn: $model.probeSNMP).toggleStyle(.checkbox).font(.system(size: 11))
            .fixedSize()
            .disabled(model.isRunning)
        if model.probeSNMP {
            TextField("community", text: $model.community)
                .textFieldStyle(.roundedBorder).frame(width: 90)
                .disabled(model.isRunning)
        }
    }

    // Previously read "Max /22 (1024 hosts)" while the code allowed 8,192.
    private var rangeHint: some View {
        Text("Up to \(BulkDiscoveryModel.maxHosts.formatted()) addresses (a /19) — keep scans focused")
            .font(.system(size: 10)).foregroundStyle(NS.text3)
            .lineLimit(1)
    }

    private var progressBar: some View {
        Group {
            if model.isRunning {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Text("Scanned \(model.scanned)/\(model.total)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(NS.text3)
                        Text("· alive \(model.alive)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(NS.green)
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.vertical, 4)
                    ProgressView(value: model.total > 0 ? Double(model.scanned) / Double(model.total) : 0)
                        .progressViewStyle(.linear)
                        .tint(NS.amber)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 6)
                }
                .background(NS.bg0)
                Divider().background(NS.borderMid)
            }
        }
    }

    private func errorBanner(_ s: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(NS.red)
            Text(s).font(.system(size: 11, design: .monospaced))
                .foregroundStyle(NS.text1).textSelection(.enabled)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(NS.red.opacity(0.08))
    }

    @ViewBuilder
    private var results: some View {
        if model.assets.isEmpty && !model.isRunning {
            VStack(spacing: 10) {
                Image(systemName: "square.grid.3x3.fill.square")
                    .font(.system(size: 40)).foregroundStyle(NS.text3)
                Text("Enter a CIDR and press Start to inventory the subnet.")
                    .font(.system(size: 12)).foregroundStyle(NS.text2)
                    .multilineTextAlignment(.center).frame(maxWidth: 380)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(model.assets) {
                TableColumn("IP") { a in
                    Text(a.ip).font(.system(.body, design: .monospaced))
                        .hostMenu(a.ip)
                }
                .width(min: 110, ideal: 130)
                TableColumn("MAC") { Text($0.mac ?? "—").font(.system(.body, design: .monospaced)) }
                    .width(min: 130, ideal: 150)
                TableColumn("Hostname") { Text($0.hostname ?? "—") }
                    .width(min: 130, ideal: 180)
                TableColumn("Vendor") { Text($0.vendor ?? "—") }
                    .width(min: 110, ideal: 140)
                TableColumn("Model") { Text($0.model ?? "—") }.width(100)
                TableColumn("Role") { a in
                    HStack(spacing: 4) {
                        Image(systemName: a.role.icon).foregroundStyle(NS.amber).frame(width: 12)
                        Text(a.role.rawValue).font(.system(size: 11))
                    }
                }
                .width(120)
                TableColumn("Open ports") { a in
                    Text(a.openPorts.isEmpty ? "—" : a.openPorts.map(String.init).joined(separator: ", "))
                        .font(.system(.body, design: .monospaced))
                }
            }
        }
    }
}
