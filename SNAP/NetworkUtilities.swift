// NetworkUtilities.swift
// SNAP — Advanced Network Analysis Platform for macOS
// Created by Sevag Bardakjian
// Copyright © 2025-2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md

import Foundation
import Network
import Darwin
import SystemConfiguration

// MARK: - Shell Runner
enum Shell {
    /// Run a command and return combined stdout+stderr.
    ///
    /// Hardened against two long-standing pitfalls:
    ///   • **Pipe-buffer deadlock** — the old implementation called
    ///     `waitUntilExit()` *before* reading the pipe, so a child that wrote
    ///     more than the ~64 KB pipe buffer would block on write while we
    ///     blocked on wait, hanging forever. We now drain the pipe to EOF
    ///     first (which only completes once the child closes it), then wait.
    ///   • **Runaway children** — a `timeout` watchdog terminates a process
    ///     that overruns, so a wedged tool can't hang the app indefinitely.
    ///
    /// With `stopsOnCancel`, cancelling the calling task terminates the
    /// process and returns what it printed so far (used by Stop buttons).
    /// Off by default, so callers that never expected a cut-short result
    /// keep getting the whole output.
    static func run(_ command: String, args: [String] = [], timeout: TimeInterval = 60,
                    stopsOnCancel: Bool = false) async -> String {
        // Shared by the worker below and the cancellation handler
        final class Running: @unchecked Sendable {
            let lock = NSLock()
            let task = Process()
            var cancelled = false
        }
        let running = Running()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let task = running.task
                    task.executableURL = URL(fileURLWithPath: command)
                    task.arguments = args
                    let pipe = Pipe()
                    task.standardOutput = pipe
                    task.standardError  = pipe

                    let lock = NSLock()
                    var finished = false
                    func finish(_ s: String) {
                        lock.lock(); let already = finished; finished = true; lock.unlock()
                        if !already { cont.resume(returning: s) }
                    }

                    // Holding the lock across run() means a cancel either lands
                    // before it (and nothing starts) or after (and terminates it)
                    running.lock.lock()
                    if stopsOnCancel && running.cancelled {
                        running.lock.unlock()
                        finish("")
                        return
                    }
                    do {
                        try task.run()
                    } catch {
                        running.lock.unlock()
                        finish("Error: \(error.localizedDescription)")
                        return
                    }
                    running.lock.unlock()

                    // Watchdog: terminate a process that overruns the timeout.
                    // Terminating closes the pipe, which unblocks the read below.
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                        if task.isRunning { task.terminate() }
                    }

                    // Drain to EOF *before* waiting — prevents the >64 KB
                    // pipe-buffer deadlock. Runs on this background thread, so the
                    // async caller is never blocked.
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    task.waitUntilExit()
                    finish(String(data: data, encoding: .utf8) ?? "")
                }
            }
        } onCancel: {
            guard stopsOnCancel else { return }
            running.lock.lock()
            running.cancelled = true
            if running.task.isRunning { running.task.terminate() }
            running.lock.unlock()
        }
    }

    static func stream(_ command: String, args: [String] = [], onLine: @escaping (String) -> Void, onFinish: @escaping () -> Void) -> Process {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: command)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError  = pipe

        // Buffer to accumulate partial line data between reads
        var buffer = Data()

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                // EOF on the pipe — flush any remaining buffer content
                if !buffer.isEmpty, let remaining = String(data: buffer, encoding: .utf8) {
                    buffer.removeAll()
                    DispatchQueue.main.async { onLine(remaining) }
                }
                handle.readabilityHandler = nil
                return
            }
            buffer.append(data)
            // Dispatch each complete line as it arrives
            while let newlineRange = buffer.range(of: Data([0x0A])) { // 0x0A = '\n'
                let lineData = buffer[buffer.startIndex..<newlineRange.lowerBound]
                buffer.removeSubrange(buffer.startIndex...newlineRange.lowerBound)
                if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                    DispatchQueue.main.async { onLine(line) }
                }
            }
        }

        task.terminationHandler = { _ in
            // Flush remaining buffer after process exits
            if !buffer.isEmpty, let remaining = String(data: buffer, encoding: .utf8) {
                buffer.removeAll()
                DispatchQueue.main.async { onLine(remaining) }
            }
            DispatchQueue.main.async { onFinish() }
        }

        var launched = false
        do {
            try task.run()
            launched = true
        } catch {
            DispatchQueue.main.async { onFinish() }
        }
        if !launched {
            // Return a sentinel — callers must guard isRunning before terminate()
            return task
        }
        return task
    }
}

// MARK: - Route Info (native, replaces `netstat -rn` parsing)

