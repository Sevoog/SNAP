// SNMPTopologyTests.swift
// SNAP — Tests
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md

import XCTest
@testable import SNAP

/// Neighbors (LLDP, CDP) and Where Is It? (ARP, BRIDGE-MIB, Q-BRIDGE-MIB)
/// against the in-memory FakeSNMPAgent.
final class SNMPTopologyTests: XCTestCase {

    // MARK: Helpers

    private func s(_ t: String) -> SNMPValue { .octetString(Data(t.utf8)) }
    private func b(_ bytes: [UInt8]) -> SNMPValue { .octetString(Data(bytes)) }
    private func dotted(_ bytes: [UInt8]) -> String { bytes.map(String.init).joined(separator: ".") }

    private let rem = "1.0.8802.1.1.2.1.4.1.1"
    private let loc = "1.0.8802.1.1.2.1.3.7.1"
    private let man = "1.0.8802.1.1.2.1.4.2.1"
    private let cdp = "1.3.6.1.4.1.9.9.23.1.2.1.1"
    private let ifName = "1.3.6.1.2.1.31.1.1.1.1"
    private let ifDescr = "1.3.6.1.2.1.2.2.1.2"
    private let ifAlias = "1.3.6.1.2.1.31.1.1.1.18"
    private let fdbPort = "1.3.6.1.2.1.17.4.3.1.2"
    private let fdbStatus = "1.3.6.1.2.1.17.4.3.1.3"
    private let basePortIfIndex = "1.3.6.1.2.1.17.1.4.1.2"
    private let qFdbPort = "1.3.6.1.2.1.17.7.1.2.2.1.2"
    private let qFdbStatus = "1.3.6.1.2.1.17.7.1.2.2.1.3"
    private let vlanFdbId = "1.3.6.1.2.1.17.7.1.4.2.1.3"

    private let coreMAC: [UInt8] = [0x00, 0x11, 0x22, 0x33, 0x44, 0x55]
    private let phoneMAC: [UInt8] = [0xaa, 0xbb, 0xcc, 0x00, 0x00, 0x01]
    private let target: [UInt8] = [0x3c, 0x22, 0xfb, 0x12, 0x34, 0x56]

    /// Two LLDP neighbors: a switch on Gi1/0/48 (LLDP port 1, named in
    /// lldpLocPortTable) and a phone on LLDP port 2 (no lldpLocPortTable
    /// row, so the name comes from ifName.2).
    private func lldpMIB() -> [(String, SNMPValue)] {
        [
            // Neighbor on LLDP port 1: index timeMark 0, port 1, remIndex 1
            ("\(rem).4.0.1.1", .integer(4)),                       // chassis ID is a MAC
            ("\(rem).5.0.1.1", b(coreMAC)),
            ("\(rem).6.0.1.1", .integer(5)),                       // port ID is an interface name
            ("\(rem).7.0.1.1", s("Te1/1/1")),
            ("\(rem).8.0.1.1", s("TenGigabitEthernet1/1/1")),
            ("\(rem).9.0.1.1", s("core-sw2.example.com")),
            ("\(rem).10.0.1.1", s("Cisco IOS Software, Catalyst 9300\r\nVersion 17.6")),
            ("\(rem).12.0.1.1", b([0x28, 0x00])),                  // bridge + router
            // Neighbor on LLDP port 2, remIndex 3
            ("\(rem).4.0.2.3", .integer(5)),                       // chassis ID is a network address
            ("\(rem).5.0.2.3", b([1, 10, 0, 0, 50])),
            ("\(rem).6.0.2.3", .integer(3)),                       // port ID is a MAC
            ("\(rem).7.0.2.3", b(phoneMAC)),
            ("\(rem).8.0.2.3", s("eth0")),
            ("\(rem).12.0.2.3", b([0x24])),                        // bridge + telephone
            // This device's LLDP port 1
            ("\(loc).2.1", .integer(5)),
            ("\(loc).3.1", s("Gi1/0/48")),
            ("\(loc).4.1", s("GigabitEthernet1/0/48")),
            // Management addresses: in the index, with and without the length
            ("\(man).3.0.1.1.1.4.10.0.0.2", .integer(2)),
            ("\(man).3.0.1.1.2.16.254.128.0.0.0.0.0.0.0.0.0.0.0.0.0.1", .integer(2)),   // IPv6, skipped
            ("\(man).3.0.2.3.1.10.0.0.51", .integer(2)),
            // Interfaces
            ("\(ifDescr).2", s("GigabitEthernet1/0/2")),
            ("\(ifDescr).48", s("GigabitEthernet1/0/48")),
            ("\(ifName).2", s("Gi1/0/2")),
            ("\(ifName).48", s("Gi1/0/48")),
            ("\(ifAlias).2", s("")),
            ("\(ifAlias).48", s("Uplink to core")),
            ("1.3.6.1.2.1.1.5.0", s("edge-sw1")),
        ]
    }

    // MARK: - LLDP

    func test_lldp_parsesNeighborsPortsAndAddresses() async throws {
        let r = try await SNMPNeighbors.query(FakeSNMPAgent(lldpMIB()).client(), maxRows: 1000)
        XCTAssertEqual(r.neighbors.count, 2)
        XCTAssertTrue(r.lldpShared)
        XCTAssertNil(r.note)
        guard r.neighbors.count == 2 else { return }

        // Sorted by local port: Gi1/0/2 before Gi1/0/48.
        let phone = r.neighbors[0], core = r.neighbors[1]

        XCTAssertEqual(core.localPort, "Gi1/0/48")
        XCTAssertEqual(core.ifIndex, 48)                         // lldpLocPortId matched ifName
        XCTAssertEqual(core.localPortLabel, "Uplink to core")
        XCTAssertEqual(core.name, "core-sw2.example.com")
        XCTAssertEqual(core.chassisId, "00:11:22:33:44:55")
        XCTAssertEqual(core.remotePort, "Te1/1/1")
        XCTAssertEqual(core.remotePortDetail, "TenGigabitEthernet1/1/1")
        XCTAssertEqual(core.kind, .networkSwitch)
        XCTAssertEqual(core.capabilities, ["Bridge", "Router"])
        XCTAssertEqual(core.address, "10.0.0.2")
        XCTAssertEqual(core.macs, [coreMAC])
        XCTAssertEqual(core.sources, [.lldp])

        XCTAssertEqual(phone.localPort, "Gi1/0/2")               // no lldpLocPortTable row: ifName.2
        XCTAssertEqual(phone.ifIndex, 2)
        XCTAssertNil(phone.localPortLabel)                       // empty ifAlias
        XCTAssertNil(phone.sysName)
        XCTAssertEqual(phone.name, "10.0.0.50")                  // chassis ID: an IPv4 network address
        XCTAssertEqual(phone.remotePort, "eth0")                 // MAC port IDs read better as the description
        XCTAssertEqual(phone.remotePortDetail, "aa:bb:cc:00:00:01")
        XCTAssertEqual(phone.kind, .phone)
        XCTAssertEqual(phone.address, "10.0.0.51")               // management address beats the chassis IP
        XCTAssertEqual(phone.macs, [phoneMAC])

        let text = SNMPNeighbors.exportText(r)
        XCTAssertTrue(text.contains("Gi1/0/48\tUplink to core\tcore-sw2.example.com\tTe1/1/1\tSwitch\t10.0.0.2"))
        XCTAssertEqual(SNMPNeighbors.summary(r), "2 neighbors found")
    }

