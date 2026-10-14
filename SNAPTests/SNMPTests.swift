// SNMPTests.swift
// SNAP — Tests for ASN.1 BER encoding/decoding, SNMP message round-trip,
//        and sysObjectID lookup.
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md

import XCTest
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
