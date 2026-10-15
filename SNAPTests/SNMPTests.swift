// SNMPTests.swift
// SNAP — Tests for ASN.1 BER encoding/decoding, SNMP message round-trip,
//        and sysObjectID lookup.
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md

import XCTest
import Network
@testable import SNAP

final class SNMPTests: XCTestCase {

    // MARK: - ASN.1 integers

    func test_encodeInteger_zero() {
        let d = ASN1.encodeInteger(0)
        XCTAssertEqual([UInt8](d), [0x02, 0x01, 0x00])
    }

    func test_encodeInteger_positiveSmall() {
        let d = ASN1.encodeInteger(127)
        XCTAssertEqual([UInt8](d), [0x02, 0x01, 0x7F])
    }

    func test_encodeInteger_positiveNeedsSignPadding() {
        // 128 needs a leading 0x00 byte to stay non-negative in two's complement.
        let d = ASN1.encodeInteger(128)
        XCTAssertEqual([UInt8](d), [0x02, 0x02, 0x00, 0x80])
    }

    func test_encodeInteger_negative() {
        // -1 in BER = single 0xFF byte.
        let d = ASN1.encodeInteger(-1)
        XCTAssertEqual([UInt8](d), [0x02, 0x01, 0xFF])
    }

    // MARK: - ASN.1 OIDs

    func test_oid_encode_simple() {
        // 1.3.6.1.2.1.1.1.0 → 06 08 2B 06 01 02 01 01 01 00
        let d = ASN1.encodeOID(OID([1,3,6,1,2,1,1,1,0]))
        XCTAssertEqual([UInt8](d),
                       [0x06, 0x08, 0x2B, 0x06, 0x01, 0x02, 0x01, 0x01, 0x01, 0x00])
    }

    func test_oid_roundTrip_viaMessage_largeSubid() throws {
        // 41112 (Ubiquiti enterprise number) needs multi-byte base-128
        // encoding. Verify the full round-trip through the message codec.
        let ubnt = OID([1,3,6,1,4,1,41112,1,2,3])
        let msg = SNMPMessage(
            version: .v2c,
            community: "public",
            pduTag: ASN1Tag.getResponse.rawValue,
            requestID: 1,
            errorStatus: 0,
            errorIndex: 0,
            varBinds: [SNMPVarBind(oid: ubnt, value: .null)]
        )
        let decoded = try SNMPMessage.decode(msg.encode())
        XCTAssertEqual(decoded.varBinds.first?.oid, ubnt)
    }

    func test_oid_roundTrip_viaMessage() throws {
        // Build a getResponse with sysObjectID = 1.3.6.1.4.1.9.1.123 (Cisco)
        // and verify our decoder recovers it intact.
        let cisco = OID([1,3,6,1,4,1,9,1,123])
        let msg = SNMPMessage(
            version: .v2c,
            community: "public",
            pduTag: ASN1Tag.getResponse.rawValue,
            requestID: 12345,
            errorStatus: 0,
            errorIndex: 0,
            varBinds: [SNMPVarBind(oid: SNMPOID.sysObjectID, value: .oid(cisco))]
        )
        let encoded = msg.encode()
        let decoded = try SNMPMessage.decode(encoded)
        XCTAssertEqual(decoded.requestID, 12345)
        XCTAssertEqual(decoded.community, "public")
        XCTAssertEqual(decoded.varBinds.count, 1)
        guard case .oid(let o) = decoded.varBinds[0].value else {
            XCTFail("expected OID value"); return
        }
        XCTAssertEqual(o, cisco)
    }

    // MARK: - SNMP message round-trip (mixed value types)

