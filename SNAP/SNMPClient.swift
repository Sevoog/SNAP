// SNMPClient.swift
// SNAP — SNMP v2c client (ASN.1 BER encoder/decoder + GET/GETNEXT/GETBULK/WALK)
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
//
// Self-contained SNMP v2c implementation. No external dependencies.
//
// What's here:
//   • ASN1 — minimal BER encoder/decoder for the tags SNMP uses
//   • SNMPValue — one of {integer, octet-string, oid, null, counter32,
//                          gauge32, timeticks, ipaddress, counter64,
//                          noSuchObject, noSuchInstance, endOfMibView}
//   • SNMPClient — async send/receive over NWConnection (UDP/161)
//   • get(_:), getNext(_:), walk(_:), bulkWalk(_:) high-level helpers
//
// What's NOT here (deferred):
//   • SNMPv3 (USM auth+priv crypto) — v2c first
//   • SET requests — read-only client by design
//   • Trap receiver — separate UDP/162 listener if/when added

import Foundation
import Network

// MARK: - ASN.1 BER

enum ASN1Tag: UInt8 {
    case integer        = 0x02
    case octetString    = 0x04
    case null           = 0x05
    case oid            = 0x06
    case sequence       = 0x30
    // SNMP application tags
    case ipAddress      = 0x40
    case counter32      = 0x41
    case gauge32        = 0x42  // also Unsigned32
    case timeTicks      = 0x43
    case opaque         = 0x44
    case counter64      = 0x46
    // Context-specific (PDU) tags
    case getRequest     = 0xA0
    case getNextRequest = 0xA1
    case getResponse    = 0xA2
    case getBulkRequest = 0xA5
    // Exception markers (in responses for GETNEXT past end of MIB, etc.)
    case noSuchObject   = 0x80
    case noSuchInstance = 0x81
    case endOfMibView   = 0x82
}

/// Object Identifier (1.3.6.1.2.1.1.1.0 style).
struct OID: Hashable, CustomStringConvertible {
    let components: [UInt32]

    init(_ components: [UInt32]) { self.components = components }

    init?(string: String) {
        let parts = string.split(separator: ".").map(String.init)
        var out: [UInt32] = []
        out.reserveCapacity(parts.count)
        for p in parts {
            // Allow a leading "." prefix; "iso" is arc 1, not a no-op
            if p.isEmpty { continue }
            if p == "iso" { out.append(1); continue }
            guard let v = UInt32(p) else { return nil }
            out.append(v)
        }
        guard out.count >= 2 else { return nil }
        // X.690: first arc is 0–2, second arc < 40 under arcs 0 and 1.
        // Also keeps 40*a + b within UInt32 for the BER encoder.
        guard out[0] <= 2, out[0] == 2 || out[1] <= 39, out[1] <= UInt32.max - 80 else { return nil }
        self.components = out
    }

    var description: String { components.map(String.init).joined(separator: ".") }

    /// True if `other` is `self` or a descendant of `self` (lexicographic prefix).
    func isAncestorOrEqual(_ other: OID) -> Bool {
        guard other.components.count >= components.count else { return false }
        for i in 0..<components.count where other.components[i] != components[i] {
            return false
        }
        return true
    }
}

/// SNMP variable-binding value.
enum SNMPValue: CustomStringConvertible, Hashable {
    case integer(Int64)
    case octetString(Data)
    case oid(OID)
    case null
    case ipAddress(Data)        // 4 bytes
    case counter32(UInt32)
    case gauge32(UInt32)
    case timeTicks(UInt32)      // hundredths of a second
    case opaque(Data)
    case counter64(UInt64)
    case noSuchObject
    case noSuchInstance
    case endOfMibView

    /// Display form (best-effort UTF-8 for octet strings, hex fallback).
    var description: String {
        switch self {
        case .integer(let i):       return String(i)
        case .octetString(let d):
            if let s = String(data: d, encoding: .utf8),
               s.unicodeScalars.allSatisfy({ $0.value >= 0x20 || $0 == "\n" || $0 == "\t" }) {
                return s
            }
            return d.map { String(format: "%02X", $0) }.joined(separator: " ")
        case .oid(let o):           return o.description
        case .null:                 return "(null)"
        case .ipAddress(let d):
            return d.map(String.init).joined(separator: ".")
        case .counter32(let u):     return String(u)
        case .gauge32(let u):       return String(u)
        case .timeTicks(let u):     return formatTimeTicks(u)
        case .opaque(let d):
            return d.map { String(format: "%02X", $0) }.joined()
        case .counter64(let u):     return String(u)
        case .noSuchObject:         return "(noSuchObject)"
        case .noSuchInstance:       return "(noSuchInstance)"
        case .endOfMibView:         return "(endOfMibView)"
        }
    }

