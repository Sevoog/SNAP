// SNMPInterfacesTests.swift
// SNAP — Tests
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md

import XCTest
import AppKit
@testable import SNAP

final class SNMPInterfacesTests: XCTestCase {

    // MARK: Fake switch

    /// sysUpTime 10,000 s. Five interfaces:
    ///   1 Gi1/0/1  Ethernet, up, 1 Gbps, "Uplink to core", unchanged since start
    ///   2 Gi1/0/2  Ethernet, up, 100 Mbps, "Printer", 1,200 + 40 errors, changed 3 min ago
    ///   3 Gi1/0/3  Ethernet, turned off, 1 Gbps, changed 9,000 s ago
    ///   4 Vl1      propVirtual (VLAN interface), up
    ///   5 Lo0      softwareLoopback, up, no speed
    private func mib(xTable: Bool = true) -> [(String, SNMPValue)] {
        var e: [(String, SNMPValue)] = [("1.3.6.1.2.1.1.3.0", .timeTicks(1_000_000))]
        func t(_ col: Int, _ idx: Int, _ v: SNMPValue) { e.append(("1.3.6.1.2.1.2.2.1.\(col).\(idx)", v)) }
        func x(_ col: Int, _ idx: Int, _ v: SNMPValue) { e.append(("1.3.6.1.2.1.31.1.1.1.\(col).\(idx)", v)) }
        func s(_ text: String) -> SNMPValue { .octetString(Data(text.utf8)) }

        let descr = ["GigabitEthernet1/0/1", "GigabitEthernet1/0/2", "GigabitEthernet1/0/3", "Vlan1", "Loopback0"]
        let names = ["Gi1/0/1", "Gi1/0/2", "Gi1/0/3", "Vl1", "Lo0"]
        let alias = ["Uplink to core", "Printer", "", "", ""]
        let types: [Int64] = [6, 6, 6, 53, 24]
        let speed: [UInt32] = [1_000_000_000, 100_000_000, 1_000_000_000, 1_000_000_000, 0]
        let admin: [Int64] = [1, 1, 2, 1, 1]
        let oper: [Int64] = [1, 1, 2, 1, 1]
        let change: [UInt32] = [0, 1_000_000 - 18_000, 100_000, 0, 0]
        for i in 0..<5 {
            let idx = i + 1
            t(2, idx, s(descr[i]))
            t(3, idx, .integer(types[i]))
            t(5, idx, .gauge32(speed[i]))
            t(7, idx, .integer(admin[i]))
            t(8, idx, .integer(oper[i]))
            t(9, idx, .timeTicks(change[i]))
            t(10, idx, .counter32(UInt32(1_000 * idx)))
            t(13, idx, .counter32(idx == 2 ? 12 : 0))
            t(14, idx, .counter32(idx == 2 ? 1_200 : 0))
            t(16, idx, .counter32(UInt32(2_000 * idx)))
            t(19, idx, .counter32(0))
            t(20, idx, .counter32(idx == 2 ? 40 : 0))
            if xTable {
                x(1, idx, s(names[i]))
                x(6, idx, .counter64(UInt64(10_000_000_000) * UInt64(idx)))
                x(10, idx, .counter64(UInt64(20_000_000_000) * UInt64(idx)))
                x(15, idx, .gauge32(speed[i] / 1_000_000))
                x(18, idx, s(alias[i]))
            }
        }
        return e
    }

    private func row(_ r: SNMPInterfaceReport, _ idx: UInt32) throws -> SNMPInterfaceRow {
        try XCTUnwrap(r.rows.first { $0.id == idx })
    }

    // MARK: Query

    func test_query_readsNamesAliasesErrorsTypesAndChanges() async throws {
        let report = try await SNMPInterfaces.query(FakeSNMPAgent(mib()).client(), maxRows: 1000)
        XCTAssertEqual(report.rows.map(\.id), [1, 2, 3, 4, 5])
        XCTAssertNil(report.note)
        XCTAssertTrue(report.unread.isEmpty)

        let gi1 = try row(report, 1)
        XCTAssertEqual(gi1.displayName, "Gi1/0/1")
        XCTAssertEqual(gi1.descr, "GigabitEthernet1/0/1")
        XCTAssertEqual(gi1.alias, "Uplink to core")
        XCTAssertEqual(gi1.speed, "1 Gbps")
        XCTAssertEqual(gi1.inOctets, 10_000_000_000)
        XCTAssertEqual(gi1.inWidth, .bits64)
        XCTAssertTrue(gi1.counters64)
        XCTAssertEqual(gi1.ifType, 6)
        XCTAssertTrue(gi1.isPhysical)
        guard case .notSinceStart(let started?)? = gi1.lastChange else {
            return XCTFail("ifLastChange 0 should read as no change since start, got \(String(describing: gi1.lastChange))")
        }
        XCTAssertEqual(Date().timeIntervalSince(started), 10_000, accuracy: 5)
        XCTAssertEqual(SNMPInterfaceFormat.changeText(gi1.lastChange, now: Date()), "Unchanged")
        XCTAssertTrue(SNMPInterfaceFormat.changeHelp(gi1.lastChange, status: "up", now: Date())
            .hasPrefix("No change since the device's SNMP service started, 2 h ago"))

        let gi2 = try row(report, 2)
        XCTAssertEqual(gi2.alias, "Printer")
        XCTAssertEqual(gi2.inErrors, 1_200)
        XCTAssertEqual(gi2.outErrors, 40)
        XCTAssertEqual(gi2.inDiscards, 12)
        XCTAssertEqual(gi2.outDiscards, 0)
        XCTAssertEqual(gi2.errorTotal, 1_240)
        XCTAssertEqual(SNMPInterfaceFormat.changeText(gi2.lastChange, now: Date()), "3 min ago")

        let gi3 = try row(report, 3)
        XCTAssertEqual(gi3.operStatus, "disabled")
        XCTAssertEqual(SNMPInterfaceFormat.changeText(gi3.lastChange, now: Date()), "2 h ago")

        let vlan = try row(report, 4)
        XCTAssertFalse(vlan.isPhysical)
        XCTAssertFalse(try row(report, 5).isPhysical)
        XCTAssertEqual(try row(report, 5).speed, "n/a")

        // Physical ports only: on by default, hides the VLAN and the loopback.
        XCTAssertTrue(SNMPInterfaces.physicalFilterApplies(report.rows))
        XCTAssertEqual(SNMPInterfaces.shownRows(report.rows, physicalOnly: true).map(\.id), [1, 2, 3])
        XCTAssertEqual(SNMPInterfaces.shownRows(report.rows, physicalOnly: false).count, 5)
    }

