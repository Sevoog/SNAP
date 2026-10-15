// SNMPInventory.swift
// SNAP — SNMP Inventory view: models and serial numbers (ENTITY-MIB)
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md
//
// Reads the parts list a device keeps in ENTITY-MIB (RFC 6933,
// entPhysicalTable): chassis, stack members, modules, power supplies, fans,
// with their models, serial numbers, and hardware, firmware, and software
// versions. Devices without ENTITY-MIB often still say what they are in
// another MIB, so SNAP then asks for the printer serial (Printer-MIB), the
// UPS identity (UPS-MIB, plus APC's serial number), and a Synology NAS's
// model and serial. When none of those answer, the pane shows sysDescr and
// says the device doesn't report hardware details over SNMP.

import SwiftUI
import AppKit

// CONTRACT (used by SNMPView.swift; keep these names and signatures):
//   struct SNMPInventoryReport: Equatable
//   enum SNMPInventory {
//     static func query(_ client: SNMPClient, maxRows: Int) async throws -> SNMPInventoryReport
//     static func summary(_ r: SNMPInventoryReport) -> String
//     static func exportText(_ r: SNMPInventoryReport) -> String
//   }
//   struct SNMPInventoryPane: View { init(model: SNMPQueryModel, report: SNMPInventoryReport) }

// MARK: - Model

/// What an inventory row is. ENTITY-MIB rows take it from entPhysicalClass;
/// rows read from other MIBs say what the whole device is.
enum SNMPPartKind: Hashable {
    case stack, chassis, module, powerSupply, fan, cpu, battery, storageDrive
    case port, sensor, container, backplane, energyObject, other
    case printer, ups, nas, device

    /// entPhysicalClass: 1 other, 2 unknown, 3 chassis, 4 backplane,
    /// 5 container, 6 powerSupply, 7 fan, 8 sensor, 9 module, 10 port,
    /// 11 stack, 12 cpu, and (added in RFC 6933) 13 energyObject,
    /// 14 battery, 15 storageDrive. Anything else reads as "Other".
    static func entity(_ code: Int64?) -> SNMPPartKind {
        switch code {
        case 3?:  return .chassis
        case 4?:  return .backplane
        case 5?:  return .container
        case 6?:  return .powerSupply
        case 7?:  return .fan
        case 8?:  return .sensor
        case 9?:  return .module
        case 10?: return .port
        case 11?: return .stack
        case 12?: return .cpu
        case 13?: return .energyObject
        case 14?: return .battery
        case 15?: return .storageDrive
        default:  return .other
        }
    }

    var label: String {
        switch self {
        case .stack:        return "Stack"
        case .chassis:      return "Chassis"
        case .module:       return "Module"
        case .powerSupply:  return "Power supply"
        case .fan:          return "Fan"
        case .cpu:          return "CPU"
        case .battery:      return "Battery"
        case .storageDrive: return "Drive"
        case .port:         return "Port"
        case .sensor:       return "Sensor"
        case .container:    return "Container"
        case .backplane:    return "Backplane"
        case .energyObject: return "Energy object"
        case .other:        return "Other"
        case .printer:      return "Printer"
        case .ups:          return "UPS"
        case .nas:          return "NAS"
        case .device:       return "Device"
        }
    }

    var icon: String {
        switch self {
        case .stack:        return "square.stack.3d.up"
        case .chassis:      return "server.rack"
        case .module:       return "memorychip"
        case .powerSupply:  return "bolt"
        case .fan:          return "fanblades"
        case .cpu:          return "cpu"
        case .battery:      return "battery.100"
        case .storageDrive: return "internaldrive"
        case .port:         return "cable.connector"
        case .sensor:       return "thermometer"
        case .container:    return "square.dashed"
        case .backplane:    return "rectangle.split.3x1"
        case .energyObject: return "bolt.circle"
        case .other:        return "shippingbox"
        case .printer:      return "printer"
        case .ups:          return "minus.plus.batteryblock"
        case .nas:          return "externaldrive.connected.to.line.below"
        case .device:       return "shippingbox"
        }
    }

    /// Listed without "Show all": the parts people look up serial numbers
    /// for. Ports, sensors, containers (slots and bays), backplanes, and
    /// other entries only show when they carry a serial number.
    var isMainPart: Bool {
        switch self {
        case .port, .sensor, .container, .backplane, .energyObject, .other: return false
        default: return true
        }
    }

