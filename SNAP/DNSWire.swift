// DNSWire.swift
// SNAP — Minimal DNS-over-UDP query/parse used by DNS Propagation + Benchmark
// Created by Sevag Bardakjian
// Copyright © 2025 Sevag Bardakjian. All rights reserved.

import Foundation
import Darwin

// MARK: - Public types

enum DNSWireType: UInt16 {
    case a     = 1
    case ns    = 2
    case cname = 5
    case soa   = 6
    case ptr   = 12
    case mx    = 15
    case txt   = 16
    case aaaa  = 28
    case srv   = 33
    case caa   = 257

    var label: String {
        switch self {
        case .a:     return "A"
        case .ns:    return "NS"
        case .cname: return "CNAME"
        case .soa:   return "SOA"
        case .ptr:   return "PTR"
        case .mx:    return "MX"
        case .txt:   return "TXT"
        case .aaaa:  return "AAAA"
        case .srv:   return "SRV"
        case .caa:   return "CAA"
        }
    }
}

struct DNSAnswer: Hashable {
    let type: String
    let value: String
    let ttl: UInt32
}

enum DNSWireError: Error, LocalizedError {
    case socketFailed
    case sendFailed
    case timeout
    case truncated
    case malformed
    case invalidName
    case rcode(Int)

    var errorDescription: String? {
        switch self {
        case .socketFailed:   return "Socket open failed"
        case .sendFailed:     return "Send failed"
        case .timeout:        return "Timed out"
        case .truncated:      return "Response truncated"
        case .malformed:      return "Malformed response"
        case .invalidName:    return "Invalid hostname — labels must be 1–63 bytes"
        case .rcode(let c):
            switch c {
            case 1: return "Format error (FORMERR)"
            case 2: return "Server failure (SERVFAIL)"
            case 3: return "NXDOMAIN — name does not exist"
            case 4: return "Not implemented (NOTIMP)"
            case 5: return "Refused (REFUSED)"
            default: return "RCODE \(c)"
            }
        }
    }
}

struct DNSResult {
    let answers: [DNSAnswer]
    let rcode: Int
    let elapsedMs: Double
    let responderIP: String
}

// MARK: - Querier

enum DNSWire {
    /// Send a UDP/53 DNS query to `server` for `name` of `type`.
    /// Returns parsed answers + elapsed time. Blocking; call from a background Task.
    static func query(server: String,
                      name: String,
                      type: DNSWireType,
                      timeout: TimeInterval = 3.0) throws -> DNSResult {

        let txID = UInt16.random(in: 0...UInt16.max)
        let packet = try buildQuery(txID: txID, name: name, type: type)

        let sock = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { throw DNSWireError.socketFailed }
        defer { Darwin.close(sock) }

        // SO_RCVTIMEO
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(53).bigEndian
        addr.sin_addr.s_addr = inet_addr(server)
        guard addr.sin_addr.s_addr != INADDR_NONE else { throw DNSWireError.sendFailed }

        let t0 = Date()
        let sent: ssize_t = packet.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    sendto(sock, raw.baseAddress, packet.count, 0, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == packet.count else { throw DNSWireError.sendFailed }

        var buf = [UInt8](repeating: 0, count: 4096)
        var from = sockaddr_in()
        var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)

        let n: ssize_t = buf.withUnsafeMutableBufferPointer { bp in
            withUnsafeMutablePointer(to: &from) { fp in
                fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                    recvfrom(sock, bp.baseAddress, bp.count, 0, sp, &fromLen)
                }
            }
        }
        let elapsed = Date().timeIntervalSince(t0) * 1000
        guard n > 0 else { throw DNSWireError.timeout }