    func test_lldp_v1_walksWithGetNext() async throws {
        let a = FakeSNMPAgent(lldpMIB()); a.v1 = true
        let r = try await SNMPNeighbors.query(a.client(version: .v1), maxRows: 1000)
        XCTAssertEqual(r.neighbors.map(\.localPort), ["Gi1/0/2", "Gi1/0/48"])
        XCTAssertEqual(r.neighbors.map(\.address), ["10.0.0.51", "10.0.0.2"])
        XCTAssertEqual(a.bulkCount, 0)
    }

    func test_lldp_capabilityBits() {
        func caps(_ bytes: [UInt8]) -> (labels: [String], kind: SNMPNeighborKind)? {
            SNMPNeighbors.lldpCapabilities(.octetString(Data(bytes)))
        }
        // First octet, most significant bit first: other(0) repeater(1) bridge(2)
        // wlanAccessPoint(3) router(4) telephone(5) docsisCableDevice(6) station(7)
        XCTAssertEqual(caps([0x20])?.kind, .networkSwitch)
        XCTAssertEqual(caps([0x28, 0x00])?.kind, .networkSwitch)          // L3 switch
        XCTAssertEqual(caps([0x08])?.kind, .router)
        XCTAssertEqual(caps([0x30])?.kind, .accessPoint)                  // bridge + AP
        XCTAssertEqual(caps([0x24])?.kind, .phone)                        // bridge + phone
        XCTAssertEqual(caps([0x01])?.kind, .station)
        XCTAssertEqual(caps([0x02])?.kind, .cableModem)
        XCTAssertEqual(caps([0x80])?.kind, .other)
        XCTAssertEqual(caps([0x00])?.kind, .unknown)
        XCTAssertEqual(caps([0xff])?.labels, ["Other", "Repeater", "Bridge", "Access point",
                                              "Router", "Phone", "Cable modem", "Station"])
        XCTAssertNil(caps([]))
        XCTAssertNil(SNMPNeighbors.lldpCapabilities(nil))
    }

    func test_lldp_managementAddressIndex() {
        // timeMark, localPortNum, remIndex, subtype, length, address
        XCTAssertEqual(SNMPNeighbors.managementAddress([0, 5, 2, 1, 4, 192, 168, 1, 2])?.ipv4, "192.168.1.2")
        XCTAssertEqual(SNMPNeighbors.managementAddress([0, 5, 2, 1, 4, 192, 168, 1, 2])?.key, [5, 2])
        XCTAssertEqual(SNMPNeighbors.managementAddress([7, 5, 2, 1, 192, 168, 1, 2])?.ipv4, "192.168.1.2")  // no length
        XCTAssertNil(SNMPNeighbors.managementAddress([0, 5, 2, 2, 16, 254, 128, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]))
        XCTAssertNil(SNMPNeighbors.managementAddress([0, 5, 2, 1, 4, 192, 168]))         // too short
        XCTAssertNil(SNMPNeighbors.managementAddress([0, 5, 2, 1, 4, 300, 168, 1, 2]))   // not an octet
        XCTAssertNil(SNMPNeighbors.managementAddress([]))
    }

    func test_lldp_idFormatting() {
        XCTAssertEqual(SNMPNeighbors.formatID(b(coreMAC), subtype: 4, macSubtype: 4, addressSubtype: 5)?.text,
                       "00:11:22:33:44:55")
        XCTAssertEqual(SNMPNeighbors.formatID(b([1, 10, 1, 2, 3]), subtype: 5, macSubtype: 4, addressSubtype: 5)?.ipv4,
                       "10.1.2.3")
        XCTAssertEqual(SNMPNeighbors.formatID(s("ge-0/0/1"), subtype: 7, macSubtype: 3, addressSubtype: 4)?.text,
                       "ge-0/0/1")
        // A binary 6-byte "local" ID is still shown as a MAC.
        XCTAssertEqual(SNMPNeighbors.formatID(b(phoneMAC), subtype: 7, macSubtype: 3, addressSubtype: 4)?.mac, phoneMAC)
        XCTAssertNil(SNMPNeighbors.formatID(b([]), subtype: 4, macSubtype: 4, addressSubtype: 5))
    }

    // MARK: - CDP

    private func cdpMIB() -> [(String, SNMPValue)] {
        [
            ("\(cdp).3.10101.1", .integer(1)),
            ("\(cdp).4.10101.1", b([10, 0, 0, 9])),
            ("\(cdp).6.10101.1", s("dist-sw1(FOC1234X0YZ)")),
            ("\(cdp).7.10101.1", s("GigabitEthernet1/0/24")),
            ("\(cdp).8.10101.1", s("cisco WS-C3850-48P")),
            ("\(cdp).9.10101.1", b([0, 0, 0, 0x29])),        // router + switch + IGMP
            ("\(cdp).3.10102.4", .integer(1)),
            ("\(cdp).4.10102.4", b([10, 0, 0, 77])),
            ("\(cdp).6.10102.4", s("SEP001122334455")),
            ("\(cdp).7.10102.4", s("Port 1")),
            ("\(cdp).8.10102.4", s("Cisco IP Phone 8845")),
            ("\(cdp).9.10102.4", b([0, 0, 0, 0x90])),        // host + phone
            ("\(ifDescr).10101", s("GigabitEthernet1/0/1")),
            ("\(ifDescr).10102", s("GigabitEthernet1/0/2")),
            ("\(ifName).10101", s("Gi1/0/1")),
            ("\(ifName).10102", s("Gi1/0/2")),
        ]
    }

    func test_cdp_parse() async throws {
        let r = try await SNMPNeighbors.query(FakeSNMPAgent(cdpMIB()).client(), maxRows: 1000)
        XCTAssertTrue(r.cdpShared)
        XCTAssertFalse(r.lldpShared)
        XCTAssertEqual(r.neighbors.count, 2)
        guard r.neighbors.count == 2 else { return }
        let sw = r.neighbors[0], phone = r.neighbors[1]
        XCTAssertEqual(sw.localPort, "Gi1/0/1")
        XCTAssertEqual(sw.ifIndex, 10101)
        XCTAssertEqual(sw.name, "dist-sw1(FOC1234X0YZ)")
        XCTAssertEqual(sw.remotePort, "GigabitEthernet1/0/24")
        XCTAssertEqual(sw.platform, "cisco WS-C3850-48P")
        XCTAssertEqual(sw.address, "10.0.0.9")
        XCTAssertEqual(sw.kind, .networkSwitch)
        XCTAssertEqual(sw.capabilities, ["Router", "Switch", "IGMP"])
        XCTAssertEqual(sw.sources, [.cdp])
        XCTAssertEqual(phone.localPort, "Gi1/0/2")
        XCTAssertEqual(phone.kind, .phone)
        XCTAssertEqual(phone.capabilities, ["Host", "Phone"])
        XCTAssertEqual(phone.address, "10.0.0.77")
    }