    /// Stacks, then chassis, sort ahead of their siblings.
    var sortRank: Int {
        switch self {
        case .stack:   return 0
        case .chassis: return 1
        default:       return 2
        }
    }
}

/// One part (or, without ENTITY-MIB, the whole device). Text fields are ""
/// when the device left them blank or doesn't have them.
struct SNMPInventoryItem: Identifiable, Hashable {
    let id: String
    var entityIndex: UInt32? = nil      // entPhysicalIndex
    var containedIn: UInt32? = nil      // entPhysicalContainedIn, nil for none
    /// Containing entries, nearest first (at most 16), for indenting.
    var ancestors: [UInt32] = []
    var kind: SNMPPartKind
    var name = ""
    var descr = ""
    var model = ""
    var serial = ""
    var manufacturer = ""
    var hardwareRev = ""
    var firmwareRev = ""
    var softwareRev = ""
    /// The MIB this row came from: "ENTITY-MIB", "Printer-MIB", ….
    var source: String

    var displayName: String {
        if !name.isEmpty { return name }
        if !descr.isEmpty { return descr }
        if let i = entityIndex { return "Entry \(i)" }
        return kind.label
    }

    /// The description, when it says more than the name and model already do.
    var detail: String? {
        guard !descr.isEmpty, descr != displayName, descr != model else { return nil }
        return descr
    }

    var shownByDefault: Bool { kind.isMainPart || !serial.isEmpty }
}

/// What the Inventory view shows for one query.
struct SNMPInventoryReport: Equatable {
    enum Source: Equatable {
        case entity        // ENTITY-MIB entPhysicalTable
        case otherMIBs     // no ENTITY-MIB: Printer-MIB, UPS-MIB, APC, Synology
        case systemOnly    // none of those: just sysDescr
    }
    var source: Source
    /// Every entry, parents before the parts they contain.
    var items: [SNMPInventoryItem]
    var note: SNMPWalkNote?

    /// What shows without "Show all". If the device lists nothing but
    /// ports, sensors, and the like, that's everything.
    var mainItems: [SNMPInventoryItem] {
        let main = items.filter(\.shownByDefault)
        return main.isEmpty ? items : main
    }
    var hiddenCount: Int { items.count - mainItems.count }
    var serialCount: Int { items.filter { !$0.serial.isEmpty }.count }
}

/// A row as the table draws it: indented under the parts it sits in.
struct SNMPInventoryDisplayRow: Identifiable, Hashable {
    let item: SNMPInventoryItem
    let depth: Int
    var id: String { item.id }
}

// MARK: - Query

enum SNMPInventory {
    // ENTITY-MIB (RFC 6933) entPhysicalTable columns: 1.3.6.1.2.1.47.1.1.1.1.<n>
    private static func ent(_ column: UInt32) -> OID { OID([1,3,6,1,2,1,47,1,1,1,1, column]) }
    static let entPhysicalDescr       = ent(2)
    static let entPhysicalContainedIn = ent(4)
    static let entPhysicalClass       = ent(5)
    static let entPhysicalName        = ent(7)
    static let entPhysicalHardwareRev = ent(8)
    static let entPhysicalFirmwareRev = ent(9)
    static let entPhysicalSoftwareRev = ent(10)
    static let entPhysicalSerialNum   = ent(11)
    static let entPhysicalMfgName     = ent(12)
    static let entPhysicalModelName   = ent(13)

    /// Printer-MIB (RFC 3805) prtGeneralSerialNumber, indexed by hrDeviceIndex.
    static let prtGeneralSerialNumber = OID([1,3,6,1,2,1,43,5,1,1,17])
    /// HOST-RESOURCES-MIB (RFC 2790) hrDeviceDescr: the printer's model text.
    static let hrDeviceDescr          = OID([1,3,6,1,2,1,25,3,2,1,3])

    /// UPS-MIB (RFC 1628) upsIdent group. It has no serial number field.
    static let upsIdentManufacturer         = OID([1,3,6,1,2,1,33,1,1,1,0])
    static let upsIdentModel                = OID([1,3,6,1,2,1,33,1,1,2,0])
    static let upsIdentUPSSoftwareVersion   = OID([1,3,6,1,2,1,33,1,1,3,0])
    static let upsIdentAgentSoftwareVersion = OID([1,3,6,1,2,1,33,1,1,4,0])
    static let upsIdentName                 = OID([1,3,6,1,2,1,33,1,1,5,0])

