// SNMPHealthTests.swift
// SNAP — Tests
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md

import XCTest
@testable import SNAP

final class SNMPHealthTests: XCTestCase {

    // MARK: - Fake devices

    private func text(_ s: String) -> SNMPValue { .octetString(Data(s.utf8)) }

    private let systemGroup: [(String, SNMPValue)] = [
        ("1.3.6.1.2.1.1.1.0", .octetString(Data("Test device".utf8))),
        ("1.3.6.1.2.1.1.5.0", .octetString(Data("device-1".utf8))),
    ]

    /// A color laser: four toners, a waste box, a page counter, idle with low paper.
    private func printerMIB(black: Int64 = 8, blackMax: Int64 = 100, waste: Int64 = 60, errorBits: [UInt8] = [0x80, 0x00],
                            descriptions: Bool = true) -> [(String, SNMPValue)] {
        let s = "1.3.6.1.2.1.43.11.1.1"
        let names = ["Black Toner Cartridge", "Cyan Toner", "Magenta Toner", "Yellow Toner", "Waste Toner Box"]
        let levels: [Int64] = [black, 46, 70, -3, waste]
        var e = systemGroup
        for i in 1...5 {
            e.append(("\(s).4.1.\(i)", .integer(i == 5 ? 4 : 3)))        // class: consumed, or a receptacle
            e.append(("\(s).5.1.\(i)", .integer(i == 5 ? 4 : 3)))        // type: toner / waste toner
            if descriptions { e.append(("\(s).6.1.\(i)", text(names[i - 1]))) }
            e.append(("\(s).8.1.\(i)", .integer(i == 1 ? blackMax : 100)))
            e.append(("\(s).9.1.\(i)", .integer(levels[i - 1])))
        }
        e.append(("1.3.6.1.2.1.43.10.2.1.3.1.1", .integer(7)))           // impressions
        e.append(("1.3.6.1.2.1.43.10.2.1.4.1.1", .counter32(812)))
        e.append(("1.3.6.1.2.1.25.3.5.1.1.1", .integer(3)))              // idle
        e.append(("1.3.6.1.2.1.25.3.5.1.2.1", .octetString(Data(errorBits))))
        return e
    }

    private func upsMIB(source: Int64 = 3, status: Int64 = 2, secondsOnBattery: Int64 = 0,
                        minutes: Int64 = 42, charge: Int64 = 100, load: Int64 = 18,
                        alarms: [UInt32] = []) -> [(String, SNMPValue)] {
        let u = "1.3.6.1.2.1.33.1"
        var e = systemGroup + [
            ("\(u).1.1.0", text("Eaton")),
            ("\(u).1.2.0", text("5PX 1500")),
            ("\(u).2.1.0", .integer(status)),
            ("\(u).2.2.0", .integer(secondsOnBattery)),
            ("\(u).2.3.0", .integer(minutes)),
            ("\(u).2.4.0", .integer(charge)),
            ("\(u).4.1.0", .integer(source)),
            ("\(u).4.4.1.5.1", .integer(load)),
            ("\(u).6.1.0", .gauge32(UInt32(alarms.count))),
        ]
        for (i, a) in alarms.enumerated() {
            e.append(("\(u).6.2.1.2.\(i + 1)", .oid(OID([1,3,6,1,2,1,33,1,6,3, a]))))
        }
        return e
    }

    private func apcMIB(output: Int64 = 2, capacity: UInt32 = 100, runtimeTicks: UInt32 = 252_000,
                        replace: Int64 = 1, load: UInt32 = 18) -> [(String, SNMPValue)] {
        let a = "1.3.6.1.4.1.318.1.1.1"
        return systemGroup + [
            ("\(a).1.1.1.0", text("Smart-UPS 1500")),
            ("\(a).2.1.1.0", .integer(2)),
            ("\(a).2.2.1.0", .gauge32(capacity)),
            ("\(a).2.2.3.0", .timeTicks(runtimeTicks)),
            ("\(a).2.2.4.0", .integer(replace)),
            ("\(a).4.1.1.0", .integer(output)),
            ("\(a).4.2.3.0", .gauge32(load)),
        ]
    }

    /// Integer32 as an old agent sends it: values over 2^31 wrap negative.
    private func int32(_ v: UInt64) -> SNMPValue { .integer(Int64(Int32(truncatingIfNeeded: v))) }