    func test_cdp_capabilityBits() {
        func kind(_ bytes: [UInt8]) -> SNMPNeighborKind? {
            SNMPNeighbors.cdpCapabilities(.octetString(Data(bytes)))?.kind
        }
        XCTAssertEqual(kind([0, 0, 0, 0x01]), .router)
        XCTAssertEqual(kind([0, 0, 0, 0x02]), .bridge)
        XCTAssertEqual(kind([0, 0, 0, 0x03]), .bridge)          // router + transparent bridge: a Cisco AP
        XCTAssertEqual(kind([0, 0, 0, 0x04]), .bridge)          // source-route bridge alone
        XCTAssertEqual(kind([0, 0, 0, 0x05]), .router)          // router + source-route bridge: a router
        XCTAssertEqual(kind([0, 0, 0, 0x0a]), .networkSwitch)
        XCTAssertEqual(kind([0, 0, 0, 0x10]), .station)
        XCTAssertEqual(kind([0, 0, 0, 0x98]), .phone)
        XCTAssertEqual(kind([0x29]), .networkSwitch)            // a short string still reads as a number
        XCTAssertNil(kind([]))
    }

    // MARK: - Merging

    func test_merge_sameNeighborOnSamePort_keepsLLDPAddsPlatform() async throws {
        var mib = lldpMIB()
        mib += [
            // The core switch again, over CDP, on ifIndex 48 (Gi1/0/48)
            ("\(cdp).3.48.1", .integer(1)),
            ("\(cdp).4.48.1", b([10, 0, 0, 2])),
            ("\(cdp).6.48.1", s("core-sw2")),
            ("\(cdp).7.48.1", s("TenGigabitEthernet1/1/1")),
            ("\(cdp).8.48.1", s("cisco C9300-48P")),
            ("\(cdp).9.48.1", b([0, 0, 0, 0x28])),
            // A different device on ifIndex 2, where LLDP saw the phone
            ("\(cdp).3.2.7", .integer(1)),
            ("\(cdp).4.2.7", b([10, 0, 0, 60])),
            ("\(cdp).6.2.7", s("lab-ap")),
            ("\(cdp).8.2.7", s("cisco AIR-AP2802I")),
            ("\(cdp).9.2.7", b([0, 0, 0, 0x03])),
        ]
        let r = try await SNMPNeighbors.query(FakeSNMPAgent(mib).client(), maxRows: 1000)
        XCTAssertEqual(r.neighbors.count, 3)
        let core = r.neighbors.first { $0.localPort == "Gi1/0/48" }
        XCTAssertEqual(core?.sources, [.lldp, .cdp])
        XCTAssertEqual(core?.name, "core-sw2.example.com")      // LLDP's name wins
        XCTAssertEqual(core?.remotePort, "Te1/1/1")             // LLDP's port wins
        XCTAssertEqual(core?.platform, "cisco C9300-48P")       // CDP adds the platform
        XCTAssertEqual(core?.capabilities, ["Bridge", "Router"])
        XCTAssertEqual(r.neighbors.filter { $0.localPort == "Gi1/0/2" }.count, 2)
        XCTAssertEqual(r.portCount, 2)
    }

    func test_deviceKey_matchesNameForms() {
        XCTAssertEqual(SNMPNeighbors.deviceKey("Core-SW2.example.com"), "core-sw2")
        XCTAssertEqual(SNMPNeighbors.deviceKey("core-sw2(FOC1234X0YZ)"), "core-sw2")
        XCTAssertEqual(SNMPNeighbors.deviceKey("core-sw2"), "core-sw2")
        XCTAssertEqual(SNMPNeighbors.deviceKey("10.0.0.5"), "10.0.0.5")
    }

    // MARK: - Empty states

    func test_neighbors_empty_saysWhetherLLDPIsShared() async throws {
        let withLLDP = FakeSNMPAgent([
            ("1.0.8802.1.1.2.1.3.2.0", b(coreMAC)),         // lldpLocChassisId
            ("1.3.6.1.2.1.1.5.0", s("edge-sw1")),
        ])
        let r1 = try await SNMPNeighbors.query(withLLDP.client(), maxRows: 1000)
        XCTAssertTrue(r1.neighbors.isEmpty)
        XCTAssertTrue(r1.lldpShared)
        XCTAssertFalse(r1.cdpShared)
        XCTAssertTrue(SNMPNeighbors.emptyDetail(r1).contains("shares LLDP over SNMP"))
        XCTAssertEqual(SNMPNeighbors.summary(r1), "No neighbors reported")

        let plain = FakeSNMPAgent([("1.3.6.1.2.1.1.5.0", s("home-router"))])
        plain.v1 = true
        let r2 = try await SNMPNeighbors.query(plain.client(version: .v1), maxRows: 1000)
        XCTAssertTrue(r2.neighbors.isEmpty)
        XCTAssertFalse(r2.lldpShared)
        XCTAssertFalse(r2.cdpShared)
        XCTAssertTrue(SNMPNeighbors.emptyDetail(r2).contains("common on home and small-office gear"))
    }

    func test_neighbors_rowLimitIsNoted() async throws {
        let r = try await SNMPNeighbors.query(FakeSNMPAgent(lldpMIB()).client(), maxRows: 1)
        XCTAssertEqual(r.note, .limit(1))
    }

    // MARK: - MAC addresses

    func test_macParsingAndFormatting() {
        let expected: [UInt8] = [0x00, 0x1a, 0x2b, 0x03, 0x04, 0x05]
        for text in ["00:1a:2b:03:04:05", "00-1A-2B-03-04-05", "001a.2b03.0405", "001A2B030405",
                     "0:1a:2b:3:4:5", " 00:1a:2b:03:04:05\n"] {
            XCTAssertEqual(SNMPWhereIs.parseMAC(text), expected, text)
            XCTAssertEqual(SNMPLocateQuery.parse(text), .mac(expected), text)
        }
        for bad in ["", "00:1a:2b:03:04", "00:1a:2b:03:04:05:06", "001:a:2b:3:4:5", "zz:1a:2b:03:04:05",
                    "00:1a:2b:03:04:5g", "00::1a:2b:03:04"] {
            XCTAssertNil(SNMPWhereIs.parseMAC(bad), bad)
        }
        XCTAssertEqual(SNMPWhereIs.formatMAC(expected), "00:1a:2b:03:04:05")
        XCTAssertEqual(SNMPLocateQuery.mac(expected).display, "00:1a:2b:03:04:05")
        XCTAssertTrue(SNMPWhereIs.isLocallyAdministered([0x3a, 0, 0, 0, 0, 1]))     // private Wi-Fi address
        XCTAssertFalse(SNMPWhereIs.isLocallyAdministered(expected))
        XCTAssertTrue(SNMPWhereIs.isMulticast([0x01, 0x00, 0x5e, 0, 0, 1]))
    }