    /// APC PowerNet-MIB (enterprise 318), for the serial number UPS-MIB lacks.
    static let apcModel    = OID([1,3,6,1,4,1,318,1,1,1,1,1,1,0])   // upsBasicIdentModel
    static let apcFirmware = OID([1,3,6,1,4,1,318,1,1,1,1,2,1,0])   // upsAdvIdentFirmwareRevision
    static let apcSerial   = OID([1,3,6,1,4,1,318,1,1,1,1,2,3,0])   // upsAdvIdentSerialNumber

    /// SYNOLOGY-SYSTEM-MIB (enterprise 6574): modelName, serialNumber, version.
    static let synoModel   = OID([1,3,6,1,4,1,6574,1,5,1,0])
    static let synoSerial  = OID([1,3,6,1,4,1,6574,1,5,2,0])
    static let synoVersion = OID([1,3,6,1,4,1,6574,1,5,3,0])

    /// Printers list one hrDevice entry, rarely two; this bounds a strange agent.
    private static let maxPrinters = 16

    static func query(_ client: SNMPClient, maxRows: Int) async throws -> SNMPInventoryReport {
        var note: SNMPWalkNote?
        // entPhysicalClass first: every entry has one, so an empty column
        // means the device has no ENTITY-MIB and the other columns can wait.
        let classes = try await readColumn(client, entPhysicalClass, reps: 30, maxRows: maxRows, note: &note)
        guard !classes.isEmpty else {
            return try await otherMIBs(client, maxRows: maxRows, note: note)
        }
        // One column at a time: gentler on small agents than parallel walks.
        var c = EntityColumns(classes: classes)
        c.containedIn = try await readColumn(client, entPhysicalContainedIn, reps: 30, maxRows: maxRows, note: &note)
        c.name        = try await readColumn(client, entPhysicalName, reps: 20, maxRows: maxRows, note: &note)
        c.descr       = try await readColumn(client, entPhysicalDescr, reps: 15, maxRows: maxRows, note: &note)
        c.modelName   = try await readColumn(client, entPhysicalModelName, reps: 20, maxRows: maxRows, note: &note)
        c.serialNum   = try await readColumn(client, entPhysicalSerialNum, reps: 20, maxRows: maxRows, note: &note)
        c.mfgName     = try await readColumn(client, entPhysicalMfgName, reps: 20, maxRows: maxRows, note: &note)
        c.hardwareRev = try await readColumn(client, entPhysicalHardwareRev, reps: 20, maxRows: maxRows, note: &note)
        c.firmwareRev = try await readColumn(client, entPhysicalFirmwareRev, reps: 20, maxRows: maxRows, note: &note)
        c.softwareRev = try await readColumn(client, entPhysicalSoftwareRev, reps: 20, maxRows: maxRows, note: &note)
        return SNMPInventoryReport(source: .entity, items: entityItems(c), note: note)
    }

    /// One table column by single-number index. A column the device lacks
    /// comes back empty (an error status on the first request means the
    /// same); a walk cut short is noted. Timeouts still throw.
    private static func readColumn(_ client: SNMPClient, _ oid: OID, reps: Int, maxRows: Int,
                                   note: inout SNMPWalkNote?) async throws -> [UInt32: SNMPValue] {
        let col: SNMPColumn
        do {
            col = try await client.column(oid, maxReps: reps, maxRows: maxRows)
        } catch SNMPError.errorStatus(_, _, _) {
            return [:]
        }
        switch col.end {
        case .complete:             break
        case .limit:                note = note ?? .limit(maxRows)
        case .notIncreasing:        note = note ?? .notIncreasing(col.order.count)
        case .error(let c, let l):  note = note ?? .error(c, l)
        }
        return col.byIndex
    }

    /// GET that never fails over a missing or refused OID: those are left
    /// out. Timeouts still throw.
    private static func tolerantGet(_ client: SNMPClient, _ oids: [OID]) async throws -> [OID: SNMPValue] {
        var vbs: [SNMPVarBind] = []
        do {
            vbs = try await client.getTolerant(oids)
        } catch SNMPError.errorStatus(_, _, _) {
            // Some agents answer genErr when asked for OIDs they don't
            // know. Ask one at a time and skip the ones that fail.
            vbs = []
            for oid in oids {
                do { vbs += try await client.get([oid]) } catch SNMPError.errorStatus(_, _, _) {}
            }
        }
        var out: [OID: SNMPValue] = [:]
        for vb in vbs where !vb.value.isException && out[vb.oid] == nil {
            out[vb.oid] = vb.value
        }
        return out
    }