        let data = Data(buf.prefix(Int(n)))
        let parsed = try parse(data, expectingTxID: txID)
        return DNSResult(answers: parsed.answers,
                         rcode: parsed.rcode,
                         elapsedMs: elapsed,
                         responderIP: server)
    }

    // MARK: - Build

    private static func buildQuery(txID: UInt16, name: String, type: DNSWireType) throws -> Data {
        var d = Data()
        // Header: ID, flags=0x0100 (RD), QDCOUNT=1
        d.append(UInt8(txID >> 8))
        d.append(UInt8(txID & 0xFF))
        d.append(0x01); d.append(0x00)        // flags: standard query + RD
        d.append(0x00); d.append(0x01)        // QDCOUNT = 1
        d.append(0x00); d.append(0x00)        // ANCOUNT
        d.append(0x00); d.append(0x00)        // NSCOUNT
        d.append(0x00); d.append(0x00)        // ARCOUNT

        // QNAME — labels (RFC 1035: max 63 bytes each; 64+ would set the
        // compression-pointer bits, and 256+ traps the UInt8 conversion)
        for label in name.split(separator: ".") {
            let bytes = Array(label.utf8)
            guard (1...63).contains(bytes.count) else { throw DNSWireError.invalidName }
            d.append(UInt8(bytes.count))
            d.append(contentsOf: bytes)
        }
        d.append(0x00) // root

        // QTYPE / QCLASS
        let t = type.rawValue
        d.append(UInt8(t >> 8)); d.append(UInt8(t & 0xFF))
        d.append(0x00); d.append(0x01) // IN
        return d
    }

    // MARK: - Parse

    private struct ParsedResponse {
        let answers: [DNSAnswer]
        let rcode: Int
    }

    private static func parse(_ data: Data, expectingTxID: UInt16) throws -> ParsedResponse {
        guard data.count >= 12 else { throw DNSWireError.malformed }
        let txID = (UInt16(data[0]) << 8) | UInt16(data[1])
        guard txID == expectingTxID else { throw DNSWireError.malformed }

        let flags = (UInt16(data[2]) << 8) | UInt16(data[3])
        let rcode = Int(flags & 0x000F)
        let qd    = Int((UInt16(data[4]) << 8) | UInt16(data[5]))
        let an    = Int((UInt16(data[6]) << 8) | UInt16(data[7]))

        var idx = 12

        // Skip question section
        for _ in 0..<qd {
            _ = try readName(in: data, at: &idx)
            guard idx + 4 <= data.count else { throw DNSWireError.malformed }
            idx += 4 // qtype + qclass
        }

        if rcode != 0 {
            // Surface common non-zero rcodes as a structured error
            if rcode == 3 || rcode == 2 || rcode == 1 || rcode == 4 || rcode == 5 {
                throw DNSWireError.rcode(rcode)
            }
        }

        var answers: [DNSAnswer] = []
        for _ in 0..<an {
            _ = try readName(in: data, at: &idx)
            guard idx + 10 <= data.count else { throw DNSWireError.malformed }
            let t   = (UInt16(data[idx]) << 8) | UInt16(data[idx + 1])
            // skip class (2)
            let ttl = (UInt32(data[idx + 4]) << 24) | (UInt32(data[idx + 5]) << 16) |
                      (UInt32(data[idx + 6]) << 8)  |  UInt32(data[idx + 7])
            let rdlen = Int((UInt16(data[idx + 8]) << 8) | UInt16(data[idx + 9]))
            idx += 10
            guard idx + rdlen <= data.count else { throw DNSWireError.malformed }
            let rdata = data.subdata(in: idx..<idx + rdlen)
            let value = renderRData(type: t, rdata: rdata, packet: data, start: idx)
            idx += rdlen

            let typeName = DNSWireType(rawValue: t)?.label ?? "TYPE\(t)"
            answers.append(DNSAnswer(type: typeName, value: value, ttl: ttl))
        }
        return ParsedResponse(answers: answers, rcode: rcode)
    }

    private static func readName(in data: Data, at idx: inout Int) throws -> String {
        var labels: [String] = []
        var jumped = false
        var ptr = idx
        var safety = 0
        while ptr < data.count {
            safety += 1
            if safety > 256 { throw DNSWireError.malformed }
            let len = Int(data[ptr])
            if len == 0 {
                ptr += 1
                if !jumped { idx = ptr }
                return labels.joined(separator: ".")
            }
            if len & 0xC0 == 0xC0 {
                guard ptr + 1 < data.count else { throw DNSWireError.malformed }
                let off = Int(((UInt16(data[ptr]) & 0x3F) << 8) | UInt16(data[ptr + 1]))
                if !jumped { idx = ptr + 2 }
                jumped = true
                ptr = off
                continue
            }
            guard ptr + 1 + len <= data.count else { throw DNSWireError.malformed }
            let bytes = data.subdata(in: (ptr + 1)..<(ptr + 1 + len))
            labels.append(String(decoding: bytes, as: UTF8.self))
            ptr += 1 + len
        }
        throw DNSWireError.malformed
    }

    private static func renderRData(type: UInt16, rdata: Data, packet: Data, start: Int) -> String {
        switch DNSWireType(rawValue: type) {
        case .a:
            guard rdata.count == 4 else { return "" }
            return rdata.map { String($0) }.joined(separator: ".")
        case .aaaa:
            guard rdata.count == 16 else { return "" }
            return stride(from: 0, to: 16, by: 2).map { i in
                String(format: "%x", (UInt16(rdata[i]) << 8) | UInt16(rdata[i + 1]))
            }.joined(separator: ":")
        case .cname, .ns, .ptr:
            var i = start
            return (try? readName(in: packet, at: &i)) ?? ""
        case .mx:
            guard rdata.count >= 3 else { return "" }
            let pref = (UInt16(rdata[0]) << 8) | UInt16(rdata[1])
            var i = start + 2
            let host = (try? readName(in: packet, at: &i)) ?? ""
            return "\(pref) \(host)"
        case .txt:
            var i = 0
            var parts: [String] = []
            while i < rdata.count {
                let len = Int(rdata[i]); i += 1
                if i + len > rdata.count { break }
                parts.append(String(decoding: rdata.subdata(in: i..<i + len), as: UTF8.self))
                i += len
            }
            return parts.joined()
        default:
            return rdata.map { String(format: "%02x", $0) }.joined()
        }
    }
}

