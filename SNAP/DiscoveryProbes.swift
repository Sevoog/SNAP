// DiscoveryProbes.swift
// SNAP — Network discovery probes (NetBIOS / SSDP / UBNT family / mDNS)
// Created by Sevag Bardakjian
// Copyright © 2025 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md
//
// Extracted from DeviceIdentifier.swift in v1.5.1 as part of the god-file split.
// Contains the LAN-sweep probes — each returns IdentitySignal values that the
// DeviceIdentifier orchestrator merges into per-IP results.

import Foundation
import Network
import Darwin

// MARK: - NetBIOS Node Status (UDP/137)

enum NetBIOSProbe {
    /// Sends an NBT Node Status query and parses the names returned.
    /// Honors Windows naming convention: NAME<00> = workstation, NAME<20> = server.
    static func probe(ip: String, timeout: TimeInterval) async -> IdentitySignal? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: send(ip: ip, timeout: timeout))
            }
        }
    }

    private static func send(ip: String, timeout: TimeInterval) -> IdentitySignal? {
        let txID = UInt16.random(in: 0...UInt16.max)
        let pkt = buildQuery(txID: txID)

        let sock = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { return nil }
        defer { Darwin.close(sock) }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(137).bigEndian
        addr.sin_addr.s_addr = inet_addr(ip)
        guard addr.sin_addr.s_addr != INADDR_NONE else { return nil }

        let sent: ssize_t = pkt.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                    sendto(sock, raw.baseAddress, pkt.count, 0, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == pkt.count else { return nil }

        var buf = [UInt8](repeating: 0, count: 1500)
        var from = sockaddr_in()
        var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n: ssize_t = buf.withUnsafeMutableBufferPointer { bp in
            withUnsafeMutablePointer(to: &from) { fp in
                fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                    recvfrom(sock, bp.baseAddress, bp.count, 0, sp, &fromLen)
                }
            }
        }
        guard n > 12 else { return nil }
        let data = Data(buf.prefix(Int(n)))
        return parseResponse(data, expectingTxID: txID)
    }

    /// 50-byte NBSTAT query for `*` (wildcard) — the only name format that
    /// returns the full NB name list from a remote host.
    private static func buildQuery(txID: UInt16) -> Data {
        var d = Data()
        d.append(UInt8(txID >> 8)); d.append(UInt8(txID & 0xFF))
        d.append(0x00); d.append(0x00)   // flags
        d.append(0x00); d.append(0x01)   // QDCOUNT
        d.append(0x00); d.append(0x00)   // ANCOUNT
        d.append(0x00); d.append(0x00)   // NSCOUNT
        d.append(0x00); d.append(0x00)   // ARCOUNT
        // Encoded name: 0x20 length byte, then "CKAA…AA" — '*<00>...' encoded
        d.append(0x20)
        let star: [UInt8] = [
            0x43, 0x4B, // C K   (= '*' encoded)
            0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41,
            0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41,
            0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41,
            0x41, 0x41, 0x41, 0x41, 0x41, 0x41
        ]
        d.append(contentsOf: star)
        d.append(0x00) // root
        // QTYPE = NBSTAT (0x21), QCLASS = IN (0x01)
        d.append(0x00); d.append(0x21)
        d.append(0x00); d.append(0x01)
        return d
    }

    private static func parseResponse(_ data: Data, expectingTxID: UInt16) -> IdentitySignal? {
        let id = (UInt16(data[0]) << 8) | UInt16(data[1])
        guard id == expectingTxID else { return nil }
        // Skip header (12) + encoded query name (1 + 32 + 1) + qtype (2) + qclass (2)
        // + answer name (34) + answer type/class/ttl (8) + rdlength (2) → 12+34+4+34+8+2 = 94
        // After that: 1 byte name_count, then 18 bytes per name.
        let nameCountOffset = 56 // 12 + 34 + 2 + 2 + ... see RFC 1002 §4.2.18
        guard data.count > nameCountOffset + 1 else { return nil }

        // The exact offset to the name_count byte depends on the response form;
        // search for the "name_count" by scanning past the first answer-record
        // headers. The reliable scheme is to skip header(12), skip the question
        // (34 = 1+32+1 name bytes + 4 qtype/qclass), then skip the answer's
        // compressed name (typically 0xC00C → 2 bytes), then 8 bytes
        // (type+class+TTL), then 2 bytes rdlength → name_count is next.
        var idx = 12
        idx += 34 // question section
        // Answer name: either 0xC0XX compressed pointer (2 bytes) or full 34-byte name.
        if idx < data.count, data[idx] & 0xC0 == 0xC0 { idx += 2 }
        else { idx += 34 }
        guard idx + 10 <= data.count else { return nil }
        idx += 10 // type(2) + class(2) + TTL(4) + rdlength(2)
        guard idx + 1 <= data.count else { return nil }
        let nameCount = Int(data[idx]); idx += 1

        var workstation: String?
        var server: String?
        for _ in 0..<nameCount {
            guard idx + 18 <= data.count else { break }
            let nameBytes = data[idx..<idx + 15]
            let suffix = data[idx + 15]
            let flags = (UInt16(data[idx + 16]) << 8) | UInt16(data[idx + 17])
            idx += 18

            // Skip group names (bit 15 of flags is the GROUP bit)
            if flags & 0x8000 != 0 { continue }

            var name = String(decoding: nameBytes, as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            // Some old Windows machines pad with spaces — drop trailing.
            while name.hasSuffix(" ") { name.removeLast() }
            if name.isEmpty { continue }

            // Suffix 0x00 → workstation, 0x20 → file server
            if suffix == 0x00, workstation == nil { workstation = name }
            if suffix == 0x20, server == nil       { server = name }
        }

        if let s = server      { return .netbios(name: s, isServer: true) }
        if let w = workstation { return .netbios(name: w, isServer: false) }
        return nil
    }
}

