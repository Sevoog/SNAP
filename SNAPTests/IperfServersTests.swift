// IperfServersTests.swift
// SNAP: Tests for saved and recent iPerf3 servers (v1.5.8)
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md

import XCTest
@testable import SNAP

@MainActor
final class IperfServersTests: XCTestCase {
    private let suite = "com.sevagbardakjian.snap.tests.iperfServers"
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

    private func entry(_ host: String, _ port: String = "5201") -> IperfHistoryEntry {
        IperfHistoryEntry(date: Date(), server: host, port: port, direction: .upload,
                          streams: 1, seconds: 10, receiverBps: 9e8, retransmits: nil, linkMbps: nil)
    }

    func test_save_addsOnce_renamesSameAddress_andPersists() {
        let store = IperfServerStore(defaults: defaults)
        store.save(name: " Office NAS ", host: "192.168.1.10 ", port: "")
        XCTAssertEqual(store.saved.map(\.name), ["Office NAS"])
        XCTAssertEqual(store.saved.first?.address, "192.168.1.10:5201")

        store.save(name: "NAS", host: "192.168.1.10", port: "5201")   // same address
        XCTAssertEqual(store.saved.map(\.name), ["NAS"])
        store.save(name: "", host: "10.0.0.5", port: "5202")          // blank name uses the address
        XCTAssertEqual(store.saved.last?.name, "10.0.0.5")

        XCTAssertEqual(IperfServerStore(defaults: defaults).saved, store.saved)
    }

    func test_renameAndRemove() {
        let store = IperfServerStore(defaults: defaults)
        store.save(name: "Lab", host: "10.0.0.5", port: "5201")
        let id = store.saved[0].id
        store.rename(id, to: "")
        XCTAssertEqual(store.saved[0].displayName, "10.0.0.5")       // blank mid-edit shows the address
        store.rename(id, to: "Lab switch")
        XCTAssertEqual(IperfServerStore(defaults: defaults).saved.first?.displayName, "Lab switch")
        store.remove(id)
        XCTAssertTrue(IperfServerStore(defaults: defaults).saved.isEmpty)
    }

    func test_recent_newestFirst_onePerAddress_skipsSaved_capped() {
        let store = IperfServerStore(defaults: defaults)
        store.save(name: "NAS", host: "192.168.1.10", port: "5201")
        let history = [entry("10.0.0.9"), entry("10.0.0.9"), entry("192.168.1.10"),
                       entry("10.0.0.9", "5202"), entry("a"), entry("b"), entry("c"), entry("d")]
        let recent = store.recent(from: history).map(\.address)
        XCTAssertEqual(recent, ["10.0.0.9:5201", "10.0.0.9:5202", "a:5201", "b:5201", "c:5201"])
    }

    func test_lastUsed_roundTrips() {
        let store = IperfServerStore(defaults: defaults)
        XCTAssertNil(store.lastUsed)
        store.recordUse(host: " 192.168.1.44", port: "")
        let last = IperfServerStore(defaults: defaults).lastUsed
        XCTAssertEqual(last?.host, "192.168.1.44")
        XCTAssertEqual(last?.port, "5201")
    }
}
