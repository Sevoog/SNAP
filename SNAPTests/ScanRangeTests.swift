// ScanRangeTests.swift
// SNAP — Tests for scan-range parsing shared by the Network Map and Bulk
// Discovery. Includes the cases formerly in NetworkMapModelTests
// (stripTrailing24 / parseSubnetPrefixes) and ParserTests (expandCIDR).
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md

import XCTest
@testable import SNAP

final class ScanRangeTests: XCTestCase {

    private func range(_ s: String, max: Int = NetworkMapModel.maxScanHosts) -> ScanRange? {
        try? ScanRange.parse(s, maxHosts: max).get()
    }

    private func failure(_ s: String, max: Int = NetworkMapModel.maxScanHosts) -> ScanRange.ParseError? {
        if case .failure(let e) = ScanRange.parse(s, maxHosts: max) { return e }
        return nil
    }

    // MARK: Classic /24 forms (formerly stripTrailing24 / parseSubnetPrefixes)

    func test_threeOctetShorthand_isDot1ToDot254() {
        let a = range("192.168.1")!.addresses()
        XCTAssertEqual(a.count, 254)
        XCTAssertEqual(a.first, "192.168.1.1")
        XCTAssertEqual(a.last, "192.168.1.254")
        XCTAssertEqual(range("10.0.10")!.addresses().first, "10.0.10.1")
    }

    func test_xAndStarSentinels() {
        XCTAssertEqual(range("192.168.1.x")!.addresses(), range("192.168.1")!.addresses())
        XCTAssertEqual(range("192.168.1.*")!.hostCount, 254)
        XCTAssertEqual(range("192.168.1.")!.hostCount, 254)          // trailing dot
    }

    func test_lists_trimmedAndEmptyEntriesDropped() {
        XCTAssertEqual(range("192.168.1, 10.0.10")!.hostCount, 508)
        XCTAssertEqual(range("  192.168.1   ,    10.0.10  ")!.hostCount, 508)
        XCTAssertEqual(range("192.168.1.0/24, 10.0.20.0/24")!.hostCount, 508)
        XCTAssertEqual(range("192.168.1.x, 10.0.30.x")!.hostCount, 508)
        XCTAssertEqual(range("192.168.1, , 10.0.10, ")!.hostCount, 508)
        XCTAssertEqual(range("192.168.1\n10.0.10")!.hostCount, 508)  // newline-separated
    }

    func test_emptyInput() {
        XCTAssertEqual(failure(""), .empty)
        XCTAssertEqual(failure("   ,  ,  "), .empty)
    }

    // MARK: CIDR (formerly expandCIDR)

    func test_cidr_slash24() {
        let a = range("192.168.1.0/24")!.addresses()
        XCTAssertEqual(a.count, 254)
        XCTAssertEqual(a.first, "192.168.1.1")
        XCTAssertEqual(a.last, "192.168.1.254")
    }

    func test_cidr_smallPrefixes() {
        XCTAssertEqual(range("10.0.0.0/30")!.addresses(), ["10.0.0.1", "10.0.0.2"])
        XCTAssertEqual(range("10.0.0.0/31")!.addresses(), ["10.0.0.0", "10.0.0.1"])   // RFC 3021
        XCTAssertEqual(range("8.8.8.8/32")!.addresses(), ["8.8.8.8"])
    }

    func test_cidr_ignoresHostBits() {
        let a = range("192.168.1.50/24")!.addresses()
        XCTAssertEqual(a.first, "192.168.1.1")
        XCTAssertEqual(a.count, 254)
    }

    /// The bug that prompted this: "10.0.0.0/16" used to scan only 10.0.0.1–254.
    func test_cidr_slash16_isTheWholeSixteen() {
        let r = range("10.0.0.0/16")!
        XCTAssertEqual(r.hostCount, 65_534)
        let a = r.addresses()
        XCTAssertEqual(a.first, "10.0.0.1")
        XCTAssertEqual(a.last, "10.0.255.254")
        XCTAssertEqual(range("10.0.0.0/22")!.hostCount, 1_022)
    }

    func test_invalidEntries() {
        XCTAssertEqual(failure("not-a-range"), .invalid(entry: "not-a-range"))
        XCTAssertEqual(failure("192.168.1.0/33"), .invalid(entry: "192.168.1.0/33"))
        XCTAssertEqual(failure("999.1.1.1/24"), .invalid(entry: "999.1.1.1/24"))
        XCTAssertEqual(failure("192.168.1.0, banana"), .invalid(entry: "banana"))
    }

    // MARK: Custom ranges

    func test_fullRange() {
        let r = range("10.0.0.50-10.0.3.200")!
        XCTAssertEqual(r.hostCount, 919)        // (3×256 + 200) − 50 + 1
        XCTAssertEqual(r.addresses().first, "10.0.0.50")
        XCTAssertEqual(r.addresses().last, "10.0.3.200")
    }