/// Default-route information read straight from `SCDynamicStore` instead of
/// shelling out to `netstat -rn -f inet` and string-parsing the "default"
/// line. The dynamic store's `State:/Network/Global/IPv4` dictionary exposes
/// the primary service's `Router` (default gateway) and `PrimaryInterface`
/// (e.g. "en0") directly — synchronous, allocation-light, and not subject to
/// CLI output-format drift.
enum RouteInfo {
    /// (gateway IP, primary interface name) for the default IPv4 route.
    static func defaultIPv4() -> (gateway: String?, interface: String?) {
        guard let store = SCDynamicStoreCreate(nil, "com.sevagbardakjian.snap.route" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        else { return (nil, nil) }
        return (global["Router"] as? String, global["PrimaryInterface"] as? String)
    }

    /// Default IPv4 gateway address, or nil if there's no default route.
    static func defaultGateway() -> String? { defaultIPv4().gateway }

    /// Interface name carrying the default IPv4 route (e.g. "en0").
    static func defaultInterface() -> String? { defaultIPv4().interface }
}

/// System DNS resolvers from `SCDynamicStore` instead of parsing
/// `scutil --dns`. `State:/Network/Global/DNS`'s `ServerAddresses` is the
/// effective global resolver list — the same set scutil reports.
enum DNSInfo {
    static func systemResolvers() -> [String] {
        guard let store = SCDynamicStoreCreate(nil, "com.sevagbardakjian.snap.dns" as CFString, nil, nil),
              let dns = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any],
              let servers = dns["ServerAddresses"] as? [String]
        else { return [] }
        // De-dupe while preserving order.
        var seen = Set<String>()
        return servers.filter { seen.insert($0).inserted }
    }
}

// MARK: - Network Info

enum InterfaceMediaType: String, Hashable {
    case ethernet = "Ethernet"
    case wifi     = "Wi-Fi"
    case vpn      = "VPN Tunnel"
    case loopback = "Loopback"
    case bridge   = "Bridge"
    case awdl     = "AirDrop / AWDL"
    case llw      = "Low-Latency WLAN"
    case ipsec    = "IPsec"
    case ppp      = "PPP"
    case other    = "Interface"

    var icon: String {
        switch self {
        case .ethernet: return "cable.connector"
        case .wifi:     return "wifi"
        case .vpn, .ipsec, .ppp: return "lock.shield"
        case .loopback: return "arrow.triangle.2.circlepath"
        case .bridge:   return "rectangle.connected.to.line.below"
        case .awdl, .llw: return "airplayaudio"
        case .other:    return "network"
        }
    }
}

struct IPv4Binding: Hashable {
    let ip: String
    let cidr: Int        // 0 when unknown
    var withCIDR: String { cidr > 0 ? "\(ip)/\(cidr)" : ip }
}

struct IPv6Binding: Hashable {
    let ip: String
    let scope: String    // "link-local", "unique-local", "global", "multicast"
}

struct InterfaceTrafficCounters: Hashable {
    let rxBytes: UInt64
    let txBytes: UInt64
    let rxPackets: UInt64
    let txPackets: UInt64
    let rxErrors: UInt32
    let txErrors: UInt32
    let rxDropped: UInt32
}

/// Lightweight per-second snapshot used by Interface Stats' live ticker.
/// Doesn't carry IP/MAC/media info — just the counters that change.
struct InterfaceLiveSnapshot: Hashable {
    let name: String
    let isUp: Bool
    let traffic: InterfaceTrafficCounters?
    let mtu: Int?
}

struct InterfaceInfo: Identifiable, Hashable {
    // Identity is the interface name. UUID-based identity made two
    // InterfaceInfo objects for the same interface (across refreshes)
    // unequal, which broke Table selection bindings.
    var id: String { name }
    static func == (lhs: InterfaceInfo, rhs: InterfaceInfo) -> Bool { lhs.name == rhs.name }
    func hash(into hasher: inout Hasher) { hasher.combine(name) }
    var name: String
    var displayName: String

    // Legacy plain-string lists (kept so existing callers in SessionReporter etc. keep working)
    var ipv4: [String]
    var ipv6: [String]

    // Rich v1.2.4 fields
    var ipv4Bindings: [IPv4Binding] = []
    var ipv6Bindings: [IPv6Binding] = []
    var macAddress: String
    var isUp: Bool
    var flags: String

    var mediaType: InterfaceMediaType = .other
    var mtu: Int? = nil
    var linkSpeed: String? = nil      // e.g. "1 Gbps" / "Wi-Fi"
    var duplex: String? = nil         // "Full" / "Half"
    var carrier: Bool? = nil          // status: active vs inactive
    var traffic: InterfaceTrafficCounters? = nil
}

class NetworkInfoProvider: ObservableObject {
    @Published var interfaces: [InterfaceInfo] = []
    @Published var externalIP: String = "Fetching..."
    @Published var hostname: String = ProcessInfo.processInfo.hostName
    /// Interface that carries the current default IPv4 route. The InfoView
    /// uses this to badge the active row in the sidebar.
    @Published var activeRouteInterface: String? = nil

    init() { refresh() }

