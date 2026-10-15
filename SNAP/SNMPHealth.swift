// SNMPHealth.swift
// SNAP — SNMP Health view: printer supplies, UPS battery, storage and CPU
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md
//
// Three checks, each asked only as far as the device answers it:
//
//   • Printer (Printer-MIB, RFC 3805): the supplies table (toner, ink, drums,
//     waste boxes) and the lifetime page counter, plus the printer's own
//     alert flags from HOST-RESOURCES-MIB's hrPrinterTable.
//   • UPS (UPS-MIB, RFC 1628): battery status, charge, minutes left, power
//     source, load per output line, and alarms. When the device has no
//     UPS-MIB, APC's PowerNet MIB (enterprise 318) is tried instead.
//   • Storage and CPU (HOST-RESOURCES-MIB, RFC 2790): hrStorageTable
//     (disks and memory) and hrProcessorLoad.
//
// A MIB the device doesn't have leaves its section out; it isn't an error.
// Each section gets a one-line verdict; the pure functions behind the
// verdicts are static so the tests can check the wording and thresholds.

import SwiftUI

// CONTRACT (used by SNMPView.swift; keep these names and signatures):
//   struct SNMPHealthReport: Equatable
//   enum SNMPHealth {
//     static func query(_ client: SNMPClient, maxRows: Int) async throws -> SNMPHealthReport
//     static func summary(_ r: SNMPHealthReport) -> String
//     static func exportText(_ r: SNMPHealthReport) -> String
//   }
//   struct SNMPHealthPane: View { init(model: SNMPQueryModel, report: SNMPHealthReport) }

// MARK: - Report

/// How much something needs attention. Worse is greater.
enum SNMPHealthLevel: Int, Comparable {
    case info, good, warning, critical
    static func < (a: SNMPHealthLevel, b: SNMPHealthLevel) -> Bool { a.rawValue < b.rawValue }
}

/// One line of plain-English judgement.
struct SNMPHealthVerdict: Equatable {
    var level: SNMPHealthLevel
    var text: String
    init(_ level: SNMPHealthLevel, _ text: String) {
        self.level = level
        self.text = text
    }
}

struct SNMPHealthReport: Equatable {
    var printer: SNMPPrinterHealth?
    var ups: SNMPUPSHealth?
    var host: SNMPHostHealth?
    /// Lists that stopped early (row limit, a device error partway).
    var notes: [String] = []

    /// How many of the three checks (printer, UPS, host resources) answered.
    var answered: Int { [printer != nil, ups != nil, host != nil].filter { $0 }.count }
    var isEmpty: Bool { answered == 0 }
}

/// One row of prtMarkerSuppliesTable.
struct SNMPPrinterSupply: Equatable, Identifiable {
    var id: String                  // the row index, e.g. "1.1"
    var name: String
    var level: Int64?               // prtMarkerSuppliesLevel as reported
    var maxCapacity: Int64?         // prtMarkerSuppliesMaxCapacity as reported
    /// A waste box (receptacleThatIsFilled): its level is the space left.
    var isReceptacle = false

    /// Percent left (of space, for a waste box), when the printer gives a
    /// level and a maximum. Rounded down, so "under 10%" stays true, and a
    /// supply with a little left can read 0: see `isOut`.
    var percent: Int? { SNMPHealth.supplyPercent(level: level, max: maxCapacity) }

    /// Nothing left (a waste box: no space left). Only a level of 0 says
    /// so; a percent rounded down to 0 can still have some left.
    var isOut: Bool { level == 0 && percent != nil }

    /// Some left, but under 1%: the percent rounds down to 0.
    var isUnderOnePercent: Bool { percent == 0 && (level ?? 0) > 0 }
}

struct SNMPPrinterHealth: Equatable {
    var supplies: [SNMPPrinterSupply] = []
    var lifeCount: UInt64?          // prtMarkerLifeCount, first marker
    var lifeCountUnit: Int64?       // prtMarkerCounterUnit for that marker
    var status: Int64?              // hrPrinterStatus
    /// hrPrinterDetectedErrorState bits that are set (0 = lowPaper, ...).
    var alerts: [Int] = []
}

struct SNMPUPSHealth: Equatable {
    enum Source: Equatable { case upsMIB, apc }
    enum Power: Equatable { case mains, boosting, trimming, battery, bypass, off, other(Int64) }
    enum Battery: Equatable { case normal, low, depleted, unknown, fault }
    /// One row of upsAlarmTable.
    struct Alarm: Equatable {
        /// The upsWellKnownAlarms number (RFC 1628), nil for a vendor's own alarm.
        var code: Int?
        var name: String
    }

    var source: Source
    var manufacturer: String?
    var model: String?
    var power: Power?
    var battery: Battery?
    var secondsOnBattery: UInt64?
    var minutesLeft: UInt64?
    var charge: Int?                // percent
    var loads: [Int] = []           // percent of capacity, per output line
    var alarmCount: Int?            // upsAlarmsPresent
    var alarmList: [Alarm] = []     // the alarms present, in table order
    /// The battery-bad alarm, or APC's "replace battery" indicator.
    var replaceBattery = false
    var overload = false
    var selfTestFailed = false

    /// Names of the alarms present.
    var alarms: [String] { alarmList.map(\.name) }
    /// The upsWellKnownAlarms numbers present.
    var alarmCodes: Set<Int> { Set(alarmList.compactMap(\.code)) }

    var isOnBattery: Bool {
        if power == .battery { return true }
        // No usable power source: upsSecondsOnBattery is 0 unless on
        // battery, and the on-battery alarm (2) says so too.
        switch power {
        case nil, .other?: return (secondsOnBattery ?? 0) > 0 || alarmCodes.contains(2)
        default:           return false
        }
    }
    var maxLoad: Int? { loads.max() }
}

/// One row of hrStorageTable, in bytes.
struct SNMPStorageEntry: Equatable, Identifiable {
    enum Kind: Equatable {
        case ram, virtualMemory, fixedDisk, removableDisk, floppyDisk, compactDisc,
             ramDisk, flashMemory, networkDisk, other
    }
    /// Why an entry is left out until "Show all" is on.
    enum Hidden: Equatable {
        case zeroSize, notDiskOrMemory, systemMount, snapImage, small, duplicate(of: String)
    }

    var id: UInt32                  // hrStorageIndex
    var kind: Kind
    var name: String
    var size: UInt64
    var used: UInt64                // as reported
    /// Linux (net-snmp): cache and buffers counted in `used`, taken off.
    var cacheBytes: UInt64? = nil
    var cacheLabel: String? = nil
    var hidden: Hidden? = nil

    var isDisk: Bool { kind == .fixedDisk || kind == .networkDisk }
    var usedNet: UInt64 {
        guard let c = cacheBytes, c <= used else { return used }
        return used - c
    }
    /// Percent used, rounded down so "under 80%" stays true. nil: no size.
    var percent: Int? { SNMPHealth.percentDown(usedNet, of: size) }
}

struct SNMPHostHealth: Equatable {
    var storage: [SNMPStorageEntry] = []
    var cpuLoads: [Int] = []        // hrProcessorLoad, one-minute average per processor

    var disks: [SNMPStorageEntry] { storage.filter { $0.hidden == nil && $0.isDisk } }
    var memory: [SNMPStorageEntry] { storage.filter { $0.hidden == nil && $0.kind == .ram } }
    var hiddenEntries: [SNMPStorageEntry] { storage.filter { $0.hidden != nil } }
    var cpuAverage: Int? {
        guard !cpuLoads.isEmpty else { return nil }
        return Int((Double(cpuLoads.reduce(0, +)) / Double(cpuLoads.count)).rounded())
    }
}

// MARK: - Query

enum SNMPHealth {
    // Thresholds (percent unless noted)
    static let supplyLowPercent = 10            // under this: replace soon; 0: empty
    static let diskWarnPercent = 80
    static let diskCriticalPercent = 90
    static let cpuWarnPercent = 75
    static let cpuCriticalPercent = 90
    static let loadWarnPercent = 75
    static let loadCriticalPercent = 90
    static let chargeWarnPercent = 50
    static let chargeCriticalPercent = 20
    static let onBatteryCriticalMinutes: UInt64 = 5
    /// Disks smaller than this are hidden until "Show all" (bytes).
    static let smallVolumeBytes: UInt64 = 100_000_000