    private func formatTimeTicks(_ t: UInt32) -> String {
        // SNMP TimeTicks are in hundredths of a second since some epoch
        // (usually device uptime).
        let totalSec = Double(t) / 100.0
        let d = Int(totalSec) / 86400
        let h = (Int(totalSec) % 86400) / 3600
        let m = (Int(totalSec) % 3600) / 60
        let s = Int(totalSec) % 60
        if d > 0 { return "\(d)d \(h)h \(m)m \(s)s" }
        if h > 0 { return "\(h)h \(m)m \(s)s" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }
}

struct SNMPVarBind: Hashable {
    let oid: OID
    let value: SNMPValue
}

// MARK: - ASN.1 encoding

enum ASN1 {

    /// Encode a length in BER short or long form.
    static func encodeLength(_ length: Int) -> Data {
        if length < 0x80 {
            return Data([UInt8(length)])
        }
        var bytes: [UInt8] = []
        var n = length
        while n > 0 { bytes.insert(UInt8(n & 0xFF), at: 0); n >>= 8 }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    /// Encode an integer in two's-complement form (BER INTEGER body).
    static func encodeIntegerBody(_ value: Int64) -> Data {
        if value == 0 { return Data([0x00]) }
        var n = value
        var bytes: [UInt8] = []
        while n != 0 && n != -1 {
            bytes.insert(UInt8(truncatingIfNeeded: n & 0xFF), at: 0)
            n >>= 8
        }
        if value > 0 && (bytes.first ?? 0) & 0x80 != 0 {
            bytes.insert(0x00, at: 0)         // pad to keep sign positive
        } else if value < 0 && (bytes.first ?? 0) & 0x80 == 0 {
            bytes.insert(0xFF, at: 0)         // pad to keep sign negative
        }
        if bytes.isEmpty { bytes = [value < 0 ? 0xFF : 0x00] }
        return Data(bytes)
    }

    /// Encode a generic TLV: tag + length + value.
    static func tlv(_ tag: UInt8, _ value: Data) -> Data {
        var out = Data([tag])
        out.append(encodeLength(value.count))
        out.append(value)
        return out
    }

    static func encodeInteger(_ value: Int64) -> Data {
        tlv(ASN1Tag.integer.rawValue, encodeIntegerBody(value))
    }

    static func encodeOctetString(_ value: Data) -> Data {
        tlv(ASN1Tag.octetString.rawValue, value)
    }

    static func encodeOctetString(_ value: String) -> Data {
        encodeOctetString(value.data(using: .utf8) ?? Data())
    }

    static func encodeNull() -> Data {
        Data([ASN1Tag.null.rawValue, 0x00])
    }

    /// Encode an OID. First two components combine as 40*a + b; subsequent
    /// components are base-128 with the high bit set on all but the last
    /// continuation byte.
    static func encodeOID(_ oid: OID) -> Data {
        let c = oid.components
        guard c.count >= 2 else { return Data() }
        var body: [UInt8] = []
        // Widen to UInt64 — OID([UInt32]) can be built directly without the
        // string-init validation, and 40*a + b must not trap on overflow
        let first64 = UInt64(c[0]) * 40 + UInt64(c[1])
        guard let first = UInt32(exactly: first64) else { return Data() }
        body.append(contentsOf: base128(first))
        for i in 2..<c.count { body.append(contentsOf: base128(c[i])) }
        return tlv(ASN1Tag.oid.rawValue, Data(body))
    }

    private static func base128(_ v: UInt32) -> [UInt8] {
        if v == 0 { return [0x00] }
        var n = v
        var out: [UInt8] = []
        while n > 0 {
            out.insert(UInt8(n & 0x7F), at: 0)
            n >>= 7
        }
        for i in 0..<(out.count - 1) { out[i] |= 0x80 }
        return out
    }

    static func encodeSequence(_ children: [Data]) -> Data {
        var body = Data()
        for c in children { body.append(c) }
        return tlv(ASN1Tag.sequence.rawValue, body)
    }

    static func encodeContextSequence(_ tag: UInt8, _ children: [Data]) -> Data {
        var body = Data()
        for c in children { body.append(c) }
        return tlv(tag, body)
    }
}

/// Encode an unsigned integer as big-endian bytes, dropping leading zero
/// bytes (but keeping at least one byte for zero).
private func encodeUnsignedBody(_ value: UInt64) -> Data {
    if value == 0 { return Data([0x00]) }
    var bytes: [UInt8] = []
    var n = value
    while n > 0 { bytes.insert(UInt8(n & 0xFF), at: 0); n >>= 8 }
    return Data(bytes)
}

// MARK: - ASN.1 decoding

struct ASN1Cursor {
    let bytes: Data
    var pos: Int