    // MARK: ENTITY-MIB

    /// The entPhysicalTable columns SNAP reads, by entPhysicalIndex.
    struct EntityColumns {
        var classes: [UInt32: SNMPValue] = [:]
        var containedIn: [UInt32: SNMPValue] = [:]
        var name: [UInt32: SNMPValue] = [:]
        var descr: [UInt32: SNMPValue] = [:]
        var modelName: [UInt32: SNMPValue] = [:]
        var serialNum: [UInt32: SNMPValue] = [:]
        var mfgName: [UInt32: SNMPValue] = [:]
        var hardwareRev: [UInt32: SNMPValue] = [:]
        var firmwareRev: [UInt32: SNMPValue] = [:]
        var softwareRev: [UInt32: SNMPValue] = [:]
    }

    /// Joins the columns into rows, each part after the part it sits in.
    static func entityItems(_ c: EntityColumns) -> [SNMPInventoryItem] {
        let ids = Set(c.classes.keys).union(c.descr.keys).union(c.name.keys).sorted()
        var parent: [UInt32: UInt32] = [:]
        var kinds: [UInt32: SNMPPartKind] = [:]
        for i in ids {
            kinds[i] = .entity(c.classes[i]?.int64)
            // 0 means "not inside anything"
            if let raw = c.containedIn[i]?.int64, raw > 0, let p = UInt32(exactly: raw) {
                parent[i] = p
            }
        }
        return treeOrder(ids, parent: parent, rank: kinds.mapValues(\.sortRank)).map { node in
            let i = node.id
            return SNMPInventoryItem(
                id: "e\(i)",
                entityIndex: i,
                containedIn: parent[i],
                ancestors: node.ancestors,
                kind: kinds[i] ?? .other,
                name: field(c.name[i]),
                descr: field(c.descr[i]),
                model: field(c.modelName[i]),
                serial: field(c.serialNum[i]),
                manufacturer: field(c.mfgName[i]),
                hardwareRev: field(c.hardwareRev[i]),
                firmwareRev: field(c.firmwareRev[i]),
                softwareRev: field(c.softwareRev[i]),
                source: "ENTITY-MIB")
        }
    }

    /// Parents before the parts they contain; siblings (and separate trees)
    /// as stacks, then chassis, then the rest, each by index. An entry whose
    /// parent is 0, itself, or not in the table starts its own tree, and a
    /// containment loop is cut where the walk first meets it.
    static func treeOrder(_ ids: [UInt32], parent: [UInt32: UInt32],
                          rank: [UInt32: Int]) -> [(id: UInt32, ancestors: [UInt32])] {
        let known = Set(ids)
        var children: [UInt32: [UInt32]] = [:]
        var roots: [UInt32] = []
        for i in ids {
            if let p = parent[i], p != i, known.contains(p) {
                children[p, default: []].append(i)
            } else {
                roots.append(i)
            }
        }
        func before(_ a: UInt32, _ b: UInt32) -> Bool {
            let ra = rank[a] ?? 2, rb = rank[b] ?? 2
            return ra != rb ? ra < rb : a < b
        }
        var out: [(id: UInt32, ancestors: [UInt32])] = []
        out.reserveCapacity(ids.count)
        var visited = Set<UInt32>()
        // Iterative depth-first walk: a long containment chain can't
        // overflow the stack.
        func visit(_ start: UInt32) {
            var pending: [(UInt32, [UInt32])] = [(start, [])]
            while let top = pending.popLast() {
                let (n, ancestors) = top
                guard visited.insert(n).inserted else { continue }
                out.append((id: n, ancestors: ancestors))
                let path = Array(([n] + ancestors).prefix(16))
                for k in (children[n] ?? []).sorted(by: before).reversed() where !visited.contains(k) {
                    pending.append((k, path))
                }
            }
        }
        for r in roots.sorted(by: before) { visit(r) }
        for i in ids.sorted() where !visited.contains(i) { visit(i) }   // loops with no way in
        return out
    }

    // MARK: Other MIBs

