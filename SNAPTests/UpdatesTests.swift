// UpdatesTests.swift
// SNAP: Tests for update checks, "What's new", and bug-report links
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md

import XCTest
@testable import SNAP

final class AppVersionTests: XCTestCase {

    func test_isNewer_comparesNumbersNotText() {
        XCTAssertTrue(AppVersion.isNewer("1.5.10", than: "1.5.9"))
        XCTAssertTrue(AppVersion.isNewer("1.6", than: "1.5.9"))
        XCTAssertTrue(AppVersion.isNewer("v2.0.0", than: "1.9.9"))
        XCTAssertFalse(AppVersion.isNewer("1.5.8", than: "1.5.8"))
        XCTAssertFalse(AppVersion.isNewer("1.5", than: "1.5.0"))
        XCTAssertFalse(AppVersion.isNewer("1.5.7", than: "1.5.8"))
    }

    func test_parts_ignoresPrefixAndSuffix() {
        XCTAssertEqual(AppVersion.parts("v1.5.8"), [1, 5, 8])
        XCTAssertEqual(AppVersion.parts("1.6.0-beta"), [1, 6, 0])
        XCTAssertEqual(AppVersion.parts("latest"), [])
        XCTAssertFalse(AppVersion.isNewer("latest", than: "1.0"))
    }
}

final class ReleaseInfoTests: XCTestCase {

    private func json(tag: String = "v1.5.9", draft: Bool = false, prerelease: Bool = false) -> Data {
        Data(####"{"tag_name":"\####(tag)","html_url":"https://github.com/Sevoog/SNAP/releases/tag/\####(tag)","body":"### What's new\n- One\n  - Nested\n- **Two**","draft":\####(draft),"prerelease":\####(prerelease)}"####.utf8)
    }

    func test_parsesTheLatestRelease() throws {
        let r = try XCTUnwrap(ReleaseInfo(json: json()))
        XCTAssertEqual(r.version, "1.5.9")
        XCTAssertEqual(r.pageURL.absoluteString, "https://github.com/Sevoog/SNAP/releases/tag/v1.5.9")
    }

    func test_neverOffersDraftsOrPrereleases() {
        XCTAssertNil(ReleaseInfo(json: json(draft: true)))
        XCTAssertNil(ReleaseInfo(json: json(prerelease: true)))
        XCTAssertNil(ReleaseInfo(json: json(tag: "nightly")))
        XCTAssertNil(ReleaseInfo(json: Data("{\"message\":\"API rate limit exceeded\"}".utf8)))
    }

    func test_styledNotes_turnsMarkdownBlocksIntoText() throws {
        let text = String(try XCTUnwrap(ReleaseInfo(json: json())).styledNotes.characters)
        XCTAssertFalse(text.contains("###"))
        XCTAssertFalse(text.contains("**"))
        XCTAssertTrue(text.contains("What's new"))
        XCTAssertTrue(text.contains("• One"))
        XCTAssertTrue(text.contains("◦ Nested"))
    }
}

@MainActor
final class UpdateCheckerTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suite = "com.sevagbardakjian.snap.tests.updates"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private let release = ReleaseInfo(version: "1.5.9", notes: "", pageURL: URL(string: "https://example.com")!)

    func test_decide() {
        XCTAssertEqual(UpdateChecker.decide(release: release, current: "1.5.8", skipped: nil, userInitiated: false), .offer)
        XCTAssertEqual(UpdateChecker.decide(release: release, current: "1.5.9", skipped: nil, userInitiated: true), .upToDate)
        XCTAssertEqual(UpdateChecker.decide(release: release, current: "1.6.0", skipped: nil, userInitiated: true), .upToDate)
        // A skipped version stays quiet automatically, but asking by hand shows it.
        XCTAssertEqual(UpdateChecker.decide(release: release, current: "1.5.8", skipped: "1.5.9", userInitiated: false), .skipped)
        XCTAssertEqual(UpdateChecker.decide(release: release, current: "1.5.8", skipped: "1.5.9", userInitiated: true), .offer)
        XCTAssertEqual(UpdateChecker.decide(release: release, current: "1.5.8", skipped: "1.5.8", userInitiated: false), .offer)
    }

    func test_automaticChecksAreOffUntilTurnedOn() {
        let checker = UpdateChecker(defaults: defaults, currentVersion: "1.5.8")
        XCTAssertFalse(checker.autoCheck)
        XCTAssertFalse(checker.hasAskedAboutAutoCheck)
        XCTAssertFalse(checker.isDue())
    }

    func test_isDue_atMostOnceADay() {
        defaults.set(true, forKey: UpdateChecker.Keys.autoCheck)
        let now = Date()
        defaults.set(now.addingTimeInterval(-2 * 3600), forKey: UpdateChecker.Keys.lastCheck)
        let checker = UpdateChecker(defaults: defaults, currentVersion: "1.5.8")
        XCTAssertFalse(checker.isDue(now: now))
        XCTAssertTrue(checker.isDue(now: now.addingTimeInterval(23 * 3600)))
        defaults.removeObject(forKey: UpdateChecker.Keys.lastCheck)
        XCTAssertTrue(checker.isDue(now: now), "never checked")
    }

    func test_skip_remembersTheVersion() {
        let checker = UpdateChecker(defaults: defaults, currentVersion: "1.5.8")
        checker.available = release
        checker.skip(release)
        XCTAssertNil(checker.available)
        XCTAssertEqual(defaults.string(forKey: UpdateChecker.Keys.skippedVersion), "1.5.9")
    }
}

final class WhatsNewTests: XCTestCase {

    func test_shouldShow_onceAfterEachUpdate() {
        XCTAssertFalse(WhatsNew.shouldShow(lastSeen: nil, hasOnboarded: false, current: "1.5.8"), "first install gets the Quick Tour")
        XCTAssertTrue(WhatsNew.shouldShow(lastSeen: nil, hasOnboarded: true, current: "1.5.8"), "updated from 1.5.7 or earlier")
        XCTAssertTrue(WhatsNew.shouldShow(lastSeen: "1.5.8", hasOnboarded: true, current: "1.5.9"))
        XCTAssertFalse(WhatsNew.shouldShow(lastSeen: "1.5.8", hasOnboarded: true, current: "1.5.8"))
        XCTAssertFalse(WhatsNew.shouldShow(lastSeen: "1.5.9", hasOnboarded: true, current: "1.5.8"), "went back a version")
    }

    func test_itemsMatchTheAppVersion() {
        XCTAssertEqual(WhatsNew.version, AppInfo.version, "update WhatsNew.items for this release")
        XCTAssertFalse(WhatsNew.items.isEmpty)
    }
}

final class IssueReportTests: XCTestCase {

    func test_url_fillsInVersionsOnly() throws {
        let url = try XCTUnwrap(IssueReport.url(template: "bug_report.yml", snapVersion: "1.5.8",
                                                macOS: OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 0)))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(url.host, "github.com")
        XCTAssertEqual(url.path, "/Sevoog/SNAP/issues/new")
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") }),
                       ["template": "bug_report.yml", "snap-version": "1.5.8", "macos-version": "27.2"])
    }
}