    var atEnd: Bool { pos >= bytes.count }
    var remaining: Int { bytes.count - pos }

    mutating func readByte() throws -> UInt8 {
        guard pos < bytes.count else { throw SNMPError.truncated }
        let b = bytes[bytes.startIndex + pos]
        pos += 1
        return b
    }

    mutating func readLength() throws -> Int {
        let first = try readByte()
        if first < 0x80 { return Int(first) }
        let n = Int(first & 0x7F)
        guard n > 0, n <= 4 else { throw SNMPError.truncated } // bound for sanity
        var len = 0
        for _ in 0..<n { len = (len << 8) | Int(try readByte()) }
        return len
    }

    /// Reads the next TLV. Returns (tag, body).
    mutating func readTLV() throws -> (UInt8, Data) {
        let tag = try readByte()
        let len = try readLength()
        guard pos + len <= bytes.count else { throw SNMPError.truncated }
        let body = bytes.subdata(in: bytes.startIndex + pos ..< bytes.startIndex + pos + len)
        pos += len
        return (tag, body)
    }
}

enum SNMPError: Error, CustomStringConvertible {
    case truncated
    case unexpectedTag(UInt8)
    case badOID
    case errorStatus(Int, String, Int)       // (code, label, index)
    case timeout
    case transport(String)
    case versionMismatch

    var description: String {
        switch self {
        case .truncated:           return "Response truncated or malformed"
        case .unexpectedTag(let t):return String(format: "Unexpected ASN.1 tag 0x%02X", t)
        case .badOID:              return "Invalid OID"
        case let .errorStatus(c, l, i):
            return "SNMP error \(c) (\(l))" + (i > 0 ? " at varbind \(i)" : "")
        case .timeout:             return "Request timed out"
        case .transport(let m):    return "Transport error: \(m)"
        case .versionMismatch:     return "Unexpected SNMP version in response"
        }
    }
}

/// Standard SNMP error-status code → human label.
func snmpErrorLabel(_ code: Int) -> String {
    switch code {
    case 0:  return "noError"
    case 1:  return "tooBig"
    case 2:  return "noSuchName"
    case 3:  return "badValue"
    case 4:  return "readOnly"
    case 5:  return "genErr"
    case 6:  return "noAccess"
    case 7:  return "wrongType"
    case 8:  return "wrongLength"
    case 9:  return "wrongEncoding"
    case 10: return "wrongValue"
    case 11: return "noCreation"
    case 12: return "inconsistentValue"
    case 13: return "resourceUnavailable"
    case 14: return "commitFailed"
    case 15: return "undoFailed"
    case 16: return "authorizationError"
    case 17: return "notWritable"
    case 18: return "inconsistentName"
    default: return "errorStatus(\(code))"
    }
}

private struct ASN1Reader {

    static func readIntegerBody(_ body: Data) -> Int64 {
        if body.isEmpty { return 0 }
        var v: Int64 = (body[body.startIndex] & 0x80) != 0 ? -1 : 0
        for b in body { v = (v << 8) | Int64(b) }
        // Result so far is treated as signed; positive padding 0x00 handled
        // by the initial sign-extension above.
        return v
    }

    static func readUnsigned32(_ body: Data) -> UInt32 {
        var v: UInt32 = 0
        for b in body { v = (v << 8) | UInt32(b) }
        return v
    }

    static func readUnsigned64(_ body: Data) -> UInt64 {
        var v: UInt64 = 0
        for b in body { v = (v << 8) | UInt64(b) }
        return v
    }

    static func readOID(_ body: Data) throws -> OID {
        guard !body.isEmpty else { throw SNMPError.badOID }
        var comps: [UInt32] = []
        let first = body[body.startIndex]
        comps.append(UInt32(first / 40))
        comps.append(UInt32(first % 40))
        var acc: UInt32 = 0
        for i in 1..<body.count {
            let b = body[body.startIndex + i]
            acc = (acc << 7) | UInt32(b & 0x7F)
            if b & 0x80 == 0 {
                comps.append(acc)
                acc = 0
            }
        }
        return OID(comps)
    }

