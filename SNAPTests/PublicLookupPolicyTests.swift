// PublicLookupPolicyTests.swift
// SNAP — Tests for how often the Dashboard repeats public-IP / ISP lookups.
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only

import XCTest
@testable import SNAP

final class PublicLookupPolicyTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    // MARK: Public IP (ipify)

    func test_ipCheck_firstTime() {
        XCTAssertTrue(PublicLookupPolicy.needsIPCheck(force: false, lastCheck: nil, now: t0))
    }

    func test_ipCheck_cachedForTenMinutes() {
        XCTAssertFalse(PublicLookupPolicy.needsIPCheck(force: false, lastCheck: t0, now: at(30)))
        XCTAssertFalse(PublicLookupPolicy.needsIPCheck(force: false, lastCheck: t0, now: at(599)))
        XCTAssertTrue(PublicLookupPolicy.needsIPCheck(force: false, lastCheck: t0, now: at(600)))
    }

    func test_ipCheck_manualRefreshForces() {
        XCTAssertTrue(PublicLookupPolicy.needsIPCheck(force: true, lastCheck: t0, now: at(1)))
    }

    // MARK: ISP details (ipinfo.io)

    func test_geo_needsAnAddress() {
        XCTAssertFalse(PublicLookupPolicy.needsGeo(force: true, publicIPv4: nil,
                                                   fetchedAt: nil, failedAt: nil, now: t0))
    }

    func test_geo_fetchedOncePerAddressPerDay() {
        let ip = "203.0.113.42"
        XCTAssertTrue(PublicLookupPolicy.needsGeo(force: false, publicIPv4: ip,
                                                  fetchedAt: nil, failedAt: nil, now: t0))
        XCTAssertFalse(PublicLookupPolicy.needsGeo(force: false, publicIPv4: ip,
                                                   fetchedAt: t0, failedAt: nil, now: at(3600)))
        XCTAssertTrue(PublicLookupPolicy.needsGeo(force: false, publicIPv4: ip,
                                                  fetchedAt: t0, failedAt: nil, now: at(86_400)))
    }

    func test_geo_backsOffAfterFailure() {
        let ip = "203.0.113.42"
        XCTAssertFalse(PublicLookupPolicy.needsGeo(force: false, publicIPv4: ip,
                                                   fetchedAt: nil, failedAt: t0, now: at(120)))
        XCTAssertTrue(PublicLookupPolicy.needsGeo(force: false, publicIPv4: ip,
                                                  fetchedAt: nil, failedAt: t0, now: at(300)))
        // A manual Refresh ignores the back-off.
        XCTAssertTrue(PublicLookupPolicy.needsGeo(force: true, publicIPv4: ip,
                                                  fetchedAt: nil, failedAt: t0, now: at(1)))
    }

    // MARK: A full day with the Dashboard open

    /// The card refreshes every 30 s: 2,880 refreshes a day. Before v1.5.3
    /// each one hit ipify twice and ipinfo once.
    func test_dayWithDashboardOpen_stableNetwork() {
        let ip = "203.0.113.42"
        var lastIPCheck: Date?
        var geoFetchedAt: Date?
        var ipChecks = 0, geoFetches = 0
        for tick in 0..<2_880 {
            let now = at(Double(tick) * 30)
            if PublicLookupPolicy.needsIPCheck(force: false, lastCheck: lastIPCheck, now: now) {
                ipChecks += 1
                lastIPCheck = now
            }
            if PublicLookupPolicy.needsGeo(force: false, publicIPv4: ip, fetchedAt: geoFetchedAt,
                                           failedAt: nil, now: now) {
                geoFetches += 1
                geoFetchedAt = now
            }
        }
        XCTAssertEqual(ipChecks, 144)     // every 10 min, down from 2,880
        XCTAssertEqual(geoFetches, 1)     // down from 2,880
    }

    /// If ipinfo is rate-limiting (or down) all day, retries are spaced
    /// 5 min apart instead of every refresh.
    func test_dayWithIpinfoFailing_retriesAreSpaced() {
        let ip = "203.0.113.42"
        var failedAt: Date?
        var attempts = 0
        for tick in 0..<2_880 {
            let now = at(Double(tick) * 30)
            if PublicLookupPolicy.needsGeo(force: false, publicIPv4: ip, fetchedAt: nil,
                                           failedAt: failedAt, now: now) {
                attempts += 1
                failedAt = now
            }
        }
        XCTAssertEqual(attempts, 288)
    }
}
