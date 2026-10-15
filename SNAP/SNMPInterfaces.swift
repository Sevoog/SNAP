// SNMPInterfaces.swift
// SNAP — SNMP Interfaces view: port table and live Watch
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md
//
// CONTRACT (used by SNMPView.swift, SNMPNeighbors.swift, SNMPWhereIs.swift):
//   struct SNMPInterfaceRow: Identifiable, Hashable        (id = ifIndex)
//   struct SNMPInterfaceReport: Equatable { rows, note }
//   enum SNMPInterfaces {
//     static func query(_ client: SNMPClient, maxRows: Int) async throws -> SNMPInterfaceReport
//     static func names(_ client: SNMPClient, maxRows: Int) async throws -> [UInt32: String]
//     static func summary(_ r: SNMPInterfaceReport) -> String
//     static func exportText(_ r: SNMPInterfaceReport) -> String
//   }
//   struct SNMPInterfacesPane: View { init(model:report:) }
//
// The table reads ifTable and ifXTable (RFC 2863) one column at a time.
// Only ifDescr and ifOperStatus are required; every other column is
// optional, so a device without ifXTable (or without error counters) still
// gets a table.
//
// Watch live polls only the rows on screen: one GET per ten ports, each with
// sysUpTime.0 so rates use the device's own clock (a GET the device fails
// with an error is asked again one OID at a time). SNMPRateMeter turns two
// counter readings into bits per second and drops readings that can't be
// trusted (a counter that went backwards or was reset, a device restart).

import SwiftUI
import Charts

// MARK: - Model

/// How wide a traffic counter is. A 32-bit counter starts over at zero after
/// 4,294,967,295 bytes (4.29 GB).
enum SNMPCounterWidth: Hashable { case bits32, bits64 }

/// When a port entered its current state (ifLastChange), placed on this
/// Mac's clock so it can read "3 min ago" later too.
enum SNMPPortChange: Hashable {
    /// Entered its current state (up, down, ...) at this time.
    case at(Date)
    /// ifLastChange is 0: no change since the device's SNMP service started
    /// (at this time, when sysUpTime or snmpEngineTime could be read).
    case notSinceStart(Date?)
}

struct SNMPInterfaceRow: Identifiable, Hashable {
    let id: UInt32              // ifIndex
    let descr: String           // ifDescr
    let operStatus: String      // "up", "down", "disabled" (admin down), ...
    let speed: String           // human-formatted
    let speedRaw: UInt64        // bits per second; 0 = not reported (or only "over 4.29 Gbps")
    let inOctets: UInt64
    let outOctets: UInt64
    var counters64 = true       // false: 32-bit counters, which wrap every 4.29 GB
    /// ifSpeed read 4,294,967,295, its ceiling, and ifHighSpeed didn't give
    /// the real speed: faster than 4.29 Gbps, by an unknown amount. speedRaw
    /// is 0 then, so % of link and the rest leave the port out.
    var speedAtCeiling = false
    /// ifName ("Gi1/0/7"). Empty when the device has no ifXTable.
    var name = ""
    /// ifAlias: the label an admin typed for the port. Empty when not set.
    var alias = ""
    /// ifType (IANAifType). nil when the device didn't say.
    var ifType: Int64?
    var inErrors: UInt64?
    var outErrors: UInt64?
    var inDiscards: UInt64?
    var outDiscards: UInt64?
    var lastChange: SNMPPortChange?
    /// Which counter each total came from; nil = the device reported none.
    /// Watch asks for the same counters.
    var inWidth: SNMPCounterWidth? = .bits64
    var outWidth: SNMPCounterWidth? = .bits64

    /// ifName, else ifDescr, else the index.
    var displayName: String {
        if !name.isEmpty { return name }
        if !descr.isEmpty { return descr }
        return "ifIndex \(id)"
    }
    var hasErrorCounts: Bool { inErrors != nil || outErrors != nil }
    /// In plus out errors. Discards are in the tooltip, not in this total.
    var errorTotal: UInt64 {
        let (sum, overflow) = (inErrors ?? 0).addingReportingOverflow(outErrors ?? 0)
        return overflow ? .max : sum
    }
    var isPhysical: Bool { ifType.map(SNMPInterfaceFormat.isPhysical) ?? false }
    /// For sorting the Speed column: a port at the ceiling sorts as 4.29 Gbps.
    var speedSort: UInt64 { speedAtCeiling ? UInt64(UInt32.max) : speedRaw }
    /// For sorting the Changed column: older first.
    var changeSortKey: Double {
        switch lastChange {
        case .at(let d)?:             return d.timeIntervalSinceReferenceDate
        case .notSinceStart(let d)?:  return (d?.timeIntervalSinceReferenceDate ?? 0) - 1e12
        case nil:                     return -Double.greatestFiniteMagnitude
        }
    }
}

/// What the Interfaces view shows for one query.
struct SNMPInterfaceReport: Equatable {
    var rows: [SNMPInterfaceRow]
    var note: SNMPWalkNote?
    /// Columns left blank because the device stopped answering, or sent a
    /// reply SNAP couldn't read, partway through ("labels", "errors", ...).
    var unread: [String] = []
}

/// ifTable / ifXTable columns this file reads beyond the shared SNMPOID set.
private enum IFMIB {
    static let ifType        = OID([1,3,6,1,2,1,2,2,1,3])
    static let ifLastChange  = OID([1,3,6,1,2,1,2,2,1,9])
    static let ifInDiscards  = OID([1,3,6,1,2,1,2,2,1,13])
    static let ifInErrors    = OID([1,3,6,1,2,1,2,2,1,14])
    static let ifOutDiscards = OID([1,3,6,1,2,1,2,2,1,19])
    static let ifOutErrors   = OID([1,3,6,1,2,1,2,2,1,20])
    static let ifName        = OID([1,3,6,1,2,1,31,1,1,1,1])
    static let ifAlias       = OID([1,3,6,1,2,1,31,1,1,1,18])
    /// SNMP-FRAMEWORK-MIB: seconds since the SNMP engine started (Integer32).
    static let snmpEngineTime = OID([1,3,6,1,6,3,10,2,1,3,0])
}

