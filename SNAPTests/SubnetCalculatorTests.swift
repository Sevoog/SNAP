// SubnetCalculatorTests.swift
// SNAP — Subnet calculator unit tests
// Created by Sevag Bardakjian
// Copyright © 2025 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only

import XCTest
@testable import SNAP

final class SubnetCalculatorTests: XCTestCase {

    // MARK: Standard /24

    func test_standard_slash24() throws {
        let info = try XCTUnwrap(SubnetCalculator.calculate(ip: "192.168.1.10", cidr: 24))
        XCTAssertEqual(info.networkAddress,   "192.168.1.0")
        XCTAssertEqual(info.broadcastAddress, "192.168.1.255")
        XCTAssertEqual(info.subnetMask,       "255.255.255.0")
        XCTAssertEqual(info.wildcardMask,     "0.0.0.255")
        XCTAssertEqual(info.firstHost,        "192.168.1.1")
        XCTAssertEqual(info.lastHost,         "192.168.1.254")
        XCTAssertEqual(info.totalHosts, 256)
        XCTAssertEqual(info.usableHosts, 254)
        XCTAssertTrue(info.isPrivate)
        XCTAssertEqual(info.ipClass, "C")
    }

    // MARK: Regression — /0 used to overflow (fixed in v1.1.0)

    func test_slash0_doesNotOverflow() throws {
        // /0 covers the entire IPv4 space. UInt32(0..0xFFFFFFFF) + 1 used to
        // wrap; widening to UInt64 fixed it. This test pins that fix.
        let info = try XCTUnwrap(SubnetCalculator.calculate(ip: "0.0.0.0", cidr: 0))
        XCTAssertEqual(info.networkAddress, "0.0.0.0")
        XCTAssertEqual(info.broadcastAddress, "255.255.255.255")
        XCTAssertEqual(info.subnetMask, "0.0.0.0")
        XCTAssertEqual(info.totalHosts, Int(UInt64(UInt32.max) + 1))
        XCTAssertEqual(info.usableHosts, Int(UInt64(UInt32.max) + 1) - 2)
    }

    // MARK: /32 — single host

    func test_slash32_singleHost() throws {
        let info = try XCTUnwrap(SubnetCalculator.calculate(ip: "10.20.30.40", cidr: 32))
        XCTAssertEqual(info.networkAddress, "10.20.30.40")
        XCTAssertEqual(info.broadcastAddress, "10.20.30.40")
        XCTAssertEqual(info.subnetMask, "255.255.255.255")
        XCTAssertEqual(info.totalHosts, 1)
        XCTAssertEqual(info.usableHosts, 1) // host route — the address itself
        XCTAssertEqual(info.firstHost, "10.20.30.40")
        XCTAssertEqual(info.lastHost,  "10.20.30.40")
    }

    // MARK: /31 — point-to-point (RFC 3021)

    func test_slash31_pointToPoint() throws {
        let info = try XCTUnwrap(SubnetCalculator.calculate(ip: "10.0.0.0", cidr: 31))
        XCTAssertEqual(info.networkAddress, "10.0.0.0")
        XCTAssertEqual(info.broadcastAddress, "10.0.0.1")
        XCTAssertEqual(info.totalHosts, 2)
        // RFC 3021: a /31 has no network/broadcast pair — both usable
        XCTAssertEqual(info.usableHosts, 2)
        XCTAssertEqual(info.firstHost, "10.0.0.0")
        XCTAssertEqual(info.lastHost,  "10.0.0.1")
    }

    // MARK: Regression — /32 at the address-space edges used to trap
    // (netInt + 1 overflowed at 255.255.255.255, bcastInt - 1 at 0.0.0.0)

    func test_slash32_atSpaceEdges_doesNotTrap() throws {
        let zero = try XCTUnwrap(SubnetCalculator.calculate(ip: "0.0.0.0", cidr: 32))
        XCTAssertEqual(zero.firstHost, "0.0.0.0")
        XCTAssertEqual(zero.lastHost,  "0.0.0.0")

        let max = try XCTUnwrap(SubnetCalculator.calculate(ip: "255.255.255.255", cidr: 32))
        XCTAssertEqual(max.firstHost, "255.255.255.255")
        XCTAssertEqual(max.lastHost,  "255.255.255.255")
    }

    // MARK: Class detection

    func test_classB_address() throws {
        let info = try XCTUnwrap(SubnetCalculator.calculate(ip: "172.16.5.10", cidr: 16))
        XCTAssertEqual(info.ipClass, "B")
        XCTAssertTrue(info.isPrivate)
    }

    func test_classA_public() throws {
        let info = try XCTUnwrap(SubnetCalculator.calculate(ip: "1.2.3.4", cidr: 8))
        XCTAssertEqual(info.ipClass, "A")
        XCTAssertFalse(info.isPrivate)
    }

    func test_multicast_classD() throws {
        let info = try XCTUnwrap(SubnetCalculator.calculate(ip: "224.0.0.1", cidr: 4))
        XCTAssertTrue(info.ipClass.hasPrefix("D"))
    }

    // MARK: Invalid inputs

    func test_invalid_cidrTooLarge() {
        XCTAssertNil(SubnetCalculator.calculate(ip: "10.0.0.1", cidr: 33))
    }

    func test_invalid_cidrNegative() {
        XCTAssertNil(SubnetCalculator.calculate(ip: "10.0.0.1", cidr: -1))
    }

    func test_invalid_ipOctetTooLarge() {
        XCTAssertNil(SubnetCalculator.calculate(ip: "256.0.0.1", cidr: 24))
    }

    func test_invalid_ipNotFourOctets() {
        XCTAssertNil(SubnetCalculator.calculate(ip: "10.0.1", cidr: 24))
    }

    func test_invalid_ipGarbage() {
        XCTAssertNil(SubnetCalculator.calculate(ip: "not.an.ip.addr", cidr: 24))
    }
}
