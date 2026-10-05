// SyslogParserTests.swift
// SNAP — Tests for the RFC 3164 / RFC 5424 syslog parser.
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only

import XCTest
@testable import SNAP

final class SyslogParserTests: XCTestCase {

    func test_rfc3164_kernelMessage() {
        let raw = "<13>May 11 22:14:15 switch01 STP-7-PORT_DOWN: GigabitEthernet1/0/24 down"
        let e = parseSyslog(raw, sourceIP: "10.1.0.1")
        XCTAssertEqual(e.facility, .user)         // 13 = user(1)*8 + notice(5)
        XCTAssertEqual(e.severity, .notice)
        XCTAssertEqual(e.host, "switch01")
        XCTAssertEqual(e.tag, "STP-7-PORT_DOWN")
        XCTAssertTrue(e.message.contains("GigabitEthernet1/0/24"))
    }

    func test_rfc3164_critical_pri() {
        // <2> = kern(0)*8 + crit(2)
        let raw = "<2>Jan  5 10:00:00 fw01 kernel: PANIC"
        let e = parseSyslog(raw, sourceIP: "192.168.1.1")
        XCTAssertEqual(e.severity, .critical)
        XCTAssertEqual(e.facility, .kern)
        XCTAssertEqual(e.tag, "kernel")
    }

    func test_rfc5424_minimal() {
        // <34>1 2026-05-12T22:14:15.003Z mymachine.example.com su - ID47 - 'su root' failed
        let raw = "<34>1 2026-05-12T22:14:15.003Z mymachine.example.com su - ID47 - 'su root' failed"
        let e = parseSyslog(raw, sourceIP: "192.168.0.5")
        XCTAssertEqual(e.facility, .auth)         // 34 = auth(4)*8 + crit(2)
        XCTAssertEqual(e.severity, .critical)
        XCTAssertEqual(e.host, "mymachine.example.com")
        XCTAssertEqual(e.tag, "su")
    }

    func test_unparseable_falls_back_gracefully() {
        let raw = "this is not a syslog line"
        let e = parseSyslog(raw, sourceIP: "10.0.0.1")
        // Default to info / other when no <PRI> is present.
        XCTAssertEqual(e.severity, .info)
        XCTAssertEqual(e.facility, .other)
        XCTAssertEqual(e.message, raw)
    }
}