    private static func otherMIBs(_ client: SNMPClient, maxRows: Int,
                                  note: SNMPWalkNote?) async throws -> SNMPInventoryReport {
        var note = note
        let printerSerials = try await readColumn(client, prtGeneralSerialNumber, reps: 10,
                                                  maxRows: maxRows, note: &note)
        let printers = Array(printerSerials.keys.sorted().prefix(maxPrinters))

        var oids = [SNMPOID.sysDescr, SNMPOID.sysName,
                    upsIdentManufacturer, upsIdentModel, upsIdentUPSSoftwareVersion,
                    upsIdentAgentSoftwareVersion, upsIdentName,
                    apcModel, apcFirmware, apcSerial,
                    synoModel, synoSerial, synoVersion]
        oids += printers.map { OID(hrDeviceDescr.components + [$0]) }
        let v = try await tolerantGet(client, oids)
        func t(_ oid: OID) -> String { field(v[oid]) }
        let sysName = t(SNMPOID.sysName)

        var items: [SNMPInventoryItem] = []

        // Printer-MIB: one row per printer (hrDeviceIndex)
        for k in printers {
            let serial = field(printerSerials[k])
            let model = t(OID(hrDeviceDescr.components + [k]))
            guard !serial.isEmpty || !model.isEmpty else { continue }
            let name = printers.count > 1 ? "Printer \(k)" : (sysName.isEmpty ? "Printer" : sysName)
            items.append(SNMPInventoryItem(
                id: "printer-\(k)", kind: .printer, name: name, model: model, serial: serial,
                source: model.isEmpty ? "Printer-MIB" : "Printer-MIB, HOST-RESOURCES-MIB"))
        }

        // UPS-MIB, with APC's serial number and firmware when it has them
        let upsModel = t(upsIdentModel), upsMaker = t(upsIdentManufacturer)
        let apcModelName = t(apcModel), apcSerialNum = t(apcSerial), apcFW = t(apcFirmware)
        let fromUPSMIB = !upsModel.isEmpty || !upsMaker.isEmpty
        let fromAPC = !apcModelName.isEmpty || !apcSerialNum.isEmpty
        if fromUPSMIB || fromAPC {
            let upsName = t(upsIdentName)
            let agentSW = t(upsIdentAgentSoftwareVersion)
            items.append(SNMPInventoryItem(
                id: "ups", kind: .ups,
                name: !upsName.isEmpty ? upsName : (sysName.isEmpty ? "UPS" : sysName),
                descr: agentSW.isEmpty ? "" : "SNMP agent software \(agentSW)",
                model: upsModel.isEmpty ? apcModelName : upsModel,
                serial: apcSerialNum,
                manufacturer: upsMaker,
                firmwareRev: apcFW,
                softwareRev: t(upsIdentUPSSoftwareVersion),
                source: [fromUPSMIB ? "UPS-MIB" : nil, fromAPC ? "APC PowerNet-MIB" : nil]
                    .compactMap { $0 }.joined(separator: ", ")))
        }

        // Synology DSM
        let synoModelName = t(synoModel), synoSerialNum = t(synoSerial)
        if !synoModelName.isEmpty || !synoSerialNum.isEmpty {
            items.append(SNMPInventoryItem(
                id: "synology", kind: .nas, name: sysName.isEmpty ? "NAS" : sysName,
                model: synoModelName, serial: synoSerialNum, manufacturer: "Synology",
                softwareRev: t(synoVersion), source: "Synology MIB"))
        }

        if items.isEmpty {
            let device = SNMPInventoryItem(
                id: "device", kind: .device, name: sysName.isEmpty ? "Device" : sysName,
                descr: multiline(v[SNMPOID.sysDescr]), source: "sysDescr")
            return SNMPInventoryReport(source: .systemOnly, items: [device], note: note)
        }
        return SNMPInventoryReport(source: .otherMIBs, items: items, note: note)
    }

    // MARK: Values

    /// A text value on one line: blanks (spaces some devices pad serial
    /// numbers with, line breaks) collapsed, binary values dropped.
    static func field(_ v: SNMPValue?) -> String {
        guard let s = v?.string else { return "" }
        return s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// A text value that may span lines (sysDescr), trimmed.
    static func multiline(_ v: SNMPValue?) -> String {
        guard let s = v?.string else { return "" }
        return s.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: { $0 == "\t" || $0.isNewline }).joined(separator: " ")
    }

    // MARK: Views of a report

    /// Rows to draw, each indented by how many of the listed rows contain it.
    static func displayRows(_ r: SNMPInventoryReport, showAll: Bool) -> [SNMPInventoryDisplayRow] {
        let list = showAll ? r.items : r.mainItems
        let listed = Set(list.compactMap(\.entityIndex))
        return list.map { item in
            SNMPInventoryDisplayRow(item: item, depth: min(8, item.ancestors.filter(listed.contains).count))
        }
    }

