// StatusBoardWiFiTests.swift
// SNAP — Tests for the Status Board Wi-Fi tile's live-value helpers.
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md

import XCTest
import CoreWLAN
@testable import SNAP

final class StatusBoardWiFiTests: XCTestCase {

    private func info(rssi: Int, noise: Int?) -> StatusBoardWiFi.Info {
        StatusBoardWiFi.Info(ssid: "Test", rssi: rssi, band: "", iface: "en0",
                             noise: noise, txRateMbps: nil, security: nil,
                             securityInsecure: false, standard: nil)
    }

    // MARK: SNR — was hard-coded as RSSI + 95

    func test_snrIsSignalMinusNoise() {
        XCTAssertEqual(info(rssi: -60, noise: -92).snr, 32)
        XCTAssertEqual(info(rssi: -68, noise: -88).snr, 20)
    }

    func test_snrUnknownWithoutBothReadings() {
        XCTAssertNil(info(rssi: -60, noise: nil).snr)
        XCTAssertNil(info(rssi: 0, noise: -92).snr)     // not associated
    }

    // MARK: PHY standard — replaces the hard-coded "MCS —"

    func test_standardNames() {
        XCTAssertEqual(StatusBoardWiFi.standard(.mode11ax, sixGHz: true), "Wi-Fi 6E")
        XCTAssertEqual(StatusBoardWiFi.standard(.mode11ax, sixGHz: false), "Wi-Fi 6")
        XCTAssertEqual(StatusBoardWiFi.standard(.mode11ac, sixGHz: false), "Wi-Fi 5")
        XCTAssertEqual(StatusBoardWiFi.standard(.mode11n, sixGHz: false), "Wi-Fi 4")
        XCTAssertEqual(StatusBoardWiFi.standard(.mode11g, sixGHz: false), "802.11g")
        XCTAssertNil(StatusBoardWiFi.standard(.modeNone, sixGHz: false))
    }

    func test_wifi7ByRawValue() {
        XCTAssertEqual(StatusBoardWiFi.standard(CWPHYMode(rawValue: 7)!, sixGHz: true), "Wi-Fi 7")
    }

    // MARK: Security — was hard-coded "WPA3"; shared with the Dashboard

    func test_securityLabels() {
        XCTAssertEqual(CWSecurity.none.snapLabel, "Open")
        XCTAssertEqual(CWSecurity.WEP.snapLabel, "WEP")
        XCTAssertEqual(CWSecurity.wpa2Personal.snapLabel, "WPA2")
        XCTAssertEqual(CWSecurity.wpa3Personal.snapLabel, "WPA3")
        XCTAssertEqual(CWSecurity.wpa3Transition.snapLabel, "WPA2/WPA3")
        XCTAssertEqual(CWSecurity(rawValue: 14)!.snapLabel, "OWE")
        XCTAssertEqual(CWSecurity(rawValue: 15)!.snapLabel, "OWE Transition")
    }
}
