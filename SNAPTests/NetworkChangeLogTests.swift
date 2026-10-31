// NetworkChangeLogTests.swift
// SNAP: Tests for the network change log (v1.5.8)
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md

import XCTest
@testable import SNAP

final class NetworkChangeLogTests: XCTestCase {

    private let home = NetworkSnapshot(interface: "en0", address: "192.168.1.20", router: "192.168.1.1",
                                       dns: ["192.168.1.1"], ssid: "Home", wifiInterface: "en0")

    private func kinds(_ old: NetworkSnapshot?, _ new: NetworkSnapshot) -> [NetworkChange.Kind] {
        NetworkChange.changes(from: old, to: new).map(\.0)
    }

    func test_firstSnapshot_describesWhereThingsStand() {
        let c = NetworkChange.changes(from: nil, to: home)
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c[0].0, .started)
        XCTAssertEqual(c[0].1, "Wi-Fi \u{201C}Home\u{201D} (en0), 192.168.1.20, router 192.168.1.1")
        XCTAssertEqual(NetworkChange.changes(from: nil, to: NetworkSnapshot()).first?.1, "Offline")
    }

    func test_noChange_nothingLogged() {
        XCTAssertTrue(kinds(home, home).isEmpty)
    }

    func test_disconnectAndReconnect_oneEntryEach() {
        var off = NetworkSnapshot()
        off.wifiInterface = "en0"
        XCTAssertEqual(NetworkChange.changes(from: home, to: off).map(\.1), ["Left Wi-Fi \u{201C}Home\u{201D}"])
        XCTAssertEqual(kinds(home, off), [.disconnected])
        XCTAssertEqual(kinds(off, home), [.connected])
    }

    /// A new Wi-Fi network brings a new address and router: one entry, not three.
    func test_wifiSwitch_isOneEntry() {
        var office = home
        office.ssid = "Office"
        office.address = "10.0.0.9"
        office.router = "10.0.0.1"
        let c = NetworkChange.changes(from: home, to: office)
        XCTAssertEqual(c.map(\.0), [.wifi])
        XCTAssertEqual(c[0].1, "Switched to \u{201C}Office\u{201D} (was \u{201C}Home\u{201D}): 10.0.0.9, router 10.0.0.1")
    }

    func test_addressRouterAndDNS_eachLogged() {
        var next = home
        next.address = "192.168.1.21"
        XCTAssertEqual(NetworkChange.changes(from: home, to: next).map(\.1), ["192.168.1.21 (was 192.168.1.20)"])
        next.router = "192.168.1.254"
        next.dns = ["1.1.1.1", "8.8.8.8"]
        XCTAssertEqual(kinds(home, next), [.address, .router, .dns])
        XCTAssertEqual(NetworkChange.changes(from: home, to: next).last?.1, "1.1.1.1, 8.8.8.8 (was 192.168.1.1)")
    }

    func test_switchToEthernet_isOneInterfaceEntry() {
        var wired = home
        wired.interface = "en5"
        wired.address = "192.168.1.30"
        let c = NetworkChange.changes(from: home, to: wired)
        XCTAssertEqual(c.map(\.0), [.interface])
        XCTAssertEqual(c[0].1, "Now using en5, 192.168.1.30, router 192.168.1.1 (was Wi-Fi \u{201C}Home\u{201D} (en0))")
    }

    /// A full-tunnel VPN takes the default route: log the VPN and its DNS,
    /// not the interface, address, and router it brings with it.
    func test_fullTunnelVPN_logsTheTunnelNotTheRouteChange() {
        var vpn = home
        vpn.interface = "utun4"
        vpn.address = "10.8.0.2"
        vpn.router = "10.8.0.1"
        vpn.dns = ["10.8.0.1"]
        vpn.vpns = ["utun4": "10.8.0.2"]
        XCTAssertEqual(kinds(home, vpn), [.vpnUp, .dns])
        XCTAssertEqual(NetworkChange.changes(from: home, to: vpn).first?.1, "utun4, 10.8.0.2")
        XCTAssertEqual(kinds(vpn, home), [.vpnDown, .dns])
    }

    @MainActor
    func test_log_newestFirst_capped_persisted_cleared() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = dir.appendingPathComponent("network-changes.json")
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = NetworkChangeLog(file: file)
        log.record(home, at: Date(timeIntervalSince1970: 1))
        log.record(home, at: Date(timeIntervalSince1970: 2))   // unchanged, nothing added
        var next = home
        next.address = "192.168.1.21"
        log.record(next, at: Date(timeIntervalSince1970: 3))
        XCTAssertEqual(log.entries.map(\.kind), [.address, .started])

        let reloaded = NetworkChangeLog(file: file)
        XCTAssertEqual(reloaded.entries, log.entries)

        for i in 0..<(NetworkChangeLog.limit + 10) {
            next.address = "10.0.\(i / 256).\(i % 256)"
            log.record(next)
        }
        XCTAssertEqual(log.entries.count, NetworkChangeLog.limit)
        XCTAssertEqual(log.entries.first?.text.hasPrefix("10.0.1."), true)

        log.clear()
        XCTAssertTrue(NetworkChangeLog(file: file).entries.isEmpty)
    }

    @MainActor
    func test_csvExport_quotesFields() {
        let log = NetworkChangeLog(file: nil)
        log.record(home, at: Date(timeIntervalSince1970: 0))
        let lines = log.exportCSV().split(separator: "\n")
        XCTAssertEqual(lines.first, "time,event,details")
        XCTAssertTrue(lines[1].hasSuffix(",\"SNAP started\",\"Wi-Fi \u{201C}Home\u{201D} (en0), 192.168.1.20, router 192.168.1.1\""))
    }
}
