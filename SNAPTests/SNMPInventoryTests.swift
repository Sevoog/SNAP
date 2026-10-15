// SNMPInventoryTests.swift
// SNAP — Tests
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md

import XCTest
@testable import SNAP

final class SNMPInventoryTests: XCTestCase {

    // MARK: Fixtures

    private func s(_ text: String) -> SNMPValue { .octetString(Data(text.utf8)) }

    private let entry = "1.3.6.1.2.1.47.1.1.1.1"

    /// Every entPhysicalTable column for one entry, the way real agents
    /// send them: blank strings, not missing values.
    private func entity(_ i: UInt32, cls: Int64, in parent: UInt32, name: String, descr: String = "",
                        model: String = "", serial: String = "", mfg: String = "",
                        hw: String = "", fw: String = "", sw: String = "") -> [(String, SNMPValue)] {
        [("\(entry).2.\(i)", s(descr)), ("\(entry).4.\(i)", .integer(Int64(parent))),
         ("\(entry).5.\(i)", .integer(cls)), ("\(entry).7.\(i)", s(name)),
         ("\(entry).8.\(i)", s(hw)), ("\(entry).9.\(i)", s(fw)), ("\(entry).10.\(i)", s(sw)),
         ("\(entry).11.\(i)", s(serial)), ("\(entry).12.\(i)", s(mfg)), ("\(entry).13.\(i)", s(model))]
    }

    private let system: [(String, SNMPValue)] = [
        ("1.3.6.1.2.1.1.1.0", .octetString(Data("Cisco IOS Software, Catalyst L3 Switch".utf8))),
        ("1.3.6.1.2.1.1.5.0", .octetString(Data("core-sw".utf8))),
    ]

    /// A two-member stack: chassis, uplink modules, power supplies, plus a
    /// slot, a sensor, and ports that should stay hidden (except the SFP
    /// with a serial number).
    private func stackedSwitch() -> FakeSNMPAgent {
        var e = system
        e += entity(1, cls: 11, in: 0, name: "Stack", descr: "c93xx Stack")
        e += entity(1000, cls: 3, in: 1, name: "Switch 1", descr: "C9300-48P", model: "C9300-48P",
                    serial: "FOC2101A1AB", mfg: "Cisco", hw: "V02", sw: "17.9.4")
        e += entity(1001, cls: 5, in: 1000, name: "Switch 1 Slot 1")
        e += entity(1010, cls: 9, in: 1001, name: "Switch 1 FRU Uplink Module 1", descr: "8x10G Uplink Module",
                    model: "C9300-NM-8X", serial: "FOC2102B2CD", hw: "V01")
        e += entity(1020, cls: 6, in: 1000, name: "Switch 1 Power Supply A", model: "PWR-C1-715WAC",
                    serial: "LIT2103C3EF")
        e += entity(1030, cls: 8, in: 1000, name: "Switch 1 Temp Sensor")
        e += entity(1100, cls: 10, in: 1010, name: "Te1/1/1")
        e += entity(2000, cls: 3, in: 1, name: "Switch 2", model: "C9300-48P", serial: "FOC2104D4GH",
                    mfg: "Cisco", hw: "V02", sw: "17.9.4")
        e += entity(2010, cls: 9, in: 2000, name: "Switch 2 FRU Uplink Module 1", model: "C9300-NM-8X",
                    serial: "FOC2105E5IJ")
        e += entity(2020, cls: 6, in: 2000, name: "Switch 2 Power Supply A", model: "PWR-C1-715WAC",
                    serial: "LIT2106F6KL")
        e += entity(2100, cls: 10, in: 2010, name: "Te2/1/1", descr: "SFP-10GBase-SR", model: "SFP-10G-SR",
                    serial: "AGM1234X5Y6")
        // Synology values on a switch must not add a row: ENTITY-MIB wins.
        e.append(("1.3.6.1.4.1.6574.1.5.1.0", s("DS920+")))
        return FakeSNMPAgent(e)
    }

