// SNMPNeighbors.swift
// SNAP — SNMP Neighbors view: what's plugged into each port (LLDP, CDP)
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md
//
// Where the answers come from:
//
//   • LLDP-MIB (IEEE 802.1AB). lldpRemTable has one row per neighbor,
//     indexed (timeMark, localPortNum, remIndex). lldpLocPortTable names this
//     device's ports by localPortNum. lldpRemManAddrTable holds each
//     neighbor's management address, and the address itself is part of the
//     row index, not a value.
//
//   • CISCO-CDP-MIB. cdpCacheTable is indexed (ifIndex, deviceIndex), so its
//     local port is an ordinary interface.
//
// A neighbor that shows up in both on the same port is listed once, with
// LLDP's fields and CDP's platform. A device without either MIB has no
// neighbors to show; that isn't an error.

import SwiftUI

// CONTRACT (used by SNMPView.swift; keep these names and signatures):
//   struct SNMPNeighborReport: Equatable
//   enum SNMPNeighbors {
//     static func query(_ client: SNMPClient, maxRows: Int) async throws -> SNMPNeighborReport
//     static func summary(_ r: SNMPNeighborReport) -> String
//     static func exportText(_ r: SNMPNeighborReport) -> String
//   }
//   struct SNMPNeighborsPane: View { init(model: SNMPQueryModel, report: SNMPNeighborReport) }
// To hop to a neighbor: model.hop(to:) switches the host (keeping the community
// and options) and runs the current view again.

// MARK: - Model

/// What a neighbor says it is, from its LLDP or CDP capabilities.
enum SNMPNeighborKind: String, Hashable {
    case phone         = "Phone"
    case accessPoint   = "Access point"
    case networkSwitch = "Switch"
    case bridge        = "Bridge"
    case router        = "Router"
    case cableModem    = "Cable modem"
    case repeater      = "Repeater"
    case station       = "Station"
    case other         = "Other"
    case unknown       = ""

    /// Passes other devices' traffic along, so an address learned on the
    /// port it's plugged into can belong to something behind it.
    var forwards: Bool {
        switch self {
        case .networkSwitch, .bridge, .accessPoint, .repeater: return true
        default: return false
        }
    }

    var icon: String {
        switch self {
        case .phone:                 return "phone.connection"
        case .accessPoint:           return "wifi"
        case .networkSwitch, .bridge: return "rectangle.connected.to.line.below"
        case .router:                return "wifi.router"
        case .cableModem:            return "cable.connector"
        case .repeater:              return "dot.radiowaves.left.and.right"
        case .station:               return "desktopcomputer"
        case .other, .unknown:       return "questionmark.circle"
        }
    }
}

/// One device seen on one of this device's ports.
struct SNMPNeighbor: Identifiable, Hashable {
    enum Source: String, Hashable { case lldp = "LLDP", cdp = "CDP" }

    var id: String
    var sources: [Source]
    /// LLDP's local port number, or the ifIndex for CDP.
    var localPortNum: UInt32
    /// This device's port, as its admins name it ("Gi1/0/14").
    var localPort: String
    /// The port's description (ifAlias), when someone set one.
    var localPortLabel: String?
    var ifIndex: UInt32?
    /// Lowercased names that identify the local port, for matching it to
    /// an interface (Where Is It?) or to the same neighbor in CDP.
    var localPortKeys: [String] = []
    var sysName: String?
    var chassisId: String?
    var remotePort: String?
    /// The other form of the remote port (its ID or its description), when different.
    var remotePortDetail: String?
    var sysDescr: String?
    var platform: String?
    var capabilities: [String] = []
    var kind: SNMPNeighborKind = .unknown
    /// IPv4 management address, when the neighbor shared one.
    var address: String?
    /// MAC addresses the neighbor gave as its chassis or port ID.
    var macs: [[UInt8]] = []

    var name: String { sysName ?? chassisId ?? "Unnamed device" }
}

struct SNMPNeighborReport: Equatable {
    var neighbors: [SNMPNeighbor] = []
    /// The device answered LLDP-MIB (it has neighbors, or its own LLDP data).
    var lldpShared = false
    /// The device answered CISCO-CDP-MIB.
    var cdpShared = false
    var note: SNMPWalkNote?

    /// Distinct local ports with a neighbor.
    var portCount: Int { Set(neighbors.map(\.localPort)).count }
}

// MARK: - Query