    func test_locateQuery_parsesIPv4() {
        XCTAssertEqual(SNMPLocateQuery.parse("192.168.1.20"), .ip("192.168.1.20"))
        XCTAssertEqual(SNMPLocateQuery.parse("010.000.001.020"), .ip("10.0.1.20"))
        XCTAssertNil(SNMPLocateQuery.parse("192.168.1.256"))
        XCTAssertNil(SNMPLocateQuery.parse("192.168.1"))
        XCTAssertNil(SNMPLocateQuery.parse("printer.local"))
    }

    // MARK: - ARP index decoding

    func test_arpIndexes() {
        // ipNetToPhysicalTable: ifIndex, type 1 (IPv4), length 4, address
        XCTAssertEqual(SNMPWhereIs.physicalIndex([3, 1, 4, 192, 168, 1, 20])?.ip, "192.168.1.20")
        XCTAssertEqual(SNMPWhereIs.physicalIndex([3, 1, 4, 192, 168, 1, 20])?.ifIndex, 3)
        XCTAssertEqual(SNMPWhereIs.physicalIndex([3, 1, 192, 168, 1, 20])?.ip, "192.168.1.20")    // no length
        XCTAssertNil(SNMPWhereIs.physicalIndex([3, 2, 16, 254, 128, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]))
        XCTAssertNil(SNMPWhereIs.physicalIndex([3, 1, 4, 192, 168]))
        // ipNetToMediaTable: ifIndex.a.b.c.d
        XCTAssertEqual(SNMPWhereIs.mediaIndex([3, 10, 0, 0, 5])?.ip, "10.0.0.5")
        XCTAssertNil(SNMPWhereIs.mediaIndex([3, 10, 0, 0]))
        XCTAssertNil(SNMPWhereIs.mediaIndex([3, 10, 0, 0, 999]))
        XCTAssertNil(SNMPWhereIs.macValue(b([0, 0, 0, 0, 0, 0])))                    // unresolved
        XCTAssertNil(SNMPWhereIs.macValue(b([1, 2, 3])))
    }

    // MARK: - Where Is It: MAC table

    /// A switch that has `target` in BRIDGE-MIB on bridge port 14 = Gi1/0/14.
    private func bridgeSwitch(port: Int64 = 14, status: Int64 = 3) -> [(String, SNMPValue)] {
        [
            ("1.3.6.1.2.1.1.2.0", .oid(OID([1,3,6,1,4,1,11,2,3,7,11,1]))),
            ("1.3.6.1.2.1.1.5.0", s("edge-sw1")),
            ("\(fdbPort).\(dotted(target))", .integer(port)),
            ("\(fdbStatus).\(dotted(target))", .integer(status)),
            ("\(basePortIfIndex).14", .integer(10114)),
            ("\(ifDescr).10114", s("GigabitEthernet1/0/14")),
            ("\(ifName).10114", s("Gi1/0/14")),
            ("\(ifAlias).10114", s("Front desk")),
        ]
    }

    private func locate(_ mib: [(String, SNMPValue)], _ find: SNMPLocateQuery, maxRows: Int = 1000,
                        thisMac: [UInt8]? = nil) async throws -> SNMPLocateReport {
        try await SNMPWhereIs.query(FakeSNMPAgent(mib).client(), find: find, maxRows: maxRows,
                                    thisMac: { _ in thisMac })
    }

    func test_whereIs_bridgeMIB_directGet() async throws {
        let r = try await locate(bridgeSwitch(), .mac(target))
        XCTAssertEqual(r.table, .bridge)
        XCTAssertTrue(r.hasMACTable)
        XCTAssertEqual(r.entryStatus, 3)
        XCTAssertEqual(r.locations.count, 1)
        XCTAssertEqual(r.locations.first?.bridgePort, 14)
        XCTAssertEqual(r.locations.first?.ifIndex, 10114)
        XCTAssertEqual(r.locations.first?.portName, "Gi1/0/14")
        XCTAssertEqual(r.locations.first?.portLabel, "Front desk")
        XCTAssertNil(r.locations.first?.macsOnPort)            // no walk, no count
        let v = SNMPWhereIs.verdict(r)
        XCTAssertEqual(v.headline, "Found on Gi1/0/14 (Front desk)")
        XCTAssertEqual(v.tone, .found)
        XCTAssertNil(v.hop)
        XCTAssertEqual(SNMPWhereIs.summary(r), v.headline)
        let text = SNMPWhereIs.exportText(r)
        XCTAssertTrue(text.contains("ifIndex 10114, bridge port 14"))
        XCTAssertTrue(text.contains("BRIDGE-MIB"))
    }

    func test_whereIs_ownAddressAndUnknownPort() async throws {
        let own = try await locate(bridgeSwitch(status: 4), .mac(target))
        XCTAssertEqual(SNMPWhereIs.verdict(own).headline, "This is the switch's own address")
        let zero = try await locate(bridgeSwitch(port: 0), .mac(target))
        XCTAssertTrue(zero.noPortLearned)
        XCTAssertTrue(zero.locations.isEmpty)
        XCTAssertEqual(SNMPWhereIs.verdict(zero).headline, "In the MAC table, but not on a port")
    }

    /// No BRIDGE-MIB entry: the Q-BRIDGE table (fdbId, MAC) is walked.
    private func qBridgeSwitch(vlanTable: Bool = true) -> [(String, SNMPValue)] {
        var mib: [(String, SNMPValue)] = [
            ("1.3.6.1.2.1.1.5.0", s("access-sw3")),
            ("\(qFdbPort).1.\(dotted([0, 1, 2, 3, 4, 5]))", .integer(48)),
            ("\(qFdbPort).20.\(dotted([0, 1, 2, 3, 4, 6]))", .integer(48)),
            ("\(qFdbPort).20.\(dotted(target))", .integer(7)),
            ("\(qFdbStatus).20.\(dotted(target))", .integer(3)),
            ("\(basePortIfIndex).7", .integer(507)),
            ("\(ifDescr).507", s("ge-0/0/7")),
            ("\(ifName).507", s("ge-0/0/7")),
        ]
        if vlanTable {
            mib += [("\(vlanFdbId).0.1", .gauge32(1)), ("\(vlanFdbId).0.20", .gauge32(20))]
        }
        return mib
    }

    func test_whereIs_qBridgeWalk_withVLAN() async throws {
        let r = try await locate(qBridgeSwitch(), .mac(target))
        XCTAssertEqual(r.table, .qBridge)
        XCTAssertEqual(r.tableRowsRead, 3)
        XCTAssertFalse(r.tableLimitHit)
        XCTAssertEqual(r.entryStatus, 3)
        XCTAssertEqual(r.locations.first?.vlans, [20])
        XCTAssertEqual(r.locations.first?.ifIndex, 507)
        XCTAssertEqual(r.locations.first?.macsOnPort, 1)
        XCTAssertEqual(SNMPWhereIs.verdict(r).headline, "Found on ge-0/0/7, VLAN 20")
    }