enum SNMPInterfaces {
    static func query(_ client: SNMPClient, maxRows: Int) async throws -> SNMPInterfaceReport {
        // One column at a time: gentler on small agents than many parallel walks.
        var note: SNMPWalkNote?
        var unread: [String] = []
        var stopped = false     // the device stopped answering: skip the remaining columns

        func column(_ oid: OID) async throws -> [UInt32: SNMPValue] {
            let col = try await client.column(oid, maxReps: 30, maxRows: maxRows)
            switch col.end {
            case .complete:             break
            case .limit:                note = note ?? .limit(maxRows)
            case .notIncreasing:        note = note ?? .notIncreasing(col.order.count)
            case .error(let c, let l):  note = note ?? .error(c, l)
            }
            return col.byIndex
        }
        /// Columns older or simpler devices may not have. An error with no
        /// rows means the column isn't there; v1 can't carry 64-bit counters.
        /// A device that stops answering here leaves the rest blank instead
        /// of losing the whole table.
        func optionalColumn(_ oid: OID, _ what: String) async throws -> [UInt32: SNMPValue] {
            if stopped { unread.append(what); return [:] }
            do {
                return try await column(oid)
            } catch SNMPError.errorStatus(_, _, _) {
                return [:]
            } catch SNMPError.timeout {
                stopped = true; unread.append(what); return [:]
            } catch SNMPError.transport(_) {
                stopped = true; unread.append(what); return [:]
            } catch is SNMPError {
                unread.append(what); return [:]     // a reply SNAP couldn't decode
            }
        }

        let descr  = try await column(SNMPOID.ifDescr)
        let oper   = try await column(SNMPOID.ifOperStatus)
        let indexes = Set(descr.keys).union(oper.keys)
        guard !indexes.isEmpty else { return SNMPInterfaceReport(rows: [], note: note) }

        let admin  = try await optionalColumn(SNMPOID.ifAdminStatus, "admin status")
        let ifNames = try await optionalColumn(IFMIB.ifName, "port names")
        let alias  = try await optionalColumn(IFMIB.ifAlias, "labels")
        let types  = try await optionalColumn(IFMIB.ifType, "port types")
        let speed  = try await optionalColumn(SNMPOID.ifSpeed, "speeds")
        let high   = try await optionalColumn(SNMPOID.ifHighSpeed, "speeds")
        let hcIn   = try await optionalColumn(SNMPOID.ifHCInOctets, "traffic totals")
        let hcOut  = hcIn.isEmpty ? [:] : try await optionalColumn(SNMPOID.ifHCOutOctets, "traffic totals")
        // 64-bit counters are only required on ports faster than 20 Mbps
        // (RFC 2863), so fall back per port, not only when the column is empty.
        let in32   = indexes.isSubset(of: hcIn.keys)  ? [:] : try await optionalColumn(SNMPOID.ifInOctets, "traffic totals")
        let out32  = indexes.isSubset(of: hcOut.keys) ? [:] : try await optionalColumn(SNMPOID.ifOutOctets, "traffic totals")
        let inErr  = try await optionalColumn(IFMIB.ifInErrors, "errors")
        let outErr = try await optionalColumn(IFMIB.ifOutErrors, "errors")
        let inDisc = try await optionalColumn(IFMIB.ifInDiscards, "errors")
        let outDisc = try await optionalColumn(IFMIB.ifOutDiscards, "errors")
        let change = try await optionalColumn(IFMIB.ifLastChange, "last change times")

        // ifLastChange is a sysUpTime value, so compare it with sysUpTime.0:
        // both come from the device's clock. snmpEngineTime.0 (seconds, no
        // practical wrap) shows whether sysUpTime has started over, which it
        // does every 497 days. Devices without SNMP-FRAMEWORK-MIB leave it out.
        var upTicks: UInt64?
        var engineSeconds: UInt64?
        func clocks() async throws -> [SNMPVarBind] {
            do {
                return try await client.getTolerant([SNMPOID.sysUpTime, IFMIB.snmpEngineTime])
            } catch SNMPError.errorStatus(_, _, _) {
                // An agent that fails the request over the second OID
                // instead of marking it missing.
                return try await client.getTolerant([SNMPOID.sysUpTime])
            }
        }
        if !change.isEmpty && !stopped {
            do {
                for vb in try await clocks() {
                    if vb.oid == SNMPOID.sysUpTime, upTicks == nil, case .timeTicks(let t) = vb.value {
                        upTicks = UInt64(t)
                    }
                    if vb.oid == IFMIB.snmpEngineTime, engineSeconds == nil, case .integer(let s) = vb.value, s >= 0 {
                        engineSeconds = UInt64(s)
                    }
                }
            } catch SNMPError.errorStatus(_, _, _) {
            } catch SNMPError.timeout {
                unread.append("last change times")
            } catch SNMPError.transport(_) {
                unread.append("last change times")
            } catch is SNMPError {
                unread.append("last change times")      // a reply SNAP couldn't decode
            }
        }
        let now = Date()

        let rows: [SNMPInterfaceRow] = indexes.sorted().map { idx in
            let ifSpeed = unsigned(speed[idx])
            let highMbps = high[idx].map(unsigned)
            let atCeiling = SNMPInterfaceFormat.speedAtCeiling(ifSpeed: ifSpeed, highSpeedMbps: highMbps)
            let speedRaw = atCeiling ? 0 : SNMPInterfaceFormat.effectiveSpeedBps(ifSpeed: ifSpeed, highSpeedMbps: highMbps)
            let inValue = hcIn[idx] ?? in32[idx]
            let outValue = hcOut[idx] ?? out32[idx]
            var row = SNMPInterfaceRow(
                id: idx,
                descr: descr[idx]?.description ?? "",
                operStatus: SNMPInterfaceFormat.statusLabel(admin: admin[idx], oper: oper[idx]),
                speed: atCeiling ? SNMPInterfaceFormat.ceilingSpeedText : SNMPInterfaceFormat.formatSpeed(speedRaw),
                speedRaw: speedRaw,
                inOctets: unsigned(inValue),
                outOctets: unsigned(outValue),
                counters64: width(inValue) == .bits64 && width(outValue) == .bits64
            )
            row.speedAtCeiling = atCeiling
            row.name = text(ifNames[idx])
            row.alias = text(alias[idx])
            row.ifType = types[idx]?.int64
            row.inErrors = inErr[idx]?.uint64
            row.outErrors = outErr[idx]?.uint64
            row.inDiscards = inDisc[idx]?.uint64
            row.outDiscards = outDisc[idx]?.uint64
            row.lastChange = SNMPInterfaceFormat.lastChange(ticks: change[idx]?.uint64, sysUpTime: upTicks,
                                                            engineTime: engineSeconds, now: now)
            row.inWidth = width(inValue)
            row.outWidth = width(outValue)
            return row
        }
        var seen = Set<String>()
        let missing = unread.filter { seen.insert($0).inserted }
        return SNMPInterfaceReport(rows: rows, note: note, unread: missing)
    }

    private static func unsigned(_ v: SNMPValue?) -> UInt64 {
        switch v {
        case .gauge32(let g):   return UInt64(g)
        case .counter32(let c): return UInt64(c)
        case .counter64(let c): return c
        case .integer(let i):   return UInt64(max(0, i))
        default:                return 0
        }
    }

    /// Only counters count: Watch turns two counter readings into a rate,
    /// and can't from anything else (a Gauge32 from an odd agent), so a
    /// port without one is left out of Watch instead of waiting forever.
    private static func width(_ v: SNMPValue?) -> SNMPCounterWidth? {
        switch v {
        case .counter64?:   return .bits64
        case .counter32?:   return .bits32
        default:            return nil
        }
    }