    func refresh() {
        Task { await fetchExternalIP() }
        // getInterfaces() shells out to `ifconfig -a` and `netstat -rn`. Running
        // it on the caller blocks the main thread and, when refresh() is invoked
        // during view creation (init) or an update, publishes `interfaces` /
        // `activeRouteInterface` from within that update — the "Publishing changes
        // from within view updates" runtime warning. Do the work off-main and
        // publish the results back on the main queue, off the update pass.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (ifaces, active) = Self.getInterfaces()
            DispatchQueue.main.async {
                guard let self else { return }
                self.interfaces = ifaces
                self.activeRouteInterface = active
            }
        }
    }

    // MARK: - One-shot interface enumeration
    //
    // We do exactly *one* getifaddrs walk and *one* ifconfig -a shell out per
    // refresh. The getifaddrs walk gives us IPs/netmasks/MAC/MTU/traffic
    // counters; ifconfig fills in media speed/duplex/carrier (macOS doesn't
    // expose those in a single syscall short of SIOCGIFMEDIA ioctl).

    /// Snapshot of just-traffic-counters for every interface. Cheap — pure
    /// getifaddrs, no shell-outs. Use this for live per-second tickers
    /// where ifconfig / netstat data isn't needed.
    static func snapshotLive() -> [InterfaceLiveSnapshot] {
        var out: [InterfaceLiveSnapshot] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return [] }
        defer { freeifaddrs(ifaddr) }
        var cur = ifaddr
        while let c = cur {
            defer { cur = c.pointee.ifa_next }
            // ifa_addr is imported as implicitly-unwrapped but can be NULL
            // for some PPP/tunnel pseudo-interfaces
            guard let sa = c.pointee.ifa_addr else { continue }
            let family = Int32(sa.pointee.sa_family)
            guard family == AF_LINK else { continue }
            guard let dataPtr = c.pointee.ifa_data else { continue }
            let name = String(cString: c.pointee.ifa_name)
            let d = dataPtr.assumingMemoryBound(to: if_data.self).pointee
            let traffic = InterfaceTrafficCounters(
                rxBytes:   UInt64(d.ifi_ibytes),
                txBytes:   UInt64(d.ifi_obytes),
                rxPackets: UInt64(d.ifi_ipackets),
                txPackets: UInt64(d.ifi_opackets),
                rxErrors:  d.ifi_ierrors,
                txErrors:  d.ifi_oerrors,
                rxDropped: d.ifi_iqdrops
            )
            let isUp = (c.pointee.ifa_flags & UInt32(IFF_UP)) != 0
                    && (c.pointee.ifa_flags & UInt32(IFF_RUNNING)) != 0
            out.append(InterfaceLiveSnapshot(
                name: name, isUp: isUp,
                traffic: traffic, mtu: Int(d.ifi_mtu)
            ))
        }
        return out
    }

    /// Full enumerator — `static` so other views (Interface Stats) can call
    /// it without going through an instance. Returns rich InterfaceInfo
    /// (getifaddrs + ifconfig media parse + default-route detection).
    static func getInterfaces() -> (ifaces: [InterfaceInfo], activeRoute: String?) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return ([], nil) }
        defer { freeifaddrs(ifaddr) }

        // Aggregator keyed by interface name
        struct Acc {
            var ipv4: [IPv4Binding] = []
            var ipv6: [IPv6Binding] = []
            var mac: String = ""
            var mtu: Int? = nil
            var traffic: InterfaceTrafficCounters? = nil
            var flagBits: UInt32 = 0
        }
        var acc: [String: Acc] = [:]
        var order: [String] = []   // insertion-ordered for stable display

        var cur = ifaddr
        while let c = cur {
            defer { cur = c.pointee.ifa_next }
            let name = String(cString: c.pointee.ifa_name)
            if acc[name] == nil {
                acc[name] = Acc()
                order.append(name)
            }
            acc[name]!.flagBits = c.pointee.ifa_flags
            // NULL ifa_addr is legal (some PPP/tunnel entries) — keep the
            // interface's name/flags but skip address parsing
            guard let sa = c.pointee.ifa_addr else { continue }
            let family = Int32(sa.pointee.sa_family)

            switch family {
            case AF_INET:
                var sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
                let ip = String(cString: buf)
                var cidr = 0
                if let maskPtr = c.pointee.ifa_netmask {
                    let msin = maskPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                    let m = UInt32(bigEndian: msin.sin_addr.s_addr)
                    cidr = m.nonzeroBitCount
                }
                acc[name]!.ipv4.append(IPv4Binding(ip: ip, cidr: cidr))

            case AF_INET6:
                var sin6 = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                inet_ntop(AF_INET6, &sin6.sin6_addr, &buf, socklen_t(INET6_ADDRSTRLEN))
                var ip = String(cString: buf)
                // Strip the "%enX" scopeid suffix that link-local addresses carry.
                if let pct = ip.firstIndex(of: "%") {
                    ip = String(ip[..<pct])
                }
                acc[name]!.ipv6.append(IPv6Binding(ip: ip, scope: ipv6Scope(ip)))

            case AF_LINK:
                // sockaddr_dl is variable-length: sdl_data is *not* a fixed
                // 12-byte tuple in memory, the real length is sdl_len. The
                // Swift import treats sdl_data as a 12-byte tuple, so reading
                // past index 11 (e.g. nameLen=7 + MAC 6 = 13) crashed for
                // interface names like "bridge0". We bound reads by sdl_len
                // via the raw pointer instead.
                let raw = UnsafeRawPointer(sa)
                let sdlLen  = Int(raw.load(fromByteOffset: 0, as: UInt8.self))
                let nameLen = Int(raw.load(fromByteOffset: 5, as: UInt8.self))
                let alen    = Int(raw.load(fromByteOffset: 6, as: UInt8.self))
                if alen == 6, 8 + nameLen + 6 <= sdlLen {
                    var bytes: [UInt8] = []
                    for i in 0..<6 {
                        bytes.append(raw.load(fromByteOffset: 8 + nameLen + i, as: UInt8.self))
                    }
                    acc[name]!.mac = bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
                }
                // if_data lives in ifa_data — MTU + counters. Some pseudo
                // interfaces (utun, ipsec) leave ifa_data as a different
                // struct; guard before reading.
                if let dataPtr = c.pointee.ifa_data {
                    let d = dataPtr.assumingMemoryBound(to: if_data.self).pointee
                    acc[name]!.mtu = Int(d.ifi_mtu)
                    acc[name]!.traffic = InterfaceTrafficCounters(
                        rxBytes:   UInt64(d.ifi_ibytes),
                        txBytes:   UInt64(d.ifi_obytes),
                        rxPackets: UInt64(d.ifi_ipackets),
                        txPackets: UInt64(d.ifi_opackets),
                        rxErrors:  d.ifi_ierrors,
                        txErrors:  d.ifi_oerrors,
                        rxDropped: d.ifi_iqdrops
                    )
                }
            default:
                break
            }
        }

        // Pull media (speed/duplex/carrier) from one ifconfig -a parse.
        let mediaInfo = parseIfconfigMediaAll()

        // Default-route interface (from "netstat -rn -f inet")
        let activeRoute = defaultRouteInterface()

        var results: [InterfaceInfo] = []
        for name in order {
            guard let a = acc[name] else { continue }
            // Filter only obviously-noisy interfaces. Keep utun (real VPN
            // tunnels) so the user can see them — the old code's
            // "utun unless we have < 5 interfaces" rule was confusing.
            if name.hasPrefix("gif") || name.hasPrefix("stf") || name.hasPrefix("anpi") {
                continue
            }
            let media = mediaInfo[name]
            let mtype = inferMediaType(name: name, mediaLine: media?.mediaLine)
            let ipv4Strings = a.ipv4.map { $0.ip }
            let ipv6Strings = a.ipv6.map { $0.ip }
            let info = InterfaceInfo(
                name: name,
                displayName: friendlyName(name),
                ipv4: ipv4Strings,
                ipv6: ipv6Strings,
                ipv4Bindings: a.ipv4,
                ipv6Bindings: a.ipv6,
                macAddress: a.mac.isEmpty ? "—" : a.mac,
                isUp: (a.flagBits & UInt32(IFF_UP)) != 0 && (a.flagBits & UInt32(IFF_RUNNING)) != 0,
                flags: formatFlags(a.flagBits),
                mediaType: mtype,
                mtu: a.mtu,
                linkSpeed: media?.linkSpeed,
                duplex: media?.duplex,
                carrier: media?.carrier,
                traffic: a.traffic
            )
            results.append(info)
        }
        return (results, activeRoute)
    }

    // MARK: Helpers

    private static func friendlyName(_ ifname: String) -> String {
        if ifname == "en0" { return "Primary (en0)" }
        if ifname.hasPrefix("en")     { return "Ethernet / Wi-Fi (\(ifname))" }
        if ifname.hasPrefix("lo")     { return "Loopback (\(ifname))" }
        if ifname.hasPrefix("utun")   { return "VPN Tunnel (\(ifname))" }
        if ifname.hasPrefix("ipsec")  { return "IPsec Tunnel (\(ifname))" }
        if ifname.hasPrefix("ppp")    { return "PPP (\(ifname))" }
        if ifname.hasPrefix("awdl")   { return "AirDrop (\(ifname))" }
        if ifname.hasPrefix("llw")    { return "Low-Latency WLAN (\(ifname))" }
        if ifname.hasPrefix("bridge") { return "Bridge (\(ifname))" }
        return ifname
    }

    private static func inferMediaType(name: String, mediaLine: String?) -> InterfaceMediaType {
        if name.hasPrefix("utun")   { return .vpn }
        if name.hasPrefix("ipsec")  { return .ipsec }
        if name.hasPrefix("ppp")    { return .ppp }
        if name.hasPrefix("lo")     { return .loopback }
        if name.hasPrefix("awdl")   { return .awdl }
        if name.hasPrefix("llw")    { return .llw }
        if name.hasPrefix("bridge") { return .bridge }
        if name.hasPrefix("en") {
            // Refined by the media line — wifi line says e.g. "autoselect"
            // with no parens; ethernet says "(1000baseT <full-duplex>)".
            if let line = mediaLine?.lowercased() {
                if line.contains("base") || line.contains("twistedpair") {
                    return .ethernet
                }
            }
            return .wifi
        }
        return .other
    }

    private static func ipv6Scope(_ ip: String) -> String {
        let lower = ip.lowercased()
        if lower.hasPrefix("fe8") || lower.hasPrefix("fe9") ||
           lower.hasPrefix("fea") || lower.hasPrefix("feb") { return "link-local" }
        if lower.hasPrefix("fc") || lower.hasPrefix("fd")   { return "unique-local" }
        if lower.hasPrefix("ff")                            { return "multicast" }
        if lower == "::1"                                   { return "loopback" }
        return "global"
    }

    private static func formatFlags(_ raw: UInt32) -> String {
        var out: [String] = []
        if (raw & UInt32(IFF_UP))        != 0 { out.append("UP") }
        if (raw & UInt32(IFF_RUNNING))   != 0 { out.append("RUNNING") }
        if (raw & UInt32(IFF_BROADCAST)) != 0 { out.append("BROADCAST") }
        if (raw & UInt32(IFF_MULTICAST)) != 0 { out.append("MULTICAST") }
        if (raw & UInt32(IFF_LOOPBACK))  != 0 { out.append("LOOPBACK") }
        if (raw & UInt32(IFF_POINTOPOINT)) != 0 { out.append("POINTTOPOINT") }
        if (raw & UInt32(IFF_PROMISC))   != 0 { out.append("PROMISC") }
        return out.joined(separator: " ")
    }

    private static func defaultRouteInterface() -> String? {
        RouteInfo.defaultInterface()
    }

    // MARK: ifconfig parsing for media speed / duplex / carrier

    fileprivate struct IfconfigMedia {
        let mediaLine: String?  // raw "(1000baseT <full-duplex>)" content
        let linkSpeed: String?
        let duplex: String?
        let carrier: Bool?
    }

    /// Runs `/sbin/ifconfig -a` once and parses every per-interface block
    /// for "media:" and "status:" lines.
    fileprivate static func parseIfconfigMediaAll() -> [String: IfconfigMedia] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
        task.arguments = ["-a"]
        let pipe = Pipe()
        task.standardOutput = pipe
        do { try task.run() } catch { return [:] }
        // Drain the pipe before waiting — `ifconfig -a` can exceed the pipe
        // buffer on hosts with many interfaces (see Shell.run)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let s = String(data: data, encoding: .utf8) else { return [:] }

        var result: [String: IfconfigMedia] = [:]
        var currentName: String? = nil
        var currentMediaLine: String? = nil
        var currentSpeed: String? = nil
        var currentDuplex: String? = nil
        var currentCarrier: Bool? = nil

        func flush() {
            if let name = currentName {
                result[name] = IfconfigMedia(
                    mediaLine: currentMediaLine,
                    linkSpeed: currentSpeed,
                    duplex: currentDuplex,
                    carrier: currentCarrier
                )
            }
            currentName = nil; currentMediaLine = nil
            currentSpeed = nil; currentDuplex = nil; currentCarrier = nil
        }

        for raw in s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            // Interface header lines start at column 0 and look like
            // "en0: flags=...". Indented lines belong to the previous header.
            if !raw.isEmpty, raw.first?.isWhitespace == false,
               let colon = raw.firstIndex(of: ":"), colon > raw.startIndex {
                flush()
                currentName = String(raw[..<colon])
                continue
            }
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("media:") {
                let after = trimmed.dropFirst("media:".count).trimmingCharacters(in: .whitespaces)
                // Capture "(1000baseT <full-duplex>)" content if present
                if let open = after.firstIndex(of: "("),
                   let close = after.firstIndex(of: ")"),
                   open < close {
                    let inner = String(after[after.index(after: open)..<close])
                    currentMediaLine = inner
                    let (speed, duplex) = parseMediaInner(inner)
                    currentSpeed = speed
                    currentDuplex = duplex
                } else {
                    currentMediaLine = after.isEmpty ? nil : after
                }
            } else if trimmed.hasPrefix("status:") {
                let after = trimmed.dropFirst("status:".count).trimmingCharacters(in: .whitespaces).lowercased()
                currentCarrier = (after == "active")
            }
        }
        flush()
        return result
    }

    private static func parseMediaInner(_ inner: String) -> (speed: String?, duplex: String?) {
        // inner looks like "1000baseT <full-duplex>" or "autoselect <full-duplex>"
        let lower = inner.lowercased()
        let speed: String?
        switch true {
        case lower.contains("100gbase"):  speed = "100 Gbps"
        case lower.contains("40gbase"):   speed = "40 Gbps"
        case lower.contains("25gbase"):   speed = "25 Gbps"
        case lower.contains("10gbase"):   speed = "10 Gbps"
        case lower.contains("5000base"), lower.contains("5gbase"):
                                          speed = "5 Gbps"
        case lower.contains("2500base"), lower.contains("2.5gbase"):
                                          speed = "2.5 Gbps"
        case lower.contains("1000base"):  speed = "1 Gbps"
        case lower.contains("100base"):   speed = "100 Mbps"
        case lower.contains("10base"):    speed = "10 Mbps"
        default:                          speed = nil
        }
        let duplex: String?
        if lower.contains("full-duplex") { duplex = "Full" }
        else if lower.contains("half-duplex") { duplex = "Half" }
        else { duplex = nil }
        return (speed, duplex)
    }

    @MainActor
    private func fetchExternalIP() async {
        guard let url = URL(string: "https://api.ipify.org") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            externalIP = String(data: data, encoding: .utf8) ?? "Unknown"
        } catch {
            externalIP = "Unavailable"
        }
    }
}