// MARK: - SSDP Collector

enum SSDPCollector {
    /// Sends an SSDP M-SEARCH multicast to 239.255.255.250:1900 and collects
    /// responses for `timeout` seconds. Returns IP → SSDP signal.
    static func collect(timeout: TimeInterval) async -> [String: [IdentitySignal]] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: run(timeout: timeout))
            }
        }
    }

    private static func run(timeout: TimeInterval) -> [String: [IdentitySignal]] {
        let sock = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { return [:] }
        defer { Darwin.close(sock) }

        // SO_REUSEADDR + nonblocking-ish via SO_RCVTIMEO
        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        // Receive timeout: we poll repeatedly with this per-recv timeout up to
        // the wall-clock total.
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Bind to any port so we receive responses
        var localAddr = sockaddr_in()
        localAddr.sin_family = sa_family_t(AF_INET)
        localAddr.sin_addr.s_addr = in_addr_t(INADDR_ANY).bigEndian
        localAddr.sin_port = 0
        _ = withUnsafePointer(to: &localAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                Darwin.bind(sock, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        // Send the M-SEARCH
        let msearch = """
        M-SEARCH * HTTP/1.1\r
        HOST: 239.255.255.250:1900\r
        MAN: "ssdp:discover"\r
        MX: 2\r
        ST: ssdp:all\r
        USER-AGENT: SNAP/1.2 macOS UPnP/1.1\r
        \r

        """.data(using: .utf8) ?? Data()

        var dstAddr = sockaddr_in()
        dstAddr.sin_family = sa_family_t(AF_INET)
        dstAddr.sin_port = UInt16(1900).bigEndian
        dstAddr.sin_addr.s_addr = inet_addr("239.255.255.250")

        _ = msearch.withUnsafeBytes { raw in
            withUnsafePointer(to: &dstAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                    sendto(sock, raw.baseAddress, msearch.count, 0, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        // Receive loop
        var results: [String: [IdentitySignal]] = [:]
        let deadline = Date().addingTimeInterval(timeout)
        var buf = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n: ssize_t = buf.withUnsafeMutableBufferPointer { bp in
                withUnsafeMutablePointer(to: &from) { fp in
                    fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                        recvfrom(sock, bp.baseAddress, bp.count, 0, sp, &fromLen)
                    }
                }
            }
            if n <= 0 { continue }

            var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &from.sin_addr, &ipBuf, socklen_t(INET_ADDRSTRLEN))
            let ip = String(cString: ipBuf)

            guard let text = String(data: Data(buf.prefix(Int(n))), encoding: .utf8) else { continue }
            let signal = parseResponse(text)
            if results[ip] == nil { results[ip] = [] }
            // Dedup: only add if SERVER string is new
            if !results[ip]!.contains(signal) {
                results[ip]!.append(signal)
            }
        }
        return results
    }

    private static func parseResponse(_ text: String) -> IdentitySignal {
        var server: String?
        var location: String?
        var model: String?
        for line in text.split(separator: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("server:") {
                server = String(line.dropFirst("server:".count)).trimmingCharacters(in: .whitespaces)
            } else if lower.hasPrefix("location:") {
                location = String(line.dropFirst("location:".count)).trimmingCharacters(in: .whitespaces)
            } else if lower.hasPrefix("x-model-name:") {
                model = String(line.dropFirst("x-model-name:".count)).trimmingCharacters(in: .whitespaces)
            } else if lower.hasPrefix("usn:") {
                // USN often contains friendly model id between "::" and end
                let usn = String(line.dropFirst("usn:".count))
                if let r = usn.range(of: "::") {
                    let tail = String(usn[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if !tail.isEmpty && model == nil { model = tail }
                }
            }
        }
        return .ssdp(server: server, model: model, location: location)
    }
}

// MARK: - UBNT Discovery (UDP/10001)
//
// Ubiquiti / UniFi gear answers a 4-byte broadcast probe on UDP port 10001
// with a TLV-encoded payload containing its exact MAC, IP, hostname, model,
// and firmware. This is the most reliable way to identify UniFi gear short
// of querying the controller. v1 and v2 protocols use the same TLV layout —
// we send both query forms and parse anything that responds.
//
// References:
//   • https://github.com/markdj/ubnt-tools-mdns
//   • Ubiquiti's own discovery tool (dscv binary)
// TLV types we care about (others ignored):
//   0x03 → firmware version string
//   0x0B → hostname
//   0x0C → platform / model name (e.g. "UAP-AC-Pro", "UDM-Pro")
//   0x14 → model code v2 (newer hardware)

enum UBNTDiscoveryProbe {
    static func collect(timeout: TimeInterval = 2.5) async -> [String: [IdentitySignal]] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: run(timeout: timeout))
            }
        }
    }

    private static func run(timeout: TimeInterval) -> [String: [IdentitySignal]] {
        let sock = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { return [:] }
        defer { Darwin.close(sock) }

        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        // 1-second per-recv timeout so we can loop until wall-clock deadline.
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Bind ephemeral so the kernel routes the response back to us.
        var local = sockaddr_in()
        local.sin_family = sa_family_t(AF_INET)
        local.sin_addr.s_addr = in_addr_t(0)  // INADDR_ANY
        local.sin_port = 0
        _ = withUnsafePointer(to: &local) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                Darwin.bind(sock, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        let queries = UBNTWire.queries

        // Send to limited broadcast 255.255.255.255 AND every directly-
        // attached subnet broadcast. macOS doesn't always route the limited
        // broadcast through every interface, and UniFi gear on a VLAN'd or
        // multi-interface host often won't see 255.255.255.255 traffic.
        var destinations: [String] = ["255.255.255.255"]
        destinations.append(contentsOf: subnetBroadcasts())

        for dstIP in destinations {
            var dst = sockaddr_in()
            dst.sin_family = sa_family_t(AF_INET)
            dst.sin_port = UInt16(10001).bigEndian
            dst.sin_addr.s_addr = inet_addr(dstIP)
            for query in queries {
                _ = query.withUnsafeBytes { raw in
                    withUnsafePointer(to: &dst) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                            sendto(sock, raw.baseAddress, query.count, 0, sp,
                                   socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }
        }

        // Receive loop
        var results: [String: [IdentitySignal]] = [:]
        let deadline = Date().addingTimeInterval(timeout)
        var buf = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n: ssize_t = buf.withUnsafeMutableBufferPointer { bp in
                withUnsafeMutablePointer(to: &from) { fp in
                    fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                        recvfrom(sock, bp.baseAddress, bp.count, 0, sp, &fromLen)
                    }
                }
            }
            if n <= 4 { continue }

            var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &from.sin_addr, &ipBuf, socklen_t(INET_ADDRSTRLEN))
            let ip = String(cString: ipBuf)

            let data = Data(buf.prefix(Int(n)))
            guard let signal = parse(data) else { continue }
            // Dedup — UniFi devices respond to multiple queries and multiple
            // destinations; collapse duplicates of the exact same signal.
            if results[ip]?.contains(signal) != true {
                results[ip, default: []].append(signal)
            }
        }
        return results
    }

    /// Returns the broadcast address of every non-loopback IPv4 interface
    /// that has an IFF_BROADCAST flag set. On a typical Mac with one Wi-Fi
    /// interface, this returns one address (e.g. 192.168.1.255).
    private static func subnetBroadcasts() -> [String] {
        var out: Set<String> = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return [] }
        defer { freeifaddrs(ifaddr) }
        var cur = ifaddr
        while let c = cur {
            defer { cur = c.pointee.ifa_next }
            let flags = Int32(c.pointee.ifa_flags)
            guard (flags & IFF_LOOPBACK) == 0,
                  (flags & IFF_UP) != 0,
                  (flags & IFF_BROADCAST) != 0 else { continue }
            // ifa_addr can be NULL for some pseudo-interfaces
            guard let sa = c.pointee.ifa_addr,
                  Int32(sa.pointee.sa_family) == AF_INET else { continue }
            guard let bcastPtr = c.pointee.ifa_dstaddr else { continue }
            var bsin = bcastPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &bsin.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
            let ip = String(cString: buf)
            if ip != "0.0.0.0" && ip != "127.0.0.1" {
                out.insert(ip)
            }
        }
        return Array(out)
    }

    static func parse(_ data: Data) -> IdentitySignal? {
        return UBNTWire.parse(data)
    }
}

