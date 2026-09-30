// NetworkMapModelTests.swift
// SNAP — Network Map model unit tests
// Created by Sevag Bardakjian
// Copyright © 2025 Sevag Bardakjian. All rights reserved.

import XCTest
@testable import SNAP

final class NetworkMapModelTests: XCTestCase {

    // MARK: stripTrailing24

    func test_stripTrailing24_alreadyShort() {
        XCTAssertEqual(NetworkMapModel.stripTrailing24("192.168.1"), "192.168.1")
    }

    func test_stripTrailing24_dropsZeroAndCidr() {
        XCTAssertEqual(NetworkMapModel.stripTrailing24("192.168.1.0/24"), "192.168.1")
    }

    func test_stripTrailing24_dropsXSentinel() {
        XCTAssertEqual(NetworkMapModel.stripTrailing24("192.168.1.x"), "192.168.1")
    }

    func test_stripTrailing24_keepsThreeOctets() {
        // Already 3 octets — leave alone, don't slice down to 2.
        XCTAssertEqual(NetworkMapModel.stripTrailing24("10.0.10"), "10.0.10")
    }

    // MARK: parseSubnetPrefixes

    func test_parse_singleSubnet() {
        XCTAssertEqual(NetworkMapModel.parseSubnetPrefixes("192.168.1"), ["192.168.1"])
    }

    func test_parse_multipleSubnets() {
        XCTAssertEqual(
            NetworkMapModel.parseSubnetPrefixes("192.168.1, 10.0.10"),
            ["192.168.1", "10.0.10"]
        )
    }

    func test_parse_trimsWhitespace() {
        XCTAssertEqual(
            NetworkMapModel.parseSubnetPrefixes("  192.168.1   ,    10.0.10  "),
            ["192.168.1", "10.0.10"]
        )
    }

    func test_parse_acceptsCIDRForms() {
        XCTAssertEqual(
            NetworkMapModel.parseSubnetPrefixes("192.168.1.0/24, 10.0.20.0/24"),
            ["192.168.1", "10.0.20"]
        )
    }

    func test_parse_acceptsTrailingX() {
        XCTAssertEqual(
            NetworkMapModel.parseSubnetPrefixes("192.168.1.x, 10.0.30.x"),
            ["192.168.1", "10.0.30"]
        )
    }

    func test_parse_dropsEmptyEntries() {
        XCTAssertEqual(
            NetworkMapModel.parseSubnetPrefixes("192.168.1, , 10.0.10, "),
            ["192.168.1", "10.0.10"]
        )
    }

    func test_parse_emptyStringYieldsEmpty() {
        XCTAssertEqual(NetworkMapModel.parseSubnetPrefixes(""), [])
    }

    func test_parse_whitespaceOnlyYieldsEmpty() {
        XCTAssertEqual(NetworkMapModel.parseSubnetPrefixes("   ,  ,  "), [])
    }

    // MARK: ipNumeric

    func test_ipNumeric_correctness() {
        XCTAssertEqual(NetworkMapModel.ipNumeric("0.0.0.0"), 0)
        XCTAssertEqual(NetworkMapModel.ipNumeric("0.0.0.1"), 1)
        XCTAssertEqual(NetworkMapModel.ipNumeric("0.0.1.0"), 256)
        XCTAssertEqual(NetworkMapModel.ipNumeric("0.1.0.0"), 65_536)
        XCTAssertEqual(NetworkMapModel.ipNumeric("1.0.0.0"), 16_777_216)
        XCTAssertEqual(NetworkMapModel.ipNumeric("255.255.255.255"), UInt32.max)
    }

    func test_ipNumeric_garbageReturnsZero() {
        XCTAssertEqual(NetworkMapModel.ipNumeric("not.an.ip"), 0)
    }
}