// MARK: - DHCP lease helper (used by InfoView's per-interface card)

struct DHCPLeaseInfo: Hashable {
    let serverIdentifier: String?
    let router:           String?
    let subnetMask:       String?
    let leaseSeconds:     Int?
    let renewalSeconds:   Int?
    let rebindingSeconds: Int?
    let dnsServers:       [String]
    let domainName:       String?
    let leaseExpires:     Date?
}

enum DHCPHelper {
    /// Returns a parsed lease for `iface`, or nil if the interface isn't
    /// DHCP-bound (e.g. statically configured, loopback, VPN tunnel).
    static func fetchLease(iface: String) async -> DHCPLeaseInfo? {
        let raw = await Shell.run("/usr/sbin/ipconfig", args: ["getpacket", iface])
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty
            || trimmed.lowercased().contains("not bound")
            || trimmed == "<none>"
            || trimmed.lowercased().contains("no such") { return nil }

        var server, router, mask, domain: String?
        var leaseT, renewT, rebindT: Int?
        var dns: [String] = []

        for line in trimmed.split(separator: "\n").map(String.init) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("server_identifier"),
               let v = capture(t, after: ":") { server = v }
            else if t.hasPrefix("router"),
                    let v = capture(t, after: ":") {
                router = v.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces)
            }
            else if t.hasPrefix("subnet_mask"),
                    let v = capture(t, after: ":") { mask = v }
            else if t.hasPrefix("domain_name "),
                    let v = capture(t, after: ":") { domain = v }
            else if t.hasPrefix("domain_name_server"),
                    let v = capture(t, after: ":") {
                dns = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            }
            else if t.hasPrefix("lease_time"),
                    let v = capture(t, after: ":"),
                    let n = parseSeconds(v) { leaseT = n }
            else if t.hasPrefix("renewal_t1_time_value"),
                    let v = capture(t, after: ":"),
                    let n = parseSeconds(v) { renewT = n }
            else if t.hasPrefix("rebinding_t2_time_value"),
                    let v = capture(t, after: ":"),
                    let n = parseSeconds(v) { rebindT = n }
        }

        // If we got no useful fields, treat as not-a-lease.
        if server == nil && router == nil && dns.isEmpty && leaseT == nil { return nil }

        // Expiry = lease file mtime + lease_time (best-effort)
        var expires: Date? = nil
        if let t = leaseT {
            let leaseFile = "/var/db/dhcpclient/leases/\(iface).plist"
            if let attrs = try? FileManager.default.attributesOfItem(atPath: leaseFile),
               let date = attrs[.modificationDate] as? Date {
                expires = date.addingTimeInterval(TimeInterval(t))
            }
        }

        return DHCPLeaseInfo(
            serverIdentifier: server, router: router, subnetMask: mask,
            leaseSeconds: leaseT, renewalSeconds: renewT, rebindingSeconds: rebindT,
            dnsServers: dns, domainName: domain, leaseExpires: expires
        )
    }

    private static func capture(_ s: String, after sep: String) -> String? {
        guard let range = s.range(of: sep) else { return nil }
        let after = s[range.upperBound...].trimmingCharacters(in: .whitespaces)
        // strip parens like "(ip): 1.2.3.4"
        if let openParen = after.firstIndex(of: ")") {
            return String(after[after.index(after: openParen)...]).trimmingCharacters(in: .whitespaces)
        }
        return after.isEmpty ? nil : after
    }

    private static func parseSeconds(_ v: String) -> Int? {
        v.split(whereSeparator: { !$0.isNumber }).last.flatMap { Int($0) }
    }
}