// MARK: - UBNT wire parser (shared by broadcast + unicast probes)

enum UBNTWire {
    /// Three known request forms. Different UniFi firmware vintages respond
    /// to different ones, so we always send all three.
    static let queries: [[UInt8]] = [
        [0x01, 0x00, 0x00, 0x00],   // v1 / AirOS
        [0x02, 0x06, 0x00, 0x00],   // UniFi OS opcode 6
        [0x02, 0x08, 0x00, 0x00],   // alternate v2 form
    ]

    static func parse(_ data: Data) -> IdentitySignal? {
        // Accept any plausible Ubiquiti discovery response: byte 0 must be
        // 0x01 (v1) or 0x02 (v2). Firmware revs differ in byte 1, and we'd
        // rather see a stray signal than silently drop a real UniFi reply.
        guard data.count >= 4 else { return nil }
        let v0 = data[0]
        guard v0 == 0x01 || v0 == 0x02 else { return nil }

        let payloadLen = Int(data[2]) << 8 | Int(data[3])
        let payloadEnd = min(4 + payloadLen, data.count)
        guard payloadEnd > 4 else { return nil }
        let payload = data.subdata(in: 4..<payloadEnd)

        var hostname: String?
        var model: String?
        var firmware: String?

        var idx = 0
        while idx + 3 <= payload.count {
            let type = payload[idx]
            let len = Int(payload[idx + 1]) << 8 | Int(payload[idx + 2])
            idx += 3
            guard idx + len <= payload.count else { break }
            let value = payload.subdata(in: idx..<idx + len)
            idx += len

            switch type {
            case 0x0B:
                if hostname == nil, let s = utf8(value) { hostname = s }
            case 0x0C, 0x14:
                // Prefer the longer / more specific of the two model fields.
                if let s = utf8(value) {
                    if model == nil || s.count > (model?.count ?? 0) { model = s }
                }
            case 0x03, 0x16:
                if firmware == nil, let s = utf8(value) { firmware = s }
            default:
                break
            }
        }

        if hostname == nil && model == nil && firmware == nil { return nil }
        return .ubnt(model: model, firmware: firmware, hostname: hostname)
    }

