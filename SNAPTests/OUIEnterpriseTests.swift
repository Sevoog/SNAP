// OUIEnterpriseTests.swift
// SNAP — Tests for OUI vendor-pattern role inference (enterprise gear).
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only

import XCTest
@testable import SNAP

final class OUIEnterpriseTests: XCTestCase {

    // MARK: Vendor-pattern role inference

    func test_paloAlto_inferredAsFirewall() {
        XCTAssertEqual(OUIDatabase.roleFromVendorString("Palo Alto Networks"), .firewall)
    }

    func test_fortinet_inferredAsFirewall() {
        XCTAssertEqual(OUIDatabase.roleFromVendorString("Fortinet, Inc."), .firewall)
    }

    func test_f5_inferredAsLoadBalancer() {
        XCTAssertEqual(OUIDatabase.roleFromVendorString("F5 Networks"), .loadBalancer)
    }

    func test_arista_inferredAsSwitch() {
        XCTAssertEqual(OUIDatabase.roleFromVendorString("Arista Networks"), .networkSwitch)
    }

    func test_juniper_inferredAsSwitch() {
        XCTAssertEqual(OUIDatabase.roleFromVendorString("Juniper Networks"), .networkSwitch)
    }

    func test_aruba_inferredAsAP() {
        XCTAssertEqual(OUIDatabase.roleFromVendorString("Aruba Networks"), .accessPoint)
    }

    func test_mikrotik_inferredAsRouter() {
        XCTAssertEqual(OUIDatabase.roleFromVendorString("Routerboard.com"), .router)
    }

    func test_cisco_leansSwitch() {
        // Cisco sells everything; we default to switch unless "meraki" or
        // "wireless" appears in the string.
        XCTAssertEqual(OUIDatabase.roleFromVendorString("Cisco Systems"), .networkSwitch)
        XCTAssertEqual(OUIDatabase.roleFromVendorString("Cisco Meraki"), .accessPoint)
    }

    func test_unknownVendor_returnsUnknown() {
        XCTAssertEqual(OUIDatabase.roleFromVendorString("Some Random Co"), .unknown)
    }
}
