// StatusBoardMonitors.swift
// SNAP — Data-fetch singletons for the v1.5.2 Status Board tiles
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian. All rights reserved.
//
// Four singletons feeding the v1.5.2 tiles that didn't have a data source
// before:
//   • DNSLatencyMonitor — pings a configured list of resolvers every 10 s
//   • SystemStatsMonitor — Mac uptime, CPU load, memory pressure, battery
//   • TopTalkersMonitor  — per-process RX/TX via `nettop -P`
//   • PublicIPMonitor    — fetches external IPv4 + ISP/ASN via ipwho.is,
//                          cached with a 10-minute refresh
// Plus `ConnectionHealth` (v1.5.3): the one scoring model behind the System
// Health tile, the Gateway Latency tile, and the menu bar status dot.
//
// All keep the same lightweight pattern used across SNAP: MainActor-isolated
// ObservableObject singletons with @Published state, background workers
// hopping back to the main thread to publish.

import Foundation
import SwiftUI
import Darwin
import IOKit.ps

// MARK: - DNS latency

@MainActor
final class DNSLatencyMonitor: ObservableObject {
    static let shared = DNSLatencyMonitor()

    struct Resolver: Identifiable, Hashable {
        let id: String   // stable — the IP
        let name: String
        let ip: String
    }

    static let defaults: [Resolver] = [
        .init(id: "sys",  name: "System",     ip: ""),          // filled in at probe time
        .init(id: "cf",   name: "Cloudflare", ip: "1.1.1.1"),
        .init(id: "goog", name: "Google",     ip: "8.8.8.8"),
        .init(id: "q9",   name: "Quad9",      ip: "9.9.9.9"),
    ]

    @Published private(set) var results: [String: Double] = [:] // resolver.id -> ms (nil == fail)
    @Published private(set) var failed: Set<String> = []
    @Published private(set) var lastRefresh: Date?

    private var timer: Timer?
    private let queue = DispatchQueue(label: "snap.dns-latency", qos: .utility)

    private init() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            Task { @MainActor in self?.probe() }
        }
        let t = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.probe() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// The effective resolvers to probe — same defaults, but the system entry
    /// picks up the first configured resolver from `DNSInfo` at probe time.
    var resolvers: [Resolver] {
        Self.defaults.map { r in
            if r.id == "sys" {
                let sys = DNSInfo.systemResolvers().first ?? ""
                return .init(id: "sys", name: "System", ip: sys)
            }
            return r
        }
    }

    private func probe() {
        let list = resolvers
        queue.async { [weak self] in
            var out: [String: Double] = [:]
            var fail: Set<String> = []
            for r in list where !r.ip.isEmpty {
                if let ms = Self.dnsPing(server: r.ip) {
                    out[r.id] = ms
                } else {
                    fail.insert(r.id)
                }
            }
            DispatchQueue.main.async {
                self?.results = out
                self?.failed = fail
                self?.lastRefresh = Date()
            }
        }
    }

    /// One DNS A-query round-trip to `server` for a lightweight name.
    /// `nonisolated` — pure computation, touches no actor state, and is
    /// deliberately called from the background probe queue.
    nonisolated private static func dnsPing(server: String) -> Double? {
        let t0 = Date()
        do {
            _ = try DNSWire.query(server: server, name: "cloudflare.com",
                                  type: .a, timeout: 1.5)
            return Date().timeIntervalSince(t0) * 1000
        } catch {
            return nil
        }
    }
}

// MARK: - System stats (uptime / CPU / memory / battery)

@MainActor
final class SystemStatsMonitor: ObservableObject {
    static let shared = SystemStatsMonitor()

    @Published private(set) var uptimeSeconds: TimeInterval = 0
    @Published private(set) var cpuPct: Double = 0                  // 0…100 (user + system)
    @Published private(set) var memUsedBytes: UInt64 = 0
    @Published private(set) var memTotalBytes: UInt64 = 0
    @Published private(set) var batteryPct: Int?                    // nil if no battery
    @Published private(set) var batteryCharging: Bool = false