    static func readValue(tag: UInt8, body: Data) throws -> SNMPValue {
        switch tag {
        case ASN1Tag.integer.rawValue:
            return .integer(readIntegerBody(body))
        case ASN1Tag.octetString.rawValue:
            return .octetString(body)
        case ASN1Tag.null.rawValue:
            return .null
        case ASN1Tag.oid.rawValue:
            return .oid(try readOID(body))
        case ASN1Tag.ipAddress.rawValue:
            return .ipAddress(body)
        case ASN1Tag.counter32.rawValue:
            return .counter32(readUnsigned32(body))
        case ASN1Tag.gauge32.rawValue:
            return .gauge32(readUnsigned32(body))
        case ASN1Tag.timeTicks.rawValue:
            return .timeTicks(readUnsigned32(body))
        case ASN1Tag.opaque.rawValue:
            return .opaque(body)
        case ASN1Tag.counter64.rawValue:
            return .counter64(readUnsigned64(body))
        case ASN1Tag.noSuchObject.rawValue:   return .noSuchObject
        case ASN1Tag.noSuchInstance.rawValue: return .noSuchInstance
        case ASN1Tag.endOfMibView.rawValue:   return .endOfMibView
        default:
            // Unknown tag — wrap as opaque so we don't lose the data.
            return .opaque(body)
        }
    }
}

// MARK: - SNMP message build / parse

enum SNMPVersion: Int64 { case v1 = 0, v2c = 1 }

struct SNMPMessage {
    let version: SNMPVersion
    let community: String
    let pduTag: UInt8
    let requestID: Int32
    let errorStatus: Int32     // for GetBulk: non-repeaters
    let errorIndex: Int32      // for GetBulk: max-repetitions
    let varBinds: [SNMPVarBind]

    func encode() -> Data {
        // varBinds → SEQUENCE { name, value } each
        let vbs: [Data] = varBinds.map { vb in
            let name = ASN1.encodeOID(vb.oid)
            let val: Data = {
                switch vb.value {
                case .null:                return ASN1.encodeNull()
                case .integer(let i):      return ASN1.encodeInteger(i)
                case .octetString(let d):  return ASN1.encodeOctetString(d)
                case .oid(let o):          return ASN1.encodeOID(o)
                case .ipAddress(let d):    return ASN1.tlv(ASN1Tag.ipAddress.rawValue, d)
                case .counter32(let u):    return ASN1.tlv(ASN1Tag.counter32.rawValue, encodeUnsignedBody(UInt64(u)))
                case .gauge32(let u):      return ASN1.tlv(ASN1Tag.gauge32.rawValue, encodeUnsignedBody(UInt64(u)))
                case .timeTicks(let u):    return ASN1.tlv(ASN1Tag.timeTicks.rawValue, encodeUnsignedBody(UInt64(u)))
                case .counter64(let u):    return ASN1.tlv(ASN1Tag.counter64.rawValue, encodeUnsignedBody(u))
                case .opaque(let d):       return ASN1.tlv(ASN1Tag.opaque.rawValue, d)
                case .noSuchObject:        return Data([ASN1Tag.noSuchObject.rawValue, 0])
                case .noSuchInstance:      return Data([ASN1Tag.noSuchInstance.rawValue, 0])
                case .endOfMibView:        return Data([ASN1Tag.endOfMibView.rawValue, 0])
                }
            }()
            return ASN1.encodeSequence([name, val])
        }
        let vbList = ASN1.encodeSequence(vbs)

        let pdu = ASN1.encodeContextSequence(pduTag, [
            ASN1.encodeInteger(Int64(requestID)),
            ASN1.encodeInteger(Int64(errorStatus)),
            ASN1.encodeInteger(Int64(errorIndex)),
            vbList,
        ])

        return ASN1.encodeSequence([
            ASN1.encodeInteger(version.rawValue),
            ASN1.encodeOctetString(community),
            pdu,
        ])
    }