enum SNMPNeighbors {
    // LLDP-MIB (1.0.8802.1.1.2)
    static let lldpRemEntry     = OID([1,0,8802,1,1,2,1,4,1,1])
    static let lldpLocPortEntry = OID([1,0,8802,1,1,2,1,3,7,1])
    static let lldpRemManAddrEntry = OID([1,0,8802,1,1,2,1,4,2,1])
    static let lldpLocChassisId = OID([1,0,8802,1,1,2,1,3,2,0])
    // CISCO-CDP-MIB (1.3.6.1.4.1.9.9.23)
    static let cdpCacheEntry    = OID([1,3,6,1,4,1,9,9,23,1,2,1,1])
    static let cdpGlobalRun     = OID([1,3,6,1,4,1,9,9,23,1,3,1,0])
    // IF-MIB ifXTable
    static let ifName           = OID([1,3,6,1,2,1,31,1,1,1,1])
    static let ifAlias          = OID([1,3,6,1,2,1,31,1,1,1,18])

    static func query(_ client: SNMPClient, maxRows: Int) async throws -> SNMPNeighborReport {
        try await fetch(client, maxRows: maxRows, portNames: nil)
    }

    /// `portNames`: interface names by ifIndex to use instead of reading the
    /// whole interface table (Where Is It? passes just the ports it found).
    static func fetch(_ client: SNMPClient, maxRows: Int,
                      portNames: [UInt32: String]?) async throws -> SNMPNeighborReport {
        var report = SNMPNeighborReport()
        func column(_ oid: OID) async throws -> SNMPColumn {
            let c = try await optionalColumn(client, oid, maxRows: maxRows)
            report.note = report.note ?? walkNote(c)
            return c
        }
        func column(_ entry: OID, _ n: UInt32) async throws -> SNMPColumn {
            try await column(OID(entry.components + [n]))
        }

        // LLDP: chassis ID and port ID are mandatory, so two empty columns
        // mean no LLDP neighbors; skip the rest.
        let chassisId = try await column(lldpRemEntry, 5)
        let portId    = try await column(lldpRemEntry, 7)
        let lldpRows  = orderedUnion(chassisId.order, portId.order)
        var lldp = LLDPColumns(chassisId: chassisId, portId: portId)
        if !lldpRows.isEmpty {
            lldp.chassisSubtype = try await column(lldpRemEntry, 4)
            lldp.portSubtype    = try await column(lldpRemEntry, 6)
            lldp.portDesc       = try await column(lldpRemEntry, 8)
            lldp.sysName        = try await column(lldpRemEntry, 9)
            lldp.sysDesc        = try await column(lldpRemEntry, 10)
            lldp.capEnabled     = try await column(lldpRemEntry, 12)
            // Some devices leave the enabled map empty; fall back to what's supported.
            if lldpRows.contains(where: { lldpCapabilities(lldp.capEnabled[$0])?.labels.isEmpty ?? true }) {
                lldp.capSupported = try await column(lldpRemEntry, 11)
            }
            lldp.locSubtype = try await column(lldpLocPortEntry, 2)
            lldp.locId      = try await column(lldpLocPortEntry, 3)
            lldp.locDesc    = try await column(lldpLocPortEntry, 4)
            // One walk over the whole entry: its columns are all optional,
            // and the address we want is in the index of whichever is there.
            let man = try await optionalWalk(client, lldpRemManAddrEntry, maxRows: maxRows)
            report.note = report.note ?? walkNote(man)
            lldp.manAddrs = managementAddresses(man.rows, entry: lldpRemManAddrEntry)
        }

        // CDP: the device ID is always there when a row is.
        let cdpDevice = try await column(cdpCacheEntry, 6)
        var cdp = CDPColumns(deviceId: cdpDevice)
        if !cdpDevice.values.isEmpty {
            cdp.addressType  = try await column(cdpCacheEntry, 3)
            cdp.address      = try await column(cdpCacheEntry, 4)
            cdp.devicePort   = try await column(cdpCacheEntry, 7)
            cdp.platform     = try await column(cdpCacheEntry, 8)
            cdp.capabilities = try await column(cdpCacheEntry, 9)
        }

        report.lldpShared = !lldpRows.isEmpty
        report.cdpShared = !cdpDevice.values.isEmpty

        if lldpRows.isEmpty && cdpDevice.values.isEmpty {
            // Nothing to show. Find out whether the MIBs are there at all,
            // so the empty state can say which.
            let v = try await optionalGet(client, [lldpLocChassisId, cdpGlobalRun])
            report.lldpShared = v[lldpLocChassisId] != nil
            report.cdpShared = v[cdpGlobalRun] != nil
            return report
        }

        var names = portNames ?? [:]
        var aliases: [UInt32: String] = [:]
        if portNames == nil {
            do {
                names = try await SNMPInterfaces.names(client, maxRows: maxRows)
            } catch SNMPError.errorStatus(_, _, _) {
                names = [:]
            }
            for (i, v) in try await column(ifAlias).byIndex {
                if let s = v.string?.trimmingCharacters(in: .whitespaces), !s.isEmpty { aliases[i] = s }
            }
        }

        let fromLLDP = buildLLDP(lldp, rows: lldpRows, names: names, aliases: aliases)
        let fromCDP = buildCDP(cdp, names: names, aliases: aliases)
        report.neighbors = sorted(merge(fromLLDP, fromCDP))
        return report
    }

