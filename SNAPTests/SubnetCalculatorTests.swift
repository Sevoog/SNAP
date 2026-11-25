// SubnetCalculatorTests.swift
// SNAP — Subnet calculator unit tests
// Created by Sevag Bardakjian
// Copyright © 2025 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md

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

    // MARK: Strict parsing (1.5.10): compactMap used to drop the bad parts

    func test_parseIPv4_isStrict() {
        XCTAssertEqual(SubnetCalculator.parseIPv4("192.168.1.10"), 0xC0A8010A)
        XCTAssertEqual(SubnetCalculator.parseIPv4(" 10.0.0.1 "), 0x0A000001)
        for bad in ["1.2.x.3.4", "1..2.3.4", "1.2.3.4.", "1.2.3", "1.2.3.256", "1.2.3.-1", "1.2.3.4 5", "", "1234.1.1.1"] {
            XCTAssertNil(SubnetCalculator.parseIPv4(bad), bad)
        }
    }

    func test_prefixLength_validMasks() {
        XCTAssertEqual(SubnetCalculator.prefixLength(fromMask: "255.255.255.0"), 24)
        XCTAssertEqual(SubnetCalculator.prefixLength(fromMask: "255.255.240.0"), 20)
        XCTAssertEqual(SubnetCalculator.prefixLength(fromMask: "255.255.255.255"), 32)
        XCTAssertEqual(SubnetCalculator.prefixLength(fromMask: "0.0.0.0"), 0)
        XCTAssertEqual(SubnetCalculator.prefixLength(fromMask: "128.0.0.0"), 1)
    }

    func test_prefixLength_rejectsNonContiguousAndOutOfRange() {
        for bad in ["255.0.255.0", "255.255.0.255", "0.255.255.255", "255.255.255.1", "255.256.0.0", "255.255", "mask"] {
            XCTAssertNil(SubnetCalculator.prefixLength(fromMask: bad), bad)
        }
    }

    func test_evaluate_reportsWhichInputIsWrong() {
        XCTAssertEqual(errorOf(SubnetCalculator.evaluate(ip: "300.1.1.1", mask: nil, cidr: 24)), .invalidAddress)
        XCTAssertEqual(errorOf(SubnetCalculator.evaluate(ip: "", mask: nil, cidr: 24)), .invalidAddress)
        // A bad mask no longer falls back to the slider value
        XCTAssertEqual(errorOf(SubnetCalculator.evaluate(ip: "10.0.0.1", mask: "255.0.255.0", cidr: 24)), .invalidMask)
        XCTAssertEqual(errorOf(SubnetCalculator.evaluate(ip: "10.0.0.1", mask: "garbage", cidr: 24)), .invalidMask)
        if case .success(let s) = SubnetCalculator.evaluate(ip: "10.0.0.1", mask: "255.255.252.0", cidr: 24) {
            XCTAssertEqual(s.cidr, 22)
        } else {
            XCTFail("valid mask rejected")
        }
        if case .success(let s) = SubnetCalculator.evaluate(ip: "10.0.0.1", mask: nil, cidr: 16) {
            XCTAssertEqual(s.cidr, 16)
        } else {
            XCTFail("CIDR mode rejected")
        }
    }

    func test_errorMessages() {
        XCTAssertEqual(SubnetInputError.invalidAddress.message,
                       "Enter an IPv4 address such as 192.168.1.10. Each of the four numbers must be 0 to 255.")
        XCTAssertEqual(SubnetInputError.invalidMask.message,
                       "That isn't a valid subnet mask. Masks are a run of 255s followed by lower numbers, like 255.255.255.0.")
    }

    // MARK: Address type (1.5.10): special ranges used to read "Public"

    func test_addressType_specialRanges() throws {
        let cases: [(String, String)] = [
            ("10.1.2.3", "Private (RFC 1918)"),
            ("172.31.255.1", "Private (RFC 1918)"),
            ("192.168.0.1", "Private (RFC 1918)"),
            ("100.64.0.1", "Carrier-grade NAT (RFC 6598)"),
            ("100.127.255.254", "Carrier-grade NAT (RFC 6598)"),
            ("127.0.0.1", "Loopback"),
            ("169.254.10.20", "Link-local"),
            ("224.0.0.251", "Multicast"),
            ("239.255.255.250", "Multicast"),
            ("240.0.0.1", "Reserved"),
            ("255.255.255.255", "Broadcast"),
            ("0.1.2.3", "Reserved (this network)"),
            ("192.0.2.5", "Documentation (RFC 5737)"),
            ("198.51.100.5", "Documentation (RFC 5737)"),
            ("203.0.113.5", "Documentation (RFC 5737)"),
            ("198.18.0.1", "Benchmarking (RFC 2544)"),
            ("192.0.0.8", "Reserved (IETF protocol assignments)"),
            ("8.8.8.8", "Public"),
            ("100.128.0.1", "Public"),
            ("172.32.0.1", "Public"),
        ]
        for (ip, label) in cases {
            let info = try XCTUnwrap(SubnetCalculator.calculate(ip: ip, cidr: 24), ip)
            XCTAssertEqual(info.addressType, label, ip)
            XCTAssertEqual(info.isPrivate, label == "Private (RFC 1918)", ip)
        }
    }

    func test_addressType_followsTheAddressNotTheNetwork() throws {
        // 10.1.2.3/4 has network 0.0.0.0, but the address typed is private
        let info = try XCTUnwrap(SubnetCalculator.calculate(ip: "10.1.2.3", cidr: 4))
        XCTAssertEqual(info.addressType, "Private (RFC 1918)")
    }

    private func errorOf(_ r: Result<SubnetInfo, SubnetInputError>) -> SubnetInputError? {
        if case .failure(let e) = r { return e }
        return nil
    }
}