    static let nothingAnswered = "This device didn't answer the standard printer, UPS, or host resources MIBs, so SNAP has no health data for it."

    // OIDs
    private static let suppliesEntry   = OID([1,3,6,1,2,1,43,11,1,1])     // prtMarkerSuppliesEntry
    private static let markerEntry     = OID([1,3,6,1,2,1,43,10,2,1])     // prtMarkerEntry
    private static let hrPrinterEntry  = OID([1,3,6,1,2,1,25,3,5,1])      // hrPrinterEntry
    private static let upsObjects      = OID([1,3,6,1,2,1,33,1])          // UPS-MIB upsObjects
    private static let apcUPS          = OID([1,3,6,1,4,1,318,1,1,1])     // PowerNet-MIB ups
    private static let hrStorageEntry  = OID([1,3,6,1,2,1,25,2,3,1])
    private static let hrStorageTypes  = OID([1,3,6,1,2,1,25,2,1])
    private static let hrProcessorLoad = OID([1,3,6,1,2,1,25,3,3,1,2])

    private static func oid(_ base: OID, _ tail: UInt32...) -> OID { OID(base.components + tail) }

    static func query(_ client: SNMPClient, maxRows: Int) async throws -> SNMPHealthReport {
        // One request at a time, one section after another.
        var reader = HealthReader(client: client, maxRows: max(1, maxRows))
        var report = SNMPHealthReport()
        report.printer = try await readPrinter(&reader)
        report.ups = try await readUPS(&reader)
        report.host = try await readHost(&reader)
        report.notes = reader.notes
        return report
    }

    // MARK: Printer

    private static func readPrinter(_ r: inout HealthReader) async throws -> SNMPPrinterHealth? {
        let list = "supply list"
        var p = SNMPPrinterHealth()
        let levels = try await r.column(oid(suppliesEntry, 9), list: list)
        if !levels.order.isEmpty {
            let descr = try await r.column(oid(suppliesEntry, 6), list: list)
            let maxCap = try await r.column(oid(suppliesEntry, 8), list: list)
            let classes = try await r.column(oid(suppliesEntry, 4), list: list)
            // The type only names supplies that have no description.
            var types = SNMPColumn()
            if levels.order.contains(where: { cleanText(descr[$0]) == nil }) {
                types = try await r.column(oid(suppliesEntry, 5), list: list)
            }
            for (n, idx) in levels.order.enumerated() {
                let name = cleanText(descr[idx])
                    ?? types[idx]?.int64.flatMap(supplyTypeName)
                    ?? "Supply \(n + 1)"
                p.supplies.append(SNMPPrinterSupply(
                    id: idx.map(String.init).joined(separator: "."),
                    name: name,
                    level: levels[idx]?.int64,
                    maxCapacity: maxCap[idx]?.int64,
                    isReceptacle: classes[idx]?.int64 == 4))
            }
        }
        if let life = try await r.firstRow(oid(markerEntry, 4)), let count = life.value.uint64 {
            p.lifeCount = count
            let unitOID = OID(oid(markerEntry, 3).components + life.index)
            p.lifeCountUnit = try await r.scalars([unitOID])[unitOID]?.int64
        }
        guard !p.supplies.isEmpty || p.lifeCount != nil else { return nil }
        // Only printers have hrPrinterTable rows, so ask once this is one.
        if let status = try await r.firstRow(oid(hrPrinterEntry, 1)) {
            p.status = status.value.int64
        }
        if let errors = try await r.firstRow(oid(hrPrinterEntry, 2)), let bits = errors.value.bytes {
            p.alerts = alertBits(bits)
        }
        return p
    }

    // MARK: UPS

    private static func readUPS(_ r: inout HealthReader) async throws -> SNMPUPSHealth? {
        if try await r.hasSubtree(upsObjects), let u = try await readUPSMIB(&r) { return u }
        if try await r.hasSubtree(apcUPS) { return try await readAPC(&r) }
        return nil
    }

    private static func readUPSMIB(_ r: inout HealthReader) async throws -> SNMPUPSHealth? {
        let mfr = oid(upsObjects, 1, 1, 0), model = oid(upsObjects, 1, 2, 0)
        let status = oid(upsObjects, 2, 1, 0), onBattery = oid(upsObjects, 2, 2, 0)
        let minutes = oid(upsObjects, 2, 3, 0), charge = oid(upsObjects, 2, 4, 0)
        let source = oid(upsObjects, 4, 1, 0), alarmsPresent = oid(upsObjects, 6, 1, 0)
        let v = try await r.scalars([mfr, model, status, onBattery, minutes, charge, source, alarmsPresent])
        guard [status, onBattery, minutes, charge, source].contains(where: { v[$0] != nil }) else { return nil }

        var u = SNMPUPSHealth(source: .upsMIB)
        u.manufacturer = cleanText(v[mfr])
        u.model = cleanText(v[model])
        u.battery = v[status]?.int64.flatMap(upsMIBBattery)
        u.secondsOnBattery = v[onBattery]?.uint64
        u.minutesLeft = v[minutes]?.uint64
        u.charge = v[charge]?.int64.map(clampPercent)
        u.power = v[source]?.int64.map(upsMIBPower)

        let loads = try await r.column(oid(upsObjects, 4, 4, 1, 5), list: "output load list")
        u.loads = loads.order.compactMap { loads[$0]?.int64 }.map { Int(max(0, min(999, $0))) }

        u.alarmCount = v[alarmsPresent]?.int64.map { Int(clamping: max(0, $0)) }
        if let n = u.alarmCount, n > 0 {
            let descr = try await r.column(oid(upsObjects, 6, 2, 1, 2), list: "alarm list")
            let wellKnown = oid(upsObjects, 6, 3)
            for idx in descr.order {
                guard case .oid(let alarm)? = descr[idx] else { continue }
                if wellKnown.isAncestorOrEqual(alarm),
                   alarm.components.count == wellKnown.components.count + 1,
                   let k = alarm.components.last {
                    switch k {
                    case 1:  u.replaceBattery = true
                    case 8:  u.overload = true
                    case 19: u.selfTestFailed = true
                    default: break
                    }
                    u.alarmList.append(.init(code: Int(k), name: upsAlarmName(Int(k)) ?? "alarm \(k)"))
                } else {
                    u.alarmList.append(.init(code: nil, name: "vendor alarm \(alarm.description)"))
                }
            }
        }
        return u
    }

    /// APC's own MIB, for APC network cards that don't serve UPS-MIB.
    private static func readAPC(_ r: inout HealthReader) async throws -> SNMPUPSHealth? {
        let model = oid(apcUPS, 1, 1, 1, 0)           // upsBasicIdentModel
        let status = oid(apcUPS, 2, 1, 1, 0)          // upsBasicBatteryStatus
        let onBattery = oid(apcUPS, 2, 1, 2, 0)       // upsBasicBatteryTimeOnBattery (TimeTicks)
        let capacity = oid(apcUPS, 2, 2, 1, 0)        // upsAdvBatteryCapacity (%)
        let runtime = oid(apcUPS, 2, 2, 3, 0)         // upsAdvBatteryRunTimeRemaining (TimeTicks)
        let replace = oid(apcUPS, 2, 2, 4, 0)         // upsAdvBatteryReplaceIndicator
        let output = oid(apcUPS, 4, 1, 1, 0)          // upsBasicOutputStatus
        let load = oid(apcUPS, 4, 2, 3, 0)            // upsAdvOutputLoad (%)
        let v = try await r.scalars([model, status, onBattery, capacity, runtime, replace, output, load])
        guard [status, capacity, runtime, output].contains(where: { v[$0] != nil }) else { return nil }

        var u = SNMPUPSHealth(source: .apc)
        u.model = cleanText(v[model])
        u.battery = v[status]?.int64.flatMap(apcBattery)
        u.secondsOnBattery = v[onBattery]?.uint64.map { $0 / 100 }
        u.charge = v[capacity]?.int64.map(clampPercent)
        u.minutesLeft = v[runtime]?.uint64.map { $0 / 6000 }
        u.replaceBattery = v[replace]?.int64 == 2
        u.power = v[output]?.int64.flatMap(apcPower)
        if let l = v[load]?.int64 { u.loads = [Int(max(0, min(999, l)))] }
        return u
    }