    func test_whereIs_qBridgeWalk_withoutVLANTable_hedgesTheVLAN() async throws {
        let r = try await locate(qBridgeSwitch(vlanTable: false), .mac(target))
        XCTAssertEqual(r.locations.first?.vlans, [])
        XCTAssertEqual(r.locations.first?.fdbIds, [20])
        XCTAssertEqual(SNMPWhereIs.verdict(r).headline, "Found on ge-0/0/7")
        let fdb = SNMPWhereIs.details(r).first { $0.label == "Forwarding database" }
        XCTAssertEqual(fdb?.value, "20 (usually the VLAN ID)")
    }

    func test_whereIs_qBridgeWalkCutShort_asksEachVLANDirectly() async throws {
        var mib: [(String, SNMPValue)] = (1...8).map { i in
            ("\(qFdbPort).1.\(dotted([0, 9, 9, 9, 9, UInt8(i)]))", .integer(Int64(i)))
        }
        mib += [
            ("\(qFdbPort).30.\(dotted(target))", .integer(5)),
            ("\(vlanFdbId).0.1", .gauge32(1)),
            ("\(vlanFdbId).0.30", .gauge32(30)),
            ("\(basePortIfIndex).5", .integer(5)),
            ("\(ifName).5", s("port5")),
        ]
        let r = try await locate(mib, .mac(target), maxRows: 4)
        XCTAssertTrue(r.tableLimitHit)
        XCTAssertEqual(r.tableRowsRead, 4)
        XCTAssertEqual(r.locations.first?.bridgePort, 5)
        XCTAssertEqual(r.locations.first?.vlans, [30])
        XCTAssertEqual(SNMPWhereIs.verdict(r).headline, "Found on port5, VLAN 30")
    }

    func test_whereIs_manyAddressesOnPort_meansUplink() async throws {
        var mib: [(String, SNMPValue)] = (1...5).map { i in
            ("\(qFdbPort).10.\(dotted([0, 9, 9, 9, 9, UInt8(i)]))", .integer(24))
        }
        mib += [
            ("\(qFdbPort).10.\(dotted(target))", .integer(24)),
            ("\(basePortIfIndex).24", .integer(24)),
            ("\(ifName).24", s("Gi0/24")),
        ]
        let r = try await locate(mib, .mac(target))
        XCTAssertEqual(r.locations.first?.macsOnPort, 6)
        let v = SNMPWhereIs.verdict(r)
        XCTAssertEqual(v.tone, .behind)
        XCTAssertTrue(v.detail.hasPrefix("6 addresses are learned on this port"))
        XCTAssertNil(v.hop)
    }

    /// A switch with a forwarding database per VLAN lists a router-on-a-stick
    /// once per VLAN. That's one address, not an uplink.
    func test_whereIs_oneMACInManyVLANs_countsOneAddress() async throws {
        var mib: [(String, SNMPValue)] = [("1.3.6.1.2.1.1.5.0", s("edge-sw1"))]
        for v in [1, 10, 20, 30, 40] {
            mib.append(("\(qFdbPort).\(v).\(dotted(target))", .integer(1)))
            mib.append(("\(vlanFdbId).0.\(v)", .gauge32(UInt32(v))))
        }
        mib += [("\(basePortIfIndex).1", .integer(1)), ("\(ifName).1", s("Gi1/0/1"))]
        let r = try await locate(mib, .mac(target))
        XCTAssertEqual(r.tableRowsRead, 5)
        XCTAssertEqual(r.locations.count, 1)
        XCTAssertEqual(r.locations.first?.vlans, [1, 10, 20, 30, 40])
        XCTAssertEqual(r.locations.first?.macsOnPort, 1)
        let v = SNMPWhereIs.verdict(r)
        XCTAssertEqual(v.tone, .found)
        XCTAssertFalse(v.detail.contains("addresses are learned"))
        XCTAssertEqual(SNMPWhereIs.details(r).first { $0.label == "Addresses on this port" }?.value, "1")
    }

    /// 100 VLANs of 2 addresses each, cut at 150 rows (VLANs 1 to 75). The
    /// direct lookups go to the cut-off database and the unread ones, not
    /// to the 74 databases the walk already read to the end.
    func test_whereIs_cutWalk_asksOnlyDatabasesItDidNotFinish() async throws {
        var mib: [(String, SNMPValue)] = []
        for f in 1...100 {
            for m in 1...2 {
                mib.append(("\(qFdbPort).\(f).\(dotted([0, 9, 9, 9, UInt8(f), UInt8(m)]))", .integer(Int64(m))))
            }
            mib.append(("\(vlanFdbId).0.\(f)", .gauge32(UInt32(f))))
        }
        mib += [
            ("\(qFdbPort).95.\(dotted(target))", .integer(7)),
            ("\(basePortIfIndex).7", .integer(7)),
            ("\(ifName).7", s("port7")),
        ]
        let r = try await locate(mib, .mac(target), maxRows: 150)
        XCTAssertTrue(r.tableLimitHit)
        XCTAssertEqual(r.tableRowsRead, 150)
        XCTAssertEqual(r.locations.first?.bridgePort, 7)
        XCTAssertEqual(r.locations.first?.vlans, [95])
        XCTAssertEqual(SNMPWhereIs.verdict(r).headline, "Found on port7, VLAN 95")
    }

    func test_whereIs_directLookupOrder() {
        // Seen 1, 2, 3: the walk read 1 and 2 to the end and cut 3 off.
        // 5 and 6 are unread.
        XCTAssertEqual(SNMPWhereIs.directLookupFdbIds(seen: [1, 2, 3], known: [6, 1, 5, 2, 3], outOfOrder: false),
                       [3, 5, 6])
        XCTAssertEqual(SNMPWhereIs.directLookupFdbIds(seen: [1, 3], known: [1, 2, 3, 4], outOfOrder: false),
                       [3, 4])                                  // 2 was passed over
        XCTAssertEqual(SNMPWhereIs.directLookupFdbIds(seen: [7], known: [], outOfOrder: false), [7])
        XCTAssertEqual(SNMPWhereIs.directLookupFdbIds(seen: [], known: [20, 10], outOfOrder: false), [10, 20])
        // Out of order: the walk can't vouch for what it passed, so the rest
        // follow, unread ones first.
        XCTAssertEqual(SNMPWhereIs.directLookupFdbIds(seen: [1, 3], known: [1, 2, 3, 4], outOfOrder: true),
                       [3, 4, 2, 1])
    }