    /// Text values (ifName, ifAlias) trimmed; binary or missing is "".
    private static func text(_ v: SNMPValue?) -> String {
        (v?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Port names by ifIndex: ifName (ifXTable), falling back to ifDescr.
    /// Shared with Neighbors and Where Is It.
    static func names(_ client: SNMPClient, maxRows: Int) async throws -> [UInt32: String] {
        var names: [UInt32: String] = [:]
        if let col = try? await client.column(IFMIB.ifName, maxRows: maxRows) {
            for (i, v) in col.byIndex { if let s = v.string, !s.isEmpty { names[i] = s } }
        }
        let descr = try await client.column(SNMPOID.ifDescr, maxRows: maxRows)
        for (i, v) in descr.byIndex where names[i] == nil {
            if let s = v.string, !s.isEmpty { names[i] = s }
        }
        return names
    }

    static func summary(_ r: SNMPInterfaceReport) -> String {
        "\(r.rows.count) interface\(r.rows.count == 1 ? "" : "s") retrieved"
    }

    // MARK: Physical ports filter

    /// True when "Physical ports only" would hide some rows and keep some.
    /// Off for devices that don't report ifType, or whose ports are all
    /// one kind.
    static func physicalFilterApplies(_ rows: [SNMPInterfaceRow]) -> Bool {
        let physical = rows.filter(\.isPhysical).count
        return physical > 0 && physical < rows.count
    }

    static func shownRows(_ rows: [SNMPInterfaceRow], physicalOnly: Bool) -> [SNMPInterfaceRow] {
        physicalOnly && physicalFilterApplies(rows) ? rows.filter(\.isPhysical) : rows
    }

    // MARK: Summary line

    /// One line above the table, about the rows shown. Every clause is a
    /// count of what the device reported, e.g.
    /// "18 of 24 up, 2 disabled. 2 ports at 100 Mbps. Gi1/0/7: 1,240 errors."
    static func summaryLine(_ rows: [SNMPInterfaceRow]) -> String {
        guard !rows.isEmpty else { return "No interfaces to show." }
        let ordered = rows.sorted { $0.id < $1.id }
        var parts: [String] = []

        let up = ordered.filter { $0.operStatus == "up" }
        let disabled = ordered.filter { $0.operStatus == "disabled" }.count
        parts.append("\(up.count.formatted()) of \(ordered.count.formatted()) up"
                     + (disabled > 0 ? ", \(disabled.formatted()) disabled." : "."))

        // Ethernet ports linked at 100 Mbps or less, when others run at 1 Gbps
        // or more: often a cable or a setting worth checking.
        let typed = ordered.contains { $0.ifType != nil }
        let ethernet = up.filter { r in
            guard typed else { return true }
            return r.ifType.map(SNMPInterfaceFormat.ethernetTypes.contains) ?? false
        }
        if let fastest = ethernet.map(\.speedSort).max(), fastest >= 1_000_000_000 {
            var bySpeed: [UInt64: Int] = [:]
            for r in ethernet where r.speedRaw > 0 && r.speedRaw <= 100_000_000 {
                bySpeed[r.speedRaw, default: 0] += 1
            }
            let speeds = bySpeed.keys.sorted(by: >)
            if !speeds.isEmpty {
                let pieces = speeds.enumerated().map { i, s -> String in
                    let n = bySpeed[s] ?? 0
                    let noun = i == 0 ? (n == 1 ? " port" : " ports") : ""
                    return "\(n.formatted())\(noun) at \(SNMPInterfaceFormat.formatSpeed(s))"
                }
                parts.append(pieces.joined(separator: ", ") + ".")
            }
        }

        let withErrors = ordered.filter { $0.errorTotal > 0 }
        if let worst = withErrors.max(by: { $0.errorTotal < $1.errorTotal }) {
            let n = worst.errorTotal
            parts.append("\(worst.displayName): \(n.formatted()) error\(n == 1 ? "" : "s").")
            let others = withErrors.count - 1
            if others > 0 {
                parts.append("\(others.formatted()) other port\(others == 1 ? " has" : "s have") errors too.")
            }
        } else if ordered.contains(where: \.hasErrorCounts) {
            parts.append("No errors counted.")
        }
        return parts.joined(separator: " ")
    }

    // MARK: Export

    static func exportText(_ r: SNMPInterfaceReport) -> String {
        let now = Date()
        var s = ""
        if physicalFilterApplies(r.rows) {
            let physical = r.rows.filter(\.isPhysical)
            s += "Physical ports (\(physical.count) of \(r.rows.count) interfaces): \(summaryLine(physical))\n\n"
        } else if !r.rows.isEmpty {
            s += summaryLine(r.rows) + "\n\n"
        }
        s += "idx\tname\talias\ttype\tstatus\tspeed\tin errors\tout errors\tin discards\tout discards\tlast change\ttotal in (bytes)\ttotal out (bytes)\n"
        func count(_ v: UInt64?) -> String { v.map(String.init) ?? "" }
        func total(_ v: UInt64, _ w: SNMPCounterWidth?) -> String {
            guard let w else { return "" }
            return String(v) + (w == .bits32 ? "*" : "")
        }
        for row in r.rows {
            let fields: [String] = [
                String(row.id),
                row.displayName,
                row.alias,
                row.ifType.map { t in SNMPInterfaceFormat.typeName(t).map { "\($0) (\(t))" } ?? String(t) } ?? "",
                row.operStatus,
                row.speedRaw > 0 || row.speedAtCeiling ? row.speed : "",
                count(row.inErrors), count(row.outErrors), count(row.inDiscards), count(row.outDiscards),
                {
                    if case .notSinceStart? = row.lastChange { return "unchanged since SNMP service start" }
                    return SNMPInterfaceFormat.changeText(row.lastChange, now: now)
                }(),
                total(row.inOctets, row.inWidth),
                total(row.outOctets, row.outWidth),
            ]
            s += fields.map { $0.replacingOccurrences(of: "\t", with: " ") }.joined(separator: "\t") + "\n"
        }
        if r.rows.contains(where: { $0.inWidth == .bits32 || $0.outWidth == .bits32 }) {
            s += "(* a 32-bit counter, which wraps every 4.29 GB)\n"
        }
        if !r.unread.isEmpty {
            s += "(the device stopped answering or sent unreadable replies; missing: \(r.unread.joined(separator: ", ")))\n"
        }
        return s + SNMPQueryModel.exportNote(r.note)
    }
}

/// Interface table helpers, kept pure for tests.
enum SNMPInterfaceFormat {
    /// ifSpeed is a Gauge32: anything over 4,294,967,295 bps should report
    /// exactly that, and RFC 2863 says to read ifHighSpeed (Mbps) instead.
    /// Some agents wrap it instead (1,410,065,408 on a 10G port), so
    /// ifHighSpeed also wins whenever it's too fast for ifSpeed to hold.
    /// Without ifHighSpeed this returns ifSpeed as reported; see
    /// `speedAtCeiling` for a ceiling value.
    static func effectiveSpeedBps(ifSpeed: UInt64, highSpeedMbps: UInt64?) -> UInt64 {
        if let hs = highSpeedMbps, hs > 0 {
            let (bps, overflow) = hs.multipliedReportingOverflow(by: 1_000_000)
            let high = overflow ? UInt64.max : bps
            if ifSpeed == 0 || ifSpeed >= UInt64(UInt32.max) || high > UInt64(UInt32.max) { return high }
        }
        return ifSpeed
    }

    /// ifSpeed at its ceiling with no ifHighSpeed to say how far past it
    /// (no ifXTable, or the device stopped answering before it): the port
    /// is faster than 4.29 Gbps, and how much faster isn't known.
    static func speedAtCeiling(ifSpeed: UInt64, highSpeedMbps: UInt64?) -> Bool {
        ifSpeed >= UInt64(UInt32.max) && (highSpeedMbps ?? 0) == 0
    }

    static let ceilingSpeedText = "over 4.29 Gbps"
    /// The Speed cell's shorter form, to fit the column.
    static let ceilingSpeedShort = "> 4 Gbps"
    static let ceilingSpeedHelp = "The device reports only that this port is faster than 4.29 Gbps (ifSpeed at its ceiling), not how much faster (ifHighSpeed)."

    /// "10 Gbps", "2.5 Gbps", "1.5 Mbps". Decimal units.
    static func formatSpeed(_ bps: UInt64) -> String {
        if bps == 0 { return "n/a" }
        func f(_ v: Double, _ unit: String) -> String {
            String(format: v == v.rounded() ? "%.0f %@" : "%.1f %@", v, unit)
        }
        if bps >= 1_000_000_000 { return f(Double(bps) / 1_000_000_000, "Gbps") }
        if bps >= 1_000_000     { return f(Double(bps) / 1_000_000, "Mbps") }
        if bps >= 1_000         { return f(Double(bps) / 1_000, "kbps") }
        return "\(bps) bps"
    }

    /// A port someone turned off (ifAdminStatus 2) reads "disabled", not a
    /// red "down": it isn't a fault.
    static func statusLabel(admin: SNMPValue?, oper: SNMPValue?) -> String {
        if case .integer(2) = admin { return "disabled" }
        return ifStatusLabel(oper)
    }

    /// The Status cell's text: the label, shortened where it wouldn't fit
    /// the column. The tooltip has the full label.
    static func statusShort(_ status: String) -> String {
        status == "lowerLayerDown" ? "lower down" : status
    }

    static func statusHelp(_ status: String) -> String {
        switch status {
        case "disabled":       return "Turned off in the device's settings (ifAdminStatus down)"
        case "notPresent":     return "notPresent: a part this interface needs is missing, typically hardware such as a module (ifOperStatus 6)"
        case "lowerLayerDown": return "lowerLayerDown: down because an interface it runs on is down (ifOperStatus 7)"
        default:               return status
        }
    }

    // MARK: Port types (IANAifType-MIB)

    /// Ethernet: ethernetCsmacd 6, iso88023Csmacd 7, fastEther 62,
    /// fastEtherFX 69, gigabitEthernet 117.
    static let ethernetTypes: Set<Int64> = [6, 7, 62, 69, 117]

    /// Types that are a port you can plug something into (or a radio):
    /// Ethernet, Wi-Fi (ieee80211 71), serial (propPointToPointSerial 22),
    /// T1/E1/T3 (18, 19, 30), SONET 39, Fibre Channel 56, DSL (adsl 94,
    /// radsl 95, sdsl 96, vdsl 97, hdsl2 168, shdsl 169, adsl2 230,
    /// adsl2plus 238, vdsl2 251), cable (docsCableDownstream 128,
    /// docsCableUpstream 129, docsCableUpstreamChannel 205), and GPON 250.
    /// Everything else is hidden by "Physical ports only": loopback 24,
    /// propVirtual 53, docsCableMaclayer 127, tunnel 131, l2vlan 135,
    /// l3ipvlan 136, ieee8023adLag 161, bridge 209, "other" 1, and so on.
    static let physicalTypes: Set<Int64> = ethernetTypes.union([
        71, 22, 18, 19, 30, 39, 56,
        94, 95, 96, 97, 168, 169, 230, 238, 251,
        128, 129, 205,
        250,
    ])

    static func isPhysical(_ ifType: Int64) -> Bool { physicalTypes.contains(ifType) }

    /// A plain name for common ifType values.
    static func typeName(_ t: Int64) -> String? {
        switch t {
        case 6, 7, 62, 69, 117: return "Ethernet"
        case 71:  return "Wi-Fi"
        case 1:   return "other"
        case 18:  return "T1"
        case 19:  return "E1"
        case 22:  return "serial"
        case 23:  return "PPP"
        case 24:  return "loopback"
        case 30:  return "T3"
        case 39:  return "SONET"
        case 53:  return "virtual"
        case 56:  return "Fibre Channel"
        case 94:  return "ADSL"
        case 95:  return "RADSL"
        case 96:  return "SDSL"
        case 97:  return "VDSL"
        case 127: return "cable MAC layer"
        case 128: return "cable downstream"
        case 129: return "cable upstream"
        case 131: return "tunnel"
        case 135: return "VLAN"
        case 136: return "VLAN (layer 3)"
        case 161: return "link aggregation"
        case 166: return "MPLS"
        case 168: return "HDSL2"
        case 169: return "SHDSL"
        case 205: return "cable upstream channel"
        case 209: return "bridge"
        case 230: return "ADSL2"
        case 238: return "ADSL2+"
        case 250: return "GPON"
        case 251: return "VDSL2"
        default:  return nil
        }
    }

    // MARK: Last change

    /// sysUpTime is 32-bit hundredths of a second, so it starts over at zero
    /// every 497.1 days (42,949,672.96 s).
    static let upTimeWrapSeconds: UInt64 = 42_949_673

    /// ifLastChange is the sysUpTime value when the port entered its current
    /// state. Both are TimeTicks (hundredths of a second) on the device's
    /// clock. 0 means no change since the SNMP service started.
    ///
    /// sysUpTime starts over every 497 days, and after that a change from
    /// before the wrap would read as far too recent. snmpEngineTime
    /// (seconds since the SNMP engine started, which doesn't wrap in
    /// practice) shows when that has happened: then a nonzero value could
    /// be from any round of the clock, so it's nil, and the start time
    /// comes from snmpEngineTime. Devices without snmpEngineTime give no
    /// sign of a wrap, so there only a value later than sysUpTime (a wrap,
    /// or an odd agent) is known to be unplaceable and is nil.
    static func lastChange(ticks: UInt64?, sysUpTime: UInt64?, engineTime: UInt64? = nil,
                           now: Date) -> SNMPPortChange? {
        guard let ticks else { return nil }
        let wrapped = (engineTime ?? 0) >= upTimeWrapSeconds
        if ticks == 0 {
            if wrapped, let seconds = engineTime {
                return .notSinceStart(now.addingTimeInterval(-Double(seconds)))
            }
            return .notSinceStart(sysUpTime.map { now.addingTimeInterval(-Double($0) / 100) })
        }
        guard !wrapped, let up = sysUpTime, ticks <= up else { return nil }
        return .at(now.addingTimeInterval(-Double(up - ticks) / 100))
    }

    static func changeText(_ c: SNMPPortChange?, now: Date) -> String {
        switch c {
        case .at(let d)?:       return SNMPFormat.ago(now.timeIntervalSince(d))
        case .notSinceStart?:   return "Unchanged"      // the tooltip says since when
        case nil:               return ""
        }
    }

    static func changeHelp(_ c: SNMPPortChange?, status: String, now: Date) -> String {
        switch c {
        case .at(let d)? where status == "disabled":
            // ifLastChange follows the link (ifOperStatus), and turning a
            // port off that was already down doesn't change it.
            return "The link last changed state \(SNMPFormat.ago(now.timeIntervalSince(d))), by the device's clock (ifLastChange). The device doesn't report when the port was turned off."
        case .at(let d)?:
            return "Became \(status) \(SNMPFormat.ago(now.timeIntervalSince(d))), by the device's clock (ifLastChange)."
        case .notSinceStart(let started)?:
            let when = started.map { ", \(SNMPFormat.ago(now.timeIntervalSince($0)))" } ?? ""
            return "No change since the device's SNMP service started\(when), which is usually when the device last restarted. (ifLastChange is 0.)"
        case nil:
            return "The device didn't report when this port last changed, or reported a time SNAP can't place."
        }
    }

    // MARK: Errors and live rates

    /// The Errors cell: exact up to 99,999, then "123K", "1.2M", "45M",
    /// "3.1B", rounded down so it never reads high. The tooltip has the
    /// exact counts.
    static func compactCount(_ n: UInt64) -> String {
        if n < 100_000 { return n.formatted() }
        let units: [(UInt64, String)] = [(1_000_000_000_000, "T"), (1_000_000_000, "B"), (1_000_000, "M"), (1_000, "K")]
        for (scale, unit) in units where n >= scale {
            let whole = n / scale
            if whole >= 10 { return "\(whole)\(unit)" }
            let tenth = (n % scale) / (scale / 10)
            return tenth == 0 ? "\(whole)\(unit)" : "\(whole).\(tenth)\(unit)"
        }
        return n.formatted()
    }

    static func errorHelp(_ r: SNMPInterfaceRow) -> String {
        func n(_ v: UInt64?) -> String { v.map { $0.formatted() } ?? "not reported" }
        return """
        In errors: \(n(r.inErrors))
        Out errors: \(n(r.outErrors))
        In discards: \(n(r.inDiscards))
        Out discards: \(n(r.outDiscards))
        Errors are damaged or malformed packets; discards are good packets the device dropped, often because it was busy. Counted since the device's counters last reset, usually at its last restart.
        """
    }

    /// The busier direction as a share of the port speed. Ports are full
    /// duplex, so in and out each have the whole speed.
    static func linkPercent(inBps: Double?, outBps: Double?, speedBps: UInt64) -> Double? {
        guard speedBps > 0, let busiest = [inBps, outBps].compactMap({ $0 }).max() else { return nil }
        return busiest / Double(speedBps) * 100
    }

    static let counter32Help = "* A 32-bit counter: it starts over at zero after every 4.29 GB, so on a busy port this isn't the total since restart."

    static func percentText(_ p: Double?) -> String {
        guard let p else { return "" }
        if p == 0 { return "0%" }
        if p < 1 { return "<1%" }
        return String(format: "%.0f%%", p)
    }

    /// The selected port's details under the table.
    static func detailLine(_ r: SNMPInterfaceRow) -> String {
        var parts = ["ifIndex \(r.id)"]
        if let t = r.ifType { parts.append(typeName(t).map { "\($0) (ifType \(t))" } ?? "ifType \(t)") }
        if r.speedRaw > 0 || r.speedAtCeiling { parts.append(r.speed) }
        if !r.descr.isEmpty && r.descr != r.displayName { parts.append(r.descr) }
        if r.hasErrorCounts {
            func n(_ v: UInt64?) -> String { v.map { $0.formatted() } ?? "n/a" }
            parts.append("errors in \(n(r.inErrors)), out \(n(r.outErrors))")
            if r.inDiscards != nil || r.outDiscards != nil {
                parts.append("discards in \(n(r.inDiscards)), out \(n(r.outDiscards))")
            }
        }
        return parts.joined(separator: " \u{00B7} ")
    }
}

private func ifStatusLabel(_ v: SNMPValue?) -> String {
    if case .integer(let i) = v {
        switch i {
        case 1: return "up"
        case 2: return "down"
        case 3: return "testing"
        case 4: return "unknown"
        case 5: return "dormant"
        case 6: return "notPresent"
        case 7: return "lowerLayerDown"
        default: return "status \(i)"
        }
    }
    return "n/a"
}

// MARK: - Watch: rate math

/// Why a reading gave no rate.
enum SNMPRateDrop: Equatable {
    case counterWentBack    // a 64-bit counter decreased: it was reset
    case counterReset       // a 32-bit counter "wrapped" faster than the port can go (or, with no speed, from low down): it was reset
    case deviceRestarted    // sysUpTime went backwards
    case noTimePassed       // same sysUpTime as last time (a cached reply)
    case noValue            // missing, or not a counter
}

enum SNMPRateOutcome: Equatable {
    case baseline           // the first reading: nothing to compare with yet
    case rate(Double)       // bits per second
    case dropped(SNMPRateDrop)

    var bps: Double? {
        if case .rate(let r) = self { return r }
        return nil
    }
}

/// Turns successive octet-counter readings into bits per second, per port
/// and direction.
struct SNMPRateMeter {
    struct Key: Hashable {
        let ifIndex: UInt32
        let outbound: Bool
    }
    /// One counter reading: the value, sysUpTime at the time (hundredths of
    /// a second; nil if the device didn't send it), and this Mac's
    /// monotonic clock as the fallback.
    struct Point: Equatable {
        let value: SNMPValue
        let ticks: UInt32?
        let local: TimeInterval
    }

    private(set) var baselines: [Key: Point] = [:]

    mutating func ingest(_ key: Key, value: SNMPValue?, ticks: UInt32?, local: TimeInterval,
                         speedBps: UInt64) -> SNMPRateOutcome {
        guard let value, Self.isCounter(value) else {
            baselines[key] = nil
            return .dropped(.noValue)
        }
        let point = Point(value: value, ticks: ticks, local: local)
        guard let previous = baselines[key] else {
            baselines[key] = point
            return .baseline
        }
        let outcome = Self.rate(from: previous, to: point, speedBps: speedBps)
        // A reply with no time passed keeps the older baseline, so the next
        // reading spans the whole gap. Anything else starts from this one
        // (after a reset or restart, that's the new baseline).
        if outcome != .dropped(.noTimePassed) { baselines[key] = point }
        return outcome
    }

    /// Forget ports no longer watched.
    mutating func keep(_ ids: Set<UInt32>) {
        baselines = baselines.filter { ids.contains($0.key.ifIndex) }
    }

    static func isCounter(_ v: SNMPValue) -> Bool {
        switch v {
        case .counter32, .counter64: return true
        default:                     return false
        }
    }

    /// Bits per second between two readings. Time comes from sysUpTime (the
    /// device's clock) when both readings have it, else from this Mac.
    /// A 32-bit counter may wrap once per interval; a 64-bit counter never
    /// wraps in practice, so a decrease means it was reset.
    static func rate(from a: Point, to b: Point, speedBps: UInt64) -> SNMPRateOutcome {
        let seconds: Double
        if let t0 = a.ticks, let t1 = b.ticks {
            guard t1 >= t0 else { return .dropped(.deviceRestarted) }
            seconds = Double(t1 - t0) / 100
        } else {
            seconds = b.local - a.local
        }
        guard seconds > 0 else { return .dropped(.noTimePassed) }

        let bytes: UInt64
        switch (a.value, b.value) {
        case let (.counter64(x), .counter64(y)):
            guard y >= x else { return .dropped(.counterWentBack) }
            bytes = y - x
        case let (.counter32(x), .counter32(y)):
            if y >= x {
                bytes = UInt64(y - x)
            } else {
                bytes = (UInt64(UInt32.max) - UInt64(x)) + UInt64(y) + 1
                // A wrap that implies more than twice the port speed is a
                // counter someone (or a restart) reset, not traffic.
                if speedBps > 0 && Double(bytes) * 8 / seconds > Double(speedBps) * 2 {
                    return .dropped(.counterReset)
                }
                // With no speed to check against, a wrap has to start from
                // the counter's top half: from lower down it would take
                // over 2 GiB in one interval, more than a 32-bit counter
                // can be trusted with anyway. Otherwise it was reset.
                if speedBps == 0 && x < UInt32(1) << 31 {
                    return .dropped(.counterReset)
                }
            }
        default:
            return .dropped(.noValue)
        }
        return .rate(Double(bytes) * 8 / seconds)
    }
}

// MARK: - Watch: reading counters

/// Why one direction of a watched port has no rate, other than waiting for
/// a second reading.
enum SNMPCounterGap: Equatable {
    /// The table had no such counter, or the last reading came back
    /// without one (missing, or not a counter).
    case notReported
    /// The device returned this error (genErr, ...) for that counter, or
    /// refused the GET it was in.
    case error(String)
}

/// One port's live state while watching.
struct SNMPPortLive: Equatable {
    var inBps: Double?
    var outBps: Double?
    var history: [SNMPRateSample] = []
    var inGap: SNMPCounterGap?
    var outGap: SNMPCounterGap?

    /// Neither direction can give a rate as things stand.
    var noCounters: Bool { inGap != nil && outGap != nil }
}

struct SNMPRateSample: Identifiable, Equatable {
    let id: Int
    let inBps: Double?
    let outBps: Double?
}

/// The network side of Watch, off the main actor.
enum SNMPInterfaceWatch {
    static let intervals: [Double] = [2, 5, 10, 30]
    static let defaultInterval: Double = 5
    /// At most this many ports are polled, the first ones shown by index.
    static let maxPorts = 100
    /// Rows per GET: sysUpTime.0 plus in and out for each, 21 varbinds.
    static let rowsPerRequest = 10
    /// Samples kept per port for the sparkline and chart.
    static let historyLength = 60

    struct Target: Equatable {
        let ifIndex: UInt32
        let inOID: OID?
        let outOID: OID?
    }

    struct Reading: Equatable {
        let ifIndex: UInt32
        let inValue: SNMPValue?
        let outValue: SNMPValue?
        let ticks: UInt32?
        let local: TimeInterval
        /// The error the device returned for that counter asked on its own,
        /// or for a GET of it that the device refused (the value is nil then).
        var inError: String? = nil
        var outError: String? = nil
    }

    /// The rows Watch asks about: the first `maxPorts` shown, by index.
    static func pick(_ shown: [SNMPInterfaceRow]) -> [SNMPInterfaceRow] {
        Array(shown.sorted { $0.id < $1.id }.prefix(maxPorts))
    }

    /// False when none of the rows Watch would ask about has a counter to
    /// ask for, so there's nothing to watch.
    static func hasCounters(_ shown: [SNMPInterfaceRow]) -> Bool {
        !targets(for: pick(shown)).isEmpty
    }

    /// Why a direction has no rate after this reading, if it isn't just
    /// waiting for the next one.
    static func gap(value: SNMPValue?, error: String?) -> SNMPCounterGap? {
        if let error { return .error(error) }
        guard let value, SNMPRateMeter.isCounter(value) else { return .notReported }
        return nil
    }

    /// The selected port's hint when neither direction has a counter to chart.
    static func noCountersHint(_ live: SNMPPortLive) -> String {
        for gap in [live.inGap, live.outGap] {
            if case .error(let label)? = gap {
                return "The device returned an error (\(label)) for this port's traffic counters at the last reading, so there's nothing to chart yet. SNAP keeps asking."
            }
        }
        return "The device isn't reporting traffic counters for this port, so there's nothing to chart."
    }

    /// The same counters the table's totals came from: 64-bit when the
    /// device has them for that port, else 32-bit.
    static func targets(for rows: [SNMPInterfaceRow]) -> [Target] {
        rows.compactMap { r in
            func oid(_ w: SNMPCounterWidth?, hc: OID, c32: OID) -> OID? {
                guard let w else { return nil }
                return OID((w == .bits64 ? hc : c32).components + [r.id])
            }
            let t = Target(ifIndex: r.id,
                           inOID: oid(r.inWidth, hc: SNMPOID.ifHCInOctets, c32: SNMPOID.ifInOctets),
                           outOID: oid(r.outWidth, hc: SNMPOID.ifHCOutOctets, c32: SNMPOID.ifOutOctets))
            return t.inOID == nil && t.outOID == nil ? nil : t
        }
    }

    /// One reading of every target, in GETs of `rowsPerRequest` ports, one
    /// after another. Each GET carries sysUpTime.0 so its counters and its
    /// time come from the same moment on the device.
    ///
    /// One bad counter (a port on a stack member or module that's offline)
    /// can make the device fail its whole GET with an error such as genErr.
    /// That GET is then asked again one OID at a time, so the other ports
    /// still get their readings and only the failing counters carry the
    /// error. A refusal (noAccess, authorizationError) is thrown only when
    /// every counter was refused; no answer is thrown as before.
    static func read(_ client: SNMPClient, _ targets: [Target],
                     clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) async throws -> [Reading] {
        func isRefusal(_ code: Int) -> Bool { code == 6 || code == 16 }
        var out: [Reading] = []
        var asked = 0               // counter OIDs asked for
        var refusedCount = 0        // ... and refused
        var refusal: SNMPError?
        var start = 0
        while start < targets.count {
            try Task.checkCancellation()
            let chunk = targets[start..<min(start + rowsPerRequest, targets.count)]
            start += rowsPerRequest
            var oids: [OID] = [SNMPOID.sysUpTime]
            for t in chunk {
                if let o = t.inOID { oids.append(o) }
                if let o = t.outOID { oids.append(o) }
            }
            asked += oids.count - 1
            var byOID: [OID: SNMPValue] = [:]
            var failed: [OID: String] = [:]
            do {
                for vb in try await client.getTolerant(oids) where byOID[vb.oid] == nil { byOID[vb.oid] = vb.value }
            } catch SNMPError.errorStatus(let code, let label, let index) where isRefusal(code) {
                refusal = .errorStatus(code, label, index)
                refusedCount += oids.count - 1
                for o in oids.dropFirst() { failed[o] = label }
            } catch SNMPError.errorStatus(_, _, _) {
                for o in oids {
                    try Task.checkCancellation()
                    do {
                        for vb in try await client.get([o]) where byOID[vb.oid] == nil { byOID[vb.oid] = vb.value }
                    } catch SNMPError.errorStatus(2, _, _) {
                        // v1's noSuchName: this one isn't there.
                    } catch SNMPError.errorStatus(let code, let label, let index) {
                        guard o != SNMPOID.sysUpTime else { continue }      // the Mac's clock stands in
                        failed[o] = label
                        if isRefusal(code) { refusal = .errorStatus(code, label, index); refusedCount += 1 }
                    }
                }
            }
            let local = clock()
            var ticks: UInt32?
            if case .timeTicks(let t)? = byOID[SNMPOID.sysUpTime] { ticks = t }
            for t in chunk {
                out.append(Reading(ifIndex: t.ifIndex,
                                   inValue: t.inOID.flatMap { byOID[$0] },
                                   outValue: t.outOID.flatMap { byOID[$0] },
                                   ticks: ticks, local: local,
                                   inError: t.inOID.flatMap { failed[$0] },
                                   outError: t.outOID.flatMap { failed[$0] }))
            }
        }
        if let refusal, refusedCount == asked { throw refusal }
        return out
    }

    /// Watched ports whose 32-bit counters could start over more than once
    /// in one interval at full speed, which would make the rate read low.
    /// A port only known to be over 4.29 Gbps counts at that speed.
    static func wrapRisk(_ rows: [SNMPInterfaceRow], interval: Double) -> [SNMPInterfaceRow] {
        rows.filter { r in
            let speed = r.speedAtCeiling ? UInt64(UInt32.max) : r.speedRaw
            return (r.inWidth == .bits32 || r.outWidth == .bits32) && speed > 0
                && Double(speed) / 8 * interval > Double(UInt32.max)
        }
    }
}

/// Polls the rows on screen while Watch live is on. Owned by the pane.
@MainActor
final class SNMPInterfaceWatcher: ObservableObject {
    @Published private(set) var isWatching = false
    @Published private(set) var live: [UInt32: SNMPPortLive] = [:]
    @Published private(set) var watchedIDs: Set<UInt32> = []
    /// Why the last reading failed, or why watching stopped.
    @Published private(set) var problem: String?
    @Published var interval: Double = SNMPInterfaceWatch.defaultInterval {
        didSet { if isWatching && interval != oldValue { restart() } }
    }

    private var client: SNMPClient?
    private var rows: [SNMPInterfaceRow] = []
    private var meter = SNMPRateMeter()
    private var task: Task<Void, Never>?
    /// Bumped by every start, restart, and stop: an old loop sees it changed and ends.
    private var generation = 0
    private var sampleID = 0

    func start(config: SNMPClientConfig, rows: [SNMPInterfaceRow]) {
        start(client: config.makeClient(), rows: rows)
    }

    func start(client: SNMPClient, rows: [SNMPInterfaceRow]) {
        stop()
        self.client = client
        isWatching = true
        setRows(rows)
        restart()
    }

    /// The rows on screen changed (the filter): watch those instead.
    func setRows(_ shown: [SNMPInterfaceRow]) {
        let picked = SNMPInterfaceWatch.pick(shown)
        rows = picked
        let ids = Set(picked.map(\.id))
        watchedIDs = ids
        var next = live.filter { ids.contains($0.key) }
        // A counter the table didn't have won't turn up in a reading
        // either: say so now instead of waiting for one.
        for r in picked where r.inWidth == nil || r.outWidth == nil {
            var entry = next[r.id] ?? SNMPPortLive()
            if r.inWidth == nil { entry.inGap = .notReported }
            if r.outWidth == nil { entry.outGap = .notReported }
            next[r.id] = entry
        }
        live = next
        meter.keep(ids)
    }

    var watchedRows: [SNMPInterfaceRow] { rows }

    func stop() {
        generation += 1
        task?.cancel()          // ends the request in flight at once
        client = nil
        isWatching = false
        problem = nil           // "SNAP keeps asking" would no longer be true
        live = [:]
        watchedIDs = []
        rows = []
        meter = SNMPRateMeter()
    }

    private struct Plan {
        let client: SNMPClient
        let targets: [SNMPInterfaceWatch.Target]
        let interval: Double
    }

    private func plan(_ gen: Int) -> Plan? {
        guard gen == generation, isWatching, let client else { return nil }
        return Plan(client: client, targets: SNMPInterfaceWatch.targets(for: rows), interval: interval)
    }

    /// One loop at a time: a new loop waits for the old one to finish, and
    /// each reading waits for the one before it, so polls never overlap.
    private func restart() {
        let previous = task
        previous?.cancel()
        generation += 1
        let gen = generation
        task = Task { [weak self] in
            await previous?.value
            while !Task.isCancelled {
                guard let plan = self?.plan(gen) else { return }
                let started = ProcessInfo.processInfo.systemUptime
                var readings: [SNMPInterfaceWatch.Reading] = []
                var failure: Error?
                do {
                    readings = try await SNMPInterfaceWatch.read(plan.client, plan.targets)
                } catch {
                    failure = error
                }
                if Task.isCancelled { return }
                guard let keepGoing = self?.finish(gen, readings: readings, failure: failure), keepGoing else { return }
                let elapsed = ProcessInfo.processInfo.systemUptime - started
                let wait = max(0.5, plan.interval - elapsed)
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
    }

    /// False to end the loop.
    private func finish(_ gen: Int, readings: [SNMPInterfaceWatch.Reading], failure: Error?) -> Bool {
        guard gen == generation, isWatching else { return false }
        guard let failure else {
            ingest(readings)
            problem = nil
            return true
        }
        if failure is CancellationError { return false }
        let time = Date().formatted(date: .omitted, time: .standard)
        let every = "every \(Int(interval)) s"
        switch failure as? SNMPError {
        case .errorStatus(let code, let label, _)? where code == 6 || code == 16:
            stop()
            problem = "The device refused to give these counters to this community (\(label)), so watching stopped."
            return false
        case .errorStatus(_, let label, _)?:
            problem = "The device returned an error (\(label)) for the reading at \(time). SNAP keeps asking \(every)."
        case .timeout?, .transport?:
            problem = "No answer to the reading at \(time). SNAP keeps asking \(every)."
        default:
            problem = "The reply to the reading at \(time) couldn't be read. SNAP keeps asking \(every)."
        }
        // The "now" values would be stale; keep the history.
        var next = live
        for k in Array(next.keys) {
            next[k]?.inBps = nil
            next[k]?.outBps = nil
        }
        live = next
        return true
    }

    private func ingest(_ readings: [SNMPInterfaceWatch.Reading]) {
        var speeds: [UInt32: UInt64] = [:]
        for r in rows { speeds[r.id] = r.speedRaw }
        var next = live
        for r in readings where watchedIDs.contains(r.ifIndex) {
            let speed = speeds[r.ifIndex] ?? 0
            let inBps = meter.ingest(.init(ifIndex: r.ifIndex, outbound: false), value: r.inValue,
                                     ticks: r.ticks, local: r.local, speedBps: speed).bps
            let outBps = meter.ingest(.init(ifIndex: r.ifIndex, outbound: true), value: r.outValue,
                                      ticks: r.ticks, local: r.local, speedBps: speed).bps
            var entry = next[r.ifIndex] ?? SNMPPortLive()
            entry.inBps = inBps
            entry.outBps = outBps
            entry.inGap = SNMPInterfaceWatch.gap(value: r.inValue, error: r.inError)
            entry.outGap = SNMPInterfaceWatch.gap(value: r.outValue, error: r.outError)
            if inBps != nil || outBps != nil {
                sampleID += 1
                entry.history.append(SNMPRateSample(id: sampleID, inBps: inBps, outBps: outBps))
                let extra = entry.history.count - SNMPInterfaceWatch.historyLength
                if extra > 0 { entry.history.removeFirst(extra) }
            }
            next[r.ifIndex] = entry
        }
        live = next
    }
}

// MARK: - View

struct SNMPInterfacesPane: View {
    @ObservedObject var model: SNMPQueryModel
    let report: SNMPInterfaceReport

    @StateObject private var watcher = SNMPInterfaceWatcher()
    @State private var physicalOnly: Bool
    @State private var selection: UInt32?
    @State private var sortOrder: [KeyPathComparator<SNMPInterfaceRow>] = [KeyPathComparator(\SNMPInterfaceRow.id)]
    @State private var liveSortOrder: [KeyPathComparator<SNMPLiveRow>] = [KeyPathComparator(\SNMPLiveRow.id)]

    init(model: SNMPQueryModel, report: SNMPInterfaceReport) {
        self.model = model
        self.report = report
        _physicalOnly = State(initialValue: SNMPInterfaces.physicalFilterApplies(report.rows))
    }

    /// For previews and tests: a watcher you've set up, and a selected row.
    init(model: SNMPQueryModel, report: SNMPInterfaceReport, watcher: SNMPInterfaceWatcher, selection: UInt32?) {
        self.init(model: model, report: report)
        _watcher = StateObject(wrappedValue: watcher)
        _selection = State(initialValue: selection)
    }

    private var shown: [SNMPInterfaceRow] {
        SNMPInterfaces.shownRows(report.rows, physicalOnly: physicalOnly)
    }

    private var selectedRow: SNMPInterfaceRow? {
        guard let selection else { return nil }
        return report.rows.first { $0.id == selection }
    }

    var body: some View {
        let rows = shown
        VStack(spacing: 0) {
            if let note = report.note {
                SNMPNoteStrip(text: Self.noteText(note))
            }
            if !report.unread.isEmpty {
                SNMPNoteStrip(text: Self.unreadText(report.unread))
            }
            if report.rows.isEmpty {
                ScrollView {
                    ToolNoteCard(icon: "tray", tint: .blue,
                                 headline: "No interfaces",
                                 detail: "The device answered, but listed no interfaces. It may not support the interface table (ifTable), or it may hide it from this community.")
                        .padding(16)
                }
            } else {
                header(rows)
                if let p = watcher.problem {
                    SNMPNoteStrip(text: p)
                }
                if watcher.isWatching {
                    watchNotes(rows)
                }
                Divider()
                if watcher.isWatching {
                    liveTable(rows)
                } else {
                    staticTable(rows)
                }
                if let row = selectedRow {
                    Divider()
                    SNMPPortDetail(row: row,
                                   config: model.configs[.interfaces],
                                   watching: watcher.isWatching,
                                   watched: watcher.watchedIDs.contains(row.id),
                                   live: watcher.live[row.id],
                                   interval: watcher.interval)
                }
            }
        }
        .onDisappear { watcher.stop() }
        .onChange(of: report) {
            watcher.stop()
            selection = nil
            physicalOnly = SNMPInterfaces.physicalFilterApplies(report.rows)
        }
        .onChange(of: physicalOnly) {
            let now = shown
            if watcher.isWatching { watcher.setRows(now) }
            if let s = selection, !now.contains(where: { $0.id == s }) { selection = nil }
        }
    }

    // MARK: Header

    private func header(_ rows: [SNMPInterfaceRow]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(SNMPInterfaces.summaryLine(rows))
                .font(.system(size: 12))
                .foregroundStyle(NS.text1)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            // One row when it fits; narrow windows put Watch on its own row.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    filterControls(rows)
                    Spacer(minLength: 8)
                    watchControls(rows)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) { filterControls(rows) }
                    HStack(spacing: 10) { watchControls(rows) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    @ViewBuilder
    private func filterControls(_ rows: [SNMPInterfaceRow]) -> some View {
        if SNMPInterfaces.physicalFilterApplies(report.rows) {
            Toggle("Physical ports only", isOn: $physicalOnly)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .fixedSize()
                .help("Hide VLANs, loopbacks, tunnels, link aggregation groups, and other virtual interfaces, by the type each one reports (ifType)")
            Text(verbatim: physicalOnly
                 ? "Showing \(rows.count) of \(report.rows.count) interfaces"
                 : "\(report.rows.count) interfaces")
                .font(.system(size: 11)).foregroundStyle(NS.text3)
                .fixedSize()
        } else {
            Text(verbatim: "\(report.rows.count) interface\(report.rows.count == 1 ? "" : "s")")
                .font(.system(size: 11)).foregroundStyle(NS.text3)
                .fixedSize()
        }
    }

    @ViewBuilder
    private func watchControls(_ rows: [SNMPInterfaceRow]) -> some View {
        Picker(selection: $watcher.interval) {
            ForEach(SNMPInterfaceWatch.intervals, id: \.self) { s in
                Text(verbatim: "Every \(Int(s)) s").tag(s)
            }
        } label: { EmptyView() }
        .pickerStyle(.menu)
        .controlSize(.small)
        .fixedSize()
        .help("How often Watch asks the device. Some devices refresh their counters only every few seconds, so short intervals can read unevenly.")
        let hasCounters = SNMPInterfaceWatch.hasCounters(rows)
        // The label says what a click will do; a pressed toggle alone is easy to miss.
        Toggle(isOn: watchBinding(rows)) {
            Label(watcher.isWatching ? "Stop Watching" : "Watch live",
                  systemImage: watcher.isWatching ? "stop.circle" : "waveform.path.ecg")
        }
        .toggleStyle(.button)
        .controlSize(.small)
        .fixedSize()
        // Stop always works, whatever the rows shown now.
        .disabled(!watcher.isWatching && (model.configs[.interfaces] == nil || !hasCounters))
        .help(watcher.isWatching
              ? "Stop asking the device for traffic counters"
              : (hasCounters
                 ? "Ask the device for these ports' traffic counters at each interval and show the rate. SNAP only reads, and asks only for the ports shown (up to \(SNMPInterfaceWatch.maxPorts))."
                 : Self.noCountersHelp(rows)))
    }

    static func noCountersHelp(_ rows: [SNMPInterfaceRow]) -> String {
        rows.count > SNMPInterfaceWatch.maxPorts
            ? "The device didn't report traffic counters for the first \(SNMPInterfaceWatch.maxPorts) ports shown, the ones Watch asks for, so there's nothing to watch."
            : "The device didn't report traffic counters for these ports, so there's nothing to watch."
    }

    private func watchBinding(_ rows: [SNMPInterfaceRow]) -> Binding<Bool> {
        Binding(
            get: { watcher.isWatching },
            set: { on in
                if on, let config = model.configs[.interfaces] {
                    watcher.start(config: config, rows: rows)
                } else {
                    watcher.stop()
                }
            }
        )
    }

    @ViewBuilder
    private func watchNotes(_ rows: [SNMPInterfaceRow]) -> some View {
        if rows.count > SNMPInterfaceWatch.maxPorts {
            SNMPNoteStrip(text: "Watching the first \(SNMPInterfaceWatch.maxPorts) of the \(rows.count) interfaces shown, by index."
                          + (SNMPInterfaces.physicalFilterApplies(report.rows) && !physicalOnly
                             ? " Turn on Physical ports only to narrow the list." : ""))
        }
        let risky = SNMPInterfaceWatch.wrapRisk(watcher.watchedRows, interval: watcher.interval)
        if let first = risky.first {
            let who = risky.count == 1 ? "\(first.displayName) counts" : "\(risky.count) ports count"
            SNMPNoteStrip(text: "\(who) traffic with 32-bit counters, which can start over more than once in \(Int(watcher.interval)) s at full speed, so the rate can read low. A shorter interval avoids this.")
        }
    }

    // MARK: Tables
    //
    // Column widths: SwiftUI's Table adds about 17 pt between columns and
    // doesn't shrink a column below its ideal width, so the ideals add up to
    // what fits a 650 pt pane with a scroll bar (476 pt in both tables).
    // Wider windows share out the extra space. Status fits "notPresent" and
    // "lower down" at 12 pt; Errors fits "99,999" at 11 pt monospaced, and
    // larger counts are compact ("123K"). Changed fits "Unchanged" and
    // "59 min ago". The ifIndex is in the Port tooltip, the selected port's
    // details, and the export.

    static let statusWidth: CGFloat = 66
    static let errorsWidth: CGFloat = 46

    private func staticTable(_ rows: [SNMPInterfaceRow]) -> some View {
        Table(rows.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Port", value: \.displayName) { r in SNMPPortNameCell(row: r) }
                .width(min: 50, ideal: 66)
            TableColumn("Label", value: \.alias) { r in SNMPAliasCell(alias: r.alias) }
                .width(min: 40, ideal: 56)
            TableColumn("Status", value: \.operStatus) { r in SNMPStatusCell(status: r.operStatus) }
                .width(min: 40, ideal: Self.statusWidth)
            TableColumn("Speed", value: \.speedSort) { r in SNMPSpeedCell(row: r) }
                .width(min: 44, ideal: 58)
            TableColumn("Errors", value: \.errorTotal) { r in SNMPErrorsCell(row: r) }
                .width(min: 34, ideal: Self.errorsWidth)
            TableColumn("Changed", value: \.changeSortKey) { r in
                SNMPChangeCell(change: r.lastChange, status: r.operStatus)
            }
            .width(min: 50, ideal: 64)
            TableColumn("Total in", value: \.inOctets) { r in
                SNMPTotalCell(bytes: r.inOctets, width: r.inWidth, outbound: false)
            }
            .width(min: 50, ideal: 60)
            TableColumn("Total out", value: \.outOctets) { r in
                SNMPTotalCell(bytes: r.outOctets, width: r.outWidth, outbound: true)
            }
            .width(min: 50, ideal: 60)
        }
    }

    /// While watching: live columns in place of Changed, Errors, and the
    /// totals, so it still fits a narrow window. The selected port's details
    /// still show its errors.
    private func liveTable(_ rows: [SNMPInterfaceRow]) -> some View {
        let liveRows = rows.map { r in
            SNMPLiveRow(row: r, live: watcher.live[r.id], watched: watcher.watchedIDs.contains(r.id))
        }
        return Table(liveRows.sorted(using: liveSortOrder), selection: $selection, sortOrder: $liveSortOrder) {
            TableColumn("Port", value: \.name) { l in SNMPPortNameCell(row: l.row) }
                .width(min: 50, ideal: 66)
            TableColumn("Label", value: \.alias) { l in SNMPAliasCell(alias: l.alias) }
                .width(min: 40, ideal: 50)
            TableColumn("Status", value: \.status) { l in SNMPStatusCell(status: l.status) }
                .width(min: 40, ideal: Self.statusWidth)
            TableColumn("Speed", value: \.speedSort) { l in SNMPSpeedCell(row: l.row) }
                .width(min: 44, ideal: 56)
            TableColumn("In now", value: \.inSort) { l in
                SNMPRateCell(bps: l.live?.inBps, gap: l.live?.inGap, watched: l.watched, color: NS.green)
            }
            .width(min: 50, ideal: 64)
            TableColumn("Out now", value: \.outSort) { l in
                SNMPRateCell(bps: l.live?.outBps, gap: l.live?.outGap, watched: l.watched, color: NS.blue)
            }
            .width(min: 50, ideal: 64)
            TableColumn("% of link", value: \.percentSort) { l in SNMPPercentCell(live: l) }
                .width(min: 40, ideal: 58)
            TableColumn("Trend") { l in SNMPTrendCell(history: l.live?.history ?? []) }
                .width(min: 36, ideal: 52)
        }
    }

    static func noteText(_ note: SNMPWalkNote) -> String {
        switch note {
        case .limit(let n):          return "Some columns stopped at the row limit (\(n.formatted())), so this list may be incomplete. Raise the limit in Options."
        case .notIncreasing:         return "The device sent an OID out of order, so SNAP stopped reading one column early. This list may be incomplete."
        case .error(_, let label):   return "The device returned an error (\(label)) partway through, so this list may be incomplete."
        case .nothing:               return ""
        }
    }

    nonisolated static func unreadText(_ unread: [String]) -> String {
        let list: String
        switch unread.count {
        case 1:  list = unread[0]
        case 2:  list = "\(unread[0]) and \(unread[1])"
        default: list = unread.dropLast().joined(separator: ", ") + ", and " + (unread.last ?? "")
        }
        return "The device stopped answering, or sent a reply SNAP couldn't read, before SNAP read every column. Not read: \(list). Try again, or raise the timeout in Options."
    }
}

/// A table row while watching: the port plus its live rates.
private struct SNMPLiveRow: Identifiable {
    let row: SNMPInterfaceRow
    let live: SNMPPortLive?
    let watched: Bool

    var id: UInt32 { row.id }
    var name: String { row.displayName }
    var alias: String { row.alias }
    var status: String { row.operStatus }
    var speedSort: UInt64 { row.speedSort }
    var inSort: Double { live?.inBps ?? -1 }
    var outSort: Double { live?.outBps ?? -1 }
    var percent: Double? {
        SNMPInterfaceFormat.linkPercent(inBps: live?.inBps, outBps: live?.outBps, speedBps: row.speedRaw)
    }
    var percentSort: Double { percent ?? -1 }
}

// MARK: - Cells

private struct SNMPPortNameCell: View {
    let row: SNMPInterfaceRow
    var body: some View {
        Text(row.displayName)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(NS.text1)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(SNMPInterfaceFormat.detailLine(row))
    }
}

private struct SNMPAliasCell: View {
    let alias: String
    var body: some View {
        Text(alias)
            .font(.system(size: 12))
            .foregroundStyle(NS.text2)
            .lineLimit(1)
            .help(alias.isEmpty ? "No label set on the device (ifAlias)" : alias)
    }
}

private struct SNMPStatusCell: View {
    let status: String
    var body: some View {
        Text(SNMPInterfaceFormat.statusShort(status))
            .font(.system(size: 12))
            .foregroundStyle(status == "up" ? NS.green : (status == "down" ? NS.red : NS.text3))
            .lineLimit(1)
            .help(SNMPInterfaceFormat.statusHelp(status))
    }
}

private struct SNMPSpeedCell: View {
    let row: SNMPInterfaceRow
    var body: some View {
        Text(row.speedAtCeiling ? SNMPInterfaceFormat.ceilingSpeedShort : (row.speedRaw == 0 ? "" : row.speed))
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(NS.text2)
            .help(row.speedAtCeiling ? SNMPInterfaceFormat.ceilingSpeedHelp
                  : (row.speedRaw == 0 ? "The device reports no speed for this interface" : ""))
    }
}

private struct SNMPErrorsCell: View {
    let row: SNMPInterfaceRow
    var body: some View {
        if row.hasErrorCounts {
            Text(verbatim: SNMPInterfaceFormat.compactCount(row.errorTotal))
                .lineLimit(1)
                .font(.system(size: 11, weight: row.errorTotal > 0 ? .semibold : .regular, design: .monospaced))
                .foregroundStyle(row.errorTotal > 0 ? NS.amber : NS.text3)
                .help(SNMPInterfaceFormat.errorHelp(row))
        } else {
            Text(verbatim: "")
                .help("The device doesn't report error counters for this port")
        }
    }
}

/// Relative to now, refreshed every few seconds.
private struct SNMPChangeCell: View {
    let change: SNMPPortChange?
    let status: String
    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { ctx in
            Text(SNMPInterfaceFormat.changeText(change, now: ctx.date))
                .font(.system(size: 11))
                .foregroundStyle(NS.text2)
                .lineLimit(1)
                .help(SNMPInterfaceFormat.changeHelp(change, status: status, now: ctx.date))
        }
    }
}

private struct SNMPTotalCell: View {
    let bytes: UInt64
    let width: SNMPCounterWidth?
    let outbound: Bool
    var body: some View {
        if let width {
            Text(verbatim: SNMPFormat.bytes(bytes) + (width == .bits64 ? "" : "*"))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(NS.text2)
                .help(width == .bits64
                      ? "Bytes \(outbound ? "sent" : "received") since the device's counter last reset, usually at its last restart"
                      : SNMPInterfaceFormat.counter32Help)
        } else {
            Text(verbatim: "").help("The device didn't report this counter")
        }
    }
}

private struct SNMPRateCell: View {
    let bps: Double?
    let gap: SNMPCounterGap?
    let watched: Bool
    let color: Color
    var body: some View {
        if !watched {
            Text(verbatim: "")
                .help("Not watched: Watch asks for at most \(SNMPInterfaceWatch.maxPorts) ports")
        } else if let bps {
            Text(verbatim: SNMPFormat.rate(bps))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(color)
        } else if case .error(let label)? = gap {
            Text(verbatim: "error")
                .font(.system(size: 11))
                .foregroundStyle(NS.amber)
                .help("The device returned an error (\(label)) for this counter at the last reading. SNAP keeps asking.")
        } else if gap == .notReported {
            Text(verbatim: "n/a")
                .font(.system(size: 11))
                .foregroundStyle(NS.text3)
                .help("The device isn't reporting this counter, so there's no rate to show")
        } else {
            Text(verbatim: "\u{2026}")
                .foregroundStyle(NS.text3)
                .help("Waiting for a reading. A rate needs two readings in a row.")
        }
    }
}

private struct SNMPPercentCell: View {
    let live: SNMPLiveRow
    var body: some View {
        let p = live.percent
        Text(verbatim: SNMPInterfaceFormat.percentText(p))
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle((p ?? 0) >= 90 ? NS.red : ((p ?? 0) >= 70 ? NS.amber : NS.text2))
            .help(live.row.speedAtCeiling
                  ? "The device reports only that this port is faster than 4.29 Gbps, so there's no share to show"
                  : live.row.speedRaw == 0
                  ? "The device reports no speed for this port, so there's no share to show"
                  : "The busier direction as a share of the port speed (\(live.row.speed)). Each direction has the full speed.")
    }
}

/// The busier direction for each reading, scaled to its own peak.
private struct SNMPTrendCell: View {
    let history: [SNMPRateSample]
    var body: some View {
        let values = history.compactMap { s in [s.inBps, s.outBps].compactMap { $0 }.max() }
        MiniSparkline(values: values, color: NS.blue)
            .frame(height: 16)
            .help("The busier direction for each reading, scaled to this port's peak")
    }
}

// MARK: - Selected port

private struct SNMPPortDetail: View {
    let row: SNMPInterfaceRow
    let config: SNMPClientConfig?
    let watching: Bool
    let watched: Bool
    let live: SNMPPortLive?
    let interval: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(row.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(NS.text1)
                            .lineLimit(1)
                        if !row.alias.isEmpty {
                            Text(row.alias)
                                .font(.system(size: 12))
                                .foregroundStyle(NS.text2)
                                .lineLimit(1)
                        }
                    }
                    Text(verbatim: SNMPInterfaceFormat.detailLine(row))
                        .font(.system(size: 11))
                        .foregroundStyle(NS.text3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 8)
                if let config {
                    SNMPPinButton(config: config,
                                  target: SNMPBoardTarget(host: config.host, port: config.port,
                                                          version: config.version.rawValue,
                                                          deviceName: nil,
                                                          ifIndex: row.id,
                                                          portName: row.displayName,
                                                          speedBps: row.speedRaw > 0 ? row.speedRaw : nil))
                }
            }
            if !watching {
                hint("Turn on Watch live to chart this port's traffic.")
            } else if !watched {
                hint("This port isn't watched: Watch asks for the first \(SNMPInterfaceWatch.maxPorts) ports shown, by index.")
            } else if let live, !live.history.isEmpty {
                SNMPPortTrafficChart(samples: live.history, speedBps: row.speedRaw)
            } else if let live, live.noCounters {
                hint(SNMPInterfaceWatch.noCountersHint(live))
            } else {
                hint("The chart starts after two readings, \(Int(interval)) s apart.")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NS.bg2)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(NS.text3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// In and out for each reading, with the port speed as a dashed line when
/// it's on the same scale (like Speed Test's per-second iPerf3 chart).
private struct SNMPPortTrafficChart: View {
    let samples: [SNMPRateSample]
    let speedBps: UInt64

    private struct Bar: Identifiable {
        let id: String
        let slot: String
        let direction: String
        let value: Double
    }

    private static let slots = SNMPInterfaceWatch.historyLength
    private var recent: [SNMPRateSample] { Array(samples.suffix(Self.slots)) }

    private var peak: Double {
        recent.map { max($0.inBps ?? 0, $0.outBps ?? 0) }.max() ?? 0
    }
    private var linkBps: Double? { speedBps > 0 ? Double(speedBps) : nil }
    /// The speed line, when it fits the bars' scale (at most twice the busiest reading).
    private var ruleBps: Double? {
        guard let l = linkBps, peak > 0, l <= 2 * peak else { return nil }
        return l
    }
    private var scale: (divisor: Double, unit: String) {
        let top = max(peak, ruleBps ?? 0)
        if top >= 1e9 { return (1e9, "Gbps") }
        if top >= 1e6 { return (1e6, "Mbps") }
        return (1e3, "kbps")
    }
    private var slotLabels: [String] { (0..<Self.slots).map { "s\($0)" } }
    private var bars: [Bar] {
        let offset = Self.slots - recent.count
        let d = scale.divisor
        var out: [Bar] = []
        for (i, s) in recent.enumerated() {
            let slot = "s\(offset + i)"
            if let v = s.inBps { out.append(Bar(id: "\(s.id)i", slot: slot, direction: "In", value: v / d)) }
            if let v = s.outBps { out.append(Bar(id: "\(s.id)o", slot: slot, direction: "Out", value: v / d)) }
        }
        return out
    }
    private var inColor: Color { NS.inkCues && !NS.inkColors ? NS.text1 : NS.green }
    private var outColor: Color { NS.inkCues && !NS.inkColors ? NS.text3 : NS.blue }
    private var speedName: String { "Port speed \(SNMPInterfaceFormat.formatSpeed(speedBps))" }

    var body: some View {
        GroupBox {
            Chart {
                ForEach(bars) { b in
                    BarMark(x: .value("Reading", b.slot), y: .value(scale.unit, b.value))
                        .foregroundStyle(by: .value("Direction", b.direction))
                        .position(by: .value("Direction", b.direction))
                }
                if let l = ruleBps {
                    RuleMark(y: .value("Speed", l / scale.divisor))
                        .foregroundStyle(NS.text3)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        .annotation(position: .top, alignment: .leading) {
                            Text(speedName).font(.caption2).foregroundStyle(NS.text3)
                        }
                }
            }
            .chartForegroundStyleScale(["In": inColor, "Out": outColor])
            .chartXScale(domain: slotLabels)
            .chartXAxis(.hidden)
            .chartYAxisLabel(scale.unit)
            .chartYAxis { AxisMarks { AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4, 4])); AxisValueLabel() } }
            .chartLegend(position: .top, alignment: .trailing)
            .frame(height: 140).padding(.top, 4)
        } label: {
            HStack {
                Label(recent.count == 1 ? "Last reading" : "Last \(recent.count) readings, oldest on the left",
                      systemImage: "chart.bar")
                    .font(.caption.bold())
                Spacer()
                if linkBps != nil && ruleBps == nil {
                    Text(verbatim: "\(speedName), above this scale").font(.caption2).foregroundStyle(NS.text3)
                }
            }
        }
    }
}