    // MARK: Storage and CPU

    private static func readHost(_ r: inout HealthReader) async throws -> SNMPHostHealth? {
        let list = "storage list"
        var h = SNMPHostHealth()
        let types = try await r.column(oid(hrStorageEntry, 2), list: list)
        if !types.order.isEmpty {
            let descr = try await r.column(oid(hrStorageEntry, 3), list: list)
            let units = try await r.column(oid(hrStorageEntry, 4), list: list)
            let sizes = try await r.column(oid(hrStorageEntry, 5), list: list)
            let used = try await r.column(oid(hrStorageEntry, 6), list: list)
            var entries: [SNMPStorageEntry] = []
            for idx in types.order where idx.count == 1 {
                let i = idx[0]
                let unit = UInt64(max(0, units[idx]?.int64 ?? 0))
                entries.append(SNMPStorageEntry(
                    id: i,
                    kind: storageKind(types[idx]),
                    name: storageName(descr[idx]) ?? "Storage \(i)",
                    size: bytes(storageCount(sizes[idx]), unit: unit),
                    used: bytes(storageCount(used[idx]), unit: unit)))
            }
            h.storage = classifyStorage(entries)
        }
        let cpu = try await r.column(hrProcessorLoad, list: "processor list")
        h.cpuLoads = cpu.order.compactMap { cpu[$0]?.int64 }.map(clampPercent)
        guard !h.storage.isEmpty || !h.cpuLoads.isEmpty else { return nil }
        return h
    }

    /// hrStorageSize and hrStorageUsed are Integer32, so older agents report
    /// volumes over 2^31 units as negative numbers: read them as unsigned.
    static func storageCount(_ v: SNMPValue?) -> UInt64? {
        guard let v else { return nil }
        if case .integer(let i) = v {
            if i >= 0 { return UInt64(i) }
            guard i >= Int64(Int32.min) else { return nil }
            return UInt64(UInt32(bitPattern: Int32(i)))
        }
        return v.uint64
    }

    private static func bytes(_ count: UInt64?, unit: UInt64) -> UInt64 {
        guard let count else { return 0 }
        let (v, overflow) = count.multipliedReportingOverflow(by: unit)
        return overflow ? 0 : v
    }

    static func storageKind(_ v: SNMPValue?) -> SNMPStorageEntry.Kind {
        guard case .oid(let o)? = v, hrStorageTypes.isAncestorOrEqual(o),
              o.components.count == hrStorageTypes.components.count + 1,
              let last = o.components.last else { return .other }
        switch last {
        case 2:  return .ram
        case 3:  return .virtualMemory
        case 4:  return .fixedDisk
        case 5:  return .removableDisk
        case 6:  return .floppyDisk
        case 7:  return .compactDisc
        case 8:  return .ramDisk
        case 9:  return .flashMemory
        case 10: return .networkDisk
        default: return .other
        }
    }

    /// The description, with Windows' "C:\ Label:System  Serial Number 1a2b"
    /// shortened to "C:\ (System)".
    static func storageName(_ v: SNMPValue?) -> String? {
        guard let s = cleanText(v) else { return nil }
        guard let r = s.range(of: " Label:") else { return s }
        let drive = String(s[..<r.lowerBound])
        var label = s[r.upperBound...]
        if let sn = label.range(of: "Serial Number") { label = label[..<sn.lowerBound] }
        let l = label.trimmingCharacters(in: .whitespaces)
        return l.isEmpty ? drive : "\(drive) (\(l))"
    }

    /// Works out what to show by default: disks of a real size and main
    /// memory. Hides what isn't a disk or memory, empty and tiny volumes,
    /// /dev, /run, /sys and /proc mounts, snap images, and the same volume
    /// mounted twice. On Linux, takes cache and buffers off memory used.
    static func classifyStorage(_ entries: [SNMPStorageEntry]) -> [SNMPStorageEntry] {
        var out = entries
        func used(named name: String) -> UInt64? {
            entries.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.used
        }
        // net-snmp on Linux counts cache and buffers in "Physical memory"
        // used, and lists them as their own entries.
        let cached = used(named: "Cached memory"), buffers = used(named: "Memory buffers")
        if cached != nil || buffers != nil,
           let pm = out.firstIndex(where: { $0.kind == .ram && $0.name.caseInsensitiveCompare("Physical memory") == .orderedSame }) {
            let (sum, overflow) = (cached ?? 0).addingReportingOverflow(buffers ?? 0)
            if !overflow, sum > 0, sum <= out[pm].used {
                out[pm].cacheBytes = sum
                out[pm].cacheLabel = cached != nil && buffers != nil ? "cache and buffers"
                                   : cached != nil ? "cache" : "buffers"
            }
        }

        for i in out.indices where !out[i].isDisk {
            if out[i].kind != .ram { out[i].hidden = .notDiskOrMemory }
            else if out[i].size == 0 { out[i].hidden = .zeroSize }
        }
        // Shorter names first, so /volume1 stays and /volume1/@docker is the duplicate.
        let diskOrder = out.indices.filter { out[$0].isDisk }
            .sorted { (out[$0].name.count, $0) < (out[$1].name.count, $1) }
        var kept: [SNMPStorageEntry] = []
        for i in diskOrder {
            let e = out[i]
            if e.size == 0 {
                out[i].hidden = .zeroSize
            } else if isSystemMount(e.name) {
                out[i].hidden = .systemMount
            } else if e.name.hasPrefix("/snap/") {
                out[i].hidden = .snapImage
            } else if e.size < smallVolumeBytes {
                out[i].hidden = .small
            } else if let d = kept.first(where: { $0.size == e.size && $0.used == e.used }) {
                out[i].hidden = .duplicate(of: d.name)
            } else {
                kept.append(e)
            }
        }
        return out
    }

    static func isSystemMount(_ name: String) -> Bool {
        ["/dev", "/run", "/sys", "/proc"].contains { name == $0 || name.hasPrefix($0 + "/") }
    }

    // MARK: Value helpers