    static func decode(_ data: Data) throws -> SNMPMessage {
        var cur = ASN1Cursor(bytes: data, pos: 0)
        let (rootTag, rootBody) = try cur.readTLV()
        guard rootTag == ASN1Tag.sequence.rawValue else { throw SNMPError.unexpectedTag(rootTag) }

        var inner = ASN1Cursor(bytes: rootBody, pos: 0)
        let (verTag, verBody) = try inner.readTLV()
        guard verTag == ASN1Tag.integer.rawValue else { throw SNMPError.unexpectedTag(verTag) }
        let version = Int(ASN1Reader.readIntegerBody(verBody))

        let (commTag, commBody) = try inner.readTLV()
        guard commTag == ASN1Tag.octetString.rawValue else { throw SNMPError.unexpectedTag(commTag) }
        let community = String(data: commBody, encoding: .utf8) ?? ""

        let (pduTag, pduBody) = try inner.readTLV()

        var pduInner = ASN1Cursor(bytes: pduBody, pos: 0)
        let (idTag, idBody) = try pduInner.readTLV()
        guard idTag == ASN1Tag.integer.rawValue else { throw SNMPError.unexpectedTag(idTag) }
        let reqID = Int32(truncatingIfNeeded: ASN1Reader.readIntegerBody(idBody))

        let (esTag, esBody) = try pduInner.readTLV()
        guard esTag == ASN1Tag.integer.rawValue else { throw SNMPError.unexpectedTag(esTag) }
        let errStatus = Int32(truncatingIfNeeded: ASN1Reader.readIntegerBody(esBody))

        let (eiTag, eiBody) = try pduInner.readTLV()
        guard eiTag == ASN1Tag.integer.rawValue else { throw SNMPError.unexpectedTag(eiTag) }
        let errIndex = Int32(truncatingIfNeeded: ASN1Reader.readIntegerBody(eiBody))

        let (vbListTag, vbListBody) = try pduInner.readTLV()
        guard vbListTag == ASN1Tag.sequence.rawValue else { throw SNMPError.unexpectedTag(vbListTag) }

        var vbs: [SNMPVarBind] = []
        var vbCur = ASN1Cursor(bytes: vbListBody, pos: 0)
        while !vbCur.atEnd {
            let (vbTag, vbBody) = try vbCur.readTLV()
            guard vbTag == ASN1Tag.sequence.rawValue else { throw SNMPError.unexpectedTag(vbTag) }
            var inner2 = ASN1Cursor(bytes: vbBody, pos: 0)
            let (nameTag, nameBody) = try inner2.readTLV()
            guard nameTag == ASN1Tag.oid.rawValue else { throw SNMPError.unexpectedTag(nameTag) }
            let oid = try ASN1Reader.readOID(nameBody)
            let (valTag, valBody) = try inner2.readTLV()
            let val = try ASN1Reader.readValue(tag: valTag, body: valBody)
            vbs.append(SNMPVarBind(oid: oid, value: val))
        }

        return SNMPMessage(
            version: SNMPVersion(rawValue: Int64(version)) ?? .v2c,
            community: community,
            pduTag: pduTag,
            requestID: reqID,
            errorStatus: errStatus,
            errorIndex: errIndex,
            varBinds: vbs
        )
    }
}

// MARK: - Client

/// Async SNMP v2c client. One instance per query host.
final class SNMPClient {
    let host: String
    let port: UInt16
    let community: String
    let version: SNMPVersion
    let timeout: TimeInterval
    let retries: Int

    private static var requestCounter: Int32 = Int32.random(in: 1..<10000)
    private static let counterLock = NSLock()

    init(host: String,
         port: UInt16 = 161,
         community: String = "public",
         version: SNMPVersion = .v2c,
         timeout: TimeInterval = 3.0,
         retries: Int = 2) {
        self.host = host
        self.port = port
        self.community = community
        self.version = version
        self.timeout = timeout
        self.retries = retries
    }

    private func nextRequestID() -> Int32 {
        Self.counterLock.lock(); defer { Self.counterLock.unlock() }
        Self.requestCounter &+= 1
        return Self.requestCounter
    }

    // MARK: GET

    func get(_ oids: [OID]) async throws -> [SNMPVarBind] {
        let msg = SNMPMessage(
            version: version,
            community: community,
            pduTag: ASN1Tag.getRequest.rawValue,
            requestID: nextRequestID(),
            errorStatus: 0,
            errorIndex: 0,
            varBinds: oids.map { SNMPVarBind(oid: $0, value: .null) }
        )
        return try await round(msg)
    }

    func get(_ oid: OID) async throws -> SNMPVarBind {
        let r = try await get([oid])
        guard let v = r.first else { throw SNMPError.truncated }
        return v
    }

    // MARK: GETNEXT

    func getNext(_ oids: [OID]) async throws -> [SNMPVarBind] {
        let msg = SNMPMessage(
            version: version,
            community: community,
            pduTag: ASN1Tag.getNextRequest.rawValue,
            requestID: nextRequestID(),
            errorStatus: 0,
            errorIndex: 0,
            varBinds: oids.map { SNMPVarBind(oid: $0, value: .null) }
        )
        return try await round(msg)
    }

    // MARK: WALK