    // MARK: Building rows (pure, for tests)

    struct LLDPColumns {
        var chassisId = SNMPColumn(), portId = SNMPColumn()
        var chassisSubtype = SNMPColumn(), portSubtype = SNMPColumn(), portDesc = SNMPColumn()
        var sysName = SNMPColumn(), sysDesc = SNMPColumn()
        var capEnabled = SNMPColumn(), capSupported = SNMPColumn()
        var locSubtype = SNMPColumn(), locId = SNMPColumn(), locDesc = SNMPColumn()
        /// IPv4 management address by [localPortNum, remIndex].
        var manAddrs: [[UInt32]: String] = [:]
    }

    struct CDPColumns {
        var deviceId = SNMPColumn()
        var addressType = SNMPColumn(), address = SNMPColumn()
        var devicePort = SNMPColumn(), platform = SNMPColumn(), capabilities = SNMPColumn()
    }

    static func buildLLDP(_ c: LLDPColumns, rows: [[UInt32]], names: [UInt32: String],
                          aliases: [UInt32: String]) -> [SNMPNeighbor] {
        let byName = reverseNames(names)
        var out: [SNMPNeighbor] = []
        for idx in rows {
            guard idx.count >= 3 else { continue }
            let portNum = idx[1], remIndex = idx[2]

            // This device's port.
            let loc = [portNum]
            let locId = formatID(c.locId[loc], subtype: c.locSubtype[loc]?.int64, macSubtype: 3, addressSubtype: 4)
            let locDesc = text(c.locDesc[loc])
            var keys: [String] = []
            for k in [locId?.text, locDesc].compactMap({ $0?.lowercased() }) where !keys.contains(k) { keys.append(k) }
            var ifIndex = keys.lazy.compactMap { byName[$0] }.first
            if ifIndex == nil, locId == nil, locDesc == nil, names[portNum] != nil {
                // No lldpLocPortTable row: many agents number LLDP ports by ifIndex.
                ifIndex = portNum
            }
            let localPort = ifIndex.flatMap { names[$0] }
                ?? (c.locSubtype[loc]?.int64 == 5 ? locId?.text : nil)
                ?? locDesc ?? locId?.text ?? "Port \(portNum)"
            if let i = ifIndex, let n = names[i]?.lowercased(), !keys.contains(n) { keys.append(n) }

            // The neighbor.
            let chassis = formatID(c.chassisId[idx], subtype: c.chassisSubtype[idx]?.int64,
                                   macSubtype: 4, addressSubtype: 5)
            let port = formatID(c.portId[idx], subtype: c.portSubtype[idx]?.int64,
                                macSubtype: 3, addressSubtype: 4)
            let portDesc = text(c.portDesc[idx])
            // An interface-name port ID is what admins call the port; other
            // kinds (a MAC, a local number) read better as the description.
            let remotePort: String?
            let other: String?
            if c.portSubtype[idx]?.int64 == 5, let p = port?.text {
                remotePort = p; other = portDesc
            } else {
                remotePort = portDesc ?? port?.text; other = portDesc == nil ? nil : port?.text
            }
            let caps = nonEmpty(lldpCapabilities(c.capEnabled[idx])) ?? lldpCapabilities(c.capSupported[idx])

            var n = SNMPNeighbor(
                id: "lldp." + idx.map(String.init).joined(separator: "."),
                sources: [.lldp],
                localPortNum: portNum,
                localPort: localPort,
                localPortLabel: ifIndex.flatMap { i in aliases[i].flatMap { $0 == localPort ? nil : $0 } },
                ifIndex: ifIndex,
                localPortKeys: keys)
            n.sysName = text(c.sysName[idx])
            n.chassisId = chassis?.text
            n.remotePort = remotePort
            n.remotePortDetail = other == remotePort ? nil : other
            n.sysDescr = text(c.sysDesc[idx])
            n.capabilities = caps?.labels ?? []
            n.kind = caps?.kind ?? .unknown
            n.address = c.manAddrs[[portNum, remIndex]] ?? chassis?.ipv4
            n.macs = [chassis?.mac, port?.mac].compactMap { $0 }
            out.append(n)
        }
        return out
    }