    /// A Synology-like NAS: net-snmp memory entries, tmpfs and cgroup mounts,
    /// a 16 TB volume whose size wraps negative, a Docker bind mount of it,
    /// a tiny EFI partition, a snap image, and four processors.
    private func synologyMIB(volumeUsedUnits: UInt64 = 3_593_750_000) -> [(String, SNMPValue)] {
        let st = "1.3.6.1.2.1.25.2.3.1"
        let type = { (n: UInt32) -> SNMPValue in .oid(OID([1,3,6,1,2,1,25,2,1, n])) }
        // (index, type, description, units, size, used)
        let rows: [(Int, UInt32, String, Int64, UInt64, UInt64)] = [
            (1,  2, "Physical memory", 1024, 4_000_000, 3_600_000),
            (3,  3, "Virtual memory",  1024, 6_000_000, 3_700_000),
            (6,  1, "Memory buffers",  1024, 4_000_000, 100_000),
            (7,  1, "Cached memory",   1024, 2_000_000, 2_000_000),
            (10, 3, "Swap space",      1024, 2_000_000, 100_000),
            (31, 4, "/",               4096, 585_937, 351_562),
            (35, 4, "/dev/shm",        4096, 500_000, 10),
            (36, 4, "/run",            4096, 500_000, 2_000),
            (37, 4, "/sys/fs/cgroup",  4096, 500_000, 0),
            (40, 4, "/boot/efi",       4096, 12_000, 1_000),
            (45, 4, "/snap/core/1",    4096, 30_000, 30_000),
            (51, 4, "/volume1",        4096, 3_906_250_000, volumeUsedUnits),
            (52, 4, "/volume1/@docker", 4096, 3_906_250_000, volumeUsedUnits),
        ]
        var e = systemGroup
        for r in rows {
            e.append(("\(st).2.\(r.0)", type(r.1)))
            e.append(("\(st).3.\(r.0)", text(r.2)))
            e.append(("\(st).4.\(r.0)", .integer(r.3)))
            e.append(("\(st).5.\(r.0)", int32(r.4)))
            e.append(("\(st).6.\(r.0)", int32(r.5)))
        }
        for (i, load) in [10, 14, 12, 12].enumerated() {
            e.append(("1.3.6.1.2.1.25.3.3.1.2.\(196_608 + i)", .integer(Int64(load))))
        }
        return e
    }

    /// A switch: system group and an interface table, none of the health MIBs.
    private func plainSwitch() -> [(String, SNMPValue)] {
        systemGroup + [
            ("1.3.6.1.2.1.2.2.1.2.1", text("eth0")),
            ("1.3.6.1.2.1.2.2.1.8.1", .integer(1)),
        ]
    }

    // MARK: - Printer

    func test_printer_lowToner() async throws {
        let r = try await SNMPHealth.query(FakeSNMPAgent(printerMIB()).client(), maxRows: 1000)
        let p = try XCTUnwrap(r.printer)
        XCTAssertNil(r.ups)
        XCTAssertNil(r.host)
        XCTAssertEqual(p.supplies.map(\.name), ["Black Toner Cartridge", "Cyan Toner", "Magenta Toner", "Yellow Toner", "Waste Toner Box"])
        XCTAssertEqual(p.supplies.map(\.percent), [8, 46, 70, nil, 60])
        XCTAssertEqual(p.supplies.map(\.isReceptacle), [false, false, false, false, true])
        XCTAssertEqual(p.supplies.first?.id, "1.1")
        XCTAssertEqual(p.lifeCount, 812)
        XCTAssertEqual(p.lifeCountUnit, 7)
        XCTAssertEqual(p.status, 3)
        XCTAssertEqual(p.alerts, [0])                          // low paper

        let v = SNMPHealth.printerVerdicts(p)
        XCTAssertEqual(v.first, SNMPHealthVerdict(.warning, "Black Toner Cartridge at 8%: replace it soon"))
        XCTAssertEqual(v.count, 1)                             // low paper doesn't make a verdict
        XCTAssertEqual(SNMPHealth.printerMinorAlerts(p), ["low paper"])
        XCTAssertEqual(SNMPHealth.printerFacts(p), ["812 pages printed", "Status: idle"])
        XCTAssertEqual(SNMPHealth.supplyStateText(p.supplies[3]), "some left")
        XCTAssertEqual(SNMPHealth.supplyStateText(p.supplies[4]), "60% space left")
        XCTAssertEqual(SNMPHealth.summary(r), "Health: 1 of 3 checks answered")
    }

    func test_printer_fineEmptyAndWasteBox() async throws {
        let fine = try await SNMPHealth.query(FakeSNMPAgent(printerMIB(black: 50)).client(), maxRows: 1000)
        XCTAssertEqual(SNMPHealth.printerVerdicts(try XCTUnwrap(fine.printer)).first,
                       SNMPHealthVerdict(.good, "Supplies look fine (lowest: Cyan Toner 46%)"))

        let empty = try await SNMPHealth.query(FakeSNMPAgent(printerMIB(black: 0)).client(), maxRows: 1000)
        XCTAssertEqual(SNMPHealth.printerVerdicts(try XCTUnwrap(empty.printer)).first,
                       SNMPHealthVerdict(.critical, "Black Toner Cartridge is empty: replace it now"))

        // A waste box's level is the space left in it.
        let waste = try await SNMPHealth.query(FakeSNMPAgent(printerMIB(black: 50, waste: 5)).client(), maxRows: 1000)
        XCTAssertEqual(SNMPHealth.printerVerdicts(try XCTUnwrap(waste.printer)).first,
                       SNMPHealthVerdict(.warning, "Waste Toner Box is nearly full (5% space left): replace it soon"))
    }