    /// 35 entries in database 1; the switch fails with genErr after 30 (the
    /// first GETBULK reply). The target is past that point.
    private func qBridgeRows(withTarget: Bool) -> [(String, SNMPValue)] {
        var mib: [(String, SNMPValue)] = [("1.3.6.1.2.1.1.5.0", s("access-sw3"))]
        mib += (1...35).map { i in ("\(qFdbPort).1.\(dotted([0, 9, 9, 9, 9, UInt8(i)]))", .integer(2)) }
        if withTarget {
            mib += [
                ("\(qFdbPort).1.\(dotted(target))", .integer(5)),
                ("\(basePortIfIndex).5", .integer(5)),
                ("\(ifName).5", s("port5")),
            ]
        }
        return mib
    }

    private func qBridgeRow(_ i: UInt8) -> OID? { OID(string: "\(qFdbPort).1.\(dotted([0, 9, 9, 9, 9, i]))") }

    func test_whereIs_qBridgeWalkErrorPartway_stillAsksDirectly() async throws {
        let a = FakeSNMPAgent(qBridgeRows(withTarget: true))
        a.failFrom = qBridgeRow(30)
        let r = try await SNMPWhereIs.query(a.client(), find: .mac(target), maxRows: 1000, thisMac: { _ in nil })
        XCTAssertEqual(r.tableEnd, .error(5, "genErr"))
        XCTAssertTrue(r.tableCut)
        XCTAssertFalse(r.tableLimitHit)
        XCTAssertEqual(r.tableRowsRead, 30)
        XCTAssertEqual(r.locations.first?.bridgePort, 5)
        XCTAssertEqual(SNMPWhereIs.verdict(r).headline, "Found on port5")
    }

    func test_whereIs_qBridgeWalkStoppedEarly_saysWhy() async throws {
        let failing = FakeSNMPAgent(qBridgeRows(withTarget: false))
        failing.failFrom = qBridgeRow(30)
        let r1 = try await SNMPWhereIs.query(failing.client(), find: .mac(target), maxRows: 1000, thisMac: { _ in nil })
        XCTAssertEqual(r1.tableEnd, .error(5, "genErr"))
        let v1 = SNMPWhereIs.verdict(r1)
        XCTAssertEqual(v1.headline, "Not in the part of the MAC table SNAP read")
        XCTAssertTrue(v1.detail.contains("returned an error (genErr) after 30 entries"), v1.detail)
        XCTAssertFalse(v1.detail.contains("row limit"))
        XCTAssertEqual(SNMPWhereIs.details(r1).first { $0.label == "MAC table" }?.value,
                       "Q-BRIDGE-MIB (dot1qTpFdbTable), first 30 entries read")

        let looping = FakeSNMPAgent(qBridgeRows(withTarget: false))
        looping.stuckAt = qBridgeRow(5)
        let r2 = try await SNMPWhereIs.query(looping.client(), find: .mac(target), maxRows: 1000, thisMac: { _ in nil })
        XCTAssertEqual(r2.tableEnd, .notIncreasing)
        XCTAssertEqual(r2.tableRowsRead, 5)
        let v2 = SNMPWhereIs.verdict(r2)
        XCTAssertEqual(v2.headline, "Not in the part of the MAC table SNAP read")
        XCTAssertTrue(v2.detail.contains("out of order"), v2.detail)
        XCTAssertFalse(v2.detail.contains("row limit"))
        for t in [SNMPWhereIs.exportText(r1), SNMPWhereIs.exportText(r2)] {
            XCTAssertFalse(t.contains("\u{2014}") || t.contains("\u{2013}"), t)
        }
    }

    // MARK: - Where Is It: uplinks

    /// The target is learned on Gi1/0/48, where LLDP sees core-sw2.
    private func uplinkSwitch(neighborMAC: [UInt8], namedLocalPort: Bool = true) -> [(String, SNMPValue)] {
        var mib: [(String, SNMPValue)] = [
            ("1.3.6.1.2.1.1.5.0", s("edge-sw1")),
            ("\(fdbPort).\(dotted(target))", .integer(48)),
            ("\(fdbStatus).\(dotted(target))", .integer(3)),
            ("\(basePortIfIndex).48", .integer(10048)),
            ("\(ifName).10048", s("Gi1/0/48")),
            ("\(ifDescr).10048", s("GigabitEthernet1/0/48")),
            ("\(rem).4.0.48.1", .integer(4)),
            ("\(rem).5.0.48.1", b(neighborMAC)),
            ("\(rem).6.0.48.1", .integer(5)),
            ("\(rem).7.0.48.1", s("Te1/1/1")),
            ("\(rem).9.0.48.1", s("core-sw2")),
            ("\(rem).12.0.48.1", b([0x20, 0x00])),
            ("\(man).3.0.48.1.1.4.10.0.0.2", .integer(2)),
        ]
        if namedLocalPort {
            mib += [("\(loc).2.48", .integer(5)), ("\(loc).3.48", s("Gi1/0/48"))]
        }
        return mib
    }

    func test_whereIs_uplinkToAnotherSwitch_offersHop() async throws {
        let r = try await locate(uplinkSwitch(neighborMAC: coreMAC), .mac(target))
        XCTAssertEqual(r.locations.first?.neighbors.map(\.name), ["core-sw2"])
        let v = SNMPWhereIs.verdict(r)
        XCTAssertEqual(v.tone, .behind)
        XCTAssertEqual(v.headline, "Found on Gi1/0/48, the link to core-sw2")
        XCTAssertTrue(v.detail.contains("further down that link"))
        XCTAssertEqual(v.hop?.address, "10.0.0.2")
        XCTAssertTrue(SNMPWhereIs.exportText(r).contains("Next: query core-sw2 at 10.0.0.2"))
    }

    /// No lldpLocPortTable: LLDP-MIB says a bridge numbers LLDP ports like its
    /// bridge ports, so LLDP port 48 is bridge port 48 (ifIndex 10048).
    func test_whereIs_lldpPortNumberAsBridgePort() async throws {
        let r = try await locate(uplinkSwitch(neighborMAC: coreMAC, namedLocalPort: false), .mac(target))
        XCTAssertEqual(r.locations.first?.neighbors.map(\.name), ["core-sw2"])
        XCTAssertEqual(SNMPWhereIs.verdict(r).hop?.address, "10.0.0.2")
    }

    func test_whereIs_targetIsTheNeighborItself() async throws {
        let r = try await locate(uplinkSwitch(neighborMAC: target), .mac(target))
        let v = SNMPWhereIs.verdict(r)
        XCTAssertEqual(v.headline, "Found on Gi1/0/48: it's core-sw2")
        XCTAssertEqual(v.tone, .found)
        XCTAssertNil(v.hop)
    }