    /// No ifXTable: names fall back to ifDescr, totals to 32-bit counters.
    func test_query_withoutXTable_stillWorks() async throws {
        let report = try await SNMPInterfaces.query(FakeSNMPAgent(mib(xTable: false)).client(), maxRows: 1000)
        XCTAssertEqual(report.rows.count, 5)
        XCTAssertTrue(report.unread.isEmpty)
        let gi1 = try row(report, 1)
        XCTAssertEqual(gi1.displayName, "GigabitEthernet1/0/1")
        XCTAssertEqual(gi1.alias, "")
        XCTAssertEqual(gi1.inOctets, 1_000)
        XCTAssertEqual(gi1.outOctets, 2_000)
        XCTAssertEqual(gi1.inWidth, .bits32)
        XCTAssertFalse(gi1.counters64)
        XCTAssertEqual(gi1.speed, "1 Gbps")
        XCTAssertEqual(try row(report, 2).errorTotal, 1_240)
        XCTAssertTrue(SNMPInterfaces.exportText(report).contains("(* a 32-bit counter, which wraps every 4.29 GB)"))
    }

    /// v1 ends walks with noSuchName and can't carry Counter64.
    func test_query_v1_withoutXTable() async throws {
        let agent = FakeSNMPAgent(mib(xTable: false)); agent.v1 = true
        let report = try await SNMPInterfaces.query(agent.client(version: .v1), maxRows: 1000)
        XCTAssertEqual(report.rows.count, 5)
        XCTAssertEqual(try row(report, 2).operStatus, "up")
        XCTAssertEqual(try row(report, 2).inWidth, .bits32)
        XCTAssertEqual(SNMPInterfaceFormat.changeText(try row(report, 2).lastChange, now: Date()), "3 min ago")
    }

    /// Only ifDescr and ifOperStatus: every optional column is blank, nothing fails.
    func test_query_minimalDevice() async throws {
        let agent = FakeSNMPAgent([
            ("1.3.6.1.2.1.2.2.1.2.1", .octetString(Data("eth0".utf8))),
            ("1.3.6.1.2.1.2.2.1.8.1", .integer(1)),
        ])
        let report = try await SNMPInterfaces.query(agent.client(), maxRows: 1000)
        let eth0 = try row(report, 1)
        XCTAssertEqual(eth0.displayName, "eth0")
        XCTAssertEqual(eth0.operStatus, "up")
        XCTAssertNil(eth0.inWidth)
        XCTAssertNil(eth0.lastChange)
        XCTAssertFalse(eth0.hasErrorCounts)
        XCTAssertNil(eth0.ifType)
        XCTAssertFalse(SNMPInterfaces.physicalFilterApplies(report.rows))
        XCTAssertEqual(SNMPInterfaces.summaryLine(report.rows), "1 of 1 up.")
    }

    /// A device that goes quiet partway keeps the rows read so far and says
    /// what's missing, instead of failing the whole query.
    func test_query_deviceStopsAnsweringPartway() async throws {
        let agent = FakeSNMPAgent(mib())
        let gone = GoesQuiet(from: OID([1,3,6,1,2,1,31,1,1,1,18]))     // ifAlias onward
        let client = SNMPClient(host: "fake", timeout: 1, retries: 0, transport: { m in
            try gone.check(m)
            return try agent.reply(m)
        })
        let report = try await SNMPInterfaces.query(client, maxRows: 1000)
        XCTAssertEqual(report.rows.count, 5)
        XCTAssertEqual(try row(report, 1).displayName, "Gi1/0/1")     // ifName came before
        XCTAssertEqual(try row(report, 1).alias, "")
        XCTAssertNil(try row(report, 1).inWidth)
        XCTAssertEqual(report.unread, ["labels", "port types", "speeds", "traffic totals", "errors", "last change times"])
        XCTAssertTrue(SNMPInterfacesPane.unreadText(report.unread)
            .contains("Not read: labels, port types, speeds, traffic totals, errors, and last change times."))
        // Once it went quiet, SNAP stopped asking.
        XCTAssertEqual(gone.timeouts, 1)
    }

    func test_exportText_hasTheNewColumns() async throws {
        let report = try await SNMPInterfaces.query(FakeSNMPAgent(mib()).client(), maxRows: 1000)
        let text = SNMPInterfaces.exportText(report)
        XCTAssertTrue(text.contains("idx\tname\talias\ttype\tstatus\tspeed\tin errors\tout errors\tin discards\tout discards\tlast change\ttotal in (bytes)\ttotal out (bytes)"))
        XCTAssertTrue(text.contains("2\tGi1/0/2\tPrinter\tEthernet (6)\tup\t100 Mbps\t1200\t40\t12\t0\t3 min ago\t20000000000\t40000000000"))
        XCTAssertTrue(text.contains("4\tVl1\t\tvirtual (53)\tup"))
        XCTAssertTrue(text.contains("1\tGi1/0/1\tUplink to core\tEthernet (6)\tup\t1 Gbps\t0\t0\t0\t0\tunchanged since SNMP service start\t10000000000\t20000000000"))
        XCTAssertTrue(text.hasPrefix("Physical ports (3 of 5 interfaces): "))
        XCTAssertFalse(text.contains("32-bit"))
    }

    // MARK: Summary line

    func test_summaryLine() async throws {
        let report = try await SNMPInterfaces.query(FakeSNMPAgent(mib()).client(), maxRows: 1000)
        let physical = SNMPInterfaces.shownRows(report.rows, physicalOnly: true)
        XCTAssertEqual(SNMPInterfaces.summaryLine(physical),
                       "2 of 3 up, 1 disabled. 1 port at 100 Mbps. Gi1/0/2: \(1_240.formatted()) errors.")
        XCTAssertEqual(SNMPInterfaces.summaryLine([]), "No interfaces to show.")
    }

    private func port(_ id: UInt32, _ name: String, up: Bool = true, speed: UInt64 = 1_000_000_000,
                      errors: UInt64? = 0, type: Int64? = 6) -> SNMPInterfaceRow {
        var r = SNMPInterfaceRow(id: id, descr: name, operStatus: up ? "up" : "down",
                                 speed: SNMPInterfaceFormat.formatSpeed(speed), speedRaw: speed,
                                 inOctets: 0, outOctets: 0)
        r.name = name
        r.inErrors = errors
        r.outErrors = errors.map { _ in 0 }
        r.ifType = type
        return r
    }

    func test_summaryLine_variants() {
        // Several ports with errors: the worst one by name, then a count.
        XCTAssertEqual(SNMPInterfaces.summaryLine([
            port(1, "ge-0/0/1", errors: 5),
            port(2, "ge-0/0/2", errors: 90),
            port(3, "ge-0/0/3", up: false, errors: 1),
        ]), "2 of 3 up. ge-0/0/2: 90 errors. 2 other ports have errors too.")
        // Slow ports only stand out next to a gigabit one; one error is singular.
        XCTAssertEqual(SNMPInterfaces.summaryLine([
            port(1, "eth1", speed: 1_000_000_000),
            port(2, "eth2", speed: 100_000_000),
            port(3, "eth3", speed: 100_000_000),
            port(4, "eth4", speed: 10_000_000, errors: 1),
        ]), "4 of 4 up. 2 ports at 100 Mbps, 1 at 10 Mbps. eth4: 1 error.")
        // An old 100 Mbps switch: nothing is slower than its neighbors.
        XCTAssertEqual(SNMPInterfaces.summaryLine([
            port(1, "port1", speed: 100_000_000),
            port(2, "port2", speed: 100_000_000),
        ]), "2 of 2 up. No errors counted.")
        // Down ports and non-Ethernet links aren't called slow.
        XCTAssertEqual(SNMPInterfaces.summaryLine([
            port(1, "Gi0/1"),
            port(2, "Gi0/2", up: false, speed: 100_000_000),
            port(3, "Se0/0", speed: 1_544_000, type: 22),
        ]), "2 of 3 up. No errors counted.")
        // No error counters at all: say nothing about errors.
        XCTAssertEqual(SNMPInterfaces.summaryLine([port(1, "eth0", errors: nil)]), "1 of 1 up.")
    }