    func test_printer_jamOutranksSupplies_andTypeNamesUnlabeledSupplies() async throws {
        // Bit 5 (jammed) plus bit 0 (low paper): 0x84.
        let r = try await SNMPHealth.query(FakeSNMPAgent(printerMIB(errorBits: [0x84], descriptions: false)).client(),
                                           maxRows: 1000)
        let p = try XCTUnwrap(r.printer)
        XCTAssertEqual(p.supplies.first?.name, "Toner")         // from prtMarkerSuppliesType
        XCTAssertEqual(p.supplies.last?.name, "Waste toner")
        let v = SNMPHealth.printerVerdicts(p)
        XCTAssertEqual(v.map(\.text), ["The printer reports: paper jam", "Toner at 8%: replace it soon"])
        XCTAssertEqual(v.first?.level, .critical)
    }

    func test_printer_v1() async throws {
        let a = FakeSNMPAgent(printerMIB()); a.v1 = true
        let r = try await SNMPHealth.query(a.client(version: .v1), maxRows: 1000)
        XCTAssertEqual(r.printer?.supplies.count, 5)
        XCTAssertEqual(r.printer?.lifeCount, 812)
        XCTAssertEqual(a.bulkCount, 0)
    }

    private func supply(_ name: String, _ level: Int64?, _ max: Int64? = 100, receptacle: Bool = false) -> SNMPPrinterSupply {
        SNMPPrinterSupply(id: name, name: name, level: level, maxCapacity: max, isReceptacle: receptacle)
    }

    func test_supplyVerdicts_edgeCases() {
        // Rounded down: 9.9% is under 10%.
        XCTAssertEqual(SNMPHealth.supplyPercent(level: 99, max: 1000), 9)
        XCTAssertEqual(SNMPHealth.supplyPercent(level: 100, max: 1000), 10)
        XCTAssertEqual(SNMPHealth.supplyPercent(level: 150, max: 100), 100)
        XCTAssertNil(SNMPHealth.supplyPercent(level: -3, max: 100))
        XCTAssertNil(SNMPHealth.supplyPercent(level: 40, max: -2))
        XCTAssertNil(SNMPHealth.supplyPercent(level: 40, max: 0))

        XCTAssertEqual(SNMPHealth.supplyVerdict([supply("Black", 10)]).level, .good)
        XCTAssertEqual(SNMPHealth.supplyVerdict([supply("Black", 9)]).level, .warning)
        XCTAssertEqual(SNMPHealth.supplyVerdict([supply("Black", 4), supply("Cyan", 2), supply("Magenta", 7)]).text,
                       "Cyan at 2%: replace it soon (2 others are under 10%)")
        XCTAssertEqual(SNMPHealth.supplyVerdict([supply("Black", 0), supply("Cyan", 0)]).text,
                       "Black is empty: replace it now (1 other supply needs replacing too)")
        XCTAssertEqual(SNMPHealth.supplyVerdict([supply("Waste", 0, receptacle: true)]).text,
                       "Waste is full: replace it now")
        XCTAssertEqual(SNMPHealth.supplyVerdict([supply("Black", -3), supply("Cyan", -3)]),
                       SNMPHealthVerdict(.info, "The printer says every supply has some left, but not how much"))
        XCTAssertEqual(SNMPHealth.supplyVerdict([supply("Black", -2), supply("Cyan", -3)]).level, .info)
        // "Lowest" names a consumable, not the waste box.
        XCTAssertEqual(SNMPHealth.supplyVerdict([supply("Waste", 20, receptacle: true), supply("Black", 55)]).text,
                       "Supplies look fine (lowest: Black 55%)")
        XCTAssertEqual(SNMPHealth.alertBits(Data([0x84, 0x01])), [0, 5, 15])
        XCTAssertNil(SNMPHealth.printerAlertVerdict([0, 2, 13]))   // low paper, low toner, a tray empty
    }