    static func buildCDP(_ c: CDPColumns, names: [UInt32: String], aliases: [UInt32: String]) -> [SNMPNeighbor] {
        var out: [SNMPNeighbor] = []
        for idx in c.deviceId.order {
            guard idx.count >= 2 else { continue }
            let ifIndex = idx[0]
            let localPort = names[ifIndex] ?? "ifIndex \(ifIndex)"
            var n = SNMPNeighbor(
                id: "cdp." + idx.map(String.init).joined(separator: "."),
                sources: [.cdp],
                localPortNum: ifIndex,
                localPort: localPort,
                localPortLabel: aliases[ifIndex].flatMap { $0 == localPort ? nil : $0 },
                ifIndex: ifIndex,
                localPortKeys: names[ifIndex].map { [$0.lowercased()] } ?? [])
            n.sysName = text(c.deviceId[idx]) ?? c.deviceId[idx]?.bytes.map { hexID(Array($0)) }
            n.remotePort = text(c.devicePort[idx])
            n.platform = text(c.platform[idx])
            if c.addressType[idx]?.int64 == 1, let b = c.address[idx]?.bytes, b.count == 4 {
                n.address = Array(b).map(String.init).joined(separator: ".")
            }
            let caps = cdpCapabilities(c.capabilities[idx])
            n.capabilities = caps?.labels ?? []
            n.kind = caps?.kind ?? .unknown
            out.append(n)
        }
        return out
    }

    /// One row per neighbor per port: a CDP row for a neighbor LLDP already
    /// listed on the same port adds its platform (and fills gaps) instead.
    static func merge(_ lldp: [SNMPNeighbor], _ cdp: [SNMPNeighbor]) -> [SNMPNeighbor] {
        var out = lldp
        for c in cdp {
            guard let i = out.firstIndex(where: {
                $0.sources == [.lldp] && samePort($0, c) && sameDevice($0, c)
            }) else {
                out.append(c)
                continue
            }
            out[i].sources.append(.cdp)
            if out[i].platform == nil { out[i].platform = c.platform }
            if out[i].address == nil { out[i].address = c.address }
            if out[i].sysName == nil { out[i].sysName = c.sysName }
            if out[i].remotePort == nil { out[i].remotePort = c.remotePort }
            if out[i].kind == .unknown { out[i].kind = c.kind; out[i].capabilities = c.capabilities }
            if out[i].ifIndex == nil { out[i].ifIndex = c.ifIndex }
            if out[i].localPortLabel == nil { out[i].localPortLabel = c.localPortLabel }
        }
        return out
    }

    private static func samePort(_ a: SNMPNeighbor, _ b: SNMPNeighbor) -> Bool {
        if let x = a.ifIndex, x == b.ifIndex { return true }
        return !Set(a.localPortKeys).isDisjoint(with: b.localPortKeys)
    }

    private static func sameDevice(_ a: SNMPNeighbor, _ b: SNMPNeighbor) -> Bool {
        if let x = a.sysName.map(deviceKey), let y = b.sysName.map(deviceKey), !x.isEmpty, x == y { return true }
        if let x = a.address, x == b.address { return true }
        return false
    }

    /// "Core-SW2.example.com", "core-sw2(FOC1234X0YZ)" and "core-sw2" all
    /// name the same device.
    static func deviceKey(_ name: String) -> String {
        var s = name.lowercased()
        if let p = s.firstIndex(of: "(") { s = String(s[..<p]) }
        s = s.trimmingCharacters(in: .whitespaces)
        let looksLikeIP = !s.isEmpty && s.allSatisfy { $0.isNumber || $0 == "." }
        if !looksLikeIP, let dot = s.firstIndex(of: ".") { s = String(s[..<dot]) }
        return s
    }

