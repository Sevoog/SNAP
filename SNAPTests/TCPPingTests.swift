// TCPPingTests.swift
// SNAP: Tests for Ping's TCP mode (v1.5.8)
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md

import XCTest
import Darwin
@testable import SNAP

final class TCPPingTests: XCTestCase {

    func test_port_acceptsOnlyValidPorts() {
        XCTAssertEqual(TCPPing.port("443"), 443)
        XCTAssertEqual(TCPPing.port(" 22 "), 22)
        XCTAssertEqual(TCPPing.port("65535"), 65535)
        XCTAssertNil(TCPPing.port("0"))
        XCTAssertNil(TCPPing.port("65536"))
        XCTAssertNil(TCPPing.port("http"))
        XCTAssertNil(TCPPing.port(""))
    }

    /// A reset still means the host answered, so it keeps its time.
    func test_outcome_mapsSocketErrors() {
        XCTAssertEqual(TCPPing.outcome(ECONNREFUSED, ms: 3), .refused(ms: 3))
        XCTAssertEqual(TCPPing.outcome(ECONNREFUSED, ms: 3).ms, 3)
        XCTAssertEqual(TCPPing.outcome(ETIMEDOUT, ms: 3), .timeout)
        XCTAssertEqual(TCPPing.outcome(EHOSTUNREACH, ms: 3), .failed("Host unreachable"))
        XCTAssertEqual(TCPPing.outcome(ENETUNREACH, ms: 3), .failed("Network unreachable"))
        XCTAssertNil(TCPPing.Outcome.timeout.ms)
    }

    func test_resolve_numericAddresses() {
        XCTAssertEqual(TCPPing.resolve("127.0.0.1", port: 80)?.display, "127.0.0.1")
        XCTAssertEqual(TCPPing.resolve("::1", port: 80)?.display, "::1")
    }

    /// Against a listener on this Mac: open while it listens, a reset once it's closed.
    func test_probe_openThenRefused() throws {
        let listener = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        XCTAssertGreaterThanOrEqual(listener, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { p -> Bool in
                Darwin.bind(listener, p, len) == 0 && listen(listener, 4) == 0
                    && getsockname(listener, p, &len) == 0
            }
        }
        XCTAssertTrue(bound)
        let port = UInt16(bigEndian: addr.sin_port)
        let target = try XCTUnwrap(TCPPing.resolve("127.0.0.1", port: port))

        let open = TCPPing.probe(target.address, timeout: 2)
        guard case .open(let ms) = open else { return XCTFail("expected open, got \(open)") }
        XCTAssertLessThan(ms, 1000)

        Darwin.close(listener)
        let closed = TCPPing.probe(target.address, timeout: 2)
        guard case .refused = closed else { return XCTFail("expected refused, got \(closed)") }
    }
}