    /// Printers that count supplies in pages: a percent rounded down to 0
    /// with some left is "under 1%", not empty; a level of 0 is empty even
    /// when the maximum is unknown.
    func test_supply_underOnePercent_andEmptyWithUnknownMax() async throws {
        // 20 pages left of 2,500, read from the device.
        let r = try await SNMPHealth.query(FakeSNMPAgent(printerMIB(black: 20, blackMax: 2500)).client(), maxRows: 1000)
        let black = try XCTUnwrap(r.printer?.supplies.first)
        XCTAssertEqual(black.percent, 0)
        XCTAssertFalse(black.isOut)
        XCTAssertTrue(black.isUnderOnePercent)
        XCTAssertEqual(SNMPHealth.printerVerdicts(try XCTUnwrap(r.printer)).first,
                       SNMPHealthVerdict(.warning, "Black Toner Cartridge is nearly empty (under 1% left): replace it soon"))
        XCTAssertEqual(SNMPHealth.supplyStateText(black), "under 1%")
        XCTAssertEqual(SNMPHealth.supplyMeterLevel(black), .warning)
        XCTAssertTrue(SNMPHealth.exportText(r).contains("Black Toner Cartridge: under 1% (level 20, max 2500)"))

        // Under 1% sorts ahead of the other low supplies.
        let pages = supply("Black", 20, 2500)
        XCTAssertEqual(SNMPHealth.supplyVerdict([supply("Cyan", 5), pages]).text,
                       "Black is nearly empty (under 1% left): replace it soon (1 other is under 10%)")
        // A waste box with 1 unit of space left out of 200 isn't full.
        let box = supply("Waste", 1, 200, receptacle: true)
        XCTAssertEqual(SNMPHealth.supplyVerdict([box]),
                       SNMPHealthVerdict(.warning, "Waste is nearly full (under 1% space left): replace it soon"))
        XCTAssertEqual(SNMPHealth.supplyStateText(box), "under 1% space left")
        // A level of 0 in fine units is still empty.
        XCTAssertEqual(SNMPHealth.supplyVerdict([supply("Black", 0, 2500), supply("Cyan", 50)]),
                       SNMPHealthVerdict(.critical, "Black is empty: replace it now"))

        // Level 0 with the maximum unknown (-2) or other (-1): empty, not "not reported".
        for max: Int64 in [-2, -1] {
            let out = supply("Black", 0, max)
            XCTAssertEqual(out.percent, 0)
            XCTAssertTrue(out.isOut)
            XCTAssertEqual(SNMPHealth.supplyVerdict([out]), SNMPHealthVerdict(.critical, "Black is empty: replace it now"))
            XCTAssertEqual(SNMPHealth.supplyStateText(out), "0%")
            XCTAssertEqual(SNMPHealth.supplyMeterLevel(out), .critical)
        }
        // A maximum of 0 usually means the slot isn't in use: no percent.
        XCTAssertNil(SNMPHealth.supplyPercent(level: 0, max: 0))
        XCTAssertFalse(supply("Unused", 0, 0).isOut)
        XCTAssertNil(SNMPHealth.supplyPercent(level: 5, max: -2))
        XCTAssertEqual(SNMPHealth.supplyMeterLevel(supply("Black", 50)), .good)
        XCTAssertNil(SNMPHealth.supplyMeterLevel(supply("Black", -3)))
    }

    // MARK: - UPS

    func test_ups_onMains() async throws {
        let r = try await SNMPHealth.query(FakeSNMPAgent(upsMIB()).client(), maxRows: 1000)
        let u = try XCTUnwrap(r.ups)
        XCTAssertNil(r.printer)
        XCTAssertNil(r.host)
        XCTAssertEqual(u.source, .upsMIB)
        XCTAssertEqual(u.power, .mains)
        XCTAssertEqual(u.battery, .normal)
        XCTAssertEqual(u.loads, [18])
        XCTAssertEqual(SNMPHealth.upsVerdict(u),
                       SNMPHealthVerdict(.good, "On mains power. Battery 100%, about 42 min of runtime at 18% load"))
        XCTAssertEqual(SNMPHealth.upsName(u), "Eaton 5PX 1500")
    }

    func test_ups_onBattery_lowAndAlarms() async throws {
        let onBattery = try await SNMPHealth.query(
            FakeSNMPAgent(upsMIB(source: 5, secondsOnBattery: 180, minutes: 14, charge: 62)).client(), maxRows: 1000)
        let u = try XCTUnwrap(onBattery.ups)
        XCTAssertTrue(u.isOnBattery)
        XCTAssertEqual(SNMPHealth.upsVerdict(u), SNMPHealthVerdict(.warning, "On battery: about 14 min left (62%)"))
        XCTAssertTrue(SNMPHealth.upsFacts(u).contains("Running on battery for 3 min"))

        let nearlyOut = try await SNMPHealth.query(
            FakeSNMPAgent(upsMIB(source: 5, status: 3, secondsOnBattery: 900, minutes: 3, charge: 15)).client(), maxRows: 1000)
        XCTAssertEqual(SNMPHealth.upsVerdict(try XCTUnwrap(nearlyOut.ups)).level, .critical)

        let low = try await SNMPHealth.query(FakeSNMPAgent(upsMIB(status: 3, minutes: 3, charge: 20)).client(), maxRows: 1000)
        XCTAssertEqual(SNMPHealth.upsVerdict(try XCTUnwrap(low.ups)),
                       SNMPHealthVerdict(.warning, "Battery low: about 3 min of runtime (20%)"))

        // upsAlarmBatteryBad (1) and upsAlarmOnBypass (9).
        let bad = try await SNMPHealth.query(FakeSNMPAgent(upsMIB(alarms: [1, 9])).client(), maxRows: 1000)
        let b = try XCTUnwrap(bad.ups)
        XCTAssertEqual(b.alarms, ["battery needs replacing", "on bypass"])
        XCTAssertTrue(b.replaceBattery)
        XCTAssertEqual(SNMPHealth.upsVerdict(b),
                       SNMPHealthVerdict(.warning, "Battery needs attention: the UPS says to replace it"))
    }