    static func cleanText(_ v: SNMPValue?) -> String? {
        guard let s = v?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    private static func clampPercent(_ v: Int64) -> Int { Int(max(0, min(100, v))) }

    /// level / max, when both make sense. A level of -1 (other), -2
    /// (unknown) or -3 (some remaining) has no percent. A level of 0 is 0%
    /// even when the maximum is -1 or -2: nothing is left of any amount. A
    /// maximum of 0 usually means the slot isn't in use, so no percent.
    static func supplyPercent(level: Int64?, max: Int64?) -> Int? {
        guard let level, let max, level >= 0 else { return nil }
        if level == 0 && (max == -1 || max == -2) { return 0 }
        guard max > 0 else { return nil }
        return percentDown(UInt64(level), of: UInt64(max))
    }

    /// part / whole as a whole percent, rounded down, at most 100. In
    /// integers, so an exact 92% never comes out as 91.
    static func percentDown(_ part: UInt64, of whole: UInt64) -> Int? {
        guard whole > 0 else { return nil }
        if part >= whole { return 100 }
        let (scaled, overflow) = part.multipliedReportingOverflow(by: 100)
        if !overflow { return Int(scaled / whole) }
        // Only past about 180 PB: divide first.
        return Swift.min(100, Int(part / (whole / 100)))
    }

    /// SNMP BITS: bit 0 is the high bit of the first byte.
    static func alertBits(_ d: Data) -> [Int] {
        var out: [Int] = []
        for (byteIndex, byte) in d.prefix(4).enumerated() {
            for bit in 0..<8 where byte & (UInt8(0x80) >> UInt8(bit)) != 0 {
                out.append(byteIndex * 8 + bit)
            }
        }
        return out
    }

    /// hrPrinterDetectedErrorState bits (RFC 2790, extended by RFC 3805).
    /// Info-level ones are listed but don't change the verdict.
    static func printerAlert(_ bit: Int) -> (name: String, level: SNMPHealthLevel)? {
        switch bit {
        case 0:  return ("low paper", .info)
        case 1:  return ("out of paper", .critical)
        case 2:  return ("low toner", .info)
        case 3:  return ("out of toner", .critical)
        case 4:  return ("a door is open", .critical)
        case 5:  return ("paper jam", .critical)
        case 6:  return ("offline", .critical)
        case 7:  return ("service requested", .warning)
        case 8:  return ("an input tray is missing", .warning)
        case 9:  return ("an output tray is missing", .warning)
        case 10: return ("a supply is missing", .critical)
        case 11: return ("output tray nearly full", .info)
        case 12: return ("output tray full", .critical)
        case 13: return ("an input tray is empty", .info)
        case 14: return ("maintenance overdue", .warning)
        default: return nil
        }
    }

    static func printerStatusText(_ s: Int64?) -> String? {
        switch s {
        case 3?: return "Idle"
        case 4?: return "Printing"
        case 5?: return "Warming up"
        default: return nil
        }
    }

    /// prtMarkerSuppliesType, used only when a supply has no description.
    static func supplyTypeName(_ t: Int64) -> String? {
        switch t {
        case 3:  return "Toner"
        case 4:  return "Waste toner"
        case 5:  return "Ink"
        case 6:  return "Ink cartridge"
        case 7:  return "Ink ribbon"
        case 8:  return "Waste ink"
        case 9:  return "Drum (OPC)"
        case 10: return "Developer"
        case 11: return "Fuser oil"
        case 15: return "Fuser"
        case 18: return "Cleaner unit"
        case 20: return "Transfer unit"
        case 21: return "Toner cartridge"
        default: return nil
        }
    }

    /// "12,345 pages printed" for impressions or sheets; the raw counter
    /// for the units printers rarely use.
    static func lifeCountText(_ count: UInt64, unit: Int64?) -> String {
        let n = count.formatted()
        switch unit {
        case 7?:  return "\(n) pages printed"
        case 8?:  return "\(n) sheets printed"
        case 3?:  return "Lifetime counter: \(n) ten-thousandths of an inch"
        case 4?:  return "Lifetime counter: \(n) micrometers"
        case 5?:  return "Lifetime counter: \(n) characters"
        case 6?:  return "Lifetime counter: \(n) lines"
        case 11?: return "Lifetime counter: \(n) hours"
        case 16?: return "Lifetime counter: \(n) feet"
        case 17?: return "Lifetime counter: \(n) meters"
        default:  return "Lifetime counter: \(n)"
        }
    }

    private static func upsMIBBattery(_ v: Int64) -> SNMPUPSHealth.Battery? {
        switch v {
        case 1: return .unknown
        case 2: return .normal
        case 3: return .low
        case 4: return .depleted
        default: return nil
        }
    }

    private static func upsMIBPower(_ v: Int64) -> SNMPUPSHealth.Power {
        switch v {
        case 2: return .off          // none: no output power
        case 3: return .mains        // normal
        case 4: return .bypass
        case 5: return .battery
        case 6: return .boosting     // booster
        case 7: return .trimming     // reducer
        default: return .other(v)
        }
    }

    private static func apcBattery(_ v: Int64) -> SNMPUPSHealth.Battery? {
        switch v {
        case 1: return .unknown
        case 2: return .normal
        case 3: return .low
        case 4: return .fault        // batteryInFaultCondition (newer PowerNet MIBs)
        default: return nil
        }
    }

    private static func apcPower(_ v: Int64) -> SNMPUPSHealth.Power? {
        switch v {
        case 1:           return nil            // unknown
        case 2, 13:       return .mains         // onLine, ecoMode
        case 3, 15:       return .battery       // onBattery, onBatteryTest
        case 4:           return .boosting      // onSmartBoost
        case 12:          return .trimming      // onSmartTrim
        case 6, 9, 10, 16: return .bypass       // software, switched, hardware-failure, emergency bypass
        case 5, 7, 8, 11: return .off           // timedSleeping, off, rebooting, sleepingUntilPowerReturn
        default:          return .other(v)
        }
    }

    /// upsWellKnownAlarms (RFC 1628).
    static func upsAlarmName(_ k: Int) -> String? {
        let names = [
            1: "battery needs replacing", 2: "on battery", 3: "low battery", 4: "battery depleted",
            5: "temperature out of range", 6: "input power out of range", 7: "output power out of range",
            8: "output overload", 9: "on bypass", 10: "bypass out of range", 11: "output off as requested",
            12: "UPS off as requested", 13: "charger failed", 14: "output off", 15: "UPS system off",
            16: "fan failure", 17: "fuse failure", 18: "general fault", 19: "self-test failed",
            20: "lost contact with the UPS", 21: "awaiting power", 22: "shutdown pending",
            23: "shutdown imminent", 24: "self-test in progress",
        ]
        return names[k]
    }

    static func stoppedEarlyNote(_ end: SNMPWalk.End, list: String, maxRows: Int) -> String? {
        switch end {
        case .complete:
            return nil
        case .limit:
            return "The \(list) stopped at the row limit (\(maxRows.formatted())), so it may be incomplete. Raise the limit in Options."
        case .notIncreasing:
            return "The device sent an OID out of order while SNAP read the \(list), so it may be incomplete."
        case .error(_, let label):
            return "The device returned an error (\(label)) partway through the \(list), so it may be incomplete."
        }
    }
}

/// Reads for one Health query; notes the lists that stopped early.
private struct HealthReader {
    let client: SNMPClient
    let maxRows: Int
    var notes: [String] = []

    /// A table column, or an empty one when the device doesn't have it.
    mutating func column(_ oid: OID, list: String) async throws -> SNMPColumn {
        let col: SNMPColumn
        do {
            col = try await client.column(oid, maxRows: maxRows)
        } catch SNMPError.errorStatus(_, _, _) {
            return SNMPColumn()
        }
        if let n = SNMPHealth.stoppedEarlyNote(col.end, list: list, maxRows: maxRows), !notes.contains(n) {
            notes.append(n)
        }
        return col
    }

    /// Single values the device has; missing ones are left out.
    func scalars(_ oids: [OID]) async throws -> [OID: SNMPValue] {
        var vbs: [SNMPVarBind] = []
        do {
            vbs = try await client.getTolerant(oids)
        } catch SNMPError.errorStatus(_, _, _) where oids.count > 1 {
            // Some agents fail a whole request over one object: ask one by one.
            for oid in oids {
                do { vbs += try await client.get([oid]) } catch SNMPError.errorStatus(_, _, _) { continue }
            }
        } catch SNMPError.errorStatus(_, _, _) {
            return [:]
        }
        var out: [OID: SNMPValue] = [:]
        for vb in vbs where !vb.value.isException && out[vb.oid] == nil && oids.contains(vb.oid) {
            out[vb.oid] = vb.value
        }
        return out
    }

    /// The first row under `column` (one GETNEXT), or nil when there is none.
    func firstRow(_ column: OID) async throws -> (index: [UInt32], value: SNMPValue)? {
        let next: [SNMPVarBind]
        do {
            next = try await client.getNext([column])
        } catch SNMPError.errorStatus(_, _, _) {
            return nil                  // v1: noSuchName past the end of the MIB
        }
        guard let vb = next.first, !vb.value.isException, column.isAncestorOrEqual(vb.oid),
              vb.oid.components.count > column.components.count else { return nil }
        return (Array(vb.oid.components.dropFirst(column.components.count)), vb.value)
    }

    func hasSubtree(_ base: OID) async throws -> Bool {
        try await firstRow(base) != nil
    }
}

// MARK: - Verdicts

extension SNMPHealth {
    /// Worst first; equal levels keep their order.
    static func ordered(_ vs: [SNMPHealthVerdict]) -> [SNMPHealthVerdict] {
        vs.enumerated().sorted { a, b in
            a.element.level != b.element.level ? a.element.level > b.element.level : a.offset < b.offset
        }.map { $0.element }
    }