    /// Walk the subtree rooted at `base` using repeated GETNEXT. Stops when
    /// the returned OID is no longer a descendant of `base`, on endOfMibView,
    /// or after `maxRows` results (safety cap).
    func walk(_ base: OID, maxRows: Int = 1024) async throws -> [SNMPVarBind] {
        var results: [SNMPVarBind] = []
        var current = base
        while results.count < maxRows {
            let next: [SNMPVarBind]
            do {
                next = try await getNext([current])
            } catch SNMPError.errorStatus(_, _, _) {
                // Some agents return tooBig/noSuchName instead of endOfMibView.
                break
            }
            guard let vb = next.first else { break }
            if !base.isAncestorOrEqual(vb.oid) { break }
            if case .endOfMibView = vb.value { break }
            if case .noSuchObject = vb.value { break }
            if case .noSuchInstance = vb.value { break }
            results.append(vb)
            current = vb.oid
        }
        return results
    }

    /// Faster walk using GETBULK (v2c only). One round-trip returns up to
    /// `maxReps` rows. Falls back to plain walk semantics on bulk-unsupported
    /// agents (some SOHO gear still does v2c without GETBULK).
    func bulkWalk(_ base: OID, maxReps: Int = 25, maxRows: Int = 1024) async throws -> [SNMPVarBind] {
        guard version == .v2c else { return try await walk(base, maxRows: maxRows) }

        var results: [SNMPVarBind] = []
        var current = base
        while results.count < maxRows {
            let msg = SNMPMessage(
                version: .v2c,
                community: community,
                pduTag: ASN1Tag.getBulkRequest.rawValue,
                requestID: nextRequestID(),
                errorStatus: 0,                 // non-repeaters
                errorIndex: Int32(maxReps),     // max-repetitions
                varBinds: [SNMPVarBind(oid: current, value: .null)]
            )
            let chunk = try await round(msg)
            if chunk.isEmpty { break }
            var didAdvance = false
            for vb in chunk {
                if !base.isAncestorOrEqual(vb.oid) { return results }
                if case .endOfMibView = vb.value { return results }
                if case .noSuchObject = vb.value { return results }
                if case .noSuchInstance = vb.value { return results }
                results.append(vb)
                current = vb.oid
                didAdvance = true
                if results.count >= maxRows { return results }
            }
            if !didAdvance { break }
        }
        return results
    }

    // MARK: Transport (UDP round trip + retries)

    private func round(_ msg: SNMPMessage) async throws -> [SNMPVarBind] {
        let payload = msg.encode()
        var lastError: Error = SNMPError.timeout
        for _ in 0...retries {
            do {
                let reply = try await sendOnce(payload, expectedID: msg.requestID)
                if reply.errorStatus != 0 {
                    throw SNMPError.errorStatus(Int(reply.errorStatus),
                                                snmpErrorLabel(Int(reply.errorStatus)),
                                                Int(reply.errorIndex))
                }
                return reply.varBinds
            } catch SNMPError.timeout {
                lastError = SNMPError.timeout
                continue
            } catch {
                throw error
            }
        }
        throw lastError
    }

    private func sendOnce(_ payload: Data, expectedID: Int32) async throws -> SNMPMessage {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<SNMPMessage, Error>) in
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                cont.resume(throwing: SNMPError.transport("invalid port")); return
            }
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
            let params = NWParameters.udp
            let conn = NWConnection(to: endpoint, using: params)

            var resumed = false
            let lock = NSLock()
            func finish(_ result: Result<SNMPMessage, Error>) {
                lock.lock()
                let already = resumed
                resumed = true
                lock.unlock()
                if already { return }
                conn.cancel()
                switch result {
                case .success(let m): cont.resume(returning: m)
                case .failure(let e): cont.resume(throwing: e)
                }
            }

            let deadline = DispatchTime.now() + timeout
            DispatchQueue.global().asyncAfter(deadline: deadline) {
                finish(.failure(SNMPError.timeout))
            }

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: payload, completion: .contentProcessed { sendErr in
                        if let sendErr = sendErr {
                            finish(.failure(SNMPError.transport(sendErr.localizedDescription)))
                            return
                        }
                        conn.receiveMessage { data, _, _, recvErr in
                            if let recvErr = recvErr {
                                finish(.failure(SNMPError.transport(recvErr.localizedDescription)))
                                return
                            }
                            guard let data = data else {
                                finish(.failure(SNMPError.truncated)); return
                            }
                            do {
                                let m = try SNMPMessage.decode(data)
                                if m.requestID != expectedID {
                                    // Stale reply for a previous attempt — keep waiting on
                                    // the receiver. Realistically we just bail here since
                                    // our retries open a fresh connection each time.
                                    finish(.failure(SNMPError.truncated))
                                    return
                                }
                                finish(.success(m))
                            } catch {
                                finish(.failure(error))
                            }
                        }
                    })
                case .failed(let e):
                    finish(.failure(SNMPError.transport(e.localizedDescription)))
                case .cancelled:
                    break
                default:
                    break
                }
            }
            conn.start(queue: DispatchQueue.global(qos: .userInitiated))
        }
    }
}