    func test_physicalFilter_onlyWhenItHidesSome() {
        XCTAssertFalse(SNMPInterfaces.physicalFilterApplies([port(1, "a"), port(2, "b")]))           // all physical
        XCTAssertFalse(SNMPInterfaces.physicalFilterApplies([port(1, "a", type: nil)]))              // no ifType
        XCTAssertFalse(SNMPInterfaces.physicalFilterApplies([port(1, "Vl1", type: 53)]))             // none physical
        XCTAssertTrue(SNMPInterfaces.physicalFilterApplies([port(1, "a"), port(2, "Po1", type: 161)]))
        for t: Int64 in [6, 7, 62, 69, 117, 71] { XCTAssertTrue(SNMPInterfaceFormat.isPhysical(t), "\(t)") }
        for t: Int64 in [1, 24, 53, 131, 135, 136, 161, 209] { XCTAssertFalse(SNMPInterfaceFormat.isPhysical(t), "\(t)") }
    }

    func test_lastChange() {
        let now = Date()
        XCTAssertNil(SNMPInterfaceFormat.lastChange(ticks: nil, sysUpTime: 100, now: now))
        XCTAssertEqual(SNMPInterfaceFormat.lastChange(ticks: 0, sysUpTime: nil, now: now), .notSinceStart(nil))
        XCTAssertEqual(SNMPInterfaceFormat.lastChange(ticks: 0, sysUpTime: 6_000, now: now),
                       .notSinceStart(now.addingTimeInterval(-60)))
        XCTAssertEqual(SNMPInterfaceFormat.lastChange(ticks: 4_000, sysUpTime: 10_000, now: now),
                       .at(now.addingTimeInterval(-60)))
        XCTAssertNil(SNMPInterfaceFormat.lastChange(ticks: 20_000, sysUpTime: 10_000, now: now))   // can't place it
        XCTAssertNil(SNMPInterfaceFormat.lastChange(ticks: 4_000, sysUpTime: nil, now: now))
        XCTAssertEqual(SNMPInterfaceFormat.changeText(.at(now.addingTimeInterval(-180)), now: now), "3 min ago")
    }

    // MARK: Watch: rate math

    private func point(_ v: SNMPValue, _ ticks: UInt32?, local: TimeInterval = 0) -> SNMPRateMeter.Point {
        SNMPRateMeter.Point(value: v, ticks: ticks, local: local)
    }

    func test_rate_normal64() {
        // 625,000,000 bytes in 5 s (500 ticks) = 1 Gbps.
        let r = SNMPRateMeter.rate(from: point(.counter64(1_000), 100),
                                   to: point(.counter64(625_001_000), 600), speedBps: 10_000_000_000)
        XCTAssertEqual(r, .rate(1_000_000_000))
    }

    func test_rate_32bitWrap() {
        // 999 bytes up to the top, then 1,001 more after wrapping: 2,000 bytes in 1 s.
        let r = SNMPRateMeter.rate(from: point(.counter32(UInt32.max - 999), 100),
                                   to: point(.counter32(1_000), 200), speedBps: 1_000_000_000)
        XCTAssertEqual(r, .rate(16_000))
    }

    func test_rate_32bitReset_isDropped() {
        // A wrap would mean ~2 Gbps on a 100 Mbps port: the counter was reset.
        let r = SNMPRateMeter.rate(from: point(.counter32(3_000_000_000), 100),
                                   to: point(.counter32(1_000), 600), speedBps: 100_000_000)
        XCTAssertEqual(r, .dropped(.counterReset))
    }

    func test_rate_64bitDecrease_isDropped() {
        var meter = SNMPRateMeter()
        let key = SNMPRateMeter.Key(ifIndex: 7, outbound: false)
        XCTAssertEqual(meter.ingest(key, value: .counter64(5_000_000), ticks: 100, local: 0, speedBps: 1_000_000_000), .baseline)
        XCTAssertEqual(meter.ingest(key, value: .counter64(1_000), ticks: 600, local: 5, speedBps: 1_000_000_000),
                       .dropped(.counterWentBack))
        // The next reading counts from the reset value.
        XCTAssertEqual(meter.ingest(key, value: .counter64(126_000), ticks: 1_100, local: 10, speedBps: 1_000_000_000),
                       .rate(200_000))
    }

    func test_rate_reboot_resetsBaseline() {
        var meter = SNMPRateMeter()
        let key = SNMPRateMeter.Key(ifIndex: 1, outbound: true)
        _ = meter.ingest(key, value: .counter64(9_000_000), ticks: 50_000, local: 0, speedBps: 0)
        // sysUpTime went backwards: the device restarted.
        XCTAssertEqual(meter.ingest(key, value: .counter64(500), ticks: 300, local: 5, speedBps: 0),
                       .dropped(.deviceRestarted))
        XCTAssertEqual(meter.ingest(key, value: .counter64(1_750), ticks: 800, local: 10, speedBps: 0),
                       .rate(2_000))
    }

    func test_rate_timeFallbacks() {
        // No sysUpTime: this Mac's clock.
        XCTAssertEqual(SNMPRateMeter.rate(from: point(.counter64(0), nil, local: 10),
                                          to: point(.counter64(1_000), nil, local: 12), speedBps: 0),
                       .rate(4_000))
        // Same sysUpTime twice (a cached reply): no rate, and the older baseline stays.
        var meter = SNMPRateMeter()
        let key = SNMPRateMeter.Key(ifIndex: 3, outbound: false)
        _ = meter.ingest(key, value: .counter64(0), ticks: 100, local: 0, speedBps: 0)
        XCTAssertEqual(meter.ingest(key, value: .counter64(0), ticks: 100, local: 2, speedBps: 0), .dropped(.noTimePassed))
        XCTAssertEqual(meter.ingest(key, value: .counter64(2_000), ticks: 300, local: 4, speedBps: 0), .rate(8_000))
        // A missing counter forgets the port.
        XCTAssertEqual(meter.ingest(key, value: .noSuchInstance, ticks: 400, local: 5, speedBps: 0), .dropped(.noValue))
        XCTAssertNil(meter.baselines[key])
        // Changing widths between readings can't be compared.
        XCTAssertEqual(SNMPRateMeter.rate(from: point(.counter32(5), 100), to: point(.counter64(10), 200), speedBps: 0),
                       .dropped(.noValue))
    }