    static func supplyVerdict(_ supplies: [SNMPPrinterSupply]) -> SNMPHealthVerdict {
        let known = supplies.compactMap { s in s.percent.map { (supply: s, pct: $0) } }
        // Empty (or full) only at a level of 0: a percent rounded down to 0
        // with some left is "under 1%", so it's low, not empty.
        let empty = known.filter { $0.supply.isOut }
        if let first = empty.first {
            var t = first.supply.isReceptacle ? "\(first.supply.name) is full: replace it now"
                                              : "\(first.supply.name) is empty: replace it now"
            if empty.count > 1 {
                t += empty.count == 2 ? " (1 other supply needs replacing too)"
                                      : " (\(empty.count - 1) other supplies need replacing too)"
            }
            return SNMPHealthVerdict(.critical, t)
        }
        let low = known.enumerated()
            .filter { $0.element.pct < supplyLowPercent }
            .sorted { ($0.element.pct, $0.offset) < ($1.element.pct, $1.offset) }
            .map { $0.element }
        if let first = low.first {
            let s = first.supply
            var t = s.isReceptacle
                ? "\(s.name) is nearly full (\(supplyAmountText(s)) space left): replace it soon"
                : s.isUnderOnePercent
                    ? "\(s.name) is nearly empty (under 1% left): replace it soon"
                    : "\(s.name) at \(first.pct)%: replace it soon"
            if low.count > 1 {
                t += low.count == 2 ? " (1 other is under \(supplyLowPercent)%)"
                                    : " (\(low.count - 1) others are under \(supplyLowPercent)%)"
            }
            return SNMPHealthVerdict(.warning, t)
        }
        if !known.isEmpty {
            // Name a consumable as the lowest when there is one.
            let consumables = known.filter { !$0.supply.isReceptacle }
            let pool = consumables.isEmpty ? known : consumables
            var lowest = pool[0]
            for k in pool.dropFirst() where k.pct < lowest.pct { lowest = k }
            let what = lowest.supply.isReceptacle ? "\(lowest.supply.name), \(lowest.pct)% space left"
                                                  : "\(lowest.supply.name) \(lowest.pct)%"
            return SNMPHealthVerdict(.good, "Supplies look fine (lowest: \(what))")
        }
        if supplies.isEmpty {
            return SNMPHealthVerdict(.info, "The printer doesn't list its supplies")
        }
        if supplies.allSatisfy({ $0.level == -3 }) {
            return SNMPHealthVerdict(.info, "The printer says every supply has some left, but not how much")
        }
        return SNMPHealthVerdict(.info, "The printer doesn't report how much of each supply is left")
    }

    /// The printer's own alerts that stop or threaten printing.
    static func printerAlertVerdict(_ alerts: [Int]) -> SNMPHealthVerdict? {
        let serious = alerts.compactMap(printerAlert).filter { $0.level > .good }
        guard let worst = serious.map({ $0.level }).max() else { return nil }
        return SNMPHealthVerdict(worst, "The printer reports: " + serious.map { $0.name }.joined(separator: ", "))
    }

    static func printerVerdicts(_ p: SNMPPrinterHealth) -> [SNMPHealthVerdict] {
        ordered([printerAlertVerdict(p.alerts), supplyVerdict(p.supplies)].compactMap { $0 })
    }

    static func minutesText(_ m: UInt64) -> String {
        m < 120 ? "\(m) min" : "\(m / 60) h \(m % 60) min"
    }

    /// upsWellKnownAlarms that mean the output is off: output off as
    /// requested (11), UPS off as requested (12), output off (14), UPS
    /// system off (15), and awaiting the return of input power (21).
    static let upsOutputOffAlarms: Set<Int> = [11, 12, 14, 15, 21]

    /// Alarms the verdict speaks to on its own, or that are only
    /// informational (self-test in progress, 24). Any other alarm,
    /// vendor alarms included, makes a warning of its own.
    static let upsAlarmsInVerdict: Set<Int> = upsOutputOffAlarms.union([1, 2, 8, 9, 19, 20, 22, 23, 24])

    static func upsVerdict(_ u: SNMPUPSHealth) -> SNMPHealthVerdict {
        let codes = u.alarmCodes
        // Power to the load is about to go, whatever else is true.
        if codes.contains(23) {
            return SNMPHealthVerdict(.critical, "The UPS is about to shut down: it will turn off power to the load within seconds")
        }
        if codes.contains(22) {
            return SNMPHealthVerdict(.critical, "A shutdown is pending: the UPS will turn off power to the load when its countdown ends")
        }
        if u.isOnBattery {
            var t = "On battery"
            switch (u.minutesLeft, u.charge) {
            case let (m?, c?): t += ": about \(minutesText(m)) left (\(c)%)"
            case let (m?, nil): t += ": about \(minutesText(m)) left"
            case let (nil, c?): t += ": \(c)% charge left"
            default: break
            }
            let critical = u.battery == .low || u.battery == .depleted
                || (u.minutesLeft.map { $0 < onBatteryCriticalMinutes } ?? false)
                || (u.charge.map { $0 < chargeCriticalPercent } ?? false)
            return SNMPHealthVerdict(critical ? .critical : .warning, t)
        }
        if u.power == .off || !codes.isDisjoint(with: upsOutputOffAlarms) {
            return SNMPHealthVerdict(.critical, "Output is off: the UPS isn't powering anything")
        }
        if u.battery == .depleted {
            return SNMPHealthVerdict(.critical, "Battery depleted: the UPS can't carry the load if the power goes out")
        }
        if u.overload {
            return SNMPHealthVerdict(.critical, "The UPS reports an overload: it's carrying more than it's rated for")
        }
        // APC has no overload alarm, and some UPS-MIB agents leave the alarm table empty.
        if let l = u.maxLoad, l > 100 {
            return SNMPHealthVerdict(.critical, "Load at \(l)%: more than the UPS is rated for")
        }
        if u.battery == .low {
            var t = "Battery low"
            switch (u.minutesLeft, u.charge) {
            case let (m?, c?): t += ": about \(minutesText(m)) of runtime (\(c)%)"
            case let (m?, nil): t += ": about \(minutesText(m)) of runtime"
            case let (nil, c?): t += " (\(c)%)"
            default: break
            }
            return SNMPHealthVerdict(.warning, t)
        }
        if u.replaceBattery {
            return SNMPHealthVerdict(.warning, "Battery needs attention: the UPS says to replace it")
        }
        if u.battery == .fault {
            return SNMPHealthVerdict(.warning, "Battery needs attention: the UPS reports a battery fault")
        }
        if u.selfTestFailed {
            return SNMPHealthVerdict(.warning, "The UPS's last self-test failed")
        }
        if u.power == .bypass || codes.contains(9) {
            return SNMPHealthVerdict(.warning, "On bypass: mains power goes straight to the load, with no battery backup")
        }
        let others = u.alarmList.filter { a in a.code.map { !upsAlarmsInVerdict.contains($0) } ?? true }.map(\.name)
        if codes.contains(20) {
            let t = "The SNMP agent has lost contact with the UPS, so these readings may be out of date"
            return SNMPHealthVerdict(.warning, others.isEmpty ? t : t + ". It also reports: " + others.joined(separator: ", "))
        }
        if !others.isEmpty {
            return SNMPHealthVerdict(.warning, "The UPS reports: " + others.joined(separator: ", "))
        }
        if u.maxLoad == 100 {
            return SNMPHealthVerdict(.warning, "Load at 100%: the UPS is at its full rated capacity")
        }
        if let l = u.maxLoad, l >= loadCriticalPercent {
            return SNMPHealthVerdict(.warning, "Load at \(l)%: close to what the UPS can carry")
        }
        if u.battery == .unknown {
            return SNMPHealthVerdict(.warning, "The UPS reports its battery status as unknown")
        }

        var runtime = u.minutesLeft.map { "about \(minutesText($0)) of runtime" }
        if let l = u.maxLoad { runtime = runtime.map { $0 + " at \(l)% load" } ?? "\(l)% load" }
        switch u.power {
        case .mains?, .boosting?, .trimming?:
            let head = u.power == .boosting ? "On mains power (boosting low voltage)"
                     : u.power == .trimming ? "On mains power (lowering high voltage)"
                     : "On mains power"
            let tail = [u.charge.map { "Battery \($0)%" }, runtime].compactMap { $0 }.joined(separator: ", ")
            return SNMPHealthVerdict(.good, tail.isEmpty ? head : head + ". " + tail)
        default:
            if u.battery == .normal {
                let tail = [u.charge.map { "\($0)%" }, runtime].compactMap { $0 }.joined(separator: ", ")
                return SNMPHealthVerdict(.good, tail.isEmpty ? "Battery normal" : "Battery normal: " + tail)
            }
            if case .other(let code)? = u.power {
                return SNMPHealthVerdict(.info, "The UPS reports a power state SNAP doesn't recognize (code \(code))")
            }
            return SNMPHealthVerdict(.info, "The UPS didn't say where its power comes from")
        }
    }