// MARK: - Well-known OIDs + sysObjectID → vendor/model

enum SNMPOID {
    static let sysDescr     = OID([1,3,6,1,2,1,1,1,0])
    static let sysObjectID  = OID([1,3,6,1,2,1,1,2,0])
    static let sysUpTime    = OID([1,3,6,1,2,1,1,3,0])
    static let sysContact   = OID([1,3,6,1,2,1,1,4,0])
    static let sysName      = OID([1,3,6,1,2,1,1,5,0])
    static let sysLocation  = OID([1,3,6,1,2,1,1,6,0])
    static let sysServices  = OID([1,3,6,1,2,1,1,7,0])

    /// ifTable column 2 (ifDescr).
    static let ifDescr      = OID([1,3,6,1,2,1,2,2,1,2])
    /// ifTable column 5 (ifSpeed).
    static let ifSpeed      = OID([1,3,6,1,2,1,2,2,1,5])
    /// ifTable column 8 (ifOperStatus).
    static let ifOperStatus = OID([1,3,6,1,2,1,2,2,1,8])
    /// ifTable column 10 (ifInOctets).
    static let ifInOctets   = OID([1,3,6,1,2,1,2,2,1,10])
    /// ifTable column 16 (ifOutOctets).
    static let ifOutOctets  = OID([1,3,6,1,2,1,2,2,1,16])
    /// ipNetToMediaTable (ARP cache on the device).
    static let ipNetToMedia = OID([1,3,6,1,2,1,4,22,1])
    /// LLDP remote systems table.
    static let lldpRemSysName = OID([1,0,8802,1,1,2,1,4,1,1,9])
    static let lldpRemPortID  = OID([1,0,8802,1,1,2,1,4,1,1,7])
    static let lldpRemPortDesc = OID([1,0,8802,1,1,2,1,4,1,1,8])
}

/// Maps a sysObjectID OID prefix to a human-readable vendor + role.
/// Used to upgrade Vendor Fingerprint output when SNMP is available.
enum SysObjectIDDatabase {

    struct Entry {
        let vendor: String
        let role: DeviceRole
        let model: String?
    }

    /// Returns the best-matching entry by longest-prefix.
    static func match(_ oid: OID) -> Entry? {
        var best: (Int, Entry)?
        for (prefix, entry) in entries {
            if prefix.isAncestorOrEqual(oid) {
                if best == nil || prefix.components.count > best!.0 {
                    best = (prefix.components.count, entry)
                }
            }
        }
        return best?.1
    }