    func test_message_roundTrip_systemGroup() throws {
        let vbs: [SNMPVarBind] = [
            SNMPVarBind(oid: SNMPOID.sysDescr, value: .octetString(Data("Cisco IOS-XE 17.6".utf8))),
            SNMPVarBind(oid: SNMPOID.sysUpTime, value: .timeTicks(12_345_678)),
            SNMPVarBind(oid: SNMPOID.sysObjectID, value: .oid(OID([1,3,6,1,4,1,9,1,1042]))),
        ]
        let msg = SNMPMessage(
            version: .v2c,
            community: "public",
            pduTag: ASN1Tag.getResponse.rawValue,
            requestID: 99,
            errorStatus: 0,
            errorIndex: 0,
            varBinds: vbs
        )
        let decoded = try SNMPMessage.decode(msg.encode())
        XCTAssertEqual(decoded.varBinds.count, 3)
        if case .octetString(let d) = decoded.varBinds[0].value {
            XCTAssertEqual(String(data: d, encoding: .utf8), "Cisco IOS-XE 17.6")
        } else { XCTFail("expected octet string") }
        if case .timeTicks(let t) = decoded.varBinds[1].value {
            XCTAssertEqual(t, 12_345_678)
        } else { XCTFail("expected timeTicks") }
    }

    // MARK: - sysObjectID lookup

    func test_sysObjectIDDatabase_matchesCisco() {
        let oid = OID([1,3,6,1,4,1,9,1,1042])
        let entry = SysObjectIDDatabase.match(oid)
        XCTAssertEqual(entry?.vendor, "Cisco")
        XCTAssertEqual(entry?.role, .networkSwitch)
    }

    func test_sysObjectIDDatabase_matchesPaloAlto() {
        let oid = OID([1,3,6,1,4,1,25461,2,3,7])
        let entry = SysObjectIDDatabase.match(oid)
        XCTAssertEqual(entry?.vendor, "Palo Alto Networks")
        XCTAssertEqual(entry?.role, .firewall)
    }

    func test_sysObjectIDDatabase_matchesArista() {
        let oid = OID([1,3,6,1,4,1,30065,1,2])
        let entry = SysObjectIDDatabase.match(oid)
        XCTAssertEqual(entry?.vendor, "Arista Networks")
        XCTAssertEqual(entry?.role, .networkSwitch)
    }

    func test_sysObjectIDDatabase_unknownEnterprise() {
        // 1.3.6.1.4.1.99999 isn't in our table.
        let oid = OID([1,3,6,1,4,1,99999,1])
        XCTAssertNil(SysObjectIDDatabase.match(oid))
    }

    // MARK: OID string validation (X.690 arc rules)

    func test_oidString_validInputs() {
        XCTAssertNotNil(OID(string: "1.3.6.1.2.1.1.1.0"))
        XCTAssertNotNil(OID(string: ".1.3.6.1"))          // leading dot
        XCTAssertNotNil(OID(string: "2.999"))             // arc 2 allows second >= 40
        XCTAssertNotNil(OID(string: "0.39"))
        // "iso" is arc 1, not a token to discard
        XCTAssertEqual(OID(string: "iso.3.6.1.2.1")?.components, [1,3,6,1,2,1])
    }

    func test_oidString_rejectsInvalidArcs() {
        XCTAssertNil(OID(string: "3.1"))                  // first arc must be 0-2
        XCTAssertNil(OID(string: "1.40"))                 // second arc < 40 under arcs 0/1
        XCTAssertNil(OID(string: "4294967295.1"))         // used to trap 40*a+b overflow
        XCTAssertNil(OID(string: "2.4294967295"))         // 80+b would overflow UInt32
    }

    // MARK: Regression — encodeOID must not trap on unvalidated OID([...])

    func test_encodeOID_overflowingFirstArcs_returnsEmpty() {
        // OID([UInt32]) bypasses string validation; the encoder must reject
        // rather than trap on 40*a+b overflow.
        XCTAssertEqual(ASN1.encodeOID(OID([UInt32.max, 1])), Data())
    }
}

// MARK: - Walks, fallbacks, and decoding against a fake agent

/// A tiny in-memory SNMP agent. Answers GET / GETNEXT / GETBULK from a
/// sorted MIB, and can misbehave on request.
final class FakeSNMPAgent: @unchecked Sendable {
    private let lock = NSLock()
    let mib: [(OID, SNMPValue)]
    var v1 = false                 // v1 rules: noSuchName errors instead of exceptions
    var tooBigAbove: Int?          // GETBULK with more repetitions than this → tooBig
    var rejectBulk = false         // GETBULK → genErr
    var stuckAt: OID?              // GETNEXT from here (or later) returns this OID again
    var failFrom: OID?             // GETNEXT/GETBULK at or past this OID → genErr
    private(set) var pdus: [UInt8] = []