    static func storageVerdict(_ disks: [SNMPStorageEntry]) -> SNMPHealthVerdict? {
        let known = disks.compactMap { d in d.percent.map { (disk: d, pct: $0) } }
        guard var fullest = known.first else { return nil }
        for k in known.dropFirst() where k.pct > fullest.pct { fullest = k }
        if fullest.pct >= diskWarnPercent {
            var t = "Volume \(fullest.disk.name) is \(fullest.pct)% full"
            let more = known.filter { $0.pct >= diskWarnPercent }.count - 1
            if more > 0 {
                t += more == 1 ? " (1 more is at least \(diskWarnPercent)% full)"
                               : " (\(more) more are at least \(diskWarnPercent)% full)"
            }
            return SNMPHealthVerdict(fullest.pct >= diskCriticalPercent ? .critical : .warning, t)
        }
        if known.count == 1 {
            return SNMPHealthVerdict(.good, "Volume \(fullest.disk.name) is \(fullest.pct)% full")
        }
        return SNMPHealthVerdict(.good, "All volumes under \(diskWarnPercent)% full (fullest: \(fullest.disk.name), \(fullest.pct)%)")
    }

    static func cpuVerdict(_ loads: [Int]) -> SNMPHealthVerdict? {
        guard let avg = SNMPHostHealth(cpuLoads: loads).cpuAverage else { return nil }
        let level: SNMPHealthLevel = avg >= cpuCriticalPercent ? .critical : avg >= cpuWarnPercent ? .warning : .good
        return SNMPHealthVerdict(level, loads.count == 1 ? "CPU \(avg)% busy"
                                                         : "CPU \(avg)% busy on average across \(loads.count) processors")
    }

    /// "Memory: 1.2 GB of 4.0 GB in use, not counting 1.8 GB of cache and buffers"
    static func memoryText(_ m: SNMPStorageEntry) -> String {
        var t = "\(SNMPFormat.bytes(m.usedNet)) of \(SNMPFormat.bytes(m.size)) in use"
        if let c = m.cacheBytes, let label = m.cacheLabel {
            t += ", not counting \(SNMPFormat.bytes(c)) of \(label)"
        }
        return t
    }

    static func hostVerdicts(_ h: SNMPHostHealth) -> [SNMPHealthVerdict] {
        var vs = [storageVerdict(h.disks), cpuVerdict(h.cpuLoads)].compactMap { $0 }
        if vs.isEmpty {
            if let m = h.memory.max(by: { $0.size < $1.size }) {
                vs.append(SNMPHealthVerdict(.info, "Memory: " + memoryText(m)))
            } else {
                vs.append(SNMPHealthVerdict(.info, "No disks or memory to show. Show all lists what the device reported."))
            }
        }
        return ordered(vs)
    }

    // MARK: Facts (the card's second line)

    static func printerFacts(_ p: SNMPPrinterHealth) -> [String] {
        [p.lifeCount.map { lifeCountText($0, unit: p.lifeCountUnit) },
         printerStatusText(p.status).map { "Status: \($0.lowercased())" }].compactMap { $0 }
    }

    /// Printer alerts that don't change the verdict ("low paper").
    static func printerMinorAlerts(_ p: SNMPPrinterHealth) -> [String] {
        p.alerts.compactMap(printerAlert).filter { $0.level <= .good }.map { $0.name }
    }

    static func upsName(_ u: SNMPUPSHealth) -> String? {
        let parts = [u.manufacturer, u.model].compactMap { $0 }
        guard !parts.isEmpty else { return nil }
        // Some UPSes repeat the maker in the model name.
        if let m = u.manufacturer, let model = u.model, model.localizedCaseInsensitiveContains(m) { return model }
        return parts.joined(separator: " ")
    }

    static func upsFacts(_ u: SNMPUPSHealth) -> [String] {
        var out: [String] = []
        if let name = upsName(u) { out.append(name) }
        if u.isOnBattery, let s = u.secondsOnBattery, s > 0 {
            out.append("Running on battery for \(s < 90 ? "\(s) s" : minutesText(s / 60))")
        }
        if u.loads.count > 1 {
            out.append("Load per output line: " + u.loads.map { "\($0)%" }.joined(separator: ", "))
        }
        return out
    }

    static func upsSourceLabel(_ u: SNMPUPSHealth) -> String {
        u.source == .apc ? "APC PowerNet MIB" : "UPS-MIB"
    }

    /// Joins short lines into sentences: "A. B."
    static func sentences(_ lines: [String]) -> String {
        lines.isEmpty ? "" : lines.map { $0.hasSuffix(".") ? $0 : $0 + "." }.joined(separator: " ")
    }

    static func hiddenText(_ h: SNMPStorageEntry.Hidden, kind: SNMPStorageEntry.Kind) -> String {
        switch h {
        case .zeroSize:          return "no size reported"
        case .notDiskOrMemory:   return kindLabel(kind)
        case .systemMount:       return "system mount"
        case .snapImage:         return "snap package image, read-only and always full"
        case .small:             return "smaller than \(smallVolumeBytes / 1_000_000) MB"
        case .duplicate(let of): return "same size and usage as \(of), likely the same volume"
        }
    }

    static func kindLabel(_ k: SNMPStorageEntry.Kind) -> String {
        switch k {
        case .ram:           return "memory"
        case .virtualMemory: return "virtual memory or swap"
        case .fixedDisk:     return "disk"
        case .removableDisk: return "removable disk"
        case .floppyDisk:    return "floppy disk"
        case .compactDisc:   return "CD or DVD"
        case .ramDisk:       return "RAM disk"
        case .flashMemory:   return "flash memory"
        case .networkDisk:   return "network disk"
        case .other:         return "other storage"
        }
    }

    // MARK: Summary and export

    static func summary(_ r: SNMPHealthReport) -> String {
        r.isEmpty ? "Health: no printer, UPS, or host data" : "Health: \(r.answered) of 3 checks answered"
    }