    func test_ups_apcFallback() async throws {
        let r = try await SNMPHealth.query(FakeSNMPAgent(apcMIB()).client(), maxRows: 1000)
        let u = try XCTUnwrap(r.ups)
        XCTAssertEqual(u.source, .apc)
        XCTAssertEqual(u.model, "Smart-UPS 1500")
        XCTAssertEqual(u.minutesLeft, 42)                       // 252,000 ticks = 2,520 s
        XCTAssertEqual(SNMPHealth.upsVerdict(u),
                       SNMPHealthVerdict(.good, "On mains power. Battery 100%, about 42 min of runtime at 18% load"))
        XCTAssertEqual(SNMPHealth.upsSourceLabel(u), "APC PowerNet MIB")

        let onBattery = try await SNMPHealth.query(
            FakeSNMPAgent(apcMIB(output: 3, capacity: 62, runtimeTicks: 84_000)).client(), maxRows: 1000)
        XCTAssertEqual(SNMPHealth.upsVerdict(try XCTUnwrap(onBattery.ups)),
                       SNMPHealthVerdict(.warning, "On battery: about 14 min left (62%)"))

        let replace = try await SNMPHealth.query(FakeSNMPAgent(apcMIB(replace: 2)).client(), maxRows: 1000)
        XCTAssertEqual(SNMPHealth.upsVerdict(try XCTUnwrap(replace.ups)).text,
                       "Battery needs attention: the UPS says to replace it")

        // v1: missing objects fail whole requests; the section still reads.
        let a = FakeSNMPAgent(apcMIB()); a.v1 = true
        let v1 = try await SNMPHealth.query(a.client(version: .v1), maxRows: 1000)
        XCTAssertEqual(v1.ups?.source, .apc)
        XCTAssertEqual(v1.ups?.charge, 100)
    }

    func test_upsVerdicts_thresholdsAndOrder() {
        var u = SNMPUPSHealth(source: .upsMIB)
        u.power = .battery; u.minutesLeft = 4; u.charge = 40
        XCTAssertEqual(SNMPHealth.upsVerdict(u).level, .critical)    // under 5 minutes
        u.minutesLeft = 5
        XCTAssertEqual(SNMPHealth.upsVerdict(u).level, .warning)
        u.power = nil; u.secondsOnBattery = 30                        // no source: seconds on battery decide
        XCTAssertTrue(u.isOnBattery)

        var m = SNMPUPSHealth(source: .upsMIB)
        m.power = .mains; m.battery = .normal; m.charge = 100; m.loads = [95]
        XCTAssertEqual(SNMPHealth.upsVerdict(m), SNMPHealthVerdict(.warning, "Load at 95%: close to what the UPS can carry"))
        m.loads = [40]; m.battery = .depleted
        XCTAssertEqual(SNMPHealth.upsVerdict(m).level, .critical)
        m.battery = .normal; m.power = .bypass
        XCTAssertEqual(SNMPHealth.upsVerdict(m).text, "On bypass: mains power goes straight to the load, with no battery backup")
        m.power = .off
        XCTAssertEqual(SNMPHealth.upsVerdict(m).text, "Output is off: the UPS isn't powering anything")
        m.power = .boosting; m.minutesLeft = 150; m.loads = []
        XCTAssertEqual(SNMPHealth.upsVerdict(m).text, "On mains power (boosting low voltage). Battery 100%, about 2 h 30 min of runtime")
    }

    /// Alarms beyond battery bad, overload, and self-test failed must not
    /// leave a green "On mains power" headline.
    func test_ups_alarms_faultsShutdownAndLostContact() async throws {
        func verdict(_ mib: [(String, SNMPValue)]) async throws -> SNMPHealthVerdict {
            let r = try await SNMPHealth.query(FakeSNMPAgent(mib).client(), maxRows: 1000)
            return SNMPHealth.upsVerdict(try XCTUnwrap(r.ups))
        }
        // On mains, battery normal: general fault (18) and charger failed (13).
        let fault = try await SNMPHealth.query(FakeSNMPAgent(upsMIB(alarms: [18, 13])).client(), maxRows: 1000)
        let f = try XCTUnwrap(fault.ups)
        XCTAssertEqual(f.alarmCodes, [18, 13])
        XCTAssertEqual(f.alarms, ["general fault", "charger failed"])
        XCTAssertEqual(SNMPHealth.upsVerdict(f), SNMPHealthVerdict(.warning, "The UPS reports: general fault, charger failed"))
        XCTAssertTrue(SNMPHealth.exportText(fault).contains("Alarms: general fault, charger failed"))

        // Lost contact (20): the readings behind any verdict may be stale.
        let lost = try await verdict(upsMIB(alarms: [20]))
        XCTAssertEqual(lost, SNMPHealthVerdict(.warning, "The SNMP agent has lost contact with the UPS, so these readings may be out of date"))

        // Shutdown imminent (23) and pending (22) are critical, on mains or on battery.
        let imminent = try await verdict(upsMIB(alarms: [23]))
        XCTAssertEqual(imminent, SNMPHealthVerdict(.critical, "The UPS is about to shut down: it will turn off power to the load within seconds"))
        let pending = try await verdict(upsMIB(source: 5, secondsOnBattery: 180, minutes: 14, charge: 62, alarms: [2, 22]))
        XCTAssertEqual(pending, SNMPHealthVerdict(.critical, "A shutdown is pending: the UPS will turn off power to the load when its countdown ends"))

        // Output off (14) and awaiting power (21) mean nothing is powered.
        for code: UInt32 in [14, 21] {
            let off = try await verdict(upsMIB(alarms: [code]))
            XCTAssertEqual(off, SNMPHealthVerdict(.critical, "Output is off: the UPS isn't powering anything"), "alarm \(code)")
        }
        // A self-test in progress (24) is only informational.
        let selfTest = try await verdict(upsMIB(alarms: [24]))
        XCTAssertEqual(selfTest.level, .good)
    }