// MARK: - Subnet Calculator
struct SubnetInfo {
    let address: String
    let cidr: Int
    var networkAddress: String = ""
    var broadcastAddress: String = ""
    var subnetMask: String = ""
    var wildcardMask: String = ""
    var firstHost: String = ""
    var lastHost: String = ""
    var totalHosts: Int = 0
    var usableHosts: Int = 0
    var ipClass: String = ""
    var isPrivate: Bool = false
    var addressType: String = ""
    var binaryMask: String = ""
}

/// Why the Subnet Calculator can't show results for what was typed.
enum SubnetInputError: Error, Equatable {
    case invalidAddress
    case invalidMask

    var message: String {
        switch self {
        case .invalidAddress:
            return "Enter an IPv4 address such as 192.168.1.10. Each of the four numbers must be 0 to 255."
        case .invalidMask:
            return "That isn't a valid subnet mask. Masks are a run of 255s followed by lower numbers, like 255.255.255.0."
        }
    }
}

class SubnetCalculator {
    /// Strict dotted-quad parse: exactly four decimal numbers, each 0 to 255.
    /// (A plain split + compactMap let "1.2.x.3.4" and "1..2.3.4" through.)
    static func parseIPv4(_ text: String) -> UInt32? {
        let parts = text.trimmingCharacters(in: .whitespaces)
            .split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard (1...3).contains(part.count),
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let octet = UInt32(part), octet <= 255 else { return nil }
            value = (value << 8) | octet
        }
        return value
    }

    /// Prefix length for a dotted mask, or nil when it isn't a valid mask
    /// (octets over 255, or bits that aren't contiguous like 255.0.255.0).
    static func prefixLength(fromMask text: String) -> Int? {
        guard let mask = parseIPv4(text) else { return nil }
        // A contiguous mask inverted is 0...01...1, so adding 1 clears every set bit
        let inverted = ~mask
        guard inverted & (inverted &+ 1) == 0 else { return nil }
        return mask.nonzeroBitCount
    }

    /// Validate what was typed, then calculate. `mask` is the Subnet Mask
    /// field in mask mode, or nil in CIDR mode (then `cidr` is used).
    static func evaluate(ip: String, mask: String?, cidr: Int) -> Result<SubnetInfo, SubnetInputError> {
        guard parseIPv4(ip) != nil else { return .failure(.invalidAddress) }
        var prefix = cidr
        if let mask {
            guard let p = prefixLength(fromMask: mask) else { return .failure(.invalidMask) }
            prefix = p
        }
        guard let info = calculate(ip: ip, cidr: prefix) else { return .failure(.invalidAddress) }
        return .success(info)
    }

    /// Plain-English label for the special-purpose ranges (RFC 6890);
    /// anything not listed is "Public".
    static func addressType(_ ip: UInt32) -> String {
        func inRange(_ base: UInt32, _ prefix: Int) -> Bool {
            let mask: UInt32 = prefix == 0 ? 0 : (0xFFFFFFFF << (32 - prefix))
            return ip & mask == base
        }
        if ip == 0xFFFFFFFF                            { return "Broadcast" }
        if inRange(0x0A000000, 8) || inRange(0xAC100000, 12) ||
           inRange(0xC0A80000, 16)                     { return "Private (RFC 1918)" }
        if inRange(0x64400000, 10)                     { return "Carrier-grade NAT (RFC 6598)" }
        if inRange(0x7F000000, 8)                      { return "Loopback" }
        if inRange(0xA9FE0000, 16)                     { return "Link-local" }
        if inRange(0xE0000000, 4)                      { return "Multicast" }
        if inRange(0x00000000, 8)                      { return "Reserved (this network)" }
        if inRange(0xC0000200, 24) || inRange(0xC6336400, 24) ||
           inRange(0xCB007100, 24)                     { return "Documentation (RFC 5737)" }
        if inRange(0xC6120000, 15)                     { return "Benchmarking (RFC 2544)" }
        if inRange(0xC0000000, 24)                     { return "Reserved (IETF protocol assignments)" }
        if inRange(0xF0000000, 4)                      { return "Reserved" }
        return "Public"
    }

    static func calculate(ip: String, cidr: Int) -> SubnetInfo? {
        guard cidr >= 0 && cidr <= 32 else { return nil }
        guard let ipInt = parseIPv4(ip) else { return nil }

        let maskInt: UInt32 = cidr == 0 ? 0 : (0xFFFFFFFF << (32 - cidr))
        let netInt  = ipInt & maskInt
        let bcastInt = netInt | (~maskInt)
        let wildInt  = ~maskInt

        func toIP(_ v: UInt32) -> String {
            "\((v >> 24) & 0xFF).\((v >> 16) & 0xFF).\((v >> 8) & 0xFF).\(v & 0xFF)"
        }

        let total = cidr >= 32 ? 1 : Int(UInt64(bcastInt - netInt) + 1)
        // RFC 3021: /31 has 2 usable hosts; /32 is a single host route
        let usable = cidr >= 31 ? total : max(0, total - 2)

        let maskStr = toIP(maskInt)
        let binary = (0..<32).map { i -> Character in
            let bit = (maskInt >> (31 - i)) & 1
            return bit == 1 ? "1" : "0"
        }
        let binaryGroups = stride(from: 0, to: 32, by: 8).map { String(binary[$0..<($0+8)]) }.joined(separator: ".")

        // Classified by the address typed, not the network: a short prefix
        // like 10.1.2.3/4 has network 0.0.0.0, which isn't what was asked about
        let typeLabel = Self.addressType(ipInt)
        let isPrivate = typeLabel == "Private (RFC 1918)"

        let ipClass: String
        switch (ipInt >> 24) & 0xFF {
        case 0...127:   ipClass = "A"
        case 128...191: ipClass = "B"
        case 192...223: ipClass = "C"
        case 224...239: ipClass = "D (Multicast)"
        default:        ipClass = "E (Reserved)"
        }

        return SubnetInfo(
            address: toIP(ipInt),
            cidr: cidr,
            networkAddress: toIP(netInt),
            broadcastAddress: toIP(bcastInt),
            subnetMask: maskStr,
            wildcardMask: toIP(wildInt),
            // /31 and /32 have no network/broadcast pair — netInt + 1 would
            // overflow at 255.255.255.255/32 and bcastInt - 1 at 0.0.0.0/32
            firstHost: toIP(cidr >= 31 ? netInt : netInt + 1),
            lastHost: toIP(cidr >= 31 ? bcastInt : bcastInt - 1),
            totalHosts: total,
            usableHosts: usable,
            ipClass: ipClass,
            isPrivate: isPrivate,
            addressType: typeLabel,
            binaryMask: binaryGroups
        )
    }
}