    /// Most vendors register a single enterprise number under
    /// 1.3.6.1.4.1.<n>. We map that root number to a vendor, and selected
    /// product-family sub-OIDs to specific roles/models.
    private static let entries: [(OID, Entry)] = [
        // Cisco — enterprise 9. Sub-roots tell us router/switch/AP.
        (OID([1,3,6,1,4,1,9,1]),    Entry(vendor: "Cisco", role: .networkSwitch, model: nil)),  // ciscoProducts
        (OID([1,3,6,1,4,1,9,12]),   Entry(vendor: "Cisco", role: .networkSwitch, model: "Catalyst")),
        (OID([1,3,6,1,4,1,9,5]),    Entry(vendor: "Cisco", role: .networkSwitch, model: "Catalyst chassis")),
        (OID([1,3,6,1,4,1,9,6,1]),  Entry(vendor: "Cisco", role: .networkSwitch, model: "Small Business")),
        // Cisco Meraki — enterprise 29671
        (OID([1,3,6,1,4,1,29671]),  Entry(vendor: "Cisco Meraki", role: .accessPoint, model: nil)),
        // Cisco — IP phones (Tandberg / Unified Communications)
        (OID([1,3,6,1,4,1,9,9,156]),Entry(vendor: "Cisco", role: .voipPhone, model: "IP Phone")),

        // Juniper — enterprise 2636
        (OID([1,3,6,1,4,1,2636]),   Entry(vendor: "Juniper Networks", role: .networkSwitch, model: nil)),
        (OID([1,3,6,1,4,1,2636,1,1,1,2,29]),  Entry(vendor: "Juniper Networks", role: .firewall, model: "SRX")),
        (OID([1,3,6,1,4,1,2636,1,1,1,2,57]),  Entry(vendor: "Juniper Networks", role: .accessPoint, model: "Mist AP")),

        // Arista — enterprise 30065
        (OID([1,3,6,1,4,1,30065]),  Entry(vendor: "Arista Networks", role: .networkSwitch, model: nil)),

        // Extreme — enterprise 1916
        (OID([1,3,6,1,4,1,1916]),   Entry(vendor: "Extreme Networks", role: .networkSwitch, model: nil)),

        // HP / HPE / 3Com / Aruba
        (OID([1,3,6,1,4,1,11]),     Entry(vendor: "HP / HPE", role: .networkSwitch, model: nil)),
        (OID([1,3,6,1,4,1,11,2,3,7,11]),  Entry(vendor: "HP", role: .printer, model: "JetDirect")),
        (OID([1,3,6,1,4,1,14823]),  Entry(vendor: "Aruba Networks", role: .accessPoint, model: nil)),
        (OID([1,3,6,1,4,1,25506]),  Entry(vendor: "H3C", role: .networkSwitch, model: nil)),

        // Palo Alto — enterprise 25461
        (OID([1,3,6,1,4,1,25461]),  Entry(vendor: "Palo Alto Networks", role: .firewall, model: nil)),

        // Fortinet — enterprise 12356
        (OID([1,3,6,1,4,1,12356]),  Entry(vendor: "Fortinet", role: .firewall, model: nil)),
        (OID([1,3,6,1,4,1,12356,118]), Entry(vendor: "Fortinet", role: .accessPoint, model: "FortiAP")),

        // Check Point — enterprise 2620
        (OID([1,3,6,1,4,1,2620]),   Entry(vendor: "Check Point", role: .firewall, model: nil)),
        // SonicWall — enterprise 8741
        (OID([1,3,6,1,4,1,8741]),   Entry(vendor: "SonicWall", role: .firewall, model: nil)),
        // WatchGuard — enterprise 3097
        (OID([1,3,6,1,4,1,3097]),   Entry(vendor: "WatchGuard", role: .firewall, model: nil)),
        // Sophos — enterprise 21067
        (OID([1,3,6,1,4,1,21067]),  Entry(vendor: "Sophos", role: .firewall, model: nil)),

        // F5 — enterprise 3375 (BIG-IP)
        (OID([1,3,6,1,4,1,3375]),   Entry(vendor: "F5 Networks", role: .loadBalancer, model: "BIG-IP")),
        // A10 — enterprise 22610
        (OID([1,3,6,1,4,1,22610]),  Entry(vendor: "A10 Networks", role: .loadBalancer, model: nil)),
        // Citrix NetScaler — enterprise 5951
        (OID([1,3,6,1,4,1,5951]),   Entry(vendor: "Citrix", role: .loadBalancer, model: "NetScaler")),

        // Mikrotik — enterprise 14988
        (OID([1,3,6,1,4,1,14988]),  Entry(vendor: "MikroTik", role: .router, model: nil)),
        // Ubiquiti — enterprise 41112
        (OID([1,3,6,1,4,1,41112]),  Entry(vendor: "Ubiquiti", role: .accessPoint, model: nil)),
        // Ruckus — enterprise 25053
        (OID([1,3,6,1,4,1,25053]),  Entry(vendor: "Ruckus", role: .accessPoint, model: nil)),

        // Microsoft Windows host SNMP service — enterprise 311
        (OID([1,3,6,1,4,1,311]),    Entry(vendor: "Microsoft", role: .windowsPC, model: nil)),
        // Linux net-snmp default — enterprise 8072
        (OID([1,3,6,1,4,1,8072,3,2,10]), Entry(vendor: "Linux", role: .linux, model: "net-snmp")),
        // VMware ESX — enterprise 6876
        (OID([1,3,6,1,4,1,6876]),   Entry(vendor: "VMware", role: .serverHardware, model: "ESXi")),
        // Synology — enterprise 6574
        (OID([1,3,6,1,4,1,6574]),   Entry(vendor: "Synology", role: .nas, model: nil)),
        // QNAP — enterprise 24681
        (OID([1,3,6,1,4,1,24681]),  Entry(vendor: "QNAP", role: .nas, model: nil)),
        // NetApp — enterprise 789
        (OID([1,3,6,1,4,1,789]),    Entry(vendor: "NetApp", role: .nas, model: nil)),
        // Polycom — enterprise 13885
        (OID([1,3,6,1,4,1,13885]),  Entry(vendor: "Polycom", role: .voipPhone, model: nil)),
        // Avaya — enterprise 6889
        (OID([1,3,6,1,4,1,6889]),   Entry(vendor: "Avaya", role: .voipPhone, model: nil)),
    ]
}