    private var timer: Timer?
    private var lastCPUTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) = (0,0,0,0)

    private init() {
        readAll()
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.readAll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func readAll() {
        uptimeSeconds = Self.readUptime()
        cpuPct = Self.readCPULoad(prev: &lastCPUTicks)
        let mem = Self.readMemory()
        memUsedBytes = mem.used
        memTotalBytes = mem.total
        let bat = Self.readBattery()
        batteryPct = bat.percent
        batteryCharging = bat.charging
    }

    // MARK: uptime

    private static func readUptime() -> TimeInterval {
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        var boot = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctl(&mib, u_int(mib.count), &boot, &size, nil, 0) == 0 else { return 0 }
        return Date().timeIntervalSince(Date(timeIntervalSince1970: TimeInterval(boot.tv_sec)))
    }

    // MARK: CPU

    private static func readCPULoad(prev: inout (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)) -> Double {
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var cpu = host_cpu_load_info_data_t()
        let rc = withUnsafeMutablePointer(to: &cpu) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard rc == KERN_SUCCESS else { return 0 }
        let user   = UInt64(cpu.cpu_ticks.0)
        let system = UInt64(cpu.cpu_ticks.1)
        let idle   = UInt64(cpu.cpu_ticks.2)
        let nice   = UInt64(cpu.cpu_ticks.3)

        let du = user   &- prev.user
        let ds = system &- prev.system
        let di = idle   &- prev.idle
        let dn = nice   &- prev.nice
        let total = du + ds + di + dn
        prev = (user, system, idle, nice)

        guard total > 0 else { return 0 }
        return Double(du + ds + dn) / Double(total) * 100.0
    }

    // MARK: memory

    private static func readMemory() -> (used: UInt64, total: UInt64) {
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var vm = vm_statistics64_data_t()
        let rc = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
            }
        }
        guard rc == KERN_SUCCESS else { return (0, 0) }

        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let ps = UInt64(pageSize)

        let active   = UInt64(vm.active_count)   * ps
        let wired    = UInt64(vm.wire_count)     * ps
        let compressed = UInt64(vm.compressor_page_count) * ps
        let used = active + wired + compressed

        var total: UInt64 = 0
        var totalSize = MemoryLayout<UInt64>.size
        var mib: [Int32] = [CTL_HW, HW_MEMSIZE]
        sysctl(&mib, u_int(mib.count), &total, &totalSize, nil, 0)
        return (used, total)
    }

    // MARK: battery

    private static func readBattery() -> (percent: Int?, charging: Bool) {
        let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        guard let blob else { return (nil, false) }
        let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] ?? []
        for src in list {
            guard let info = IOPSGetPowerSourceDescription(blob, src)?.takeUnretainedValue() as? [String: Any] else { continue }
            guard (info[kIOPSTypeKey as String] as? String) == kIOPSInternalBatteryType else { continue }
            let cap = info[kIOPSCurrentCapacityKey as String] as? Int
            let charging = (info[kIOPSIsChargingKey as String] as? Bool) == true
            return (cap, charging)
        }
        return (nil, false)
    }
}

// MARK: - Top Talkers (per-process bandwidth via nettop)

@MainActor
final class TopTalkersMonitor: ObservableObject {
    static let shared = TopTalkersMonitor()

    struct Talker: Identifiable {
        let id: String       // "PID·name"
        let pid: Int
        let name: String
        let rxRate: Double   // bytes/sec
        let txRate: Double
    }

    @Published private(set) var talkers: [Talker] = []
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var errorNote: String?

    private var timer: Timer?
    private let queue = DispatchQueue(label: "snap.top-talkers", qos: .utility)
    private var running = false