    func test_upsVerdict_vendorAndCoveredAlarms() {
        var u = SNMPUPSHealth(source: .upsMIB)
        u.power = .mains; u.battery = .normal; u.charge = 100
        u.alarmList = [.init(code: nil, name: "vendor alarm 1.3.6.1.4.1.534.1.7.13")]
        XCTAssertEqual(SNMPHealth.upsVerdict(u),
                       SNMPHealthVerdict(.warning, "The UPS reports: vendor alarm 1.3.6.1.4.1.534.1.7.13"))
        u.alarmList = [.init(code: 20, name: "lost contact with the UPS"), .init(code: 16, name: "fan failure")]
        XCTAssertEqual(SNMPHealth.upsVerdict(u).text,
                       "The SNMP agent has lost contact with the UPS, so these readings may be out of date. It also reports: fan failure")
        // The on-bypass alarm says bypass even when the power source doesn't.
        u.alarmList = [.init(code: 9, name: "on bypass")]
        XCTAssertEqual(SNMPHealth.upsVerdict(u).text, "On bypass: mains power goes straight to the load, with no battery backup")
        // With no power source, the on-battery alarm reads as on battery.
        u.power = nil; u.alarmList = [.init(code: 2, name: "on battery")]
        XCTAssertTrue(u.isOnBattery)
        XCTAssertEqual(SNMPHealth.upsVerdict(u).level, .warning)
        // Alarms the verdict already covers don't repeat as "The UPS reports".
        u.power = .mains; u.alarmList = [.init(code: 24, name: "self-test in progress")]
        XCTAssertEqual(SNMPHealth.upsVerdict(u).level, .good)
    }

    /// APC's sleeping and rebooting states turn the output off.
    func test_ups_apcSleepingOrRebooting_isOutputOff() async throws {
        for code: Int64 in [5, 8, 11] {      // timedSleeping, rebooting, sleepingUntilPowerReturn
            let r = try await SNMPHealth.query(FakeSNMPAgent(apcMIB(output: code, load: 0)).client(), maxRows: 1000)
            let u = try XCTUnwrap(r.ups)
            XCTAssertEqual(u.power, .off, "code \(code)")
            XCTAssertEqual(SNMPHealth.upsVerdict(u),
                           SNMPHealthVerdict(.critical, "Output is off: the UPS isn't powering anything"), "code \(code)")
            XCTAssertTrue(SNMPHealth.exportText(r).contains("Power source: none (output off)"), "code \(code)")
        }
    }

    /// Over 100% is over the rating: critical, on APC too, which has no
    /// overload alarm. Exactly 100% is at the rating.
    func test_upsVerdict_loadOverRating() async throws {
        let apc = try await SNMPHealth.query(FakeSNMPAgent(apcMIB(load: 112)).client(), maxRows: 1000)
        XCTAssertEqual(SNMPHealth.upsVerdict(try XCTUnwrap(apc.ups)),
                       SNMPHealthVerdict(.critical, "Load at 112%: more than the UPS is rated for"))

        var m = SNMPUPSHealth(source: .upsMIB)
        m.power = .mains; m.battery = .normal; m.charge = 100
        m.loads = [100]
        XCTAssertEqual(SNMPHealth.upsVerdict(m), SNMPHealthVerdict(.warning, "Load at 100%: the UPS is at its full rated capacity"))
        m.loads = [40, 101]
        XCTAssertEqual(SNMPHealth.upsVerdict(m), SNMPHealthVerdict(.critical, "Load at 101%: more than the UPS is rated for"))
        // Over the rating outranks a battery warning.
        m.replaceBattery = true; m.loads = [130]
        XCTAssertEqual(SNMPHealth.upsVerdict(m).text, "Load at 130%: more than the UPS is rated for")
        m.replaceBattery = false; m.loads = [90]
        XCTAssertEqual(SNMPHealth.upsVerdict(m).text, "Load at 90%: close to what the UPS can carry")
    }

    // MARK: - Storage and CPU