    init(_ entries: [(String, SNMPValue)]) {
        mib = entries.map { (OID(string: $0.0)!, $0.1) }.sorted { $0.0 < $1.0 }
    }

    func client(version: SNMPVersion = .v2c) -> SNMPClient {
        SNMPClient(host: "fake", version: version, timeout: 1, retries: 0,
                   transport: { [self] m in try self.reply(m) })
    }

    private func next(after oid: OID) -> SNMPVarBind? {
        if let s = stuckAt, oid >= s { return SNMPVarBind(oid: s, value: .integer(0)) }
        guard let e = mib.first(where: { $0.0 > oid }) else { return nil }
        return SNMPVarBind(oid: e.0, value: e.1)
    }

    func reply(_ m: SNMPMessage) throws -> SNMPMessage {
        lock.lock(); pdus.append(m.pduTag); lock.unlock()
        func respond(_ vbs: [SNMPVarBind], status: Int32 = 0, index: Int32 = 0) -> SNMPMessage {
            SNMPMessage(version: m.version, community: m.community, pduTag: ASN1Tag.getResponse.rawValue,
                        requestID: m.requestID, errorStatus: status, errorIndex: index, varBinds: vbs)
        }
        var out: [SNMPVarBind] = []
        switch m.pduTag {
        case ASN1Tag.getRequest.rawValue:
            for (i, vb) in m.varBinds.enumerated() {
                if let e = mib.first(where: { $0.0 == vb.oid }) {
                    out.append(SNMPVarBind(oid: vb.oid, value: e.1))
                } else if v1 {
                    return respond(m.varBinds, status: 2, index: Int32(i + 1))
                } else {
                    out.append(SNMPVarBind(oid: vb.oid, value: .noSuchObject))
                }
            }
        case ASN1Tag.getNextRequest.rawValue:
            if let f = failFrom, m.varBinds[0].oid >= f { return respond(m.varBinds, status: 5, index: 1) }
            for (i, vb) in m.varBinds.enumerated() {
                if let n = next(after: vb.oid) {
                    out.append(n)
                } else if v1 {
                    return respond(m.varBinds, status: 2, index: Int32(i + 1))
                } else {
                    out.append(SNMPVarBind(oid: vb.oid, value: .endOfMibView))
                }
            }
        case ASN1Tag.getBulkRequest.rawValue:
            if rejectBulk { return respond(m.varBinds, status: 5, index: 1) }
            if let f = failFrom, m.varBinds[0].oid >= f { return respond(m.varBinds, status: 5, index: 1) }
            let reps = Int(m.errorIndex)
            if let limit = tooBigAbove, reps > limit { return respond([], status: 1) }
            var cur = m.varBinds[0].oid
            for _ in 0..<reps {
                guard let n = next(after: cur) else {
                    out.append(SNMPVarBind(oid: cur, value: .endOfMibView)); break
                }
                out.append(n); cur = n.oid
            }
        default:
            throw SNMPError.unexpectedTag(m.pduTag)
        }
        return respond(out)
    }

    var sawGetNext: Bool { pdus.contains(ASN1Tag.getNextRequest.rawValue) }
    var bulkCount: Int { pdus.filter { $0 == ASN1Tag.getBulkRequest.rawValue }.count }
}

final class SNMPWalkTests: XCTestCase {
    /// ifDescr.1-5, then the next column (ifType), then the system group's sysName.
    private func agent() -> FakeSNMPAgent {
        var e: [(String, SNMPValue)] = (1...5).map { ("1.3.6.1.2.1.2.2.1.2.\($0)", .octetString(Data("eth\($0)".utf8))) }
        e.append(("1.3.6.1.2.1.2.2.1.3.1", .integer(6)))
        e.append(("1.3.6.1.2.1.1.5.0", .octetString(Data("switch-1".utf8))))
        return FakeSNMPAgent(e)
    }
    private let ifDescr = SNMPOID.ifDescr

    func test_oidOrdering_isNumericComponentWise() {
        XCTAssertLessThan(OID(string: "1.3.6.1.2")!, OID(string: "1.3.6.1.2.1")!)        // parent first
        XCTAssertLessThan(OID(string: "1.3.6.1.2.1.2")!, OID(string: "1.3.6.1.2.1.10")!)  // 2 < 10, not "10" < "2"
        XCTAssertFalse(OID(string: "1.3.6.1")! < OID(string: "1.3.6.1")!)
    }