    func test_lastOctetShorthand_andDashVariants() {
        XCTAssertEqual(range("192.168.1.100-150")!.hostCount, 51)
        XCTAssertEqual(range("192.168.1.100–150")!.hostCount, 51)      // en dash
        XCTAssertEqual(range("192.168.1.100 - 150")!.hostCount, 51)    // spaces
        XCTAssertEqual(range("192.168.1.100—192.168.1.150")!.hostCount, 51) // em dash
    }

    func test_rangeCrossesOctetBoundary() {
        XCTAssertEqual(range("10.0.0.254-10.0.1.1")!.addresses(),
                       ["10.0.0.254", "10.0.0.255", "10.0.1.0", "10.0.1.1"])
    }

    func test_invalidRanges() {
        XCTAssertNotNil(failure("10.0.0.200-10.0.0.100"))   // backwards
        XCTAssertNotNil(failure("192.168.1.100-300"))       // octet > 255
        XCTAssertNotNil(failure("192.168.1.5-"))
    }

    /// Changed on purpose: a bare address is that one host. It used to be
    /// rejected (Bulk Discovery) or widened to its /24 (Network Map).
    func test_singleHost() {
        XCTAssertEqual(range("192.168.1.20")!.addresses(), ["192.168.1.20"])
        XCTAssertEqual(range("192.168.1.0")!.hostCount, 1)
    }

    func test_overlapsCountedOnce_inTypedOrder() {
        let r = range("10.0.0.0/30, 10.0.0.2-10.0.0.5, 192.168.1.9")!
        XCTAssertEqual(r.hostCount, 6)
        XCTAssertEqual(r.addresses(), ["10.0.0.1", "10.0.0.2", "10.0.0.3",
                                       "10.0.0.4", "10.0.0.5", "192.168.1.9"])
        XCTAssertEqual(range("192.168.1.0/24, 192.168.1.100-150")!.hostCount, 254)
    }

    // MARK: Limits

    func test_networkMapLimit_isASixteen() {
        XCTAssertNotNil(range("10.0.0.0/16"))
        XCTAssertEqual(failure("10.0.0.0/15"), .tooLarge(count: 131_070, max: 65_536))
        XCTAssertEqual(failure("10.0.0.0/8"), .tooLarge(count: 16_777_214, max: 65_536))
    }

    /// Counted without enumerating, so a /0 can't hang the UI.
    func test_slashZero_failsFast() {
        XCTAssertEqual(failure("0.0.0.0/0"), .tooLarge(count: 4_294_967_294, max: 65_536))
    }

    /// Formerly test_expandCIDR_rejectsOversizedRange — Bulk Discovery's cap.
    func test_bulkDiscoveryLimit() {
        XCTAssertNotNil(range("10.0.0.0/19", max: BulkDiscoveryModel.maxHosts))
        XCTAssertEqual(failure("10.0.0.0/16", max: BulkDiscoveryModel.maxHosts),
                       .tooLarge(count: 65_534, max: 8_192))
    }

    // MARK: Prefill from the Mac's own network

    func test_networkCIDR_usesRealMask() {
        let ip = ScanRange.address("10.0.5.20")!
        XCTAssertEqual(ScanRange.networkCIDR(ip: ip, mask: 0xFFFF_0000), "10.0.0.0/16")
        XCTAssertEqual(ScanRange.networkCIDR(ip: ScanRange.address("192.168.1.20")!,
                                             mask: 0xFFFF_FF00), "192.168.1.0/24")
        XCTAssertEqual(ScanRange.networkCIDR(ip: ScanRange.address("10.0.5.70")!,
                                             mask: 0xFFFF_FFC0), "10.0.5.64/26")
    }

    func test_networkCIDR_narrowsHugeNetworksToTheMacsSixteen() {
        XCTAssertEqual(ScanRange.networkCIDR(ip: ScanRange.address("10.20.5.20")!,
                                             mask: 0xFF00_0000), "10.20.0.0/16")
    }

    // MARK: Time estimate (Network Map)

    func test_scanTimeEstimates() {
        XCTAssertEqual(NetworkMapModel.estimatedScanSeconds(hosts: 254), 19)
        XCTAssertEqual(NetworkMapModel.estimatedScanSeconds(hosts: 1_022), 46)
        XCTAssertEqual(NetworkMapModel.estimatedScanSeconds(hosts: 65_534), 2_263)
        XCTAssertEqual(NetworkMapModel.describeDuration(seconds: 19), "about 19 seconds")
        XCTAssertEqual(NetworkMapModel.describeDuration(seconds: 2_263), "about 38 minutes")
    }
}