    // MARK: ENTITY-MIB

    func test_stackedSwitch_mainPartsInTreeOrder() async throws {
        let r = try await SNMPInventory.query(stackedSwitch().client(), maxRows: 1000)
        XCTAssertEqual(r.source, .entity)
        XCTAssertNil(r.note)
        XCTAssertEqual(r.items.count, 11)
        // Parents before what they contain; slot, sensor, and the bare port hidden.
        XCTAssertEqual(r.mainItems.map(\.entityIndex), [1, 1000, 1010, 1020, 2000, 2010, 2100, 2020])
        XCTAssertEqual(r.hiddenCount, 3)
        XCTAssertEqual(r.serialCount, 7)
        XCTAssertEqual(SNMPInventory.summary(r), "8 parts, 7 serial numbers")

        let chassis = try XCTUnwrap(r.items.first { $0.entityIndex == 1000 })
        XCTAssertEqual(chassis.kind, .chassis)
        XCTAssertEqual(chassis.model, "C9300-48P")
        XCTAssertEqual(chassis.serial, "FOC2101A1AB")
        XCTAssertEqual(chassis.manufacturer, "Cisco")
        XCTAssertEqual(chassis.hardwareRev, "V02")
        XCTAssertEqual(chassis.softwareRev, "17.9.4")
        XCTAssertEqual(chassis.containedIn, 1)
        XCTAssertNil(chassis.detail)                       // descr repeats the model
        XCTAssertEqual(r.items.first { $0.entityIndex == 1 }?.kind, .stack)
        XCTAssertEqual(r.items.first { $0.entityIndex == 1020 }?.kind, .powerSupply)
        XCTAssertEqual(r.items.first { $0.entityIndex == 1010 }?.detail, "8x10G Uplink Module")

        // Indent counts only listed rows: the hidden slot doesn't add a level.
        let depths = Dictionary(SNMPInventory.displayRows(r, showAll: false).map { ($0.item.entityIndex ?? 0, $0.depth) },
                                uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(depths[1], 0)
        XCTAssertEqual(depths[1000], 1)
        XCTAssertEqual(depths[1010], 2)
        XCTAssertEqual(depths[1020], 2)
        XCTAssertEqual(depths[2100], 3)
    }

    func test_showAll_listsEverythingIndentedByContainment() async throws {
        let r = try await SNMPInventory.query(stackedSwitch().client(), maxRows: 1000)
        let rows = SNMPInventory.displayRows(r, showAll: true)
        XCTAssertEqual(rows.map(\.item.entityIndex),
                       [1, 1000, 1001, 1010, 1100, 1020, 1030, 2000, 2010, 2100, 2020])
        let depth = Dictionary(rows.map { ($0.item.entityIndex ?? 0, $0.depth) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(depth[1001], 2)
        XCTAssertEqual(depth[1010], 3)
        XCTAssertEqual(depth[1100], 4)
        XCTAssertEqual(r.items.first { $0.entityIndex == 1001 }?.kind, .container)
        XCTAssertEqual(r.items.first { $0.entityIndex == 1030 }?.kind, .sensor)
    }

    /// v1 has no GETBULK and ends walks with noSuchName: same inventory.
    func test_stackedSwitch_overV1() async throws {
        let a = stackedSwitch(); a.v1 = true
        let r = try await SNMPInventory.query(a.client(version: .v1), maxRows: 1000)
        XCTAssertEqual(r.source, .entity)
        XCTAssertEqual(r.mainItems.count, 8)
        XCTAssertEqual(r.serialCount, 7)
        XCTAssertEqual(a.bulkCount, 0)
    }

    func test_copyAllSerials_onePartPerLine() async throws {
        let r = try await SNMPInventory.query(stackedSwitch().client(), maxRows: 1000)
        let lines = SNMPInventory.serialList(r).components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 7)
        XCTAssertEqual(lines.first, "Switch 1\tC9300-48P\tFOC2101A1AB")
        XCTAssertTrue(lines.contains("Te2/1/1\tSFP-10G-SR\tAGM1234X5Y6"))
        XCTAssertFalse(lines.contains { $0.hasPrefix("Stack") })      // no serial, not copied
    }

    func test_export_hasEveryField() async throws {
        let r = try await SNMPInventory.query(stackedSwitch().client(), maxRows: 1000)
        let text = SNMPInventory.exportText(r)
        XCTAssertTrue(text.hasPrefix("Source: ENTITY-MIB"))
        XCTAssertTrue(text.contains("8 parts, 7 serial numbers"))
        XCTAssertTrue(text.contains("index\tname\tkind\tmodel\tserial\tmanufacturer\thardware\tfirmware\tsoftware\tdescription\tcontained in\tsource"))
        XCTAssertTrue(text.contains("1000\tSwitch 1\tChassis\tC9300-48P\tFOC2101A1AB\tCisco\tV02\t\t17.9.4\tC9300-48P\t1\tENTITY-MIB"))
        XCTAssertTrue(text.contains("(Left out: 3 entries with no serial number"))
        XCTAssertFalse(text.contains("Te1/1/1"))
    }

    func test_rowLimit_isNoted() async throws {
        let r = try await SNMPInventory.query(stackedSwitch().client(), maxRows: 4)
        XCTAssertEqual(r.note, .limit(4))
        XCTAssertEqual(r.source, .entity)
        XCTAssertEqual(r.items.count, 4)
    }

    /// Stacks and chassis lead; a containment loop and a missing parent
    /// still list every entry exactly once.
    func test_treeOrder_chassisFirst_andSurvivesLoops() {
        let ids: [UInt32] = [1, 2, 3, 4, 5, 6, 7]
        let parent: [UInt32: UInt32] = [3: 4, 4: 3,      // a loop with no way in
                                        5: 99,           // parent not in the table
                                        6: 6,            // contained in itself
                                        7: 2]
        let rank: [UInt32: Int] = [2: 1, 7: 2]           // 2 is a chassis
        let order = SNMPInventory.treeOrder(ids, parent: parent, rank: rank)
        XCTAssertEqual(order.map(\.id), [2, 7, 1, 5, 6, 3, 4])
        XCTAssertEqual(order.first { $0.id == 7 }?.ancestors, [2])
        XCTAssertEqual(order.first { $0.id == 4 }?.ancestors, [3])
        XCTAssertEqual(Set(order.map(\.id)).count, ids.count)
    }

    /// Wrong types, blank padding, binary serials, and odd indexes: no crash.
    func test_oddDeviceValues() async throws {
        let a = FakeSNMPAgent([
            ("\(entry).5.1", .integer(3)),
            ("\(entry).5.2", s("chassis")),                    // class as a string
            ("\(entry).5.3", .integer(99)),                    // a class we don't know
            ("\(entry).5.4.7", .integer(9)),                   // a two-number index
            ("\(entry).4.1", .integer(-5)),                    // negative parent
            ("\(entry).4.2", .integer(Int64(UInt32.max) + 10)),
            ("\(entry).7.1", s("  Chassis\r\n")),
            ("\(entry).11.1", s("  SN 123\t456  ")),
            ("\(entry).11.2", .octetString(Data([0x00, 0x1A, 0x2B, 0x3C]))),
            ("\(entry).11.3", .noSuchInstance),
            ("\(entry).13.1", .integer(5)),                    // model as a number
        ])
        let r = try await SNMPInventory.query(a.client(), maxRows: 100)
        XCTAssertEqual(r.items.map(\.entityIndex), [1, 2, 3])
        let first = try XCTUnwrap(r.items.first)
        XCTAssertEqual(first.name, "Chassis")
        XCTAssertEqual(first.serial, "SN 123 456")
        XCTAssertEqual(first.model, "")
        XCTAssertNil(first.containedIn)
        XCTAssertEqual(r.items[1].kind, .other)
        XCTAssertEqual(r.items[1].serial, "")
        XCTAssertEqual(r.items[1].displayName, "Entry 2")
        XCTAssertEqual(r.items[2].kind, .other)
    }

    /// A device that lists only ports and sensors shows them all, not nothing.
    func test_onlyMinorEntries_areAllShown() async throws {
        var e: [(String, SNMPValue)] = []
        e += entity(1, cls: 10, in: 0, name: "eth0")
        e += entity(2, cls: 8, in: 0, name: "CPU temp")
        let r = try await SNMPInventory.query(FakeSNMPAgent(e).client(), maxRows: 100)
        XCTAssertEqual(r.mainItems.count, 2)
        XCTAssertEqual(r.hiddenCount, 0)
        XCTAssertEqual(SNMPInventory.summary(r), "2 parts, no serial numbers")
    }

    // MARK: Without ENTITY-MIB

    func test_printerFallback() async throws {
        let a = FakeSNMPAgent([
            ("1.3.6.1.2.1.1.1.0", s("HP ETHERNET MULTI-ENVIRONMENT")),
            ("1.3.6.1.2.1.1.5.0", s("printer-2f")),
            ("1.3.6.1.2.1.25.3.2.1.3.1", s("HP LaserJet Pro M404dn")),
            ("1.3.6.1.2.1.43.5.1.1.17.1", .octetString(Data("PHBQK12345\0\0".utf8))),
        ])
        let r = try await SNMPInventory.query(a.client(), maxRows: 1000)
        XCTAssertEqual(r.source, .otherMIBs)
        XCTAssertEqual(r.items.count, 1)
        let p = try XCTUnwrap(r.items.first)
        XCTAssertEqual(p.kind, .printer)
        XCTAssertEqual(p.name, "printer-2f")
        XCTAssertEqual(p.model, "HP LaserJet Pro M404dn")
        XCTAssertEqual(p.serial, "PHBQK12345")
        XCTAssertEqual(p.source, "Printer-MIB, HOST-RESOURCES-MIB")
        XCTAssertEqual(SNMPInventory.summary(r), "1 part, 1 serial number")
        XCTAssertEqual(SNMPInventory.serialList(r), "printer-2f\tHP LaserJet Pro M404dn\tPHBQK12345")
        XCTAssertTrue(SNMPInventory.exportText(r).contains("\tPrinter-MIB, HOST-RESOURCES-MIB\n"))
    }

    func test_printerFallback_overV1() async throws {
        let a = FakeSNMPAgent([
            ("1.3.6.1.2.1.1.1.0", s("Brother NC-8300h")),
            ("1.3.6.1.2.1.43.5.1.1.17.1", s("E7834512")),
        ])
        a.v1 = true
        let r = try await SNMPInventory.query(a.client(version: .v1), maxRows: 1000)
        XCTAssertEqual(r.items.map(\.serial), ["E7834512"])
        XCTAssertEqual(r.items.first?.name, "Printer")
        XCTAssertEqual(r.items.first?.source, "Printer-MIB")
    }

    func test_upsFallback_withAPCSerial() async throws {
        let a = FakeSNMPAgent([
            ("1.3.6.1.2.1.1.1.0", s("APC Web/SNMP Management Card")),
            ("1.3.6.1.2.1.33.1.1.1.0", s("APC")),
            ("1.3.6.1.2.1.33.1.1.2.0", s("Smart-UPS 1500")),
            ("1.3.6.1.2.1.33.1.1.3.0", s("UPS 09.3")),
            ("1.3.6.1.2.1.33.1.1.4.0", s("v6.8.2")),
            ("1.3.6.1.2.1.33.1.1.5.0", s("rack-ups")),
            ("1.3.6.1.4.1.318.1.1.1.1.2.1.0", s("UPS 09.3 (ID18)")),
            ("1.3.6.1.4.1.318.1.1.1.1.2.3.0", s("AS1234567890")),
        ])
        let r = try await SNMPInventory.query(a.client(), maxRows: 1000)
        XCTAssertEqual(r.source, .otherMIBs)
        let u = try XCTUnwrap(r.items.first)
        XCTAssertEqual(u.kind, .ups)
        XCTAssertEqual(u.name, "rack-ups")
        XCTAssertEqual(u.model, "Smart-UPS 1500")
        XCTAssertEqual(u.manufacturer, "APC")
        XCTAssertEqual(u.serial, "AS1234567890")
        XCTAssertEqual(u.softwareRev, "UPS 09.3")
        XCTAssertEqual(u.firmwareRev, "UPS 09.3 (ID18)")
        XCTAssertEqual(u.descr, "SNMP agent software v6.8.2")
        XCTAssertEqual(u.source, "UPS-MIB, APC PowerNet-MIB")
    }

    func test_upsFallback_withoutSerial() async throws {
        let a = FakeSNMPAgent([
            ("1.3.6.1.2.1.33.1.1.1.0", s("Eaton")),
            ("1.3.6.1.2.1.33.1.1.2.0", s("5PX 1500")),
        ])
        let r = try await SNMPInventory.query(a.client(), maxRows: 1000)
        XCTAssertEqual(r.items.map(\.kind), [.ups])
        XCTAssertEqual(r.items.first?.name, "UPS")
        XCTAssertEqual(r.items.first?.serial, "")
        XCTAssertEqual(r.items.first?.source, "UPS-MIB")
        XCTAssertEqual(SNMPInventory.summary(r), "1 part, no serial numbers")
        XCTAssertEqual(SNMPInventory.serialList(r), "")
    }

    func test_synologyFallback() async throws {
        let a = FakeSNMPAgent([
            ("1.3.6.1.2.1.1.1.0", s("Linux nas 4.4.302+ #69057 SMP x86_64")),
            ("1.3.6.1.2.1.1.5.0", s("nas")),
            ("1.3.6.1.4.1.6574.1.5.1.0", s("DS920+")),
            ("1.3.6.1.4.1.6574.1.5.2.0", s("2040PDN123456")),
            ("1.3.6.1.4.1.6574.1.5.3.0", s("DSM 7.2-64570")),
        ])
        let r = try await SNMPInventory.query(a.client(), maxRows: 1000)
        XCTAssertEqual(r.source, .otherMIBs)
        let n = try XCTUnwrap(r.items.first)
        XCTAssertEqual(r.items.count, 1)
        XCTAssertEqual(n.kind, .nas)
        XCTAssertEqual(n.name, "nas")
        XCTAssertEqual(n.model, "DS920+")
        XCTAssertEqual(n.serial, "2040PDN123456")
        XCTAssertEqual(n.manufacturer, "Synology")
        XCTAssertEqual(n.softwareRev, "DSM 7.2-64570")
        XCTAssertEqual(n.source, "Synology MIB")
    }

    // MARK: Nothing to report

    func test_nothing_showsSysDescrAsDeviceRow() async throws {
        let a = FakeSNMPAgent([
            ("1.3.6.1.2.1.1.1.0", s("Linux router 5.15.0\r\nbuilt by OpenWrt\r\n")),
            ("1.3.6.1.2.1.1.5.0", s("gw")),
        ])
        let r = try await SNMPInventory.query(a.client(), maxRows: 1000)
        XCTAssertEqual(r.source, .systemOnly)
        XCTAssertEqual(r.items.count, 1)
        let d = try XCTUnwrap(r.items.first)
        XCTAssertEqual(d.kind, .device)
        XCTAssertEqual(d.name, "gw")
        XCTAssertEqual(d.descr, "Linux router 5.15.0\nbuilt by OpenWrt")
        XCTAssertEqual(d.serial, "")
        XCTAssertEqual(d.source, "sysDescr")
        XCTAssertEqual(SNMPInventory.summary(r), "No hardware details reported")
        XCTAssertEqual(SNMPInventory.serialList(r), "")
        let text = SNMPInventory.exportText(r)
        XCTAssertTrue(text.hasPrefix("This device doesn't report models or serial numbers over SNMP"))
        XCTAssertTrue(text.contains("\tgw\tDevice\t"))
        XCTAssertTrue(text.contains("Linux router 5.15.0 built by OpenWrt"))   // one line in the export
    }

    /// v1 fails a whole GET over one missing OID; the fallback GET must
    /// still come back with the values that are there.
    func test_nothing_overV1() async throws {
        let a = FakeSNMPAgent([("1.3.6.1.2.1.1.1.0", s("ZyXEL GS1900-8"))])
        a.v1 = true
        let r = try await SNMPInventory.query(a.client(version: .v1), maxRows: 1000)
        XCTAssertEqual(r.source, .systemOnly)
        XCTAssertEqual(r.items.first?.name, "Device")
        XCTAssertEqual(r.items.first?.descr, "ZyXEL GS1900-8")
    }

    func test_emptyAgent_stillReturnsDeviceRow() async throws {
        let r = try await SNMPInventory.query(FakeSNMPAgent([]).client(), maxRows: 1000)
        XCTAssertEqual(r.source, .systemOnly)
        XCTAssertEqual(r.items.first?.descr, "")
        XCTAssertEqual(r.items.first?.displayName, "Device")
    }

    // MARK: Table layout

    /// Each table layout fits the narrowest pane it's used in, with a scroll
    /// bar showing, so no column runs off the right edge between a 650 pt
    /// pane and a wide window.
    func test_tableLayouts_fitTheirNarrowestPane() {
        let narrow = SNMPInventoryPane.narrowIdeals, wide = SNMPInventoryPane.wideIdeals
        XCTAssertEqual(narrow.count, 4)                     // Part, Model, Serial, Versions
        XCTAssertEqual(wide.count, 5)                       // Name, Kind, Model, Serial, Versions
        XCTAssertLessThanOrEqual(SNMPInventoryPane.tableWidth(narrow), 650)
        XCTAssertLessThanOrEqual(SNMPInventoryPane.tableWidth(wide), SNMPInventoryPane.wideLayoutWidth)
        XCTAssertLessThanOrEqual(SNMPInventoryPane.wideLayoutWidth, 1100)
        // The rule matches an offscreen render of the 7-column table this
        // replaced: it needed 1,094 pt, plus 17 pt for a scroll bar, but
        // was used from 880 pt.
        XCTAssertEqual(SNMPInventoryPane.tableWidth([260, 100, 160, 170, 70, 90, 110]), 1094 + 17)
    }

    func test_versionsColumn_linesAndTooltip() async throws {
        let r = try await SNMPInventory.query(stackedSwitch().client(), maxRows: 1000)
        let chassis = try XCTUnwrap(r.items.first { $0.entityIndex == 1000 })
        XCTAssertEqual(SNMPInventoryPane.versionLines(chassis), ["HW V02", "SW 17.9.4"])
        XCTAssertEqual(SNMPInventoryPane.versionsHelp(chassis), "Hardware: V02\nSoftware: 17.9.4")
        let stack = try XCTUnwrap(r.items.first { $0.entityIndex == 1 })
        XCTAssertEqual(SNMPInventoryPane.versionLines(stack), [])
        XCTAssertEqual(SNMPInventoryPane.versionsHelp(stack), "")
    }

    /// A device that rejects GETBULK still gets its inventory read.
    func test_bulkRejected_fallsBackToGetNext() async throws {
        let a = stackedSwitch(); a.rejectBulk = true
        let r = try await SNMPInventory.query(a.client(), maxRows: 1000)
        XCTAssertEqual(r.mainItems.count, 8)
        XCTAssertTrue(a.sawGetNext)
    }
}