// MARK: - Wake-on-LAN
class WakeOnLANSender {
    enum SendResult: Equatable {
        case sent
        case invalidMAC
        case invalidAddress
        case sendFailed
    }

    /// The six bytes of a MAC written as aa:bb:cc:dd:ee:ff, aa-bb-cc-dd-ee-ff,
    /// aabb.ccdd.eeff or aabbccddeeff (any case), or nil if it isn't one.
    static func macBytes(_ mac: String) -> [UInt8]? {
        let trimmed = mac.trimmingCharacters(in: .whitespaces)
        let separators: Set<Character> = [":", "-", "."]
        let used = Set(trimmed.filter { separators.contains($0) })
        guard used.count <= 1 else { return nil }   // no mixing separators
        let hex = trimmed.filter { !separators.contains($0) }
        guard hex.count == 12, hex.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        if let sep = used.first {
            // Separators must split the digits evenly: pairs for : and -, groups of four for .
            let size = sep == "." ? 4 : 2
            let groups = trimmed.split(separator: sep, omittingEmptySubsequences: false)
            guard groups.count == 12 / size, groups.allSatisfy({ $0.count == size }) else { return nil }
        }
        var bytes = [UInt8]()
        var idx = hex.startIndex
        for _ in 0..<6 {
            let next = hex.index(idx, offsetBy: 2)
            guard let byte = UInt8(hex[idx..<next], radix: 16) else { return nil }
            bytes.append(byte)
            idx = next
        }
        return bytes
    }

