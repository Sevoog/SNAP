// NetworkMapModelTests.swift
// SNAP — Network Map model unit tests
// Created by Sevag Bardakjian
// Copyright © 2025 Sevag Bardakjian. All rights reserved.

import XCTest
@testable import SNAP

final class NetworkMapModelTests: XCTestCase {

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