    func test_linkPercent() {
        XCTAssertEqual(SNMPInterfaceFormat.linkPercent(inBps: 250_000_000, outBps: 10_000_000, speedBps: 1_000_000_000), 25)
        XCTAssertNil(SNMPInterfaceFormat.linkPercent(inBps: 5, outBps: 5, speedBps: 0))
        XCTAssertNil(SNMPInterfaceFormat.linkPercent(inBps: nil, outBps: nil, speedBps: 1_000))
        XCTAssertEqual(SNMPInterfaceFormat.percentText(0), "0%")
        XCTAssertEqual(SNMPInterfaceFormat.percentText(0.4), "<1%")
        XCTAssertEqual(SNMPInterfaceFormat.percentText(42.4), "42%")
    }

    // MARK: Watch: reading counters

    func test_watchRead_chunksAndUsesTheTableCounters() async throws {
        // 25 ports with 64-bit counters, plus port 26 with only 32-bit ones.
        var e: [(String, SNMPValue)] = [("1.3.6.1.2.1.1.3.0", .timeTicks(4_242))]
        var rows: [SNMPInterfaceRow] = []
        for i in 1...25 {
            e.append(("1.3.6.1.2.1.31.1.1.1.6.\(i)", .counter64(UInt64(i) * 100)))
            e.append(("1.3.6.1.2.1.31.1.1.1.10.\(i)", .counter64(UInt64(i) * 200)))
            rows.append(port(UInt32(i), "p\(i)"))
        }
        e.append(("1.3.6.1.2.1.2.2.1.10.26", .counter32(7)))
        e.append(("1.3.6.1.2.1.2.2.1.16.26", .counter32(8)))
        var old = port(26, "old")
        old.inWidth = .bits32; old.outWidth = .bits32
        rows.append(old)
        var none = port(27, "none")
        none.inWidth = nil; none.outWidth = nil
        rows.append(none)

        let targets = SNMPInterfaceWatch.targets(for: rows)
        XCTAssertEqual(targets.count, 26)      // port 27 has no counters to ask for
        XCTAssertEqual(targets.last?.inOID, OID([1,3,6,1,2,1,2,2,1,10,26]))

        let agent = FakeSNMPAgent(e)
        let readings = try await SNMPInterfaceWatch.read(agent.client(), targets, clock: { 1 })
        XCTAssertEqual(readings.count, 26)
        XCTAssertEqual(agent.pdus.filter { $0 == ASN1Tag.getRequest.rawValue }.count, 3)   // 10 + 10 + 6 ports
        XCTAssertEqual(readings[0], SNMPInterfaceWatch.Reading(ifIndex: 1, inValue: .counter64(100),
                                                               outValue: .counter64(200), ticks: 4_242, local: 1))
        XCTAssertEqual(readings[25].inValue, .counter32(7))
        XCTAssertEqual(readings[25].outValue, .counter32(8))
    }

    func test_wrapRisk() {
        var fast = port(1, "Te1/1", speed: 10_000_000_000)
        fast.inWidth = .bits32
        XCTAssertEqual(SNMPInterfaceWatch.wrapRisk([fast], interval: 2).count, 0)    // 2.5 GB per 2 s
        XCTAssertEqual(SNMPInterfaceWatch.wrapRisk([fast], interval: 5).count, 1)    // 6.25 GB per 5 s
        XCTAssertEqual(SNMPInterfaceWatch.wrapRisk([port(2, "Te1/2", speed: 10_000_000_000)], interval: 30).count, 0)
    }

    @MainActor
    func test_watcher_stopClearsState() async throws {
        let agent = FakeSNMPAgent(mib())
        let report = try await SNMPInterfaces.query(agent.client(), maxRows: 1000)
        let watcher = SNMPInterfaceWatcher()
        var many = report.rows
        for i in 100..<250 { many.append(port(UInt32(i), "x\(i)")) }
        watcher.start(client: agent.client(), rows: many)
        XCTAssertTrue(watcher.isWatching)
        XCTAssertEqual(watcher.watchedIDs.count, SNMPInterfaceWatch.maxPorts)
        XCTAssertTrue(watcher.watchedIDs.contains(1))
        watcher.setRows(SNMPInterfaces.shownRows(report.rows, physicalOnly: true))
        XCTAssertEqual(watcher.watchedIDs, [1, 2, 3])
        watcher.stop()
        XCTAssertFalse(watcher.isWatching)
        XCTAssertTrue(watcher.watchedIDs.isEmpty)
        XCTAssertTrue(watcher.live.isEmpty)
    }

    /// The whole loop against a device whose counters rise 1 Mbps in and
    /// 2 Mbps out per second of its own clock, whatever the real time.
    @MainActor
    func test_watcher_computesRatesAndNeverOverlaps() async throws {
        let device = RisingCounters()
        let client = SNMPClient(host: "fake", timeout: 1, retries: 0,
                                transport: { m in try await device.reply(m) })
        var r = port(5, "Gi1/0/5")
        r.inWidth = .bits64; r.outWidth = .bits64
        let watcher = SNMPInterfaceWatcher()
        watcher.interval = 0.5          // the loop waits at least 0.5 s between readings
        watcher.start(client: client, rows: [r])
        defer { watcher.stop() }

        let deadline = Date().addingTimeInterval(5)
        while (watcher.live[5]?.history.count ?? 0) < 2 && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let live = try XCTUnwrap(watcher.live[5])
        XCTAssertGreaterThanOrEqual(live.history.count, 2)
        XCTAssertEqual(live.inBps ?? 0, 1_000_000, accuracy: 1)
        XCTAssertEqual(live.outBps ?? 0, 2_000_000, accuracy: 1)
        XCTAssertNil(watcher.problem)
        XCTAssertEqual(device.maxInFlight, 1)
    }
}

extension SNMPInterfacesTests {
    @MainActor
    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
    }

    /// A refusal stops watching and says so; no answer keeps asking; Stop
    /// clears the "keeps asking" note.
    @MainActor
    func test_watcher_failures() async throws {
        var r = port(1, "Gi1/0/1")
        r.inWidth = .bits64; r.outWidth = .bits64

        let refuses = SNMPClient(host: "fake", timeout: 1, retries: 0, transport: { m in
            SNMPMessage(version: m.version, community: m.community, pduTag: ASN1Tag.getResponse.rawValue,
                        requestID: m.requestID, errorStatus: 16, errorIndex: 1, varBinds: m.varBinds)
        })
        let w1 = SNMPInterfaceWatcher()
        w1.start(client: refuses, rows: [r])
        try await waitFor { !w1.isWatching }
        XCTAssertFalse(w1.isWatching)
        XCTAssertEqual(w1.problem, "The device refused to give these counters to this community (authorizationError), so watching stopped.")

        let silent = SNMPClient(host: "fake", timeout: 1, retries: 0, transport: { _ in throw SNMPError.timeout })
        let w2 = SNMPInterfaceWatcher()
        w2.start(client: silent, rows: [r])
        try await waitFor { w2.problem != nil }
        XCTAssertTrue(w2.isWatching)
        XCTAssertTrue(w2.problem?.hasPrefix("No answer to the reading at ") ?? false)
        XCTAssertTrue(w2.problem?.hasSuffix("SNAP keeps asking every 5 s.") ?? false)
        w2.stop()
        XCTAssertNil(w2.problem)
    }
}