// MARK: - Curated public resolvers

struct DNSResolver: Identifiable, Hashable {
    let id: String   // ip
    let ip: String
    let name: String
    let region: String
    var location: String { "\(name) · \(region)" }
}

enum PublicResolvers {
    /// Geographically diverse public resolvers reachable on UDP/53.
    /// Anycast networks are tagged "Anycast (global)" — for SNAP's purposes,
    /// the more important axis is operator diversity, since anycast endpoints
    /// hit different POPs from different vantage points.
    static let all: [DNSResolver] = [
        DNSResolver(id: "1.1.1.1",          ip: "1.1.1.1",          name: "Cloudflare",   region: "Anycast"),
        DNSResolver(id: "1.0.0.1",          ip: "1.0.0.1",          name: "Cloudflare",   region: "Anycast (alt)"),
        DNSResolver(id: "8.8.8.8",          ip: "8.8.8.8",          name: "Google",       region: "Anycast"),
        DNSResolver(id: "8.8.4.4",          ip: "8.8.4.4",          name: "Google",       region: "Anycast (alt)"),
        DNSResolver(id: "9.9.9.9",          ip: "9.9.9.9",          name: "Quad9",        region: "Anycast"),
        DNSResolver(id: "149.112.112.112",  ip: "149.112.112.112",  name: "Quad9",        region: "Anycast (alt)"),
        DNSResolver(id: "208.67.222.222",   ip: "208.67.222.222",   name: "OpenDNS",      region: "Anycast"),
        DNSResolver(id: "208.67.220.220",   ip: "208.67.220.220",   name: "OpenDNS",      region: "Anycast (alt)"),
        DNSResolver(id: "94.140.14.14",     ip: "94.140.14.14",     name: "AdGuard",      region: "Anycast"),
        DNSResolver(id: "76.76.2.0",        ip: "76.76.2.0",        name: "ControlD",     region: "Anycast"),
        DNSResolver(id: "185.228.168.9",    ip: "185.228.168.9",    name: "CleanBrowsing",region: "Anycast"),
        DNSResolver(id: "64.6.64.6",        ip: "64.6.64.6",        name: "Verisign",     region: "Anycast"),
        DNSResolver(id: "84.200.69.80",     ip: "84.200.69.80",     name: "DNS.WATCH",    region: "Europe"),
        DNSResolver(id: "77.88.8.8",        ip: "77.88.8.8",        name: "Yandex",       region: "Russia"),
        DNSResolver(id: "180.76.76.76",     ip: "180.76.76.76",     name: "Baidu",        region: "China"),
        DNSResolver(id: "223.5.5.5",        ip: "223.5.5.5",        name: "AliDNS",       region: "China"),
    ]
}
