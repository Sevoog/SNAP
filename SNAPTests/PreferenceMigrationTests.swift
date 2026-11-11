// PreferenceMigrationTests.swift
// SNAP: Tests for moving preferences off the old com.bardaklabs.snap names (v1.5.9)
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md

import XCTest
@testable import SNAP

final class PreferenceMigrationTests: XCTestCase {
    private let suite = "com.sevagbardakjian.snap.tests.preferenceMigration"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func test_movesEveryOldKey_keepingValuesAndTypes() {
        let layout = Data([1, 2, 3])
        defaults.set("midnight", forKey: "com.bardaklabs.snap.theme.v1")
        defaults.set(layout, forKey: "com.bardaklabs.snap.dashboardLayout.v1")
        defaults.set(true, forKey: "com.bardaklabs.snap.didOnboard.v1")
        defaults.set(["1.1.1.1", "github.com"], forKey: "com.bardaklabs.snap.history.v1.ping")
        defaults.set("keep me", forKey: "snap_iperf_history")

        XCTAssertEqual(PreferenceMigration.run(defaults), 4)

        XCTAssertEqual(defaults.string(forKey: "com.sevagbardakjian.snap.theme.v1"), "midnight")
        XCTAssertEqual(defaults.data(forKey: "com.sevagbardakjian.snap.dashboardLayout.v1"), layout)
        XCTAssertTrue(defaults.bool(forKey: "com.sevagbardakjian.snap.didOnboard.v1"))
        XCTAssertEqual(defaults.stringArray(forKey: "com.sevagbardakjian.snap.history.v1.ping"), ["1.1.1.1", "github.com"])
        XCTAssertNil(defaults.object(forKey: "com.bardaklabs.snap.theme.v1"))
        XCTAssertNil(defaults.object(forKey: "com.bardaklabs.snap.history.v1.ping"))
        XCTAssertEqual(defaults.string(forKey: "snap_iperf_history"), "keep me")   // other keys untouched
    }

    /// A value already under the new name (set by 1.5.9) wins; the stale old copy goes.
    func test_existingNewValueWins_andRunningAgainMovesNothing() {
        defaults.set("daylight", forKey: "com.sevagbardakjian.snap.theme.v1")
        defaults.set("midnight", forKey: "com.bardaklabs.snap.theme.v1")
        XCTAssertEqual(PreferenceMigration.run(defaults), 0)
        XCTAssertEqual(defaults.string(forKey: "com.sevagbardakjian.snap.theme.v1"), "daylight")
        XCTAssertNil(defaults.object(forKey: "com.bardaklabs.snap.theme.v1"))
        XCTAssertEqual(PreferenceMigration.run(defaults), 0)
    }

    /// Every preference key in the app uses the new prefix, so nothing is
    /// left reading a name the migration just emptied.
    func test_appKeys_useTheNewPrefix() {
        let keys = [SNMPCommunityStore.Backend.rememberedHostsKey, SNMPCommunityStore.Backend.boardHostKey,
                    SNMPBoardWatchEnvironment.targetKey]
        for k in keys { XCTAssertTrue(k.hasPrefix(PreferenceMigration.newPrefix), k) }
    }
}