// MARK: - Review fixes

extension SNMPInterfacesTests {
    private static let engineTime = "1.3.6.1.6.3.10.2.1.3.0"

    // MARK: sysUpTime wrap

    /// Up 600 days: sysUpTime has started over and reads about 103 days. A
    /// change from before the wrap used to read as recent ("53 d ago"), and
    /// "unchanged since start" said 103 d.
    func test_lastChange_sysUpTimeWrapped() {
        let now = Date()
        let day: UInt64 = 86_400
        let wrapped: UInt64 = 600 * day
        XCTAssertNil(SNMPInterfaceFormat.lastChange(ticks: 50 * day * 100, sysUpTime: 103 * day * 100,
                                                    engineTime: wrapped, now: now))
        XCTAssertEqual(SNMPInterfaceFormat.lastChange(ticks: 0, sysUpTime: 103 * day * 100, engineTime: wrapped, now: now),
                       .notSinceStart(now.addingTimeInterval(-Double(wrapped))))
        // Just under 497.1 days, sysUpTime hasn't wrapped yet and is used as before.
        XCTAssertEqual(SNMPInterfaceFormat.lastChange(ticks: 4_000, sysUpTime: 10_000, engineTime: 42_949_672, now: now),
                       .at(now.addingTimeInterval(-60)))
        XCTAssertEqual(SNMPInterfaceFormat.lastChange(ticks: 0, sysUpTime: 6_000, engineTime: 60, now: now),
                       .notSinceStart(now.addingTimeInterval(-60)))
    }

    func test_query_readsSnmpEngineTime_forWrappedUpTime() async throws {
        var e = mib()
        e.append((Self.engineTime, .integer(51_840_000)))       // 600 days
        let report = try await SNMPInterfaces.query(FakeSNMPAgent(e).client(), maxRows: 1000)
        guard case .notSinceStart(let started?)? = try row(report, 1).lastChange else {
            return XCTFail("ifLastChange 0 should still read as unchanged since start")
        }
        XCTAssertEqual(Date().timeIntervalSince(started), 51_840_000, accuracy: 5)
        XCTAssertTrue(SNMPInterfaceFormat.changeHelp(try row(report, 1).lastChange, status: "up", now: Date())
            .hasPrefix("No change since the device's SNMP service started, 600 d ago"))
        XCTAssertNil(try row(report, 2).lastChange)            // can't tell which round of the clock
        XCTAssertEqual(SNMPInterfaceFormat.changeText(try row(report, 2).lastChange, now: Date()), "")

        // Engine time under 497 days: as before.
        var young = mib()
        young.append((Self.engineTime, .integer(10_000)))
        let r2 = try await SNMPInterfaces.query(FakeSNMPAgent(young).client(), maxRows: 1000)
        XCTAssertEqual(SNMPInterfaceFormat.changeText(try row(r2, 2).lastChange, now: Date()), "3 min ago")

        // v1 without SNMP-FRAMEWORK-MIB: the missing OID doesn't cost sysUpTime.
        let agent = FakeSNMPAgent(mib(xTable: false)); agent.v1 = true
        let r3 = try await SNMPInterfaces.query(agent.client(version: .v1), maxRows: 1000)
        XCTAssertEqual(SNMPInterfaceFormat.changeText(try row(r3, 2).lastChange, now: Date()), "3 min ago")
    }

    /// An agent that fails the clocks GET over snmpEngineTime still gets sysUpTime.
    func test_query_engineTimeError_fallsBackToUpTimeAlone() async throws {
        let agent = FakeSNMPAgent(mib())
        let engine = OID(string: Self.engineTime)!
        let client = SNMPClient(host: "fake", timeout: 1, retries: 0, transport: { m in
            if m.varBinds.contains(where: { $0.oid == engine }) {
                return SNMPMessage(version: m.version, community: m.community, pduTag: ASN1Tag.getResponse.rawValue,
                                   requestID: m.requestID, errorStatus: 5, errorIndex: 2, varBinds: m.varBinds)
            }
            return try agent.reply(m)
        })
        let report = try await SNMPInterfaces.query(client, maxRows: 1000)
        XCTAssertEqual(SNMPInterfaceFormat.changeText(try row(report, 2).lastChange, now: Date()), "3 min ago")
        XCTAssertTrue(report.unread.isEmpty)
    }

    // MARK: Unreadable sysUpTime reply

    /// A garbled reply to the sysUpTime GET used to fail the whole query.
    func test_query_unreadableUpTimeReply_keepsTheTable() async throws {
        let agent = FakeSNMPAgent(mib())
        let client = SNMPClient(host: "fake", timeout: 1, retries: 0, transport: { m in
            if m.pduTag == ASN1Tag.getRequest.rawValue, m.varBinds.contains(where: { $0.oid == SNMPOID.sysUpTime }) {
                throw SNMPError.truncated
            }
            return try agent.reply(m)
        })
        let report = try await SNMPInterfaces.query(client, maxRows: 1000)
        XCTAssertEqual(report.rows.count, 5)
        XCTAssertEqual(report.unread, ["last change times"])
        XCTAssertEqual(try row(report, 1).lastChange, .notSinceStart(nil))
        XCTAssertNil(try row(report, 2).lastChange)
        XCTAssertEqual(try row(report, 2).alias, "Printer")
        XCTAssertEqual(try row(report, 2).errorTotal, 1_240)
    }

    // MARK: Speeds

    /// Ports with ifDescr "portN", up, the given ifSpeed and (when not nil)
    /// ifHighSpeed, and 32-bit counters.
    private func speedAgent(_ ports: [(UInt32, UInt32?)]) -> FakeSNMPAgent {
        var e: [(String, SNMPValue)] = [("1.3.6.1.2.1.1.3.0", .timeTicks(1_000))]
        for (i, p) in ports.enumerated() {
            let idx = i + 1
            e.append(("1.3.6.1.2.1.2.2.1.2.\(idx)", .octetString(Data("port\(idx)".utf8))))
            e.append(("1.3.6.1.2.1.2.2.1.5.\(idx)", .gauge32(p.0)))
            e.append(("1.3.6.1.2.1.2.2.1.8.\(idx)", .integer(1)))
            e.append(("1.3.6.1.2.1.2.2.1.10.\(idx)", .counter32(1)))
            e.append(("1.3.6.1.2.1.2.2.1.16.\(idx)", .counter32(2)))
            if let h = p.1 { e.append(("1.3.6.1.2.1.31.1.1.1.15.\(idx)", .gauge32(h))) }
        }
        return FakeSNMPAgent(e)
    }