    func test_bulkWalk_staysInSubtree() async throws {
        let w = try await agent().client().bulkWalk(ifDescr, maxReps: 2)
        XCTAssertEqual(w.rows.map(\.value.description), ["eth1", "eth2", "eth3", "eth4", "eth5"])
        XCTAssertEqual(w.end, .complete)
    }

    func test_bulkWalk_reportsRowLimit() async throws {
        let w = try await agent().client().bulkWalk(ifDescr, maxReps: 25, maxRows: 3)
        XCTAssertEqual(w.rows.count, 3)
        XCTAssertEqual(w.end, .limit)
    }

    func test_bulkWalk_tooBig_asksForFewerRows() async throws {
        let a = agent(); a.tooBigAbove = 2
        let w = try await a.client().bulkWalk(ifDescr, maxReps: 25)
        XCTAssertEqual(w.rows.count, 5)
        XCTAssertEqual(w.end, .complete)
        XCTAssertFalse(a.sawGetNext)        // it asked for fewer rows, not fell back
        XCTAssertGreaterThan(a.bulkCount, 1)
    }

    /// A device error partway through used to end the walk as if complete.
    func test_walk_errorPartway_isReported() async throws {
        // Requests that start at ifDescr.2 or later fail: rows .1 and .2 arrive first.
        let a = agent(); a.failFrom = OID(string: "1.3.6.1.2.1.2.2.1.2.2")
        let w = try await a.client().bulkWalk(ifDescr, maxReps: 2)
        XCTAssertEqual(w.rows.count, 2)
        XCTAssertEqual(w.end, .error(5, "genErr"))
        // On the very first request there's nothing to show: the error is thrown.
        let b = agent(); b.failFrom = ifDescr
        do {
            _ = try await b.client().bulkWalk(ifDescr)
            XCTFail("expected genErr")
        } catch SNMPError.errorStatus(5, _, _) {}
    }

    /// Auto only falls back to v1 when v2c never answered; replies are counted.
    func test_client_countsReplies() async throws {
        let c = agent().client()
        XCTAssertEqual(c.repliesReceived, 0)
        _ = try await c.get([SNMPOID.sysName])
        _ = try await c.bulkWalk(ifDescr, maxReps: 2)
        XCTAssertEqual(c.repliesReceived, 4)   // 1 GET + 3 GETBULKs
    }

    func test_bulkWalk_rejected_fallsBackToGetNext() async throws {
        let a = agent(); a.rejectBulk = true
        let w = try await a.client().bulkWalk(ifDescr, maxReps: 25)
        XCTAssertEqual(w.rows.count, 5)
        XCTAssertTrue(a.sawGetNext)
    }

    /// A repeating agent used to fill the walk with duplicates, and the
    /// Interfaces join then crashed on the duplicate keys.
    func test_walks_stopWhenAgentRepeats() async throws {
        let a = agent(); a.stuckAt = OID(string: "1.3.6.1.2.1.2.2.1.2.3")
        let bulk = try await a.client().bulkWalk(ifDescr, maxReps: 25)
        XCTAssertEqual(bulk.rows.count, 3)
        XCTAssertEqual(bulk.end, .notIncreasing)
        let next = try await a.client(version: .v1).walk(ifDescr)
        XCTAssertEqual(next.rows.count, 3)
        XCTAssertEqual(next.end, .notIncreasing)
    }

    /// v1 has no GETBULK and ends a walk with a noSuchName error.
    func test_v1_walkEndsOnNoSuchName() async throws {
        let a = agent(); a.v1 = true
        // ifType.1 is the last entry in the MIB, so the walk runs off the end.
        let w = try await a.client(version: .v1).bulkWalk(OID(string: "1.3.6.1.2.1.2.2.1.3")!)
        XCTAssertEqual(w.rows.map(\.value.description), ["6"])
        XCTAssertEqual(w.end, .complete)
        XCTAssertEqual(a.bulkCount, 0)
    }