    /// "Copy All Serials": one part per line, name, model, and serial
    /// separated by tabs so it pastes into a spreadsheet.
    static func serialList(_ r: SNMPInventoryReport) -> String {
        r.items.filter { !$0.serial.isEmpty }
            .map { [$0.displayName, $0.model, $0.serial].map(oneLine).joined(separator: "\t") }
            .joined(separator: "\n")
    }

    static func summary(_ r: SNMPInventoryReport) -> String {
        if r.source == .systemOnly { return "No hardware details reported" }
        let parts = r.mainItems.count, serials = r.serialCount
        let p = "\(parts) part\(parts == 1 ? "" : "s")"
        let s = serials == 0 ? "no serial numbers" : "\(serials) serial number\(serials == 1 ? "" : "s")"
        return "\(p), \(s)"
    }

    static func exportText(_ r: SNMPInventoryReport) -> String {
        var s: String
        switch r.source {
        case .entity:
            s = "Source: ENTITY-MIB (entPhysicalTable)\n"
        case .otherMIBs:
            s = "Source: this device has no ENTITY-MIB parts table; each row names the MIB it came from\n"
        case .systemOnly:
            s = "This device doesn't report models or serial numbers over SNMP: it has no ENTITY-MIB parts table, and SNAP found no model or serial number in the printer, UPS, APC, or Synology values it also asks for.\n"
        }
        s += summary(r) + "\n\n"
        s += "index\tname\tkind\tmodel\tserial\tmanufacturer\thardware\tfirmware\tsoftware\tdescription\tcontained in\tsource\n"
        for i in r.mainItems {
            let fields = [i.entityIndex.map { String($0) } ?? "", i.displayName, i.kind.label, i.model,
                          i.serial, i.manufacturer, i.hardwareRev, i.firmwareRev, i.softwareRev,
                          i.descr, i.containedIn.map { String($0) } ?? "", i.source]
            s += fields.map(oneLine).joined(separator: "\t") + "\n"
        }
        let hidden = r.hiddenCount
        if hidden > 0 {
            s += "(Left out: \(hidden) \(hidden == 1 ? "entry" : "entries") with no serial number, such as ports, sensors, and slots.)\n"
        }
        return s + SNMPQueryModel.exportNote(r.note)
    }
}

// MARK: - View

struct SNMPInventoryPane: View {
    @ObservedObject var model: SNMPQueryModel
    let report: SNMPInventoryReport
    @State private var showAll = false

    // Column widths. SwiftUI's Table doesn't shrink a column below its
    // ideal width (past that, the last columns run off the right edge). It
    // adds 17 pt beside each column and about 15 pt of insets at the ends,
    // and a scroll bar takes 17 pt more when the system shows scroll bars.
    // So each layout's ideals add up to what fits the narrowest pane it's
    // used in (`tableWidth`); wider panes share out the extra space.

    /// Part (with its kind), Model, Serial, Versions: fits a 650 pt pane.
    static let narrowIdeals: [CGFloat] = [185, 120, 145, 90]
    /// Name, Kind, Model, Serial, Versions: fits `wideLayoutWidth`.
    static let wideIdeals: [CGFloat] = [225, 100, 150, 170, 130]
    /// From this width Kind gets its own column; narrower, it's a line
    /// under the part's name.
    static let wideLayoutWidth: CGFloat = 900

    /// The pane width a table with these ideal column widths needs, with a
    /// scroll bar showing.
    static func tableWidth(_ ideals: [CGFloat]) -> CGFloat {
        ideals.reduce(0, +) + 17 * CGFloat(ideals.count) + 15 + 17
    }

