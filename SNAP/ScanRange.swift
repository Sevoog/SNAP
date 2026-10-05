// ScanRange.swift
// SNAP — IPv4 scan targets: CIDR, custom ranges, and the /24 shorthand
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian. All rights reserved.
//
// Shared by the Network Map and Bulk Discovery so both accept the same
// forms and agree on host counts. Before v1.5.3 the Network Map only ever
// scanned one /24 per entry — typing "10.0.0.0/16" was silently cut to
// 10.0.0.1–254 — and its prefill ignored the real subnet mask.

import Foundation
import Darwin

/// Parsed scan targets. Entries are comma- or newline-separated:
///
///     192.168.1               → 192.168.1.1–254 (classic /24 shorthand)
///     192.168.1.x  / .*       → same
///     10.0.0.0/16             → every usable host in the CIDR, any length
///     10.0.0.50-10.0.3.200    → inclusive range (– and — work too)
///     192.168.1.100-150       → last-octet shorthand
///     192.168.1.20            → that one host
struct ScanRange: Equatable {

    /// Inclusive address span, as host-order integers.
    struct Span: Equatable {
        let first: UInt32
        let last: UInt32
    }

    enum ParseError: Error, Equatable {
        case empty
        case invalid(entry: String)
        case tooLarge(count: Int, max: Int)

        var message: String {
            switch self {
            case .empty:
                return "Enter a range to scan."
            case .invalid(let entry):
                return "Couldn't read “\(entry)”. Try 192.168.1.0/24, 10.0.0.1-10.0.3.254, or 192.168.1."
            case .tooLarge(let count, let max):
                return "\(count.formatted()) addresses is more than this tool scans at once (max \(max.formatted())). Narrow the range."
            }
        }
    }

    /// Spans in the order typed (may overlap).
    let spans: [Span]
    /// Distinct addresses across all spans.
    let hostCount: Int

    // MARK: Parsing

    static func parse(_ raw: String, maxHosts: Int) -> Result<ScanRange, ParseError> {
        let entries = raw
            .split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !entries.isEmpty else { return .failure(.empty) }

        var spans: [Span] = []
        for entry in entries {
            guard let span = parseEntry(entry) else { return .failure(.invalid(entry: entry)) }
            spans.append(span)
        }
        // Count before anything is enumerated, so a /0 can't hang the UI.
        let count = distinctCount(spans)
        guard count <= maxHosts else { return .failure(.tooLarge(count: count, max: maxHosts)) }
        return .success(ScanRange(spans: spans, hostCount: count))
    }

    private static func parseEntry(_ rawEntry: String) -> Span? {
        var entry = rawEntry
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: " ", with: "")
        if entry.hasSuffix(".") { entry.removeLast() }

        // CIDR — 10.0.0.0/16 (host bits are ignored: 192.168.1.50/24 = the /24)
        if let slash = entry.firstIndex(of: "/") {
            guard let len = Int(entry[entry.index(after: slash)...]), (0...32).contains(len),
                  let ip = address(String(entry[..<slash])) else { return nil }
            let mask: UInt32 = len == 0 ? 0 : UInt32.max << (32 - UInt32(len))
            let network = ip & mask
            let broadcast = network | ~mask
            // /31 and /32 have no network/broadcast to skip (RFC 3021).
            return len >= 31 ? Span(first: network, last: broadcast)
                             : Span(first: network + 1, last: broadcast - 1)
        }

        // Range — 10.0.0.50-10.0.3.200 or 192.168.1.100-150
        if let dash = entry.firstIndex(of: "-") {
            guard let start = address(String(entry[..<dash])) else { return nil }
            let rhs = String(entry[entry.index(after: dash)...])
            let end: UInt32
            if let full = address(rhs) {
                end = full
            } else if let last = UInt8(rhs) {
                end = (start & 0xFFFF_FF00) | UInt32(last)
            } else {
                return nil
            }
            guard start <= end else { return nil }
            return Span(first: start, last: end)
        }

