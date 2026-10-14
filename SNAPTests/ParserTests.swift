// ParserTests.swift
// SNAP — Tests for pure parsing / range helpers that back several tools.
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md
//
// These cover the kind of logic most likely to silently break on an OS
// update (CLI-output parsing) or off-by-one mistakes (CIDR math, channel
// sub-band boundaries).

import XCTest
@testable import SNAP

final class ParserTests: XCTestCase {

    // MARK: - ARP cache parsing (ARP Table)

    func test_parseARP_typicalLines() {
        let raw = """
        ? (192.168.1.1) at 8c:85:90:aa:bb:cc on en0 ifscope [ethernet]
        ? (192.168.1.42) at a4:b1:97:11:22:33 on en0 ifscope [ethernet]
        ? (192.168.1.99) at (incomplete) on en0 ifscope [ethernet]
        """
        let entries = ARPTableView.parseARP(raw, gateway: "192.168.1.1")
        // The (incomplete) entry is dropped.
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first?.ip, "192.168.1.1")
        XCTAssertEqual(entries.first?.mac, "8c:85:90:aa:bb:cc")
        XCTAssertTrue(entries.first?.isGateway ?? false)
        XCTAssertEqual(entries.first?.iface, "en0")
        XCTAssertFalse(entries.last?.isGateway ?? true)
    }

    func test_parseARP_sortsByNumericIP() {
        let raw = """
        ? (192.168.1.200) at aa:aa:aa:aa:aa:aa on en0 ifscope [ethernet]
        ? (192.168.1.20) at bb:bb:bb:bb:bb:bb on en0 ifscope [ethernet]
        ? (192.168.1.100) at cc:cc:cc:cc:cc:cc on en0 ifscope [ethernet]
        """
        let ips = ARPTableView.parseARP(raw, gateway: nil).map { $0.ip }
        XCTAssertEqual(ips, ["192.168.1.20", "192.168.1.100", "192.168.1.200"])
    }

    func test_parseARP_emptyInput() {
        XCTAssertTrue(ARPTableView.parseARP("", gateway: nil).isEmpty)
    }

    // MARK: - WiFi band / channel helpers

    func test_centerFreq_24GHz() {
        XCTAssertEqual(WiFiBand.twoGHz.centerFreq(1), 2412)
        XCTAssertEqual(WiFiBand.twoGHz.centerFreq(6), 2437)
        XCTAssertEqual(WiFiBand.twoGHz.centerFreq(11), 2462)
    }

    func test_centerFreq_5and6GHz() {
        XCTAssertEqual(WiFiBand.fiveGHz.centerFreq(36), 5180)
        XCTAssertEqual(WiFiBand.fiveGHz.centerFreq(149), 5745)
        XCTAssertEqual(WiFiBand.sixGHz.centerFreq(1), 5955)
    }

    func test_subBand_5GHz_DFSboundaries() {
        XCTAssertEqual(WiFiChannelInfo.subBand(.fiveGHz, 36).0, "U-NII-1")
        XCTAssertFalse(WiFiChannelInfo.subBand(.fiveGHz, 36).1)   // not DFS
        XCTAssertEqual(WiFiChannelInfo.subBand(.fiveGHz, 52).0, "U-NII-2A")
        XCTAssertTrue(WiFiChannelInfo.subBand(.fiveGHz, 52).1)    // DFS
        XCTAssertEqual(WiFiChannelInfo.subBand(.fiveGHz, 100).0, "U-NII-2C")
        XCTAssertTrue(WiFiChannelInfo.subBand(.fiveGHz, 100).1)   // DFS
        XCTAssertEqual(WiFiChannelInfo.subBand(.fiveGHz, 149).0, "U-NII-3")
        XCTAssertFalse(WiFiChannelInfo.subBand(.fiveGHz, 149).1)  // not DFS
    }

    func test_subBand_6GHz_neverDFS() {
        XCTAssertFalse(WiFiChannelInfo.subBand(.sixGHz, 37).1)
        XCTAssertFalse(WiFiChannelInfo.subBand(.sixGHz, 200).1)
    }
}