    var body: some View {
        VStack(spacing: 0) {
            if let note = report.note {
                SNMPNoteStrip(text: Self.noteText(note))
            }
            if report.source == .systemOnly {
                systemOnly
            } else {
                if report.source == .otherMIBs {
                    SNMPNoteStrip(text: "This device doesn't list its parts in ENTITY-MIB, so SNAP read these details from other MIBs it answers. Each row names the MIB it came from.")
                } else if report.serialCount == 0 {
                    SNMPNoteStrip(text: "This device lists its parts but leaves every serial number blank over SNMP. Look for them on the device's labels or in its admin page.")
                }
                header
                Divider()
                GeometryReader { geo in
                    let rows = SNMPInventory.displayRows(report, showAll: showAll)
                    if geo.size.width >= Self.wideLayoutWidth {
                        wideTable(rows)
                    } else {
                        narrowTable(rows)
                    }
                }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                countLabel
                Spacer(minLength: 8)
                showAllToggle
                copyAllButton
            }
            VStack(alignment: .leading, spacing: 6) {
                countLabel
                HStack(spacing: 12) {
                    showAllToggle
                    Spacer(minLength: 0)
                    copyAllButton
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private var countLabel: some View {
        Text(SNMPInventory.summary(report) + (report.source == .entity ? ", from ENTITY-MIB" : ""))
            .font(.system(size: 11)).foregroundStyle(NS.text2)
            .fixedSize()
    }

    @ViewBuilder
    private var showAllToggle: some View {
        let hidden = report.hiddenCount
        if hidden > 0 {
            Toggle(isOn: $showAll) { Text("Show all (\(hidden) more)") }
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .fixedSize()
                .help("Also list ports, sensors, containers (slots and bays), backplanes, and other entries that have no serial number")
        }
    }

    private var copyAllButton: some View {
        SNMPInventoryCopyButton(title: "Copy All Serials",
                                help: "Copy every serial number, one part per line: name, model, and serial, separated by tabs",
                                text: { SNMPInventory.serialList(report) })
            .buttonStyle(.bordered).controlSize(.small)
            .fixedSize()
            .disabled(report.serialCount == 0)
    }

    // MARK: Tables

    private func wideTable(_ rows: [SNMPInventoryDisplayRow]) -> some View {
        let w = Self.wideIdeals
        return Table(rows) {
            TableColumn("Name") { r in nameCell(r, showKind: false) }
                .width(min: 150, ideal: w[0])
            TableColumn("Kind") { r in kindCell(r.item) }
                .width(min: 70, ideal: w[1])
            TableColumn("Model") { r in modelCell(r.item) }
                .width(min: 90, ideal: w[2])
            TableColumn("Serial") { r in serialCell(r.item) }
                .width(min: 110, ideal: w[3])
            TableColumn("Versions") { r in versionsCell(r.item) }
                .width(min: 70, ideal: w[4])
        }
    }

    private func narrowTable(_ rows: [SNMPInventoryDisplayRow]) -> some View {
        let w = Self.narrowIdeals
        return Table(rows) {
            TableColumn("Part") { r in nameCell(r, showKind: true) }
                .width(min: 140, ideal: w[0])
            TableColumn("Model") { r in modelCell(r.item) }
                .width(min: 80, ideal: w[1])
            TableColumn("Serial") { r in serialCell(r.item) }
                .width(min: 110, ideal: w[2])
            TableColumn("Versions") { r in versionsCell(r.item) }
                .width(min: 60, ideal: w[3])
        }
    }

    // MARK: Cells

    private func nameCell(_ r: SNMPInventoryDisplayRow, showKind: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: r.item.kind.icon)
                .font(.system(size: 11))
                .foregroundStyle(NS.text3)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(r.item.displayName)
                    .foregroundStyle(NS.text1)
                    .lineLimit(2)
                    .textSelection(.enabled)
                if showKind, Self.kindLine(r.item) != r.item.displayName {
                    Text(Self.kindLine(r.item))
                        .font(.caption).foregroundStyle(NS.text3)
                        .lineLimit(2)
                }
                if let d = r.item.detail {
                    Text(d)
                        .font(.caption).foregroundStyle(NS.text3)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.leading, CGFloat(r.depth) * 12)
        .help(Self.nameHelp(r.item))
    }

    private func kindCell(_ item: SNMPInventoryItem) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(item.kind.label).foregroundStyle(NS.text2)
            if item.source != "ENTITY-MIB" {
                Text(item.source)
                    .font(.caption).foregroundStyle(NS.text3)
                    .lineLimit(2)
            }
        }
        .help(Self.kindLine(item))
    }

    private func modelCell(_ item: SNMPInventoryItem) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            if !item.model.isEmpty {
                Text(item.model)
                    .foregroundStyle(NS.text1)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .help(item.model)
            }
            if !item.manufacturer.isEmpty {
                Text(item.manufacturer)
                    .font(.caption).foregroundStyle(NS.text3)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func serialCell(_ item: SNMPInventoryItem) -> some View {
        if item.serial.isEmpty {
            Text("None")
                .foregroundStyle(NS.text3)
                .help(Self.noSerialHelp(item))
        } else {
            HStack(spacing: 4) {
                Text(item.serial)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(NS.text1)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(item.serial)
                Spacer(minLength: 0)
                SNMPInventoryCopyButton(title: nil, help: "Copy this serial number",
                                        text: { item.serial })
                    .buttonStyle(.borderless)
            }
        }
    }

    private func versionsCell(_ item: SNMPInventoryItem) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Self.versionLines(item), id: \.self) { line in
                Text(line)
                    .font(.caption).foregroundStyle(NS.text2)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
        }
        .help(Self.versionsHelp(item))
    }