    static func sorted(_ list: [SNMPNeighbor]) -> [SNMPNeighbor] {
        list.sorted {
            let c = $0.localPort.localizedStandardCompare($1.localPort)
            if c != .orderedSame { return c == .orderedAscending }
            if $0.localPortNum != $1.localPortNum { return $0.localPortNum < $1.localPortNum }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// True when this neighbor is on the given port. Used by Where Is It?
    /// LLDP-MIB says a bridge numbers its LLDP ports like its bridge ports,
    /// so with nothing better to go on, a matching bridge port counts.
    static func isOn(_ n: SNMPNeighbor, bridgePort: UInt32, ifIndex: UInt32?, portNames: [String]) -> Bool {
        if let i = ifIndex, n.ifIndex == i { return true }
        let keys = Set(portNames.map { $0.lowercased() })
        if !keys.isDisjoint(with: n.localPortKeys) { return true }
        return n.sources.first == .lldp && n.ifIndex == nil && n.localPortNum == bridgePort
    }

    // MARK: Decoding

    /// LLDP capability map (BITS, first octet, most significant bit first):
    /// other(0) repeater(1) bridge(2) wlanAccessPoint(3) router(4)
    /// telephone(5) docsisCableDevice(6) stationOnly(7).
    static func lldpCapabilities(_ v: SNMPValue?) -> (labels: [String], kind: SNMPNeighborKind)? {
        guard let d = v?.bytes, let first = d.first else { return nil }
        let names = ["Other", "Repeater", "Bridge", "Access point", "Router", "Phone", "Cable modem", "Station"]
        var labels: [String] = []
        for bit in 0..<8 where first & (UInt8(0x80) >> UInt8(bit)) != 0 { labels.append(names[bit]) }
        let kind: SNMPNeighborKind
        if first & 0x04 != 0      { kind = .phone }
        else if first & 0x10 != 0 { kind = .accessPoint }
        else if first & 0x20 != 0 { kind = .networkSwitch }
        else if first & 0x08 != 0 { kind = .router }
        else if first & 0x02 != 0 { kind = .cableModem }
        else if first & 0x40 != 0 { kind = .repeater }
        else if first & 0x01 != 0 { kind = .station }
        else if first & 0x80 != 0 { kind = .other }
        else                      { kind = .unknown }
        return (labels, kind)
    }

    /// CDP capabilities: the 32-bit field from the CDP packet, most
    /// significant byte first. router 0x01, transparent bridge 0x02,
    /// source-route bridge 0x04, switch 0x08, host 0x10, IGMP 0x20,
    /// repeater 0x40, phone 0x80. Some Cisco routers send router plus
    /// source-route bridge (a Token Ring feature), so that pair is a router.
    static func cdpCapabilities(_ v: SNMPValue?) -> (labels: [String], kind: SNMPNeighborKind)? {
        guard let d = v?.bytes, !d.isEmpty else { return nil }
        var bits: UInt32 = 0
        for b in d.suffix(4) { bits = (bits << 8) | UInt32(b) }
        let table: [(UInt32, String)] = [(0x01, "Router"), (0x02, "Bridge"), (0x04, "Source-route bridge"),
                                         (0x08, "Switch"), (0x10, "Host"), (0x20, "IGMP"),
                                         (0x40, "Repeater"), (0x80, "Phone")]
        let labels = table.filter { bits & $0.0 != 0 }.map(\.1)
        let router = bits & 0x01 != 0
        let kind: SNMPNeighborKind
        if bits & 0x80 != 0       { kind = .phone }
        else if bits & 0x08 != 0  { kind = .networkSwitch }
        else if bits & 0x02 != 0 || (bits & 0x04 != 0 && !router) { kind = .bridge }
        else if router            { kind = .router }
        else if bits & 0x40 != 0  { kind = .repeater }
        else if bits & 0x10 != 0  { kind = .station }
        else                      { kind = .unknown }
        return (labels, kind)
    }

    /// A chassis or port ID: a MAC, an address, or a name.
    /// LLDP chassis subtypes: macAddress 4, networkAddress 5.
    /// LLDP port subtypes: macAddress 3, networkAddress 4.
    static func formatID(_ v: SNMPValue?, subtype: Int64?, macSubtype: Int64,
                         addressSubtype: Int64) -> (text: String, mac: [UInt8]?, ipv4: String?)? {
        guard let d = v?.bytes, !d.isEmpty else { return nil }
        let b = Array(d)
        if subtype == macSubtype, b.count == 6 {
            return (SNMPWhereIs.formatMAC(b), b, nil)
        }
        if subtype == addressSubtype, b.count == 5, b[0] == 1 {    // IANA family 1 = IPv4
            let ip = b[1...].map(String.init).joined(separator: ".")
            return (ip, nil, ip)
        }
        if let s = SNMPValue.text(d)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            return (s, nil, nil)
        }
        if b.count == 6 { return (SNMPWhereIs.formatMAC(b), b, nil) }
        return (hexID(b), nil, nil)
    }

    /// lldpRemManAddrTable rows: the index is (timeMark, localPortNum,
    /// remIndex, addrSubtype, addrLen, address bytes...). Returns IPv4
    /// addresses by [localPortNum, remIndex], first one per neighbor.
    static func managementAddresses(_ rows: [SNMPVarBind], entry: OID) -> [[UInt32]: String] {
        var out: [[UInt32]: String] = [:]
        for vb in rows {
            // Skip the column number that follows the entry OID.
            let index = Array(vb.oid.components.dropFirst(entry.components.count + 1))
            guard let m = managementAddress(index), out[m.key] == nil else { continue }
            out[m.key] = m.ipv4
        }
        return out
    }

    /// Decodes one lldpRemManAddrTable index. The address is length-prefixed
    /// (an OCTET STRING index); some agents leave the length out.
    static func managementAddress(_ index: [UInt32]) -> (key: [UInt32], ipv4: String)? {
        guard index.count >= 8, index[3] == 1 else { return nil }   // subtype 1 = IPv4
        let rest = Array(index[4...])
        let octets: [UInt32]
        if rest.count == 5, rest[0] == 4 { octets = Array(rest[1...]) }
        else if rest.count == 4 { octets = rest }
        else { return nil }
        guard octets.allSatisfy({ $0 <= 255 }) else { return nil }
        return ([index[1], index[2]], octets.map(String.init).joined(separator: "."))
    }

    static func text(_ v: SNMPValue?) -> String? {
        guard let s = v?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    private static func hexID(_ b: [UInt8]) -> String {
        b.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    private static func nonEmpty(_ c: (labels: [String], kind: SNMPNeighborKind)?) -> (labels: [String], kind: SNMPNeighborKind)? {
        guard let c, !c.labels.isEmpty else { return nil }
        return c
    }

    /// Lowercased interface name to ifIndex, for names only one interface has.
    private static func reverseNames(_ names: [UInt32: String]) -> [String: UInt32] {
        var out: [String: UInt32] = [:]
        var taken: Set<String> = []
        for (i, n) in names {
            let k = n.lowercased()
            if taken.contains(k) { out[k] = nil; continue }
            taken.insert(k)
            out[k] = i
        }
        return out
    }

    private static func orderedUnion(_ a: [[UInt32]], _ b: [[UInt32]]) -> [[UInt32]] {
        var seen = Set(a)
        var out = a
        for i in b where !seen.contains(i) { seen.insert(i); out.append(i) }
        return out
    }

    // MARK: Reading helpers (shared with Where Is It?)

    /// A column the device may not have. An error status on the first
    /// request means it isn't there; timeouts still end the query.
    static func optionalColumn(_ client: SNMPClient, _ oid: OID, maxRows: Int) async throws -> SNMPColumn {
        do {
            return try await client.column(oid, maxReps: 30, maxRows: maxRows)
        } catch SNMPError.errorStatus(_, _, _) {
            return SNMPColumn()
        }
    }

    static func optionalWalk(_ client: SNMPClient, _ oid: OID, maxRows: Int) async throws -> SNMPWalk {
        do {
            return try await client.bulkWalk(oid, maxReps: 30, maxRows: maxRows)
        } catch SNMPError.errorStatus(_, _, _) {
            return SNMPWalk(rows: [], end: .complete)
        }
    }

    /// GET values the device may not have. Missing ones are left out.
    static func optionalGet(_ client: SNMPClient, _ oids: [OID]) async throws -> [OID: SNMPValue] {
        let vbs: [SNMPVarBind]
        do {
            vbs = try await client.getTolerant(oids)
        } catch SNMPError.errorStatus(_, _, _) {
            return [:]
        }
        var out: [OID: SNMPValue] = [:]
        for vb in vbs where !vb.value.isException && out[vb.oid] == nil { out[vb.oid] = vb.value }
        return out
    }

    static func walkNote(_ c: SNMPColumn) -> SNMPWalkNote? { walkNote(c.end, rows: c.order.count) }
    static func walkNote(_ w: SNMPWalk) -> SNMPWalkNote? { walkNote(w.end, rows: w.rows.count) }

    private static func walkNote(_ end: SNMPWalk.End, rows: Int) -> SNMPWalkNote? {
        switch end {
        case .complete:            return nil
        case .limit:               return .limit(rows)
        case .notIncreasing:       return .notIncreasing(rows)
        case .error(let c, let l): return .error(c, l)
        }
    }

    // MARK: Text

    static func summary(_ r: SNMPNeighborReport) -> String {
        let n = r.neighbors.count
        if n == 0 { return "No neighbors reported" }
        return "\(n) neighbor\(n == 1 ? "" : "s") found"
    }

    static func exportText(_ r: SNMPNeighborReport) -> String {
        if r.neighbors.isEmpty { return emptyDetail(r) + "\n" }
        var s = "Local port\tLabel\tNeighbor\tTheir port\tKind\tAddress\tPlatform\tChassis ID\tFrom\n"
        for n in r.neighbors {
            let cols = [n.localPort, n.localPortLabel ?? "", n.name, n.remotePort ?? "", n.kind.rawValue,
                        n.address ?? "", n.platform ?? "", n.chassisId ?? "",
                        n.sources.map(\.rawValue).joined(separator: ", ")]
            s += cols.joined(separator: "\t") + "\n"
        }
        if let note = r.note { s += "(" + noteText(note) + ")\n" }
        return s
    }

    static func emptyDetail(_ r: SNMPNeighborReport) -> String {
        if r.lldpShared || r.cdpShared {
            let mib = r.lldpShared && r.cdpShared ? "LLDP and CDP" : (r.lldpShared ? "LLDP" : "CDP")
            return "The device shares \(mib) over SNMP, but lists no neighbors. A port only shows a neighbor when the device on the other end sends LLDP or CDP, and many computers don't."
        }
        return "The device may not run LLDP or CDP, or may not share them over SNMP, which is common on home and small-office gear."
    }

    static func noteText(_ note: SNMPWalkNote) -> String {
        switch note {
        case .limit(let n):        return "Some tables stopped at the row limit (\(n.formatted())), so this list may be incomplete. Raise the limit in Options."
        case .notIncreasing:       return "The device sent an OID out of order, so SNAP stopped reading one table early. This list may be incomplete."
        case .error(_, let label): return "The device returned an error (\(label)) partway through, so this list may be incomplete."
        case .nothing:             return ""
        }
    }
}

// MARK: - View

struct SNMPNeighborsPane: View {
    @ObservedObject var model: SNMPQueryModel
    let report: SNMPNeighborReport

    var body: some View {
        VStack(spacing: 0) {
            if let note = report.note {
                SNMPNoteStrip(text: SNMPNeighbors.noteText(note))
            }
            if report.neighbors.isEmpty {
                ScrollView {
                    ToolNoteCard(icon: "point.3.connected.trianglepath.dotted", tint: .blue,
                                 headline: "No neighbors reported",
                                 detail: SNMPNeighbors.emptyDetail(report),
                                 notes: emptyNotes)
                        .frame(maxWidth: 640, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            } else {
                GeometryReader { geo in
                    let wide = geo.size.width >= 900
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                            Section {
                                ForEach(report.neighbors) { n in
                                    row(n, wide: wide)
                                    Divider().background(NS.border)
                                }
                            } header: {
                                header(wide: wide)
                            }
                        }
                    }
                }
            }
        }
    }

    private var emptyNotes: [String] {
        var notes: [String] = []
        if !report.lldpShared {
            notes.append("On a managed switch, LLDP is a setting, often both for the whole switch and for each port.")
        }
        notes.append("Try the switch or router this device connects to: it may list this device as its neighbor.")
        return notes
    }

    // MARK: Layout

    private enum W {
        static let local: CGFloat = 150, localNarrow: CGFloat = 112
        static let their: CGFloat = 150
        static let kind: CGFloat = 110, kindNarrow: CGFloat = 96
        static let address: CGFloat = 118
        static let query: CGFloat = 64
    }

    private func header(wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(NS.blue)
                Text(headline)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(NS.text1)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8)
            HStack(spacing: 12) {
                columnTitle("Local port").frame(width: wide ? W.local : W.localNarrow, alignment: .leading)
                columnTitle("Neighbor").frame(maxWidth: .infinity, alignment: .leading)
                if wide { columnTitle("Their port").frame(width: W.their, alignment: .leading) }
                columnTitle("Kind").frame(width: wide ? W.kind : W.kindNarrow, alignment: .leading)
                columnTitle("Address").frame(width: W.address, alignment: .leading)
                Color.clear.frame(width: W.query, height: 1)
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
            .background(NS.bg2)
            Divider().background(NS.border)
        }
        .background(NS.bg1)
    }

    private var headline: String {
        let n = report.neighbors.count, p = report.portCount
        let sources = Set(report.neighbors.flatMap(\.sources))
        let from = sources.count == 2 ? "LLDP and CDP" : (sources.first?.rawValue ?? "")
        return "\(n) neighbor\(n == 1 ? "" : "s") on \(p) port\(p == 1 ? "" : "s"), from \(from)"
    }

    private func columnTitle(_ s: String) -> some View {
        Text(s).font(.system(size: 11, weight: .semibold)).foregroundStyle(NS.text3)
    }

    private func row(_ n: SNMPNeighbor, wide: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: n.localPort)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(NS.text1)
                    .lineLimit(1).truncationMode(.middle)
                if let label = n.localPortLabel {
                    Text(verbatim: label).font(.system(size: 11)).foregroundStyle(NS.text3).lineLimit(1)
                }
            }
            .frame(width: wide ? W.local : W.localNarrow, alignment: .leading)
            .help(localHelp(n))

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: n.name)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(NS.text1)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                if !wide, let p = n.remotePort {
                    (Text("Their port: ").font(.system(size: 11))
                        + Text(verbatim: p).font(.system(size: 11, design: .monospaced)))
                        .foregroundStyle(NS.text2)
                        .lineLimit(1).truncationMode(.tail)
                }
                if let sub = subtitle(n) {
                    Text(verbatim: sub).font(.system(size: 11)).foregroundStyle(NS.text3).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(neighborHelp(n))

            if wide {
                Text(verbatim: n.remotePort ?? "")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(NS.text2)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(width: W.their, alignment: .leading)
                    .help(n.remotePortDetail.map { "Also sent as: \($0)" } ?? "")
            }

            Group {
                if n.kind == .unknown {
                    Color.clear.frame(height: 1)
                } else {
                    Label(n.kind.rawValue, systemImage: n.kind.icon)
                        .font(.system(size: 11)).foregroundStyle(NS.text2)
                        .lineLimit(1)
                }
            }
            .frame(width: wide ? W.kind : W.kindNarrow, alignment: .leading)
            .help(n.capabilities.isEmpty ? "The neighbor didn't say what it is" : "Says it is: " + n.capabilities.joined(separator: ", "))

            Group {
                if let ip = n.address {
                    Text(verbatim: ip)
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(NS.text1)
                        .lineLimit(1)
                        .hostMenu(ip)
                } else {
                    Text("Not shared").font(.system(size: 11)).foregroundStyle(NS.text3)
                        .help("The neighbor didn't share an IPv4 management address")
                }
            }
            .frame(width: W.address, alignment: .leading)

            Group {
                if let ip = n.address {
                    Button("Query") { model.hop(to: ip) }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(model.isRunning)
                        .help("Read \(n.name)'s neighbors at \(ip), with the same community and options")
                } else {
                    Color.clear.frame(height: 1)
                }
            }
            .frame(width: W.query, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    /// Platform, else the first line of the neighbor's description.
    private func subtitle(_ n: SNMPNeighbor) -> String? {
        if let p = n.platform { return p }
        guard let d = n.sysDescr else { return n.sysName == nil ? nil : n.chassisId }
        return d.split(whereSeparator: \.isNewline).first.map(String.init)
    }

    private func localHelp(_ n: SNMPNeighbor) -> String {
        var parts = ["This device's port \(n.localPort)"]
        if let i = n.ifIndex { parts.append("ifIndex \(i)") }
        if n.sources.contains(.lldp) && n.ifIndex != n.localPortNum { parts.append("LLDP port \(n.localPortNum)") }
        return parts.joined(separator: ", ")
    }

    private func neighborHelp(_ n: SNMPNeighbor) -> String {
        var lines: [String] = []
        if let c = n.chassisId, c != n.name { lines.append("Chassis ID: \(c)") }
        if let d = n.sysDescr { lines.append(d) }
        if let p = n.platform, p != n.sysDescr { lines.append("Platform: \(p)") }
        lines.append("Learned from " + n.sources.map(\.rawValue).joined(separator: " and "))
        return lines.joined(separator: "\n")
    }
}