    /// Cisco access points send CDP router + transparent bridge, which reads
    /// as a bridge: the verdict mustn't call one a switch.
    func test_whereIs_cdpBridgeNeighbor_isNotCalledASwitch() async throws {
        var mib = bridgeSwitch()
        mib += [
            ("\(cdp).3.10114.1", .integer(1)),
            ("\(cdp).4.10114.1", b([10, 0, 0, 60])),
            ("\(cdp).6.10114.1", s("lab-ap")),
            ("\(cdp).8.10114.1", s("cisco AIR-AP2802I")),
            ("\(cdp).9.10114.1", b([0, 0, 0, 0x03])),
        ]
        let r = try await locate(mib, .mac(target))
        XCTAssertEqual(r.locations.first?.neighbors.map(\.kind), [.bridge])
        let v = SNMPWhereIs.verdict(r)
        XCTAssertEqual(v.tone, .behind)
        XCTAssertTrue(v.detail.hasPrefix("lab-ap, a bridge (a switch or access point), is plugged into this port"), v.detail)
        XCTAssertFalse(v.detail.contains("a switch,"))
        XCTAssertEqual(v.hop?.address, "10.0.0.60")
    }

    /// Neighbors only sharpen the answer: a timeout reading them keeps the
    /// port found, and says the neighbors are missing. Stopping still stops.
    func test_whereIs_neighborReadFails_keepsThePort() async throws {
        let agent = FakeSNMPAgent(bridgeSwitch())
        let lldpMIBRoot = OID([1, 0, 8802])
        func client(failing: Error) -> SNMPClient {
            SNMPClient(host: "fake", version: .v2c, timeout: 1, retries: 0, transport: { m in
                if let o = m.varBinds.first?.oid, lldpMIBRoot.isAncestorOrEqual(o) { throw failing }
                return try agent.reply(m)
            })
        }
        let r = try await SNMPWhereIs.query(client(failing: SNMPError.timeout), find: .mac(target),
                                            maxRows: 1000, thisMac: { _ in nil })
        XCTAssertTrue(r.neighborsUnread)
        XCTAssertEqual(r.locations.first?.portName, "Gi1/0/14")
        let v = SNMPWhereIs.verdict(r)
        XCTAssertEqual(v.headline, "Found on Gi1/0/14 (Front desk)")
        XCTAssertTrue(v.notes.contains { $0.contains("couldn't read edge-sw1's LLDP and CDP neighbors") }, "\(v.notes)")

        do {
            _ = try await SNMPWhereIs.query(client(failing: CancellationError()), find: .mac(target),
                                            maxRows: 1000, thisMac: { _ in nil })
            XCTFail("A stopped run must not return a result")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    /// Many addresses with unreadable neighbors: don't claim nothing shared LLDP.
    func test_whereIs_manyAddresses_neighborsUnread_doesNotClaimNoLLDP() {
        var r = SNMPLocateReport(query: .mac(target))
        r.mac = target
        r.table = .qBridge
        r.hasMACTable = true
        r.neighborsUnread = true
        r.locations = [SNMPLocateReport.Location(bridgePort: 24, portName: "Gi0/24", macsOnPort: 9)]
        let v = SNMPWhereIs.verdict(r)
        XCTAssertEqual(v.tone, .behind)
        XCTAssertFalse(v.detail.contains("Nothing on it shared LLDP or CDP"))
        XCTAssertTrue(v.notes.contains { $0.contains("couldn't read") })
    }

    // MARK: - Where Is It: IP to MAC

    func test_whereIs_ipToMAC_viaDeviceARP() async throws {
        var mib = bridgeSwitch()
        mib += [
            ("1.3.6.1.2.1.4.35.1.4.3.1.4.192.168.1.20", b(target)),     // with the length
            ("1.3.6.1.2.1.4.35.1.4.3.1.192.168.1.21", b(coreMAC)),      // without it
        ]
        var askedThisMac = false
        let r = try await SNMPWhereIs.query(FakeSNMPAgent(mib).client(), find: .ip("192.168.1.20"), maxRows: 1000,
                                            thisMac: { _ in askedThisMac = true; return nil })
        XCTAssertFalse(askedThisMac)
        XCTAssertEqual(r.mac, target)
        XCTAssertEqual(r.macSource, .deviceARP)
        XCTAssertTrue(r.ipInDeviceARP)
        XCTAssertEqual(r.locations.first?.portName, "Gi1/0/14")

        let other = try await locate(mib, .ip("192.168.1.21"))
        XCTAssertEqual(other.mac, coreMAC)
    }

    func test_whereIs_ipToMAC_viaOlderARPTable() async throws {
        var mib = bridgeSwitch()
        mib.append(("1.3.6.1.2.1.4.22.1.2.3.192.168.1.20", b(target)))
        let r = try await locate(mib, .ip("192.168.1.20"))
        XCTAssertEqual(r.mac, target)
        XCTAssertEqual(r.macSource, .deviceARP)
    }

    func test_whereIs_ipToMAC_viaThisMac() async throws {
        let r = try await locate(bridgeSwitch(), .ip("192.168.1.20"), thisMac: target)
        XCTAssertEqual(r.macSource, .thisMac)
        XCTAssertFalse(r.ipInDeviceARP)
        XCTAssertEqual(SNMPWhereIs.verdict(r).headline, "Found on Gi1/0/14 (Front desk)")
    }

    func test_whereIs_ipWithNoMAC_suggestsPing() async throws {
        let r = try await locate(bridgeSwitch(), .ip("192.168.1.99"))
        XCTAssertNil(r.mac)
        let v = SNMPWhereIs.verdict(r)
        XCTAssertEqual(v.headline, "No MAC address found for 192.168.1.99")
        XCTAssertEqual(v.pingAddress, "192.168.1.99")
        XCTAssertEqual(v.tone, .missing)
        XCTAssertTrue(v.detail.hasPrefix("Neither edge-sw1's ARP table nor this Mac's has 192.168.1.99"))
    }

    private let physARP = "1.3.6.1.2.1.4.35.1.4"

    /// ipNetToPhysicalTable with 35 IPv4 rows (192.168.1.1 to .35).
    private func physRows() -> [(String, SNMPValue)] {
        (1...35).map { i in ("\(physARP).3.1.4.192.168.1.\(i)", b(coreMAC)) }
    }

    /// The newer ARP table fails partway, so the older one is still read.
    func test_whereIs_arpReadStoppedEarly_readsOlderTable() async throws {
        var mib = bridgeSwitch() + physRows()
        mib.append(("\(physARP).3.1.4.192.168.1.200", b(target)))
        mib.append(("1.3.6.1.2.1.4.22.1.2.3.192.168.1.200", b(target)))
        let a = FakeSNMPAgent(mib)
        a.failFrom = OID(string: "\(physARP).3.1.4.192.168.1.30")
        let r = try await SNMPWhereIs.query(a.client(), find: .ip("192.168.1.200"), maxRows: 1000, thisMac: { _ in nil })
        XCTAssertEqual(r.mac, target)
        XCTAssertEqual(r.macSource, .deviceARP)
        XCTAssertEqual(r.locations.first?.portName, "Gi1/0/14")
    }

    /// The IP isn't in the part of the ARP table SNAP read, and there's no
    /// older table: say the read was partial, and why, without blaming the
    /// row limit.
    func test_whereIs_arpReadStoppedEarly_saysWhy() async throws {
        let failing = FakeSNMPAgent(bridgeSwitch() + physRows())
        failing.failFrom = OID(string: "\(physARP).3.1.4.192.168.1.30")
        let r1 = try await SNMPWhereIs.query(failing.client(), find: .ip("192.168.1.250"), maxRows: 1000,
                                             thisMac: { _ in nil })
        XCTAssertNil(r1.mac)
        XCTAssertEqual(r1.arpEnd, .error(5, "genErr"))
        XCTAssertFalse(r1.arpLimitHit)
        let v1 = SNMPWhereIs.verdict(r1)
        XCTAssertTrue(v1.notes.contains { $0.contains("ARP table: the device returned an error (genErr) partway through") },
                      "\(v1.notes)")
        XCTAssertFalse(v1.notes.contains { $0.contains("row limit") })
        XCTAssertFalse(v1.detail.hasPrefix("Neither"), v1.detail)
        XCTAssertTrue(v1.detail.contains("in the part of edge-sw1's ARP table it read"), v1.detail)

        let looping = FakeSNMPAgent(bridgeSwitch() + physRows())
        looping.stuckAt = OID(string: "\(physARP).3.1.4.192.168.1.5")
        let r2 = try await SNMPWhereIs.query(looping.client(), find: .ip("192.168.1.250"), maxRows: 1000,
                                             thisMac: { _ in nil })
        XCTAssertEqual(r2.arpEnd, .notIncreasing)
        let v2 = SNMPWhereIs.verdict(r2)
        XCTAssertTrue(v2.notes.contains { $0.contains("sent an entry out of order") }, "\(v2.notes)")
        XCTAssertFalse(v2.notes.contains { $0.contains("row limit") })

        // The row limit keeps its own wording.
        let r3 = try await locate(bridgeSwitch() + physRows(), .ip("192.168.1.250"), maxRows: 10)
        XCTAssertTrue(r3.arpLimitHit)
        XCTAssertTrue(SNMPWhereIs.verdict(r3).notes.contains { $0.contains("stopped at the row limit") })
    }

    // MARK: - Where Is It: not found

    func test_whereIs_routerWithARPButNoMACTable() async throws {
        let mib: [(String, SNMPValue)] = [
            ("1.3.6.1.2.1.1.5.0", s("gw")),
            ("1.3.6.1.2.1.4.22.1.2.2.10.0.0.5", b(target)),
        ]
        let r = try await locate(mib, .ip("10.0.0.5"))
        XCTAssertTrue(r.ipInDeviceARP)
        XCTAssertFalse(r.hasMACTable)
        let v = SNMPWhereIs.verdict(r)
        XCTAssertEqual(v.headline, "No MAC table on this device")
        XCTAssertTrue(v.detail.contains("may be a router rather than a switch"))
    }

    func test_whereIs_ciscoNotFound_explainsPerVLANTables() async throws {
        let mib: [(String, SNMPValue)] = [
            ("1.3.6.1.2.1.1.2.0", .oid(OID([1,3,6,1,4,1,9,1,1208]))),
            ("\(fdbPort).\(dotted(coreMAC))", .integer(3)),          // some other address
        ]
        let r = try await locate(mib, .mac(target))
        XCTAssertTrue(r.isCisco)
        XCTAssertTrue(r.hasMACTable)
        XCTAssertEqual(r.table, .bridge)
        let v = SNMPWhereIs.verdict(r)
        XCTAssertEqual(v.headline, "Not in this switch's MAC table")
        XCTAssertTrue(v.notes.contains { $0.contains("public@20") })
    }

    /// Cisco Business switches answer Q-BRIDGE for every VLAN: no per-VLAN note.
    func test_whereIs_ciscoQBridgeNotFound_skipsPerVLANNote() async throws {
        let mib: [(String, SNMPValue)] = [
            ("1.3.6.1.2.1.1.2.0", .oid(OID([1,3,6,1,4,1,9,6,1,94,48,5]))),
            ("\(qFdbPort).1.\(dotted(coreMAC))", .integer(3)),
            ("\(qFdbPort).20.\(dotted(phoneMAC))", .integer(4)),
        ]
        let r = try await locate(mib, .mac(target))
        XCTAssertTrue(r.isCisco)
        XCTAssertEqual(r.table, .qBridge)
        let v = SNMPWhereIs.verdict(r)
        XCTAssertEqual(v.headline, "Not in this switch's MAC table")
        XCTAssertFalse(v.notes.contains { $0.contains("public@20") }, "\(v.notes)")
    }

    /// Broadcast and multicast addresses set the locally administered bit
    /// too, but they aren't private addresses.
    func test_whereIs_groupAddressesAreNotCalledPrivate() async throws {
        let cases: [([UInt8], String, String)] = [
            ([0xff, 0xff, 0xff, 0xff, 0xff, 0xff], "None: the broadcast address", "is the broadcast address"),
            ([0x33, 0x33, 0x00, 0x00, 0x00, 0x01], "None: a multicast address", "is a multicast address"),
        ]
        for (mac, vendorPrefix, note) in cases {
            let r = try await locate([("1.3.6.1.2.1.1.5.0", s("sw"))], .mac(mac))
            XCTAssertNil(r.vendor)
            let vendor = SNMPWhereIs.details(r).first { $0.label == "Vendor" }?.value ?? ""
            XCTAssertTrue(vendor.hasPrefix(vendorPrefix), vendor)
            XCTAssertFalse(vendor.contains("private"), vendor)
            XCTAssertTrue(SNMPWhereIs.verdict(r).notes.contains { $0.contains(note) })
        }
    }

    func test_whereIs_privateAddressHasNoVendor() async throws {
        let priv: [UInt8] = [0x3a, 0x10, 0x20, 0x30, 0x40, 0x50]
        let r = try await locate([("1.3.6.1.2.1.1.5.0", s("sw"))], .mac(priv))
        XCTAssertNil(r.vendor)
        let vendor = SNMPWhereIs.details(r).first { $0.label == "Vendor" }?.value ?? ""
        XCTAssertTrue(vendor.hasPrefix("None: a private address"))
    }

    /// Copy everywhere must avoid em and en dashes.
    func test_copy_hasNoLongDashes() async throws {
        let reports = [
            try await locate(bridgeSwitch(), .mac(target)),
            try await locate(uplinkSwitch(neighborMAC: coreMAC), .mac(target)),
            try await locate([], .ip("10.1.1.1")),
            try await locate([], .mac(target)),
        ]
        for r in reports {
            let text = SNMPWhereIs.exportText(r)
            XCTAssertFalse(text.contains("\u{2014}") || text.contains("\u{2013}"), text)
        }
        let n = try await SNMPNeighbors.query(FakeSNMPAgent(lldpMIB()).client(), maxRows: 1000)
        let empty = try await SNMPNeighbors.query(FakeSNMPAgent([]).client(), maxRows: 1000)
        for t in [SNMPNeighbors.exportText(n), SNMPNeighbors.exportText(empty)] {
            XCTAssertFalse(t.contains("\u{2014}") || t.contains("\u{2013}"), t)
        }
    }
}