    static func exportText(_ r: SNMPHealthReport) -> String {
        guard !r.isEmpty else {
            return nothingAnswered + "\n" + r.notes.map { "(\($0))\n" }.joined()
        }
        var s = ""
        func verdictLines(_ vs: [SNMPHealthVerdict]) {
            for (i, v) in vs.enumerated() { s += (i == 0 ? "  Verdict: " : "  Also:    ") + v.text + "\n" }
        }

        if let p = r.printer {
            s += "Printer (Printer-MIB)\n"
            verdictLines(printerVerdicts(p))
            if let c = p.lifeCount { s += "  \(lifeCountText(c, unit: p.lifeCountUnit))\n" }
            if let st = printerStatusText(p.status) { s += "  Status: \(st.lowercased())\n" }
            let alerts = p.alerts.compactMap(printerAlert).map { $0.name }
            if !alerts.isEmpty { s += "  Printer alerts: \(alerts.joined(separator: ", "))\n" }
            if !p.supplies.isEmpty {
                s += "  Supplies:\n"
                for x in p.supplies {
                    let raw = "level \(x.level.map(String.init) ?? "not given"), max \(x.maxCapacity.map(String.init) ?? "not given")"
                    s += "    \(x.name): \(supplyStateText(x)) (\(raw))\n"
                }
            }
            s += "\n"
        }

        if let u = r.ups {
            s += "UPS (\(upsSourceLabel(u)))\n"
            verdictLines([upsVerdict(u)])
            if let m = u.manufacturer { s += "  Manufacturer: \(m)\n" }
            if let m = u.model { s += "  Model: \(m)\n" }
            if let p = u.power { s += "  Power source: \(powerLabel(p))\n" }
            if let b = u.battery { s += "  Battery status: \(batteryLabel(b))\n" }
            if let c = u.charge { s += "  Charge: \(c)%\n" }
            if let m = u.minutesLeft { s += "  Runtime left: \(minutesText(m))\n" }
            if let sec = u.secondsOnBattery, sec > 0 { s += "  Time on battery: \(sec) s\n" }
            if !u.loads.isEmpty { s += "  Load: \(u.loads.map { "\($0)%" }.joined(separator: ", "))\n" }
            if u.source == .upsMIB {
                s += "  Alarms: \(u.alarms.isEmpty ? (u.alarmCount.map { $0 == 0 ? "none" : "\($0)" } ?? "not reported") : u.alarms.joined(separator: ", "))\n"
            }
            if u.source == .apc && u.replaceBattery { s += "  Replace battery: yes\n" }
            s += "\n"
        }

        if let h = r.host {
            s += "Storage and CPU (HOST-RESOURCES-MIB)\n"
            verdictLines(hostVerdicts(h))
            if !h.disks.isEmpty {
                s += "  Volumes:\n"
                for d in h.disks { s += "    \(d.name): \(storageLine(d))\n" }
            }
            if !h.memory.isEmpty {
                s += "  Memory:\n"
                for m in h.memory { s += "    \(m.name): \(m.percent.map { "\($0)%, " } ?? "")\(memoryText(m))\n" }
            }
            if let avg = h.cpuAverage {
                s += "  Processors: \(h.cpuLoads.count), average \(avg)% busy over the last minute"
                s += h.cpuLoads.count > 1 ? " (\(h.cpuLoads.map { "\($0)%" }.joined(separator: ", ")))\n" : "\n"
            }
            let hidden = h.hiddenEntries
            if !hidden.isEmpty {
                s += "  Hidden by default:\n"
                for e in hidden {
                    guard let why = e.hidden else { continue }
                    s += "    \(e.name): \(storageLine(e)) [\(hiddenText(why, kind: e.kind))]\n"
                }
            }
            s += "\n"
        }
        for n in r.notes { s += "(\(n))\n" }
        return s
    }

    static func storageLine(_ e: SNMPStorageEntry) -> String {
        guard let p = e.percent else { return "no size reported" }
        return "\(p)% (\(SNMPFormat.bytes(e.usedNet)) of \(SNMPFormat.bytes(e.size)) used)"
    }

    static func supplyStateText(_ x: SNMPPrinterSupply) -> String {
        if x.percent != nil {
            let amount = supplyAmountText(x)
            return x.isReceptacle ? "\(amount) space left" : amount
        }
        switch x.level {
        case .some(-3): return x.isReceptacle ? "some space left" : "some left"
        case .some(-2): return "unknown"
        default:  return "not reported"
        }
    }

    /// "8%", or "under 1%" when some is left but the percent rounds down
    /// to 0. Empty when there's no percent.
    static func supplyAmountText(_ x: SNMPPrinterSupply) -> String {
        guard let p = x.percent else { return "" }
        return x.isUnderOnePercent ? "under 1%" : "\(p)%"
    }

    /// How a supply's bar is colored: critical only when nothing is left,
    /// nil when the printer gives no percent.
    static func supplyMeterLevel(_ x: SNMPPrinterSupply) -> SNMPHealthLevel? {
        guard let p = x.percent else { return nil }
        return x.isOut ? .critical : p < supplyLowPercent ? .warning : .good
    }

    static func powerLabel(_ p: SNMPUPSHealth.Power) -> String {
        switch p {
        case .mains:          return "mains"
        case .boosting:       return "mains, boosting low voltage"
        case .trimming:       return "mains, lowering high voltage"
        case .battery:        return "battery"
        case .bypass:         return "bypass"
        case .off:            return "none (output off)"
        case .other(let c):   return "other (code \(c))"
        }
    }

    static func batteryLabel(_ b: SNMPUPSHealth.Battery) -> String {
        switch b {
        case .normal:   return "normal"
        case .low:      return "low"
        case .depleted: return "depleted"
        case .unknown:  return "unknown"
        case .fault:    return "fault"
        }
    }
}

// MARK: - View

struct SNMPHealthPane: View {
    @ObservedObject var model: SNMPQueryModel
    let report: SNMPHealthReport
    @State private var showAllStorage = false

    var body: some View {
        VStack(spacing: 0) {
            ForEach(report.notes, id: \.self) { SNMPNoteStrip(text: $0) }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if report.isEmpty { nothingCard }
                    if let p = report.printer { printerSection(p) }
                    if let u = report.ups { upsSection(u) }
                    if let h = report.host { hostSection(h) }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        }
    }

    private var nothingCard: some View {
        ToolNoteCard(
            icon: "heart.text.square", tint: NS.blue,
            headline: "No health data from this device",
            detail: SNMPHealth.nothingAnswered,
            notes: [
                "Health reads the Printer MIB (toner and ink), the UPS MIB or APC's PowerNet MIB (battery and runtime), and the Host Resources MIB (storage and CPU).",
                "Many switches and routers support none of these. Try Interfaces or Inventory instead.",
                "The device may also hide these MIBs from this community string.",
            ])
    }

    // MARK: Printer