    func test_speed_highSpeedWins_whenIfSpeedCantHoldIt() {
        // 10G and 5G reported modulo 2^32.
        XCTAssertEqual(SNMPInterfaceFormat.effectiveSpeedBps(ifSpeed: 1_410_065_408, highSpeedMbps: 10_000), 10_000_000_000)
        XCTAssertEqual(SNMPInterfaceFormat.effectiveSpeedBps(ifSpeed: 705_032_704, highSpeedMbps: 5_000), 5_000_000_000)
        // ifSpeed can hold these, so it's kept (ifHighSpeed rounds to Mbps).
        XCTAssertEqual(SNMPInterfaceFormat.effectiveSpeedBps(ifSpeed: 2_500_000_000, highSpeedMbps: 2_500), 2_500_000_000)
        XCTAssertEqual(SNMPInterfaceFormat.effectiveSpeedBps(ifSpeed: 1_544_000, highSpeedMbps: 2), 1_544_000)
        XCTAssertEqual(SNMPInterfaceFormat.effectiveSpeedBps(ifSpeed: 100_000_000, highSpeedMbps: nil), 100_000_000)
        XCTAssertTrue(SNMPInterfaceFormat.speedAtCeiling(ifSpeed: 4_294_967_295, highSpeedMbps: nil))
        XCTAssertTrue(SNMPInterfaceFormat.speedAtCeiling(ifSpeed: 4_294_967_295, highSpeedMbps: 0))
        XCTAssertFalse(SNMPInterfaceFormat.speedAtCeiling(ifSpeed: 4_294_967_295, highSpeedMbps: 10_000))
        XCTAssertFalse(SNMPInterfaceFormat.speedAtCeiling(ifSpeed: 1_000_000_000, highSpeedMbps: nil))
    }

    func test_query_wrappedAndCeilingSpeeds() async throws {
        // Port 1: a wrapped ifSpeed with ifHighSpeed 10000. Port 2: ifSpeed
        // at its ceiling and no ifHighSpeed for it.
        let report = try await SNMPInterfaces.query(speedAgent([(1_410_065_408, 10_000), (4_294_967_295, nil)]).client(),
                                                    maxRows: 1000)
        let tenGig = try row(report, 1)
        XCTAssertEqual(tenGig.speedRaw, 10_000_000_000)
        XCTAssertEqual(tenGig.speed, "10 Gbps")
        XCTAssertEqual(SNMPInterfaceFormat.linkPercent(inBps: 3_000_000_000, outBps: nil, speedBps: tenGig.speedRaw), 30)

        let fast = try row(report, 2)
        XCTAssertTrue(fast.speedAtCeiling)
        XCTAssertEqual(fast.speedRaw, 0)                // so % of link and the pinned tile leave it out
        XCTAssertEqual(fast.speed, "over 4.29 Gbps")
        XCTAssertEqual(fast.speedSort, 4_294_967_295)
        XCTAssertNil(SNMPInterfaceFormat.linkPercent(inBps: 3_000_000_000, outBps: nil, speedBps: fast.speedRaw))
        XCTAssertTrue(SNMPInterfaceFormat.detailLine(fast).contains("over 4.29 Gbps"))
        XCTAssertTrue(SNMPInterfaces.exportText(report).contains("2\tport2\t\t\tup\tover 4.29 Gbps\t"))
        // 32-bit counters past 4.29 Gbps can start over twice in 10 s; at 5 s it depends on the real speed.
        XCTAssertEqual(SNMPInterfaceWatch.wrapRisk([fast], interval: 10).count, 1)
        XCTAssertEqual(SNMPInterfaceWatch.wrapRisk([fast], interval: 5).count, 0)
    }

    // MARK: Ports without counters

    /// A Gauge32 octet "counter" can't give a rate, so it isn't one.
    func test_query_gaugeOctets_areNotCounters() async throws {
        let agent = FakeSNMPAgent([
            ("1.3.6.1.2.1.2.2.1.2.1", .octetString(Data("eth0".utf8))),
            ("1.3.6.1.2.1.2.2.1.8.1", .integer(1)),
            ("1.3.6.1.2.1.2.2.1.10.1", .gauge32(5)),
            ("1.3.6.1.2.1.2.2.1.16.1", .counter32(6)),
        ])
        let report = try await SNMPInterfaces.query(agent.client(), maxRows: 1000)
        let eth0 = try row(report, 1)
        XCTAssertNil(eth0.inWidth)
        XCTAssertEqual(eth0.outWidth, .bits32)
        let target = try XCTUnwrap(SNMPInterfaceWatch.targets(for: [eth0]).first)
        XCTAssertNil(target.inOID)
        XCTAssertNotNil(target.outOID)
    }

    @MainActor
    func test_watch_portsWithoutCounters_sayNotReported() async throws {
        var none = port(1, "Gi1/0/1"); none.inWidth = nil; none.outWidth = nil
        var inOnly = port(2, "Gi1/0/2"); inOnly.inWidth = .bits64; inOnly.outWidth = nil
        var missing = port(3, "Gi1/0/3"); missing.inWidth = .bits32; missing.outWidth = .bits32

        // Nothing to ask for: Watch live is off, and says why.
        XCTAssertFalse(SNMPInterfaceWatch.hasCounters([]))
        XCTAssertFalse(SNMPInterfaceWatch.hasCounters([none]))
        XCTAssertTrue(SNMPInterfaceWatch.hasCounters([none, inOnly]))
        XCTAssertEqual(SNMPInterfacesPane.noCountersHelp([none]),
                       "The device didn't report traffic counters for these ports, so there's nothing to watch.")

        // RisingCounters has 64-bit counters only: port 3's 32-bit ones come back noSuchObject.
        let device = RisingCounters()
        let client = SNMPClient(host: "fake", timeout: 1, retries: 0, transport: { m in try await device.reply(m) })
        let watcher = SNMPInterfaceWatcher()
        watcher.interval = 0.5
        watcher.start(client: client, rows: [none, inOnly, missing])
        defer { watcher.stop() }
        // Known before any reading.
        XCTAssertEqual(watcher.live[1]?.inGap, .notReported)
        XCTAssertEqual(watcher.live[1]?.outGap, .notReported)
        XCTAssertEqual(watcher.live[2]?.outGap, .notReported)
        XCTAssertNil(watcher.live[2]?.inGap)

        try await waitFor { (watcher.live[2]?.history.count ?? 0) >= 1 }
        let two = try XCTUnwrap(watcher.live[2])
        XCTAssertEqual(two.inBps ?? 0, 1_000_000, accuracy: 1)
        XCTAssertEqual(two.outGap, .notReported)
        XCTAssertFalse(two.noCounters)
        let three = try XCTUnwrap(watcher.live[3])
        XCTAssertEqual(three.inGap, .notReported)
        XCTAssertEqual(three.outGap, .notReported)
        XCTAssertTrue(three.noCounters)
        XCTAssertEqual(SNMPInterfaceWatch.noCountersHint(three),
                       "The device isn't reporting traffic counters for this port, so there's nothing to chart.")
        XCTAssertTrue(try XCTUnwrap(watcher.live[1]).noCounters)
        XCTAssertNil(watcher.problem)
    }