    /// Walking sysName.0 used to return 0 rows: the next OID is outside it.
    func test_walkSubtree_getsSingleValue() async throws {
        let w = try await agent().client().walkSubtree(SNMPOID.sysName)
        XCTAssertEqual(w.rows.map(\.value.description), ["switch-1"])
        let missing = try await agent().client().walkSubtree(SNMPOID.sysContact)
        XCTAssertTrue(missing.rows.isEmpty)
        let a = agent(); a.v1 = true
        let missingV1 = try await a.client(version: .v1).walkSubtree(SNMPOID.sysContact)
        XCTAssertTrue(missingV1.rows.isEmpty)
    }

    /// v1 fails a whole GET when one OID is missing; getTolerant asks again one by one.
    func test_getTolerant_v1_marksMissingOIDs() async throws {
        let a = agent(); a.v1 = true
        let vbs = try await a.client(version: .v1).getTolerant([SNMPOID.sysName, SNMPOID.sysContact])
        XCTAssertEqual(vbs.count, 2)
        XCTAssertEqual(vbs[0].value.description, "switch-1")
        XCTAssertEqual(vbs[1].value, .noSuchObject)
    }

    func test_octetStrings_textOrHex() {
        // Cisco IOS sysDescr uses CRLF; printers often pad with NULs.
        XCTAssertEqual(SNMPValue.octetString(Data("Cisco IOS\r\nVersion 15.2".utf8)).description, "Cisco IOS\r\nVersion 15.2")
        XCTAssertEqual(SNMPValue.octetString(Data("HP LaserJet\0\0".utf8)).description, "HP LaserJet")
        XCTAssertEqual(SNMPValue.octetString(Data([0x00, 0x1A, 0x2B, 0x3C, 0x4D, 0x5E])).description, "00 1A 2B 3C 4D 5E")
        XCTAssertEqual(SNMPValue.octetString(Data([0, 0, 0, 0])).description, "00 00 00 00")
        // BITS / PortList / addresses that end in zero bytes stay hex.
        XCTAssertEqual(SNMPValue.octetString(Data([0x28, 0x00])).description, "28 00")
        XCTAssertEqual(SNMPValue.octetString(Data([0x20, 0x00])).description, "20 00")
        XCTAssertEqual(SNMPValue.octetString(Data([0x60, 0, 0, 0])).description, "60 00 00 00")
        XCTAssertEqual(SNMPValue.octetString(Data([0x0A, 0, 0, 0])).description, "0A 00 00 00")
        XCTAssertFalse(SNMPValue.octetString(Data([0x28, 0x00])).isText)
        XCTAssertEqual(SNMPValue.octetString(Data()).description, "")
        XCTAssertTrue(SNMPValue.octetString(Data("eth0".utf8)).isText)
        XCTAssertFalse(SNMPValue.octetString(Data([0x00, 0x1A, 0x2B])).isText)
    }

    func test_interfaceSpeedAndStatus() {
        // ifSpeed tops out at 4,294,967,295; 10G ports must use ifHighSpeed.
        XCTAssertEqual(SNMPInterfaceFormat.effectiveSpeedBps(ifSpeed: 4_294_967_295, highSpeedMbps: 10_000), 10_000_000_000)
        XCTAssertEqual(SNMPInterfaceFormat.effectiveSpeedBps(ifSpeed: 1_000_000_000, highSpeedMbps: 1000), 1_000_000_000)
        XCTAssertEqual(SNMPInterfaceFormat.effectiveSpeedBps(ifSpeed: 1_544_000, highSpeedMbps: 2), 1_544_000)  // T1: ifHighSpeed rounds
        XCTAssertEqual(SNMPInterfaceFormat.effectiveSpeedBps(ifSpeed: 4_294_967_295, highSpeedMbps: nil), 4_294_967_295)
        XCTAssertEqual(SNMPInterfaceFormat.formatSpeed(10_000_000_000), "10 Gbps")
        XCTAssertEqual(SNMPInterfaceFormat.formatSpeed(2_500_000_000), "2.5 Gbps")
        XCTAssertEqual(SNMPInterfaceFormat.formatSpeed(1_544_000), "1.5 Mbps")
        XCTAssertEqual(SNMPInterfaceFormat.formatSpeed(100_000_000), "100 Mbps")
        XCTAssertEqual(SNMPInterfaceFormat.statusLabel(admin: .integer(2), oper: .integer(2)), "disabled")
        XCTAssertEqual(SNMPInterfaceFormat.statusLabel(admin: .integer(1), oper: .integer(2)), "down")
        XCTAssertEqual(SNMPInterfaceFormat.statusLabel(admin: nil, oper: .integer(1)), "up")
    }