    private static func utf8(_ data: Data) -> String? {
        guard let s = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - UBNT Unicast Probe
//
// Sends UBNT discovery to a specific IP (no broadcast). Useful when:
//   • The Mac is on a different VLAN/subnet than the UniFi gear (unicast
//     routes through the gateway; broadcast doesn't cross VLANs)
//   • macOS doesn't reliably deliver 255.255.255.255 traffic
//   • UniFi devices filter ICMP but answer UBNT on UDP/10001
//
// Used in two places: (a) per-IP sweep alongside ping, and (b) per-device
// probe in stage 2 for devices discovered by other means.

enum UBNTUnicastProbe {
    static func probe(ip: String, timeout: TimeInterval = 1.5) async -> IdentitySignal? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: run(ip: ip, timeout: timeout))
            }
        }
    }

    private static func run(ip: String, timeout: TimeInterval) -> IdentitySignal? {
        let sock = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { return nil }
        defer { Darwin.close(sock) }

        // Whole-call timeout split: each recv waits up to ~0.5s; we loop
        // until the wall-clock deadline.
        var tv = timeval(tv_sec: 0, tv_usec: 500_000)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var dst = sockaddr_in()
        dst.sin_family = sa_family_t(AF_INET)
        dst.sin_port = UInt16(10001).bigEndian
        dst.sin_addr.s_addr = inet_addr(ip)
        guard dst.sin_addr.s_addr != INADDR_NONE else { return nil }

        for q in UBNTWire.queries {
            _ = q.withUnsafeBytes { raw in
                withUnsafePointer(to: &dst) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                        sendto(sock, raw.baseAddress, q.count, 0, sp,
                               socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }

        var buf = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n: ssize_t = buf.withUnsafeMutableBufferPointer { bp in
                withUnsafeMutablePointer(to: &from) { fp in
                    fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                        recvfrom(sock, bp.baseAddress, bp.count, 0, sp, &fromLen)
                    }
                }
            }
            if n <= 4 { continue }
            // Verify the response came from the IP we probed (we're using one
            // socket per IP, but better safe than sorry).
            var srcBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &from.sin_addr, &srcBuf, socklen_t(INET_ADDRSTRLEN))
            let src = String(cString: srcBuf)
            guard src == ip else { continue }

            let data = Data(buf.prefix(Int(n)))
            if let sig = UBNTWire.parse(data) { return sig }
        }
        return nil
    }
}