    func test_host_synologyLike() async throws {
        let r = try await SNMPHealth.query(FakeSNMPAgent(synologyMIB()).client(), maxRows: 1000)
        let h = try XCTUnwrap(r.host)
        XCTAssertNil(r.printer)
        XCTAssertNil(r.ups)

        // Negative Integer32 sizes read as unsigned: 3,906,250,000 units of 4 KB = 16 TB.
        let vol = try XCTUnwrap(h.storage.first { $0.name == "/volume1" })
        XCTAssertEqual(vol.size, 16_000_000_000_000)
        XCTAssertEqual(vol.percent, 92)

        XCTAssertEqual(h.disks.map(\.name), ["/", "/volume1"])
        XCTAssertEqual(h.memory.map(\.name), ["Physical memory"])
        func hidden(_ n: String) -> SNMPStorageEntry.Hidden? { h.storage.first { $0.name == n }?.hidden }
        XCTAssertEqual(hidden("/dev/shm"), .systemMount)
        XCTAssertEqual(hidden("/run"), .systemMount)
        XCTAssertEqual(hidden("/sys/fs/cgroup"), .systemMount)
        XCTAssertEqual(hidden("/boot/efi"), .small)
        XCTAssertEqual(hidden("/snap/core/1"), .snapImage)
        XCTAssertEqual(hidden("/volume1/@docker"), .duplicate(of: "/volume1"))
        XCTAssertEqual(hidden("Swap space"), .notDiskOrMemory)
        XCTAssertEqual(hidden("Cached memory"), .notDiskOrMemory)

        // Linux counts cache and buffers in "used": 3,600,000 - 2,000,000 - 100,000 KB.
        let mem = try XCTUnwrap(h.memory.first)
        XCTAssertEqual(mem.cacheBytes, 2_100_000 * 1024)
        XCTAssertEqual(mem.cacheLabel, "cache and buffers")
        XCTAssertEqual(mem.usedNet, 1_500_000 * 1024)
        XCTAssertEqual(mem.percent, 37)

        XCTAssertEqual(h.cpuLoads, [10, 14, 12, 12])
        XCTAssertEqual(SNMPHealth.hostVerdicts(h),
                       [SNMPHealthVerdict(.critical, "Volume /volume1 is 92% full"),
                        SNMPHealthVerdict(.good, "CPU 12% busy on average across 4 processors")])

        let text = SNMPHealth.exportText(r)
        XCTAssertTrue(text.contains("Verdict: Volume /volume1 is 92% full"))
        XCTAssertTrue(text.contains("/volume1/@docker"))       // hidden entries are still exported
        XCTAssertTrue(text.contains("not counting"))
    }

    func test_host_allUnder80() async throws {
        // 2,343,750,000 of 3,906,250,000 units: 60%.
        let r = try await SNMPHealth.query(FakeSNMPAgent(synologyMIB(volumeUsedUnits: 2_343_750_000)).client(), maxRows: 1000)
        let h = try XCTUnwrap(r.host)
        XCTAssertEqual(SNMPHealth.storageVerdict(h.disks),
                       SNMPHealthVerdict(.good, "All volumes under 80% full (fullest: /volume1, 60%)"))
    }

    func test_storageAndCPU_thresholds() {
        func disk(_ name: String, _ pct: UInt64) -> SNMPStorageEntry {
            SNMPStorageEntry(id: 1, kind: .fixedDisk, name: name, size: 1_000_000_000_000, used: pct * 10_000_000_000)
        }
        XCTAssertEqual(SNMPHealth.storageVerdict([disk("/data", 80)])?.level, .warning)
        XCTAssertEqual(SNMPHealth.storageVerdict([disk("/data", 90)])?.level, .critical)
        XCTAssertEqual(SNMPHealth.storageVerdict([disk("/data", 79)]), SNMPHealthVerdict(.good, "Volume /data is 79% full"))
        XCTAssertEqual(SNMPHealth.storageVerdict([disk("/a", 85), disk("/b", 91), disk("/c", 20)])?.text,
                       "Volume /b is 91% full (1 more is at least 80% full)")
        // 79.99% rounds down, so "under 80%" stays true.
        let almost = SNMPStorageEntry(id: 1, kind: .fixedDisk, name: "/x", size: 10_000, used: 7_999)
        XCTAssertEqual(almost.percent, 79)
        XCTAssertNil(SNMPHealth.storageVerdict([]))

        XCTAssertEqual(SNMPHealth.cpuVerdict([74, 76])?.level, .warning)      // average 75
        XCTAssertEqual(SNMPHealth.cpuVerdict([70])?.level, .good)
        XCTAssertEqual(SNMPHealth.cpuVerdict([95, 85])?.level, .critical)     // average 90
        XCTAssertEqual(SNMPHealth.cpuVerdict([33])?.text, "CPU 33% busy")
        XCTAssertNil(SNMPHealth.cpuVerdict([]))
    }