    /// Stop used to leave the request running until its timeout, which then
    /// reported "timed out" over whatever the user did next.
    func test_cancel_endsRequestImmediately() async throws {
        let listener = try NWListener(using: .udp, on: .any)   // receives, never answers
        let ready = expectation(description: "listening")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.newConnectionHandler = { $0.start(queue: .global()) }
        listener.start(queue: .global())
        await fulfillment(of: [ready], timeout: 5)
        defer { listener.cancel() }

        let client = SNMPClient(host: "127.0.0.1", port: listener.port!.rawValue, timeout: 10, retries: 0)
        let started = Date()
        let task = Task { try await client.get([SNMPOID.sysName]) }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(client.localAddress, "127.0.0.1")
    }
}

// MARK: - Remember: filling in and forgetting saved communities

private final class CountingSecrets: SNMPSecretStore {
    var items: [String: String] = [:]
    var reads = 0
    func read(account: String) -> SNMPSecretLookup {
        reads += 1
        return items[account].map { .found($0) } ?? .missing
    }
    func write(account: String, secret: String) -> Bool { items[account] = secret; return true }
    func delete(account: String) { items[account] = nil }
}

@MainActor
final class SNMPRememberTests: XCTestCase {
    private let suite = "snap.tests.snmp.remember"
    private var secrets: CountingSecrets!
    private var live: SNMPCommunityStore.Backend?

    override func setUp() async throws {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        secrets = CountingSecrets()
        live = SNMPCommunityStore.backend
        SNMPCommunityStore.backend = .init(secrets: secrets, defaults: defaults,
                                           indexKey: "remembered", boardKey: "board")
        SNMPCommunityStore.save(host: "10.0.0.2", port: 161, community: "s3cret")
    }

    override func tearDown() async throws {
        if let live { SNMPCommunityStore.backend = live }
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    /// Typing past a saved host used to leave its community in the field.
    func test_savedHost_fillsIn_andLeavingItRestoresWhatWasTyped() {
        let m = SNMPQueryModel()
        m.community = "mine"
        m.host = "10.0.0.2"; m.hostChanged()
        XCTAssertEqual(m.community, "s3cret")
        XCTAssertTrue(m.rememberCommunity)
        m.host = "10.0.0.25"; m.hostChanged()
        XCTAssertEqual(m.community, "mine")
        XCTAssertFalse(m.rememberCommunity)
        XCTAssertTrue(SNMPCommunityStore.hasSaved(host: "10.0.0.2", port: 161))   // nothing forgotten
    }

    func test_sameHost_readsTheKeychainOnce() {
        let m = SNMPQueryModel()
        m.host = "10.0.0.2"
        m.hostChanged(); m.hostChanged(); m.hostChanged()
        XCTAssertEqual(secrets.reads, 1)
    }

    func test_untickingRemember_forgetsThatHostOnly() {
        SNMPCommunityStore.save(host: "10.0.0.3", port: 161, community: "other")
        let m = SNMPQueryModel()
        m.host = "10.0.0.2"; m.hostChanged()
        m.userSetRemember(false)
        XCTAssertFalse(SNMPCommunityStore.hasSaved(host: "10.0.0.2", port: 161))
        XCTAssertTrue(SNMPCommunityStore.hasSaved(host: "10.0.0.3", port: 161))
    }

    /// A tick made by hand on an unsaved host survives editing the host.
    func test_manualTick_onUnsavedHost_isKept() {
        let m = SNMPQueryModel()
        m.host = "192.168.1.1"; m.hostChanged()
        m.userSetRemember(true)
        m.host = "192.168.1.10"; m.hostChanged()
        XCTAssertTrue(m.rememberCommunity)
    }

    func test_forgetAll_clearsAndUnticks() {
        let m = SNMPQueryModel()
        m.host = "10.0.0.2"; m.hostChanged()
        m.forgetAllCommunities()
        XCTAssertFalse(m.rememberCommunity)
        XCTAssertEqual(SNMPCommunityStore.savedCount, 0)
    }
}