        // 192.168.1 / 192.168.1.x / 192.168.1.* → .1–.254
        let parts = entry.split(separator: ".", omittingEmptySubsequences: false)
        let isShorthand = parts.count == 3
            || (parts.count == 4 && (parts[3] == "x" || parts[3] == "X" || parts[3] == "*"))
        if isShorthand {
            guard let base = address(parts.prefix(3).joined(separator: ".") + ".0") else { return nil }
            return Span(first: base + 1, last: base + 254)
        }

        // Single host
        guard let ip = address(entry) else { return nil }
        return Span(first: ip, last: ip)
    }

    /// Dotted-quad → host-order integer. Exactly four decimal octets.
    static func address(_ s: String) -> UInt32? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for p in parts {
            guard !p.isEmpty, p.allSatisfy(\.isASCII), p.allSatisfy(\.isNumber),
                  let octet = UInt8(p) else { return nil }
            value = (value << 8) | UInt32(octet)
        }
        return value
    }

    static func string(_ ip: UInt32) -> String {
        "\((ip >> 24) & 0xFF).\((ip >> 16) & 0xFF).\((ip >> 8) & 0xFF).\(ip & 0xFF)"
    }

    /// Distinct addresses across possibly-overlapping spans, without
    /// enumerating them.
    private static func distinctCount(_ spans: [Span]) -> Int {
        let sorted = spans.sorted { $0.first < $1.first }
        var total: UInt64 = 0
        var curFirst: UInt64?, curLast: UInt64 = 0
        for s in sorted {
            let f = UInt64(s.first), l = UInt64(s.last)
            if let cf = curFirst, f <= curLast + 1 {
                curLast = max(curLast, l)
                curFirst = cf
            } else {
                if let cf = curFirst { total += curLast - cf + 1 }
                curFirst = f
                curLast = l
            }
        }
        if let cf = curFirst { total += curLast - cf + 1 }
        return Int(total)
    }

    // MARK: Expansion

    /// Every distinct address, in the order typed.
    func addresses() -> [String] {
        var seen = Set<UInt32>()
        seen.reserveCapacity(hostCount)
        var out: [String] = []
        out.reserveCapacity(hostCount)
        for span in spans {
            var ip = span.first
            while true {
                if seen.insert(ip).inserted { out.append(Self.string(ip)) }
                if ip == span.last { break }
                ip += 1
            }
        }
        return out
    }

    // MARK: Local network

    /// "10.0.0.0/16" for an address and netmask. Networks larger than
    /// `widestPrefix` are narrowed to the slice containing `ip`, since
    /// that's the most a scan tool handles at once.
    static func networkCIDR(ip: UInt32, mask: UInt32, widestPrefix: Int = 16) -> String {
        let len = max(mask.nonzeroBitCount, widestPrefix)
        let m: UInt32 = len == 0 ? 0 : UInt32.max << (32 - UInt32(len))
        return "\(string(ip & m))/\(len)"
    }

    /// The Mac's own LAN: the Ethernet/Wi-Fi interface carrying the default
    /// route (else the first one with an address), with its real netmask.
    /// `slash24` is the /24 around this Mac — a quick alternative to a big
    /// network.
    static func localNetwork() -> (cidr: String, slash24: String)? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }

        var candidates: [(name: String, ip: UInt32, mask: UInt32)] = []
        var cur = ifaddr
        while let c = cur {
            defer { cur = c.pointee.ifa_next }
            let name = String(cString: c.pointee.ifa_name)
            guard name.hasPrefix("en"),
                  Int32(c.pointee.ifa_flags) & IFF_UP != 0,
                  let sa = c.pointee.ifa_addr, Int32(sa.pointee.sa_family) == AF_INET,
                  let nm = c.pointee.ifa_netmask else { continue }
            let ip = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            let mask = nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            // Skip 127/8 and 169.254/16 (link-local).
            if ip >> 24 == 127 || ip >> 16 == 0xA9FE { continue }
            candidates.append((name, ip, mask))
        }
        let primary = RouteInfo.defaultInterface()
        guard let pick = candidates.first(where: { $0.name == primary }) ?? candidates.first else {
            return nil
        }
        return (networkCIDR(ip: pick.ip, mask: pick.mask),
                networkCIDR(ip: pick.ip, mask: 0xFFFF_FF00, widestPrefix: 24))
    }
}