    /// Canonical lowercase colon form (aa:bb:cc:dd:ee:ff), or nil if invalid.
    static func normalizedMAC(_ mac: String) -> String? {
        macBytes(mac)?.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    /// UDP port 1 to 65535, or nil.
    static func parsePort(_ text: String) -> UInt16? {
        guard let p = UInt16(text.trimmingCharacters(in: .whitespaces)), p > 0 else { return nil }
        return p
    }

    /// Strict IPv4 parse. inet_addr turned anything unparseable into
    /// INADDR_NONE, which is 255.255.255.255, so typos silently broadcast.
    static func parseIPv4(_ text: String) -> in_addr? {
        var addr = in_addr()
        guard inet_pton(AF_INET, text.trimmingCharacters(in: .whitespaces), &addr) == 1 else { return nil }
        return addr
    }

    static func send(mac: String, broadcastIP: String = "255.255.255.255", port: UInt16 = 9) -> SendResult {
        guard let macBytes = macBytes(mac) else { return .invalidMAC }
        guard let target = parseIPv4(broadcastIP), port > 0 else { return .invalidAddress }

        // Magic packet: 6x 0xFF + 16x MAC
        var magic = [UInt8](repeating: 0xFF, count: 6)
        for _ in 0..<16 { magic += macBytes }

        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock != -1 else { return .sendFailed }
        defer { close(sock) }

        var broadcast: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &broadcast, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = target

        let sent = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                sendto(sock, magic, magic.count, 0, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return sent == magic.count ? .sent : .sendFailed
    }
}

// MARK: - Lists macOS can withhold

/// macOS 27 hides the ARP table and the socket list from tools started by
/// an app that isn't signed with a Developer ID: `arp` and `netstat` print
/// no entries (netstat keeps its headers), while the same commands in
/// Terminal list everything. Local Network and Location permission don't
/// change it. Release builds are Developer ID signed and get the full
/// lists; builds signed to run locally (built from source, CI) don't, and
/// fall back to launchd. These turn a list that still comes back empty into
/// a message instead of a blank table.
enum WithheldLists {
    /// No entries in `arp -an` output. A Mac on a network always has at
    /// least its router in the table, so with a router known this means
    /// macOS didn't share it.
    static func arpIsEmpty(_ output: String) -> Bool {
        !output.split(separator: "\n").contains { $0.contains(" at ") }
    }

    static let arpMessage = "macOS didn't give SNAP its ARP table (the devices this Mac has talked to on your network), so there's nothing to list. In Terminal, arp -an still shows it."
    static let macNote = "macOS didn't share MAC addresses with SNAP, so vendor names that come from them are missing. In Terminal, arp -an still shows them."
    static let connectionsLimitedNote = "macOS didn't give SNAP the full connection list, so this shows connections of apps running as you. System connections (owned by root) and recently closed ones aren't included."
    static let connectionsMessage = "macOS didn't give SNAP the connection list, and SNAP couldn't read it another way. In Terminal, netstat -an still shows it."

    /// `arp` with `args`. When SNAP's own run comes back empty on a network
    /// (macOS withheld the table), it's asked again through launchd.
    static func arp(_ args: [String], timeout: TimeInterval = 60) async -> String {
        let direct = await Shell.run("/usr/sbin/arp", args: args, timeout: timeout)
        guard arpIsEmpty(direct), RouteInfo.defaultGateway() != nil else { return direct }
        return await Shell.runViaLaunchd("/usr/sbin/arp", args: args) ?? direct
    }
}

// MARK: - Running a system tool through launchd (stopgap)

extension Shell {
    /// The only commands `runViaLaunchd` will run.
    static let launchdCommands: Set<String> = ["/usr/sbin/arp", "/usr/sbin/netstat"]

    /// Runs `command` as a one-off launchd job and returns what it printed,
    /// or nil if it couldn't run or didn't finish within `timeout`.
    ///
    /// For builds that aren't Developer ID signed, which macOS 27 doesn't
    /// give the ARP table and socket list (see `WithheldLists`): a job
    /// launchd starts isn't one of SNAP's own processes, and it gets the
    /// full list, as Terminal does. Release builds don't need it, since
    /// their own arp and netstat already list everything.
    ///
    /// The job is `launchctl submit`, which launchd would restart when it
    /// exits, so the job removes itself as its last step. That way it can't
    /// keep running even if SNAP quits mid-way; SNAP also removes it after.
    /// Paths are passed as arguments to the script, never pasted into it.
    static func runViaLaunchd(_ command: String, args: [String], timeout: TimeInterval = 5) async -> String? {
        guard launchdCommands.contains(command) else { return nil }
        let id = UUID().uuidString
        let label = "com.sevagbardakjian.snap.list.\(id)"
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("snap-list-\(id).txt").path
        let script = #"label="$1"; out="$2"; shift 2; "$@" > "$out.tmp" 2>&1; /bin/mv "$out.tmp" "$out"; exec /bin/launchctl remove "$label""#
        defer {
            try? FileManager.default.removeItem(atPath: out)
            try? FileManager.default.removeItem(atPath: out + ".tmp")
        }
        _ = await Shell.run("/bin/launchctl",
                            args: ["submit", "-l", label, "--", "/bin/sh", "-c", script, "sh", label, out, command] + args,
                            timeout: 5)
        // The file appears (by rename) only once the command has finished
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: out) { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        // Normally already gone (the job removes itself); harmless if so
        _ = await Shell.run("/bin/launchctl", args: ["remove", label], timeout: 5)
        return try? String(contentsOfFile: out, encoding: .utf8)
    }
}