// MARK: - mDNS Collector
//
// NetServiceBrowser is a Cocoa-style delegate API rooted in a run loop.
// We start every browser on the main run loop, let the delegate callbacks
// fire on main, then after `timeout` seconds stop them and resume the
// caller's continuation with what we collected.

final class MDNSCollector: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private static let serviceTypes: [String] = [
        "_companion-link._tcp.",
        "_airplay._tcp.",
        "_raop._tcp.",
        "_googlecast._tcp.",
        "_hap._tcp.",
        "_ipp._tcp.",
        "_ipps._tcp.",
        "_printer._tcp.",
        "_pdl-datastream._tcp.",
        "_sonos._tcp.",
        "_spotify-connect._tcp.",
        "_smb._tcp.",
        "_afpovertcp._tcp.",
        "_ssh._tcp.",
        "_workstation._tcp.",
        "_androidtvremote2._tcp.",
        "_amzn-wplay._tcp.",
        // v1.2.2: broader catch-net so previously-silent devices register
        "_unifi._tcp.",            // UniFi controller / device advertisement
        "_unifi-protect._tcp.",    // UniFi Protect cameras / NVR
        "_http._tcp.",             // many IoT / NAS / printers expose this
        "_https._tcp.",            // ditto for TLS-only admin UIs
        "_device-info._tcp.",      // Apple-specific device info hints
    ]

    /// Browses every service type for `timeout` seconds and returns per-IP
    /// mDNS signals (one per resolved service). The signal carries the
    /// service type, model+friendly-name parsed from TXT, and the resolved
    /// hostname so the merge layer can identify and label the device.
    static func collect(timeout: TimeInterval) async -> [String: [IdentitySignal]] {
        await withCheckedContinuation { cont in
            DispatchQueue.main.async {
                let collector = MDNSCollector()
                collector.continuation = cont
                for svc in serviceTypes { collector.startBrowser(type: svc) }
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                    collector.finish()
                }
            }
        }
    }

    private var browsers: [NetServiceBrowser] = []
    private var resolving: [NetService] = []
    private var results: [String: [IdentitySignal]] = [:]
    private var seenKinds: Set<String> = []
    private var continuation: CheckedContinuation<[String: [IdentitySignal]], Never>?

    private func startBrowser(type: String) {
        let b = NetServiceBrowser()
        b.delegate = self
        b.searchForServices(ofType: type, inDomain: "local.")
        browsers.append(b)
    }

    private func finish() {
        for b in browsers { b.stop() }
        for s in resolving { s.stop() }
        browsers = []
        resolving = []
        if let cont = continuation {
            continuation = nil
            cont.resume(returning: results)
        }
    }

    // MARK: - NetServiceBrowserDelegate

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didFind service: NetService,
                           moreComing: Bool) {
        service.delegate = self
        service.startMonitoring()
        service.resolve(withTimeout: 4.0)
        resolving.append(service)
    }

    // MARK: - NetServiceDelegate

    func netServiceDidResolveAddress(_ sender: NetService) {
        collectResolved(sender)
    }

    func netService(_ sender: NetService, didUpdateTXTRecord data: Data) {
        collectResolved(sender)
    }

    private func collectResolved(_ service: NetService) {
        guard let addrs = service.addresses else { return }
        let ips = addrs.compactMap(ipString(from:))
        guard !ips.isEmpty else { return }

        let txtData = service.txtRecordData() ?? Data()
        let txt = NetService.dictionary(fromTXTRecord: txtData)
        let (model, friendly) = parseTXT(serviceType: service.type, txt: txt)
        let signal = IdentitySignal.mDNS(service: stripTrailingDot(service.type),
                                         model: model,
                                         friendly: friendly,
                                         hostname: service.hostName)

        for ip in ips {
            let kind = "\(ip)|\(service.type)"
            if seenKinds.contains(kind) { continue }
            seenKinds.insert(kind)
            results[ip, default: []].append(signal)
        }
    }

    private func ipString(from data: Data) -> String? {
        return data.withUnsafeBytes { raw -> String? in
            guard let base = raw.baseAddress else { return nil }
            let family = base.assumingMemoryBound(to: sockaddr.self).pointee.sa_family
            if family == sa_family_t(AF_INET) {
                let sin = base.assumingMemoryBound(to: sockaddr_in.self).pointee
                var addr = sin.sin_addr
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
                return String(cString: buf)
            }
            // We don't return IPv6 here — the LAN map is IPv4-keyed.
            return nil
        }
    }

    private func parseTXT(serviceType: String,
                          txt: [String: Data]) -> (model: String?, friendly: String?) {
        func str(_ key: String) -> String? {
            guard let d = txt[key], let s = String(data: d, encoding: .utf8) else { return nil }
            return s.isEmpty ? nil : s
        }
        switch serviceType {
        case "_googlecast._tcp.":   return (model: str("md"), friendly: str("fn"))
        case "_airplay._tcp.":      return (model: str("model"), friendly: str("deviceid"))
        case "_raop._tcp.":         return (model: str("am"), friendly: str("cn"))
        case "_hap._tcp.":          return (model: str("md"), friendly: str("ci"))
        case "_companion-link._tcp.":
            return (model: str("rpMd") ?? str("rpHN") ?? str("rpMRtID"), friendly: str("rpHN"))
        case "_sonos._tcp.":        return (model: str("mdl"), friendly: str("rincon"))
        case "_ipp._tcp.", "_ipps._tcp.":
            return (model: str("ty") ?? str("usb_MDL"), friendly: str("note"))
        case "_workstation._tcp.": return (model: nil, friendly: nil)
        default:
            return (model: str("md") ?? str("model") ?? str("ty"),
                    friendly: str("fn") ?? str("nm") ?? str("name"))
        }
    }

    private func stripTrailingDot(_ s: String) -> String {
        s.hasSuffix(".") ? String(s.dropLast()) : s
    }
}