    private func printerSection(_ p: SNMPPrinterHealth) -> some View {
        let minor = SNMPHealth.printerMinorAlerts(p)
        return HealthSection(
            title: "Printer", icon: "printer", source: "Printer-MIB",
            verdicts: SNMPHealth.printerVerdicts(p),
            facts: SNMPHealth.printerFacts(p),
            notes: minor.isEmpty ? [] : ["The printer also reports: " + minor.joined(separator: ", ") + "."]
        ) {
            if !p.supplies.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(p.supplies) { s in
                        HealthMeterRow(name: s.name,
                                       value: SNMPHealth.supplyStateText(s),
                                       // Under 1%: a sliver, so it doesn't read as empty.
                                       fraction: s.percent.map { s.isUnderOnePercent ? 0.005 : Double($0) / 100 },
                                       color: supplyColor(s),
                                       help: supplyHelp(s))
                    }
                }
            }
        }
    }

    private func supplyColor(_ s: SNMPPrinterSupply) -> Color {
        SNMPHealth.supplyMeterLevel(s)?.tint ?? NS.text3
    }

    private func supplyHelp(_ s: SNMPPrinterSupply) -> String {
        let raw = "Level \(s.level.map(String.init) ?? "not given") of \(s.maxCapacity.map(String.init) ?? "not given")"
        return s.isReceptacle ? raw + ". A waste container: the bar shows the space left in it." : raw
    }

    // MARK: UPS

    private func upsSection(_ u: SNMPUPSHealth) -> some View {
        HealthSection(
            title: "UPS", icon: "minus.plus.batteryblock", source: SNMPHealth.upsSourceLabel(u),
            verdicts: [SNMPHealth.upsVerdict(u)],
            facts: SNMPHealth.upsFacts(u),
            notes: u.alarms.isEmpty ? [] : ["UPS alarms: " + u.alarms.joined(separator: ", ") + "."]
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if let c = u.charge {
                    HealthMeterRow(name: "Battery charge",
                                   value: "\(c)%",
                                   detail: u.battery.map { "Battery " + SNMPHealth.batteryLabel($0) },
                                   fraction: Double(c) / 100,
                                   color: c < SNMPHealth.chargeCriticalPercent ? NS.red
                                        : c < SNMPHealth.chargeWarnPercent ? NS.amber : NS.green)
                }
                if let m = u.minutesLeft {
                    HealthFactRow(name: u.isOnBattery ? "Time left on battery" : "Runtime if the power goes out",
                                  value: "about " + SNMPHealth.minutesText(m))
                }
                if let l = u.maxLoad {
                    HealthMeterRow(name: u.loads.count > 1 ? "Load (busiest output line)" : "Load",
                                   value: "\(l)%",
                                   fraction: Double(min(l, 100)) / 100,
                                   color: l >= SNMPHealth.loadCriticalPercent ? NS.red
                                        : l >= SNMPHealth.loadWarnPercent ? NS.amber : NS.green,
                                   help: "Percent of the UPS's rated capacity in use")
                }
                if let p = u.power {
                    HealthFactRow(name: "Power source", value: SNMPHealth.powerLabel(p).capitalizedFirst)
                }
            }
        }
    }

    // MARK: Storage and CPU

    private func hostSection(_ h: SNMPHostHealth) -> some View {
        let hidden = h.hiddenEntries
        return HealthSection(
            title: "Storage and CPU", icon: "internaldrive", source: "HOST-RESOURCES-MIB",
            verdicts: SNMPHealth.hostVerdicts(h)
        ) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(h.disks) { d in
                    HealthMeterRow(name: d.name,
                                   value: d.percent.map { "\($0)%" } ?? "",
                                   detail: "\(SNMPFormat.bytes(d.usedNet)) of \(SNMPFormat.bytes(d.size)) used",
                                   fraction: d.percent.map { Double($0) / 100 },
                                   color: diskColor(d.percent),
                                   help: SNMPHealth.kindLabel(d.kind).capitalizedFirst)
                }
                ForEach(h.memory) { m in
                    HealthMeterRow(name: m.name,
                                   value: m.percent.map { "\($0)%" } ?? "",
                                   detail: "\(SNMPFormat.bytes(m.usedNet)) of \(SNMPFormat.bytes(m.size)) in use",
                                   caption: m.cacheBytes.flatMap { c in m.cacheLabel.map { "Not counting \(SNMPFormat.bytes(c)) of \($0), which the system can free when it needs the memory" } },
                                   fraction: m.percent.map { Double($0) / 100 },
                                   color: NS.blue,
                                   help: "Memory")
                }
                if let avg = h.cpuAverage {
                    HealthMeterRow(name: h.cpuLoads.count == 1 ? "CPU" : "CPU, average of \(h.cpuLoads.count) processors",
                                   value: "\(avg)%",
                                   caption: "Busy time over the last minute. The device lists one entry per processor it sees, usually one per core or hardware thread.",
                                   fraction: Double(avg) / 100,
                                   color: cpuColor(avg))
                    if h.cpuLoads.count > 1 && h.cpuLoads.count <= 48 {
                        ProcessorBars(loads: h.cpuLoads, color: cpuColor)
                    }
                }
                if !hidden.isEmpty {
                    Toggle(isOn: $showAllStorage) {
                        Text(verbatim: "Show all storage entries (\(hidden.count) hidden)")
                            .font(.system(size: 11)).foregroundStyle(NS.text2)
                    }
                    .toggleStyle(.checkbox)
                    .padding(.top, 2)
                    if showAllStorage {
                        ForEach(hidden) { e in
                            HealthMeterRow(name: e.name,
                                           value: e.percent.map { "\($0)%" } ?? "",
                                           detail: e.percent == nil ? nil : "\(SNMPFormat.bytes(e.usedNet)) of \(SNMPFormat.bytes(e.size))",
                                           caption: e.hidden.map { "Hidden: " + SNMPHealth.hiddenText($0, kind: e.kind) },
                                           fraction: e.percent.map { Double($0) / 100 },
                                           color: NS.text3,
                                           dim: true)
                        }
                    }
                }
            }
        }
    }

    private func diskColor(_ p: Int?) -> Color {
        guard let p else { return NS.text3 }
        return p >= SNMPHealth.diskCriticalPercent ? NS.red : p >= SNMPHealth.diskWarnPercent ? NS.amber : NS.green
    }

    private func cpuColor(_ p: Int) -> Color {
        p >= SNMPHealth.cpuCriticalPercent ? NS.red : p >= SNMPHealth.cpuWarnPercent ? NS.amber : NS.green
    }
}

// MARK: - Pieces

private extension SNMPHealthLevel {
    var tint: Color {
        switch self {
        case .info:     return NS.blue
        case .good:     return NS.green
        case .warning:  return NS.amber
        case .critical: return NS.red
        }
    }
    var icon: String {
        switch self {
        case .info:     return "info.circle"
        case .good:     return "checkmark.circle"
        case .warning:  return "exclamationmark.triangle"
        case .critical: return "exclamationmark.octagon"
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// A small title, then a card: the verdict as the headline, the other
/// verdicts and facts under it, then the section's bars.
private struct HealthSection<Content: View>: View {
    let title: String
    let icon: String
    let source: String
    let verdicts: [SNMPHealthVerdict]
    let facts: [String]
    let notes: [String]
    let content: Content

    init(title: String, icon: String, source: String, verdicts: [SNMPHealthVerdict],
         facts: [String] = [], notes: [String] = [], @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.source = source
        self.verdicts = verdicts
        self.facts = facts
        self.notes = notes
        self.content = content()
    }

    var body: some View {
        let head = verdicts.first ?? SNMPHealthVerdict(.info, title)
        let detail = SNMPHealth.sentences(verdicts.dropFirst().map(\.text) + facts)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11)).foregroundStyle(NS.text3)
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(NS.text2)
                Spacer()
                Text(source).font(.system(size: 10)).foregroundStyle(NS.text3)
            }
            ToolNoteCard(icon: head.level.icon, tint: head.level.tint, headline: head.text,
                         detail: detail.isEmpty ? "Read from \(source)." : detail,
                         notes: notes) {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            }
        }
    }
}

/// Name and value on one line, a bar under them, and an optional caption.
private struct HealthMeterRow: View {
    let name: String
    let value: String
    var detail: String? = nil
    var caption: String? = nil
    let fraction: Double?           // nil: the bar stays empty
    let color: Color
    var help: String? = nil
    var dim = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(dim ? NS.text3 : NS.text1)
                    .lineLimit(1).truncationMode(.middle)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(NS.text3).lineLimit(1)
                }
                Text(value)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(dim ? NS.text3 : NS.text1)
                    .fixedSize()
            }
            HealthBar(fraction: fraction, color: color)
            if let caption {
                Text(caption).font(.system(size: 11)).foregroundStyle(NS.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .help(help ?? "")
        .accessibilityElement(children: .combine)
    }
}

/// A label and a value, no bar ("Runtime if the power goes out: about 42 min").
private struct HealthFactRow: View {
    let name: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name).font(.system(size: 12, weight: .medium)).foregroundStyle(NS.text1)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(value).font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(NS.text1)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }
}

private struct HealthBar: View {
    let fraction: Double?
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                if let f = fraction {
                    let clamped = max(0, min(1, f))
                    Capsule().fill(NS.text1.opacity(0.08))
                    Capsule().fill(color)
                        .frame(width: clamped > 0 ? max(4, geo.size.width * clamped) : 0)
                } else {
                    // No measurement: a dashed outline, so it doesn't read as empty.
                    Capsule().strokeBorder(NS.text3.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
        }
        .frame(height: 7)
        .accessibilityHidden(true)
    }
}

/// One small bar per processor.
private struct ProcessorBars: View {
    let loads: [Int]
    let color: (Int) -> Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(loads.enumerated()), id: \.offset) { i, load in
                let tip = "Processor \(i + 1): \(load)% busy"
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 1.5).fill(NS.text1.opacity(0.08))
                    RoundedRectangle(cornerRadius: 1.5).fill(color(load))
                        .frame(height: max(1, 26 * CGFloat(max(0, min(100, load))) / 100))
                }
                .frame(width: 8, height: 26)
                .help(tip)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: "Per-processor load: " + loads.map { "\($0)%" }.joined(separator: ", ")))
    }
}