    // MARK: One failing counter

    /// A device that fails any GET including `bad` with `status`.
    private func failing(_ bad: Set<OID>, status: Int32 = 5,
                         _ next: @escaping SNMPClient.Transport) -> SNMPClient {
        SNMPClient(host: "fake", timeout: 1, retries: 0, transport: { m in
            if m.pduTag == ASN1Tag.getRequest.rawValue, let i = m.varBinds.firstIndex(where: { bad.contains($0.oid) }) {
                return SNMPMessage(version: m.version, community: m.community, pduTag: ASN1Tag.getResponse.rawValue,
                                   requestID: m.requestID, errorStatus: status, errorIndex: Int32(i + 1), varBinds: m.varBinds)
            }
            return try await next(m)
        })
    }

    /// One port's counter failing with genErr used to throw away every
    /// port's reading, every poll.
    func test_watchRead_oneFailingCounter_keepsTheOthers() async throws {
        var e: [(String, SNMPValue)] = [("1.3.6.1.2.1.1.3.0", .timeTicks(4_242))]
        var rows: [SNMPInterfaceRow] = []
        for i in 1...25 {
            e.append(("1.3.6.1.2.1.31.1.1.1.6.\(i)", .counter64(UInt64(i) * 100)))
            e.append(("1.3.6.1.2.1.31.1.1.1.10.\(i)", .counter64(UInt64(i) * 200)))
            rows.append(port(UInt32(i), "p\(i)"))
        }
        let agent = FakeSNMPAgent(e)
        let bad = OID(SNMPOID.ifHCInOctets.components + [13])
        let client = failing([bad]) { m in try agent.reply(m) }
        let readings = try await SNMPInterfaceWatch.read(client, SNMPInterfaceWatch.targets(for: rows), clock: { 1 })
        XCTAssertEqual(readings.count, 25)
        let r13 = try XCTUnwrap(readings.first { $0.ifIndex == 13 })
        XCTAssertNil(r13.inValue)
        XCTAssertEqual(r13.inError, "genErr")
        XCTAssertEqual(r13.outValue, .counter64(2_600))
        XCTAssertNil(r13.outError)
        XCTAssertEqual(r13.ticks, 4_242)
        XCTAssertEqual(SNMPInterfaceWatch.gap(value: r13.inValue, error: r13.inError), .error("genErr"))
        for r in readings where r.ifIndex != 13 {
            XCTAssertEqual(r.inValue, .counter64(UInt64(r.ifIndex) * 100), "\(r.ifIndex)")
            XCTAssertNil(r.inError)
            XCTAssertEqual(r.ticks, 4_242)
        }
    }

    /// A refusal for some counters is per port; for all of them it stops Watch.
    func test_watchRead_refusals() async throws {
        var e: [(String, SNMPValue)] = [("1.3.6.1.2.1.1.3.0", .timeTicks(1))]
        var rows: [SNMPInterfaceRow] = []
        for i in 1...12 {
            e.append(("1.3.6.1.2.1.31.1.1.1.6.\(i)", .counter64(1)))
            e.append(("1.3.6.1.2.1.31.1.1.1.10.\(i)", .counter64(2)))
            rows.append(port(UInt32(i), "p\(i)"))
        }
        let agent = FakeSNMPAgent(e)
        let targets = SNMPInterfaceWatch.targets(for: rows)
        // The first GET (ports 1-10) is refused, the second isn't.
        let some = failing([OID(SNMPOID.ifHCInOctets.components + [1])], status: 16) { m in try agent.reply(m) }
        let readings = try await SNMPInterfaceWatch.read(some, targets, clock: { 1 })
        XCTAssertEqual(readings.first { $0.ifIndex == 1 }?.inError, "authorizationError")
        XCTAssertEqual(readings.first { $0.ifIndex == 11 }?.inValue, .counter64(1))
        // Every counter refused: thrown, so the watcher stops.
        let all = failing(Set(targets.flatMap { [$0.inOID, $0.outOID].compactMap { $0 } }), status: 16) { m in try agent.reply(m) }
        do {
            _ = try await SNMPInterfaceWatch.read(all, targets, clock: { 1 })
            XCTFail("expected authorizationError")
        } catch SNMPError.errorStatus(16, _, _) {}
    }

    @MainActor
    func test_watcher_oneFailingCounter_keepsWatchingTheRest() async throws {
        var a = port(1, "Gi1/0/1"); a.inWidth = .bits64; a.outWidth = .bits64
        var b = port(2, "Gi1/0/2"); b.inWidth = .bits64; b.outWidth = .bits64
        let device = RisingCounters()
        let client = failing([OID(SNMPOID.ifHCInOctets.components + [2])]) { m in try await device.reply(m) }
        let watcher = SNMPInterfaceWatcher()
        watcher.interval = 0.5
        watcher.start(client: client, rows: [a, b])
        defer { watcher.stop() }
        try await waitFor { (watcher.live[1]?.history.count ?? 0) >= 1 }
        XCTAssertNil(watcher.problem)
        let one = try XCTUnwrap(watcher.live[1])
        XCTAssertEqual(one.inBps ?? 0, 1_000_000, accuracy: 1)
        XCTAssertEqual(one.outBps ?? 0, 2_000_000, accuracy: 1)
        let two = try XCTUnwrap(watcher.live[2])
        XCTAssertEqual(two.inGap, .error("genErr"))
        XCTAssertNil(two.inBps)
        XCTAssertEqual(two.outBps ?? 0, 2_000_000, accuracy: 1)
    }

    // MARK: Column widths