    func test_storageValueHelpers() {
        XCTAssertEqual(SNMPHealth.storageCount(.integer(-388_717_296)), 3_906_250_000)
        XCTAssertEqual(SNMPHealth.storageCount(.integer(1234)), 1234)
        XCTAssertEqual(SNMPHealth.storageCount(.gauge32(77)), 77)
        XCTAssertNil(SNMPHealth.storageCount(.integer(Int64(Int32.min) - 1)))
        XCTAssertNil(SNMPHealth.storageCount(.octetString(Data())))
        XCTAssertEqual(SNMPHealth.storageName(.octetString(Data("C:\\ Label:System  Serial Number 5a3b2c1d".utf8))), "C:\\ (System)")
        XCTAssertEqual(SNMPHealth.storageName(.octetString(Data("D:\\ Label:  Serial Number 1234".utf8))), "D:\\")
        XCTAssertEqual(SNMPHealth.storageName(.octetString(Data("/volume1".utf8))), "/volume1")
        XCTAssertEqual(SNMPHealth.storageKind(.oid(OID([1,3,6,1,2,1,25,2,1,10]))), .networkDisk)
        XCTAssertEqual(SNMPHealth.storageKind(.oid(OID([1,3,6,1,4,1,9,9]))), .other)
        XCTAssertEqual(SNMPHealth.storageKind(.integer(4)), .other)
        // Cache can't be more than what's used: then nothing is taken off.
        let odd = SNMPHealth.classifyStorage([
            SNMPStorageEntry(id: 1, kind: .ram, name: "Physical memory", size: 100, used: 10),
            SNMPStorageEntry(id: 2, kind: .other, name: "Cached memory", size: 50, used: 50),
        ])
        XCTAssertNil(odd[0].cacheBytes)
        XCTAssertEqual(odd[0].usedNet, 10)
    }

    // MARK: - Nothing, row limits, odd data

    func test_nothingAnswered_v2cAndV1() async throws {
        let a = FakeSNMPAgent(plainSwitch())
        let r = try await SNMPHealth.query(a.client(), maxRows: 1000)
        XCTAssertTrue(r.isEmpty)
        XCTAssertEqual(r.answered, 0)
        XCTAssertEqual(SNMPHealth.summary(r), "Health: no printer, UPS, or host data")
        XCTAssertTrue(SNMPHealth.exportText(r).hasPrefix(SNMPHealth.nothingAnswered))
        // One request per check: supplies, page counter, UPS-MIB, APC, storage, processors.
        XCTAssertEqual(a.pdus.count, 6)

        let b = FakeSNMPAgent(plainSwitch()); b.v1 = true
        let v1 = try await SNMPHealth.query(b.client(version: .v1), maxRows: 1000)
        XCTAssertTrue(v1.isEmpty)
    }

    func test_rowLimit_addsNote() async throws {
        let r = try await SNMPHealth.query(FakeSNMPAgent(synologyMIB()).client(), maxRows: 4)
        XCTAssertNotNil(r.host)
        XCTAssertTrue(r.notes.contains { $0.contains("storage list stopped at the row limit") })
        XCTAssertTrue(SNMPHealth.exportText(r).contains("row limit"))
    }

    func test_oddValues_dontCrash() async throws {
        // Wrong types everywhere, an empty description, a two-part storage index.
        let s = "1.3.6.1.2.1.43.11.1.1"
        let e: [(String, SNMPValue)] = systemGroup + [
            ("\(s).6.1.1", .octetString(Data())),
            ("\(s).8.1.1", .octetString(Data([0xFF]))),
            ("\(s).9.1.1", .null),
            ("1.3.6.1.2.1.33.1.2.4.0", .octetString(Data("full".utf8))),
            ("1.3.6.1.2.1.33.1.4.1.0", .integer(99)),
            ("1.3.6.1.2.1.25.2.3.1.2.1.2", .oid(OID([1,3,6,1,2,1,25,2,1,4]))),
            ("1.3.6.1.2.1.25.2.3.1.2.5", .integer(4)),
            ("1.3.6.1.2.1.25.2.3.1.4.5", .integer(-1)),
            ("1.3.6.1.2.1.25.2.3.1.5.5", .integer(1000)),
            ("1.3.6.1.2.1.25.3.3.1.2.1", .integer(250)),
        ]
        let r = try await SNMPHealth.query(FakeSNMPAgent(e).client(), maxRows: 1000)
        XCTAssertEqual(r.printer?.supplies.first?.name, "Supply 1")
        XCTAssertNil(r.printer?.supplies.first?.percent)
        XCTAssertEqual(r.ups?.power, .other(99))
        XCTAssertNil(r.ups?.charge)
        XCTAssertEqual(r.host?.storage.count, 1)                // the two-part index is skipped
        XCTAssertEqual(r.host?.storage.first?.hidden, .notDiskOrMemory)
        XCTAssertEqual(r.host?.cpuLoads, [100])                 // clamped
        _ = SNMPHealth.exportText(r)
        XCTAssertEqual(SNMPHealth.upsVerdict(try XCTUnwrap(r.ups)).level, .info)
    }
}
