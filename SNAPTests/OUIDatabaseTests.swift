// OUIDatabaseTests.swift
// SNAP — OUI vendor lookup tests
// Created by Sevag Bardakjian
// Copyright © 2025 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md

import XCTest
@testable import SNAP

final class OUIDatabaseTests: XCTestCase {

    // MARK: Separator + case normalization

    func test_lookup_acceptsColonSeparators() {
        XCTAssertEqual(OUIDatabase.lookup("A4:B1:97:00:00:00"), "Apple")
    }

    func test_lookup_acceptsDashSeparators() {
        XCTAssertEqual(OUIDatabase.lookup("A4-B1-97-00-00-00"), "Apple")
    }

    func test_lookup_acceptsDottedCiscoStyle() {
        XCTAssertEqual(OUIDatabase.lookup("A4B1.9700.0000"), "Apple")
    }

    func test_lookup_acceptsNoSeparators() {
        XCTAssertEqual(OUIDatabase.lookup("A4B19700ABCD"), "Apple")
    }

    func test_lookup_isCaseInsensitive() {
        XCTAssertEqual(OUIDatabase.lookup("a4:b1:97:00:00:00"), "Apple")
        XCTAssertEqual(OUIDatabase.lookup("A4:B1:97:00:00:00"), "Apple")
        XCTAssertEqual(OUIDatabase.lookup("a4b19700:0000"),     "Apple")
    }

    // MARK: Edge cases — must not crash

    func test_lookup_emptyStringReturnsNil() {
        XCTAssertNil(OUIDatabase.lookup(""))
    }

    func test_lookup_shortStringReturnsNil() {
        XCTAssertNil(OUIDatabase.lookup("aa:bb"))
    }

    func test_lookup_unknownPrefixReturnsNil() {
        // FF:FF:FF is the broadcast MAC — never in our curated table.
        XCTAssertNil(OUIDatabase.lookup("FF:FF:FF:00:00:00"))
    }

    // MARK: Role hints — common consumer vendors

    func test_roleHint_sonos_isSonos() {
        let h = OUIDatabase.roleHint("B8:E9:37:00:00:00")
        XCTAssertEqual(h?.vendor, "Sonos")
        XCTAssertEqual(h?.role, .sonos)
    }

    func test_roleHint_roku_isRoku() {
        let h = OUIDatabase.roleHint("B0:EE:7B:00:00:00")
        XCTAssertEqual(h?.vendor, "Roku")
        XCTAssertEqual(h?.role, .roku)
    }

    func test_roleHint_raspberryPi_isRaspberryPi() {
        let h = OUIDatabase.roleHint("B8:27:EB:00:00:00")
        XCTAssertEqual(h?.vendor, "Raspberry Pi")
        XCTAssertEqual(h?.role, .raspberryPi)
    }

    func test_roleHint_apple_genericAppleDevice() {
        // Apple OUIs intentionally don't disambiguate Mac/iPhone/iPad/etc.
        // Refinement happens via mDNS service-type signals later.
        let h = OUIDatabase.roleHint("A4:B1:97:00:00:00")
        XCTAssertEqual(h?.vendor, "Apple")
        XCTAssertEqual(h?.role, .appleDevice)
    }

    func test_roleHint_pixelOUI_isAndroidPhone() {
        // Google's Pixel-line OUIs were specifically tagged as androidPhone
        // (not generic Google iot) in v1.2.2.
        let h = OUIDatabase.roleHint("28:BD:89:00:00:00")
        XCTAssertEqual(h?.vendor, "Google")
        XCTAssertEqual(h?.role, .androidPhone)
    }

    func test_roleHint_ubiquiti_isAccessPoint() {
        let h = OUIDatabase.roleHint("24:5A:4C:00:00:00")
        XCTAssertEqual(h?.vendor, "Ubiquiti")
        XCTAssertEqual(h?.role, .accessPoint)
    }
}