    // MARK: No hardware details

    private var systemOnly: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ToolNoteCard(
                    icon: "shippingbox", tint: NS.blue,
                    headline: "No hardware details from this device",
                    detail: "It answered, but it doesn't report models or serial numbers over SNMP. It has no ENTITY-MIB parts table, and SNAP found no model or serial number in the printer, UPS, APC, or Synology values it also asks for. The serial number is usually on a label on the device, or in its admin page.")
                if let item = report.items.first {
                    deviceRow(item)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    private func deviceRow(_ item: SNMPInventoryItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: item.kind.icon).foregroundStyle(NS.text3)
                Text(item.displayName)
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(NS.text1)
                    .textSelection(.enabled)
                if item.displayName != item.kind.label {
                    Text(item.kind.label).font(.caption).foregroundStyle(NS.text3)
                }
                Spacer(minLength: 0)
            }
            if item.descr.isEmpty {
                Text("It didn't send a description (sysDescr) either.")
                    .font(.system(size: 12)).foregroundStyle(NS.text3)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Description (sysDescr)")
                        .font(.caption).foregroundStyle(NS.text3)
                    Text(item.descr)
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(NS.text1)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Serial number: none reported")
                .font(.caption).foregroundStyle(NS.text3)
        }
        .padding(12)
        .frame(maxWidth: 640, alignment: .leading)
        .background(NS.bg2)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Text

    static func kindLine(_ item: SNMPInventoryItem) -> String {
        item.source == "ENTITY-MIB" ? item.kind.label : "\(item.kind.label), from \(item.source)"
    }

    /// "HW V02", "FW 1.0.3", "SW 17.9.4", leaving out the blank ones.
    nonisolated static func versionLines(_ item: SNMPInventoryItem) -> [String] {
        [("HW", item.hardwareRev), ("FW", item.firmwareRev), ("SW", item.softwareRev)]
            .filter { !$0.1.isEmpty }
            .map { "\($0.0) \($0.1)" }
    }

    /// The Versions tooltip: each version in full, on its own line, since
    /// the column may cut a long one short.
    nonisolated static func versionsHelp(_ item: SNMPInventoryItem) -> String {
        [("Hardware", item.hardwareRev), ("Firmware", item.firmwareRev), ("Software", item.softwareRev)]
            .filter { !$0.1.isEmpty }
            .map { "\($0.0): \($0.1)" }
            .joined(separator: "\n")
    }

    static func nameHelp(_ item: SNMPInventoryItem) -> String {
        var lines = [item.displayName]
        if let d = item.detail { lines.append(d) }
        if let i = item.entityIndex { lines.append("entPhysicalIndex \(i)") }
        return lines.joined(separator: "\n")
    }

    static func noSerialHelp(_ item: SNMPInventoryItem) -> String {
        switch item.kind {
        case .ups:
            return "UPS-MIB has no serial number field, and this UPS didn't report one in APC's PowerNet-MIB either."
        default:
            return "The device didn't report a serial number for this entry."
        }
    }

    static func noteText(_ note: SNMPWalkNote) -> String {
        switch note {
        case .limit(let n):         return "SNAP stopped at the row limit (\(n.formatted()) entries), so this list may be incomplete. Raise the limit in Options."
        case .notIncreasing:        return "The device sent an OID out of order, so SNAP stopped reading one column early. This list may be incomplete."
        case .error(_, let label):  return "The device returned an error (\(label)) partway through, so this list may be incomplete."
        case .nothing:              return ""
        }
    }
}

/// Copies text and shows a check mark for a moment. With a title it's a
/// labeled button ("Copy All Serials"); without, an icon for a table row.
private struct SNMPInventoryCopyButton: View {
    let title: String?
    let help: String
    let text: () -> String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text(), forType: .string)
            withAnimation { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                withAnimation { copied = false }
            }
        } label: {
            if let title {
                Label(copied ? "Copied" : title, systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
            } else {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(copied ? NS.green : NS.text3)
            }
        }
        .help(help)
        .accessibilityLabel(title ?? help)
    }
}