    private init() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            Task { @MainActor in self?.sample() }
        }
        let t = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// nettop -P -x -k pid,command,bytes_in,bytes_out -L 2 -s 1
    /// -P: per-process. -x: raw values. -k: columns. -L 2: two samples so we
    /// can delta. -s 1: 1s interval between samples.
    private func sample() {
        guard !running else { return }
        running = true
        queue.async { [weak self] in
            defer { DispatchQueue.main.async { self?.running = false } }
            let output = Self.runNettop()
            let parsed = Self.parse(output: output)
            DispatchQueue.main.async {
                self?.talkers = parsed
                self?.lastRefresh = Date()
                if parsed.isEmpty && !output.isEmpty {
                    self?.errorNote = "No per-process data — nettop may need Full Disk Access."
                } else {
                    self?.errorNote = nil
                }
            }
        }
    }

    /// `nonisolated` — spawns a subprocess and returns its output; no actor
    /// state involved, and it must run off the main thread.
    nonisolated private static func runNettop() -> String {
        let p = Process()
        p.launchPath = "/usr/bin/nettop"
        p.arguments = ["-P", "-x", "-k",
                       "pid,command,bytes_in,bytes_out",
                       "-L", "2", "-s", "1"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        // Drain to EOF before waiting — otherwise pipe fills at ~64 KB and
        // nettop stalls indefinitely. Same pattern as Shell.run.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// nettop -L 2 emits two samples separated by a marker line. The SECOND
    /// sample's byte counts are what we want (per-process delta over 1s).
    /// `nonisolated` — pure string parsing, called from the sampling queue.
    nonisolated private static func parse(output: String) -> [Talker] {
        // Split into per-sample sections by the "==" marker line nettop uses.
        let sections = output.components(separatedBy: "==")
        guard sections.count >= 2 else { return [] }
        let last = sections.last!  // second sample block
        var out: [Talker] = []
        let lines = last.split(separator: "\n")

        for line in lines {
            let s = String(line).trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { continue }
            // Skip header rows.
            if s.hasPrefix("time,") || s.hasPrefix("bytes_in,") || s.hasPrefix(",") { continue }
            let cols = s.split(separator: ",", omittingEmptySubsequences: false).map { String($0) }
            // Expect: <rowIdx>,<time>,<process[.PID]>,<bytes_in>,<bytes_out>
            //   e.g. "1,15:04:22.123456,Safari.421,12345,6789"
            // Field count varies by nettop build; look for the process-and-pid
            // pattern and pull integer bytes fields off the tail.
            guard cols.count >= 4 else { continue }
            // Find the process.PID column — it contains a dot with digits after.
            guard let procIdx = cols.firstIndex(where: { c in
                guard let dot = c.lastIndex(of: ".") else { return false }
                return c[c.index(after: dot)...].allSatisfy(\.isNumber)
            }) else { continue }
            let procField = cols[procIdx]
            let dot = procField.lastIndex(of: ".")!
            let name = String(procField[..<dot])
            let pid = Int(procField[procField.index(after: dot)...]) ?? 0
            // Bytes fields — try the two immediately after process.
            let restNums = cols.dropFirst(procIdx + 1).compactMap { UInt64($0) }
            guard restNums.count >= 2 else { continue }
            let rx = Double(restNums[0])
            let tx = Double(restNums[1])
            // nettop's `-L 2 -s 1` gives per-second bytes for the second sample.
            out.append(Talker(id: "\(pid)·\(name)", pid: pid, name: name,
                              rxRate: rx, txRate: tx))
        }
        // Top 5 by total throughput.
        return out.sorted { ($0.rxRate + $0.txRate) > ($1.rxRate + $1.txRate) }.prefix(5).map { $0 }
    }
}

// MARK: - Public IP (external IPv4 + ISP/ASN via ipwho.is)

@MainActor
final class PublicIPMonitor: ObservableObject {
    static let shared = PublicIPMonitor()

    @Published private(set) var ip: String?
    @Published private(set) var isp: String?
    @Published private(set) var asn: String?
    @Published private(set) var city: String?
    @Published private(set) var country: String?
    @Published private(set) var countryCode: String?
    @Published private(set) var flagEmoji: String?
    @Published private(set) var lastRefresh: Date?

    private var timer: Timer?

    private init() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        let t = Timer(timeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() {
        if DemoMode.isActive {
            ip = DemoMode.ip
            isp = DemoMode.isp
            asn = DemoMode.asn
            city = DemoMode.city
            country = DemoMode.country
            countryCode = DemoMode.countryCode
            flagEmoji = DemoMode.flagEmoji
            lastRefresh = Date()
            return
        }
        guard let url = URL(string: "https://ipwho.is/") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["success"] as? Bool == true else { return }
            let ip   = json["ip"]           as? String
            let city = json["city"]         as? String
            let ctry = json["country"]      as? String
            let cc   = json["country_code"] as? String
            let flag = (json["flag"] as? [String: Any])?["emoji"] as? String
            let conn = json["connection"] as? [String: Any]
            let isp  = conn?["isp"] as? String ?? conn?["org"] as? String
            let asnNum = conn?["asn"]
            let asnStr: String? = asnNum.map { "AS\($0)" }
            DispatchQueue.main.async {
                guard let self else { return }
                self.ip = ip
                self.isp = isp
                self.asn = asnStr
                self.city = city
                self.country = ctry
                self.countryCode = cc
                self.flagEmoji = flag
                self.lastRefresh = Date()
            }
        }.resume()
    }
}

// MARK: - Connection health (shared scoring)

/// One scoring model for "how healthy is the path to my router?", shared by
/// the System Health and Gateway Latency tiles so they can't contradict each
/// other. Inputs are `MenuBarMonitor`'s gateway ping window (30 samples at
/// 10 s ≈ 5 min), Wi-Fi signal when Wi-Fi carries the default route, and
/// alerts from the last hour.
///
/// Thresholds are gateway-scale: a healthy first hop answers in a few ms
/// with near-zero jitter. Before v1.5.3 the score used a 40 ms
/// internet-scale cutoff and ignored jitter and Wi-Fi, so it could read
/// "Excellent" next to 64 ms of jitter.
enum ConnectionHealth {

    struct Assessment: Equatable {
        /// 0–100, or nil before the first gateway sample.
        let score: Int?
        let grade: String
        /// Most significant factors first, e.g. "Jitter 32 ms · Weak Wi‑Fi".
        let summary: String
    }

    enum GatewayState: Equatable {
        case measuring, healthy, slow, unstable, degraded, notResponding
    }

    // Each factor is free up to its "fine" level, then costs points up to a
    // cap. Calibrated so each gateway factor alone crosses the tile's warning
    // line (avg > 30 ms, jitter > 15 ms, loss ≥ 5 %) as the score drops
    // below 90, and reaches its cap where the gateway reads "Degraded".
    static func latencyPenalty(_ avgMs: Double) -> Double { min(30, max(0, avgMs - 10) * 0.5) }
    static func jitterPenalty(_ ms: Double) -> Double { min(25, max(0, ms - 5)) }
    static func lossPenalty(_ pct: Double) -> Double { min(80, max(0, pct) * 3) }
    static func wifiPenalty(_ quality: Int) -> Double { min(20, Double(max(0, 60 - quality)) * 0.5) }
    static func alertPenalty(_ count: Int) -> Double { min(20, Double(max(0, count)) * 4) }

    /// This many timeouts in a row means the router is down *now*, whatever
    /// the rest of the window says. Two (≈20 s at the 10 s cadence) is fast
    /// enough to catch an outage without flagging a single dropped ping.
    static let outageTimeouts = 2

    static func assess(avgMs: Double?, jitterMs: Double?, lossPct: Double, samples: Int,
                       wifiQuality: Int?, recentAlerts: Int,
                       trailingTimeouts: Int = 0) -> Assessment {
        guard samples > 0 else {
            return Assessment(score: nil, grade: "Measuring", summary: "Waiting for gateway samples")
        }
        guard let avg = avgMs, trailingTimeouts < outageTimeouts else {
            return Assessment(score: 0, grade: "Poor", summary: "Router not responding")
        }
        let jitter = jitterMs ?? 0
        let lat = latencyPenalty(avg)
        let jit = jitterPenalty(jitter)
        let loss = lossPenalty(lossPct)
        let wifi = wifiQuality.map(wifiPenalty) ?? 0
        let alerts = alertPenalty(recentAlerts)

        // Named when they cost ≥ 5 points; any loss or alert is always named.
        let factors: [(cost: Double, text: String, named: Bool)] = [
            (lat, "Latency \(Int(avg.rounded())) ms", lat >= 5),
            (jit, "Jitter \(Int(jitter.rounded())) ms", jit >= 5),
            (loss, "\(Int(lossPct.rounded()))% loss", lossPct > 0),
            (wifi, "Weak Wi‑Fi", wifi >= 5),
            (alerts, recentAlerts == 1 ? "1 alert this hour" : "\(recentAlerts) alerts this hour", recentAlerts > 0),
        ]
        let total = tenths(factors.reduce(0) { $0 + $1.cost })
        let score = Int(max(0, min(100, 100 - total)))

        var named = factors.enumerated()
            .filter { $0.element.named }
            .sorted { $0.element.cost != $1.element.cost ? $0.element.cost > $1.element.cost : $0.offset < $1.offset }
            .prefix(3)
            .map { $0.element.text }
        if named.isEmpty {
            named = ["Latency stable", "No packet loss"]
        } else if lossPct == 0 && named.count < 3 {
            named.append("No packet loss")
        }
        return Assessment(score: score, grade: grade(score), summary: named.joined(separator: " · "))
    }

    static func grade(_ score: Int) -> String {
        switch score {
        case 90...:   return "Excellent"
        case 75..<90: return "Good"
        case 50..<75: return "Fair"
        case 25..<50: return "Degraded"
        default:      return "Poor"
        }
    }

    /// The Gateway Latency tile's label and the menu bar dot, judged on the
    /// same window and the same costs as the score — not on the single
    /// latest ping.
    static func gatewayState(avgMs: Double?, jitterMs: Double?, lossPct: Double,
                             samples: Int, trailingTimeouts: Int = 0) -> GatewayState {
        guard samples > 0 else { return .measuring }
        guard let avg = avgMs, trailingTimeouts < outageTimeouts else { return .notResponding }
        let lat = latencyPenalty(avg)
        let unsteady = jitterPenalty(jitterMs ?? 0) + lossPenalty(lossPct)
        let cost = tenths(lat + unsteady)
        if cost <= 10 { return .healthy }
        if cost >= 30 { return .degraded }
        return lat >= unsteady ? .slow : .unstable
    }

    /// Costs rounded to 0.1 before comparing, so float noise can't flip a
    /// boundary: one lost ping in 30 is 3.333…% × 3 = 10.000000000000002,
    /// which would otherwise tip "Healthy / 90" into "Slow / 89".
    private static func tenths(_ x: Double) -> Double { (x * 10).rounded() / 10 }

    /// RSSI → 0–100 (−40 dBm = 100, −85 dBm = 0); 0 when not associated.
    /// Shared by the Wi-Fi tile's quality ring and the health score.
    static func wifiQuality(rssi: Int) -> Int {
        guard rssi != 0 else { return 0 }
        let s = 100.0 - (Double(-40 - rssi) * (100.0 / 45.0))
        return Int(max(0, min(100, s)))
    }
}