    /// At the narrowest pane the columns sit at their ideal widths: every
    /// status label and error count has to fit there. "notPresent" and
    /// "lowerLayerDown" used to clip, and so did counts of 100,000 or more.
    @MainActor
    func test_statusAndErrors_fitTheirColumns() {
        func width(_ s: String, _ font: NSFont) -> CGFloat { (s as NSString).size(withAttributes: [.font: font]).width }
        let statusFont = NSFont.systemFont(ofSize: 12)
        var labels = (1...7).map { SNMPInterfaceFormat.statusLabel(admin: .integer(1), oper: .integer(Int64($0))) }
        labels += ["disabled", SNMPInterfaceFormat.statusLabel(admin: nil, oper: .integer(99))]
        XCTAssertTrue(labels.contains("notPresent") && labels.contains("lowerLayerDown"))
        for s in labels {
            XCTAssertLessThanOrEqual(width(SNMPInterfaceFormat.statusShort(s), statusFont), SNMPInterfacesPane.statusWidth, s)
        }
        XCTAssertEqual(SNMPInterfaceFormat.statusShort("lowerLayerDown"), "lower down")
        XCTAssertTrue(SNMPInterfaceFormat.statusHelp("lowerLayerDown").hasPrefix("lowerLayerDown: "))
        XCTAssertTrue(SNMPInterfaceFormat.statusHelp("notPresent").hasPrefix("notPresent: "))

        let errorFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        let counts: [UInt64] = [0, 99_999, 100_000, 123_456, 999_999, 1_234_567, 9_999_999, 45_600_000,
                                999_999_999, 4_294_967_295, 999_999_999_999, 99_999_999_999_999]
        for n in counts {
            XCTAssertLessThanOrEqual(width(SNMPInterfaceFormat.compactCount(n), errorFont), SNMPInterfacesPane.errorsWidth, "\(n)")
        }
        XCTAssertEqual(SNMPInterfaceFormat.compactCount(99_999), 99_999.formatted())
        XCTAssertEqual(SNMPInterfaceFormat.compactCount(123_456), "123K")
        XCTAssertEqual(SNMPInterfaceFormat.compactCount(999_999), "999K")        // rounded down, never up
        XCTAssertEqual(SNMPInterfaceFormat.compactCount(1_000_000), "1M")
        XCTAssertEqual(SNMPInterfaceFormat.compactCount(1_234_567), "1.2M")
        XCTAssertEqual(SNMPInterfaceFormat.compactCount(1_999_999), "1.9M")
        XCTAssertEqual(SNMPInterfaceFormat.compactCount(45_600_000), "45M")
        XCTAssertEqual(SNMPInterfaceFormat.compactCount(4_294_967_295), "4.2B")
    }

    // MARK: Port types

    /// ADSL2/ADSL2+ lines and cable RF ports used to be hidden as virtual.
    func test_physicalFilter_keepsDSLAndCableLines() {
        for t: Int64 in [94, 95, 96, 97, 168, 169, 230, 238, 251, 128, 129, 205, 250] {
            XCTAssertTrue(SNMPInterfaceFormat.isPhysical(t), "\(t)")
        }
        XCTAssertFalse(SNMPInterfaceFormat.isPhysical(127))      // docsCableMaclayer: a MAC layer, not a line
        XCTAssertEqual(SNMPInterfaceFormat.typeName(238), "ADSL2+")
        XCTAssertEqual(SNMPInterfaceFormat.typeName(230), "ADSL2")
        XCTAssertEqual(SNMPInterfaceFormat.typeName(128), "cable downstream")
        XCTAssertEqual(SNMPInterfaceFormat.typeName(129), "cable upstream")
        // A DSL router: Ethernet, Wi-Fi, PPP, and an ADSL2+ line, which stays.
        let rows = [port(1, "eth0"), port(2, "wlan0", type: 71), port(3, "ppp0", type: 23), port(4, "dsl0", type: 238)]
        XCTAssertTrue(SNMPInterfaces.physicalFilterApplies(rows))
        XCTAssertEqual(SNMPInterfaces.shownRows(rows, physicalOnly: true).map(\.id), [1, 2, 4])
    }

    // MARK: Changed tooltip

    /// ifLastChange follows the link, not the admin setting: a port down for
    /// 120 days and turned off today still says 120 d.
    func test_changeHelp_disabledPort_describesTheLink() {
        let now = Date()
        let change = SNMPPortChange.at(now.addingTimeInterval(-120 * 86_400))
        XCTAssertEqual(SNMPInterfaceFormat.changeHelp(change, status: "disabled", now: now),
                       "The link last changed state 120 d ago, by the device's clock (ifLastChange). The device doesn't report when the port was turned off.")
        XCTAssertEqual(SNMPInterfaceFormat.changeHelp(change, status: "down", now: now),
                       "Became down 120 d ago, by the device's clock (ifLastChange).")
    }

    // MARK: 32-bit reset with no speed

    /// A PPP link (ifSpeed 0) reconnects and its counter restarts: that used
    /// to read as a wrap worth about 6.4 Gbps.
    func test_rate_32bitReset_withNoSpeed_isDropped() {
        XCTAssertEqual(SNMPRateMeter.rate(from: point(.counter32(300_000_000), 100),
                                          to: point(.counter32(5_000), 600), speedBps: 0),
                       .dropped(.counterReset))
        // A real wrap from the top half still counts.
        XCTAssertEqual(SNMPRateMeter.rate(from: point(.counter32(UInt32.max - 999), 100),
                                          to: point(.counter32(1_000), 200), speedBps: 0),
                       .rate(16_000))
        // The next reading counts from the reset value.
        var meter = SNMPRateMeter()
        let key = SNMPRateMeter.Key(ifIndex: 9, outbound: false)
        _ = meter.ingest(key, value: .counter32(300_000_000), ticks: 100, local: 0, speedBps: 0)
        XCTAssertEqual(meter.ingest(key, value: .counter32(5_000), ticks: 600, local: 5, speedBps: 0), .dropped(.counterReset))
        XCTAssertEqual(meter.ingest(key, value: .counter32(130_000), ticks: 1_100, local: 10, speedBps: 0), .rate(200_000))
    }
}

/// Times out every request from the first one at or past `from`.
private final class GoesQuiet: @unchecked Sendable {
    private let lock = NSLock()
    private let from: OID
    private var quiet = false
    private(set) var timeouts = 0
    init(from: OID) { self.from = from }

    func check(_ m: SNMPMessage) throws {
        lock.lock(); defer { lock.unlock() }
        if !quiet, let first = m.varBinds.first?.oid, first >= from { quiet = true }
        if quiet { timeouts += 1; throw SNMPError.timeout }
    }
}

/// A scripted agent for Watch: each GET is one more second on the device
/// (sysUpTime + 100 ticks), with ifHCInOctets + 125,000 and ifHCOutOctets
/// + 250,000. Records how many requests were in flight at once.
private final class RisingCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var polls: UInt64 = 0
    private var inFlight = 0
    private(set) var maxInFlight = 0

    private func begin() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        polls += 1
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        return polls
    }
    private func end() { lock.lock(); inFlight -= 1; lock.unlock() }

    func reply(_ m: SNMPMessage) async throws -> SNMPMessage {
        let n = begin()
        try await Task.sleep(nanoseconds: 20_000_000)
        end()

        let vbs: [SNMPVarBind] = m.varBinds.map { vb in
            let c = vb.oid.components
            if vb.oid == SNMPOID.sysUpTime { return SNMPVarBind(oid: vb.oid, value: .timeTicks(UInt32(n * 100))) }
            if Array(c.dropLast()) == SNMPOID.ifHCInOctets.components {
                return SNMPVarBind(oid: vb.oid, value: .counter64(n * 125_000))
            }
            if Array(c.dropLast()) == SNMPOID.ifHCOutOctets.components {
                return SNMPVarBind(oid: vb.oid, value: .counter64(n * 250_000))
            }
            return SNMPVarBind(oid: vb.oid, value: .noSuchObject)
        }
        return SNMPMessage(version: m.version, community: m.community, pduTag: ASN1Tag.getResponse.rawValue,
                           requestID: m.requestID, errorStatus: 0, errorIndex: 0, varBinds: vbs)
    }
}
