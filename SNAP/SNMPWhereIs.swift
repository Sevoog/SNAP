// SNMPWhereIs.swift
// SNAP — SNMP "Where Is It?" view: find the switch port for an IP or MAC
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md
//
// How it looks:
//
//   1. An IP address needs a MAC first: the device's ARP table
//      (ipNetToPhysicalTable, then the older ipNetToMediaTable), then this
//      Mac's own ARP cache (arp -n).
//   2. The MAC to a bridge port: one GET of BRIDGE-MIB dot1dTpFdbPort for
//      that MAC, else a walk of Q-BRIDGE-MIB dot1qTpFdbPort (one table across
//      all VLANs), within the row limit.
//   3. The bridge port to an interface (dot1dBasePortIfIndex), and the
//      interface's name and description (ifName, ifAlias).
//   4. Whether that port leads to another switch: an LLDP or CDP neighbor
//      that forwards traffic, or many addresses learned on it. Then the pane
//      offers to ask that switch next.

import SwiftUI

// CONTRACT (used by SNMPView.swift; keep these names and signatures):
//   enum SNMPLocateQuery: Equatable { case ip(String), mac([UInt8]); static func parse(_:) -> SNMPLocateQuery?; var display: String }
//   struct SNMPLocateReport: Equatable
//   enum SNMPWhereIs {
//     static func query(_ client: SNMPClient, find: SNMPLocateQuery, maxRows: Int) async throws -> SNMPLocateReport
//     static func summary(_ r: SNMPLocateReport) -> String
//     static func exportText(_ r: SNMPLocateReport) -> String
//   }
//   struct SNMPWhereIsPane: View { init(model: SNMPQueryModel, report: SNMPLocateReport) }

/// What to look for: an IPv4 address or a MAC address.
enum SNMPLocateQuery: Equatable {
    case ip(String)
    case mac([UInt8])

    /// Accepts 192.168.1.20, or a MAC as aa:bb:cc:dd:ee:ff, aa-bb-cc-dd-ee-ff,
    /// aabb.ccdd.eeff (Cisco), aabbccddeeff, or 0:1a:2b:3:4:5 (as macOS's
    /// arp prints it, without leading zeros).
    static func parse(_ text: String) -> SNMPLocateQuery? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let octets = s.split(separator: ".", omittingEmptySubsequences: false)
        if octets.count == 4, octets.allSatisfy({ !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) {
            let values = octets.compactMap { Int($0) }
            guard values.count == 4, values.allSatisfy({ $0 <= 255 }) else { return nil }
            return .ip(values.map(String.init).joined(separator: "."))
        }
        return SNMPWhereIs.parseMAC(s).map { .mac($0) }
    }

    var display: String {
        switch self {
        case .ip(let a):  return a
        case .mac(let b): return SNMPWhereIs.formatMAC(b)
        }
    }
}

struct SNMPLocateReport: Equatable {
    enum MACSource: Equatable { case typed, deviceARP, thisMac }
    enum Table: Equatable { case bridge, qBridge }

    /// One switch port the address is learned on.
    struct Location: Equatable, Identifiable {
        var id: UInt32 { bridgePort }
        var bridgePort: UInt32
        var ifIndex: UInt32?
        var portName: String?
        /// The port's description (ifAlias), when someone set one.
        var portLabel: String?
        /// Lowercased ifName and ifDescr, to match LLDP and CDP neighbors.
        var portKeys: [String] = []
        /// VLANs confirmed through dot1qVlanCurrentTable.
        var vlans: [UInt32] = []
        /// Q-BRIDGE forwarding database numbers SNAP couldn't tie to one VLAN.
        var fdbIds: [UInt32] = []
        /// Addresses learned on this port, when SNAP walked the MAC table.
        var macsOnPort: Int?
        var neighbors: [SNMPNeighbor] = []

        /// "Gi1/0/14 (Front desk)", or "bridge port 14".
        var display: String {
            let name = portName ?? "bridge port \(bridgePort)"
            return portLabel.map { "\(name) (\($0))" } ?? name
        }
    }

    var query: SNMPLocateQuery
    var deviceName: String?
    var isCisco = false
    var mac: [UInt8]?
    var macSource: MACSource?
    var vendor: String?
    /// The IP was in the device's own ARP table.
    var ipInDeviceARP = false
    /// How the read of the device's ARP tables ended when the IP didn't
    /// turn up: .complete, or why it stopped early.
    var arpEnd: SNMPWalk.End = .complete
    /// The ARP tables stopped at the row limit before the IP turned up.
    var arpLimitHit: Bool { arpEnd == .limit }
    var table: Table?
    /// The device has a MAC address table with entries in it.
    var hasMACTable = false
    /// How the Q-BRIDGE MAC table walk ended: .complete, or why it stopped
    /// early (the row limit, an error, an entry out of order).
    var tableEnd: SNMPWalk.End = .complete
    /// SNAP read only part of the MAC table, for whatever reason.
    var tableCut: Bool { tableEnd != .complete }
    var tableLimitHit: Bool { tableEnd == .limit }
    var tableRowsRead = 0
    var vlanTableRead = false
    /// dot1dTpFdbStatus / dot1qTpFdbStatus: 1 other, 2 invalid, 3 learned, 4 self, 5 mgmt.
    var entryStatus: Int64?
    /// The device has the address, but with port 0: it doesn't know the port.
    var noPortLearned = false
    var locations: [Location] = []
    /// Reading the LLDP and CDP neighbors failed (a timeout, say), so the
    /// ports found have no neighbor information.
    var neighborsUnread = false

    init(query: SNMPLocateQuery) { self.query = query }
}

/// The one-line answer and what to do next. Computed from the report so
/// the pane, the status line, and the export say the same thing.
struct SNMPLocateVerdict: Equatable {
    enum Tone: Equatable { case found, behind, missing, problem }
    var tone: Tone
    var headline: String
    var detail: String
    var notes: [String] = []
    /// A switch further down the link, to ask next.
    var hop: SNMPNeighbor?
    /// Suggest pinging this address first.
    var pingAddress: String?
}

/// One line of the details box.
struct SNMPLocateDetail: Hashable {
    var label: String
    var value: String
    var mono = false
    var copyable = false
    /// An address to offer the host menu for.
    var host: String?
}

// MARK: - Query

enum SNMPWhereIs {
    static let ipNetToPhysicalPhysAddress = OID([1,3,6,1,2,1,4,35,1,4])
    static let ipNetToMediaPhysAddress    = OID([1,3,6,1,2,1,4,22,1,2])
    static let dot1dTpFdbPort       = OID([1,3,6,1,2,1,17,4,3,1,2])
    static let dot1dTpFdbStatus     = OID([1,3,6,1,2,1,17,4,3,1,3])
    static let dot1dBasePortIfIndex = OID([1,3,6,1,2,1,17,1,4,1,2])
    static let dot1qTpFdbPort       = OID([1,3,6,1,2,1,17,7,1,2,2,1,2])
    static let dot1qTpFdbStatus     = OID([1,3,6,1,2,1,17,7,1,2,2,1,3])
    static let dot1qVlanFdbId       = OID([1,3,6,1,2,1,17,7,1,4,2,1,3])
    static let ifAlias              = OID([1,3,6,1,2,1,31,1,1,1,18])
    static let ifName               = OID([1,3,6,1,2,1,31,1,1,1,1])
    private static let cisco        = OID([1,3,6,1,4,1,9])

    /// This many addresses learned on one port suggests it leads to another
    /// switch or an access point rather than to one device.
    static let manyAddresses = 5
    /// Forwarding databases to ask for the address directly when the MAC
    /// table walk stops early.
    static let maxDirectFdbLookups = 64

    static func query(_ client: SNMPClient, find: SNMPLocateQuery, maxRows: Int) async throws -> SNMPLocateReport {
        try await query(client, find: find, maxRows: maxRows, thisMac: macFromThisMac)
    }

    /// `thisMac` looks the IP up in this Mac's ARP cache (tests pass their own).
    static func query(_ client: SNMPClient, find: SNMPLocateQuery, maxRows: Int,
                      thisMac: (String) async -> [UInt8]?) async throws -> SNMPLocateReport {
        var r = SNMPLocateReport(query: find)
        let sys = try await SNMPNeighbors.optionalGet(client, [SNMPOID.sysObjectID, SNMPOID.sysName])
        if case .oid(let o)? = sys[SNMPOID.sysObjectID] { r.isCisco = cisco.isAncestorOrEqual(o) }
        r.deviceName = SNMPNeighbors.text(sys[SNMPOID.sysName])

        // 1. The MAC address.
        switch find {
        case .mac(let m):
            r.mac = m
            r.macSource = .typed
        case .ip(let ip):
            let arp = try await deviceARP(client, ip: ip, maxRows: maxRows)
            r.arpEnd = arp.end
            if let m = arp.mac {
                r.mac = m
                r.macSource = .deviceARP
                r.ipInDeviceARP = true
            } else if let m = await thisMac(ip) {
                r.mac = m
                r.macSource = .thisMac
            }
        }
        guard let mac = r.mac, mac.count == 6 else { return r }
        if !isMulticast(mac) && !isLocallyAdministered(mac) { r.vendor = OUIDatabase.lookup(formatMAC(mac)) }

        // 2. The MAC to bridge ports.
        let macIndex = mac.map(UInt32.init)
        var hits: [(port: UInt32, fdbId: UInt32?)] = []
        var perPort: [UInt32: Int]?
        var vlanMap: [UInt32: [UInt32]] = [:]
        let portOID = OID(dot1dTpFdbPort.components + macIndex)
        let statusOID = OID(dot1dTpFdbStatus.components + macIndex)
        let direct = try await SNMPNeighbors.optionalGet(client, [portOID, statusOID])
        if let p = direct[portOID]?.uint64 {
            // BRIDGE-MIB has it: one GET, no walk.
            r.table = .bridge
            r.hasMACTable = true
            r.entryStatus = direct[statusOID]?.int64
            hits.append((UInt32(clamping: p), nil))
        } else {
            // Q-BRIDGE-MIB: one table for all VLANs, indexed (fdbId, MAC).
            let q = try await SNMPNeighbors.optionalColumn(client, dot1qTpFdbPort, maxRows: maxRows)
            r.tableRowsRead = q.order.count
            r.tableEnd = q.end
            // Distinct addresses per port: a switch with a forwarding
            // database per VLAN lists one device once for each VLAN it's in.
            var macsByPort: [UInt32: Set<[UInt32]>] = [:]
            var seenFdbIds: [UInt32] = []
            for idx in q.order {
                guard idx.count == 7, let p = q.values[idx]?.uint64 else { continue }
                let port = UInt32(clamping: p)
                let macPart = Array(idx[1...])
                if port > 0 { macsByPort[port, default: []].insert(macPart) }
                if !seenFdbIds.contains(idx[0]) { seenFdbIds.append(idx[0]) }
                if macPart == macIndex { hits.append((port, idx[0])) }
            }
            if !q.values.isEmpty {
                r.table = .qBridge
                r.hasMACTable = true
                perPort = macsByPort.mapValues(\.count)
            }
            if hits.isEmpty && r.tableCut {
                // The walk stopped early: ask for the address directly in
                // the forwarding databases it didn't finish.
                vlanMap = try await vlans(client, maxRows: maxRows)
                r.vlanTableRead = !vlanMap.isEmpty
                let fdbIds = directLookupFdbIds(seen: seenFdbIds, known: Array(vlanMap.keys),
                                                outOfOrder: q.end == .notIncreasing)
                let oids = fdbIds.prefix(maxDirectFdbLookups).map { OID(dot1qTpFdbPort.components + [$0] + macIndex) }
                let found = try await getChunked(client, oids)
                for oid in oids {
                    guard let p = found[oid]?.uint64, let f = oid.components.dropLast(6).last else { continue }
                    hits.append((UInt32(clamping: p), f))
                }
            } else if !hits.isEmpty {
                vlanMap = try await vlans(client, maxRows: maxRows)
                r.vlanTableRead = !vlanMap.isEmpty
            }
            if let f = hits.first?.fdbId {
                let s = try await SNMPNeighbors.optionalGet(client, [OID(dot1qTpFdbStatus.components + [f] + macIndex)])
                r.entryStatus = s.values.first?.int64
            }
            if hits.isEmpty && !r.hasMACTable, try await hasRows(client, dot1dTpFdbPort) {
                // No Q-BRIDGE entries, but the plain BRIDGE-MIB table has some.
                r.table = .bridge
                r.hasMACTable = true
            }
        }
        r.locations = locations(from: hits, vlanMap: vlanMap, perPort: perPort)
        r.noPortLearned = !hits.isEmpty && r.locations.isEmpty
        guard !r.locations.isEmpty else { return r }

        // 3. Bridge ports to interfaces and their names.
        let ifOIDs = r.locations.map { OID(dot1dBasePortIfIndex.components + [$0.bridgePort]) }
        let ifValues = try await getChunked(client, ifOIDs)
        for i in r.locations.indices {
            if let v = ifValues[ifOIDs[i]]?.uint64, v > 0 { r.locations[i].ifIndex = UInt32(clamping: v) }
        }
        var nameOIDs: [OID] = []
        for loc in r.locations {
            guard let i = loc.ifIndex else { continue }
            nameOIDs += [OID(ifName.components + [i]), OID(SNMPOID.ifDescr.components + [i]), OID(ifAlias.components + [i])]
        }
        let names = try await getChunked(client, nameOIDs)
        var portNames: [UInt32: String] = [:]
        for i in r.locations.indices {
            guard let idx = r.locations[i].ifIndex else { continue }
            let name = SNMPNeighbors.text(names[OID(ifName.components + [idx])])
            let descr = SNMPNeighbors.text(names[OID(SNMPOID.ifDescr.components + [idx])])
            let alias = SNMPNeighbors.text(names[OID(ifAlias.components + [idx])])
            let display = name ?? descr
            r.locations[i].portName = display
            r.locations[i].portLabel = alias == display ? nil : alias
            r.locations[i].portKeys = [name, descr].compactMap { $0?.lowercased() }
            if let display { portNames[idx] = display }
        }

        // 4. Neighbors on those ports: is it a link to another switch?
        if r.entryStatus != 4 {
            do {
                let nb = try await SNMPNeighbors.fetch(client, maxRows: maxRows, portNames: portNames)
                for i in r.locations.indices {
                    let loc = r.locations[i]
                    r.locations[i].neighbors = nb.neighbors.filter {
                        SNMPNeighbors.isOn($0, bridgePort: loc.bridgePort, ifIndex: loc.ifIndex, portNames: loc.portKeys)
                    }
                }
            } catch {
                // Neighbors only sharpen the answer: keep the port found.
                // A stopped run still stops.
                if error is CancellationError { throw error }
                try Task.checkCancellation()
                r.neighborsUnread = true
            }
        }
        return r
    }

    /// Hits grouped by port, in the order found. Port 0 means the switch
    /// knows the address but not its port, so it isn't a location.
    private static func locations(from hits: [(port: UInt32, fdbId: UInt32?)],
                                  vlanMap: [UInt32: [UInt32]], perPort: [UInt32: Int]?) -> [SNMPLocateReport.Location] {
        var out: [SNMPLocateReport.Location] = []
        for h in hits where h.port > 0 {
            var i = out.firstIndex(where: { $0.bridgePort == h.port })
            if i == nil {
                out.append(SNMPLocateReport.Location(bridgePort: h.port, macsOnPort: perPort?[h.port]))
                i = out.count - 1
            }
            guard let at = i, let f = h.fdbId else { continue }
            if let v = vlanMap[f], v.count == 1, let vlan = v.first {
                if !out[at].vlans.contains(vlan) { out[at].vlans.append(vlan) }
            } else if !out[at].fdbIds.contains(f) {
                out[at].fdbIds.append(f)
            }
        }
        return out
    }

    /// Forwarding databases to ask for the address directly after the MAC
    /// table walk stopped early, most promising first. The walk goes in
    /// (fdbId, MAC) order, so it read every database it saw to the end
    /// except the last, and a known database below that one is empty (the
    /// walk passed over it). That leaves the last one, cut off partway, and
    /// the known ones after it. A walk that stopped on an entry out of
    /// order can't vouch for what it passed, so the rest follow it.
    static func directLookupFdbIds(seen: [UInt32], known: [UInt32], outOfOrder: Bool) -> [UInt32] {
        let sortedKnown = known.sorted()
        var out: [UInt32]
        if let last = seen.last {
            out = [last] + sortedKnown.filter { $0 > last }
        } else {
            out = sortedKnown
        }
        if outOfOrder {
            for f in sortedKnown where !out.contains(f) && !seen.contains(f) { out.append(f) }
            for f in seen.reversed() where !out.contains(f) { out.append(f) }
        }
        return out
    }

    /// Forwarding database number to VLAN IDs, from dot1qVlanCurrentTable
    /// (index timeMark, VLAN ID; value dot1qVlanFdbId).
    static func vlans(_ client: SNMPClient, maxRows: Int) async throws -> [UInt32: [UInt32]] {
        let c = try await SNMPNeighbors.optionalColumn(client, dot1qVlanFdbId, maxRows: maxRows)
        var map: [UInt32: [UInt32]] = [:]
        for idx in c.order {
            guard idx.count == 2, let f = c.values[idx]?.uint64 else { continue }
            let fid = UInt32(clamping: f)
            if !(map[fid]?.contains(idx[1]) ?? false) { map[fid, default: []].append(idx[1]) }
        }
        return map
    }

    private static func hasRows(_ client: SNMPClient, _ column: OID) async throws -> Bool {
        do {
            guard let vb = try await client.getNext([column]).first else { return false }
            return column.isAncestorOrEqual(vb.oid) && !vb.value.isException
        } catch SNMPError.errorStatus(_, _, _) {
            return false
        }
    }

    /// GETs in batches of ten, so a small agent isn't asked for too much at once.
    private static func getChunked(_ client: SNMPClient, _ oids: [OID]) async throws -> [OID: SNMPValue] {
        var out: [OID: SNMPValue] = [:]
        var start = 0
        while start < oids.count {
            let end = min(start + 10, oids.count)
            for (k, v) in try await SNMPNeighbors.optionalGet(client, Array(oids[start..<end])) where out[k] == nil {
                out[k] = v
            }
            start = end
        }
        return out
    }

    // MARK: ARP

    struct ARPResult: Equatable {
        var mac: [UInt8]?
        /// When the IP didn't turn up: .complete, or why the read stopped
        /// early (the row limit, an error, an entry out of order).
        var end: SNMPWalk.End = .complete
        var limitHit: Bool { end == .limit }
    }

    /// The device's ARP entry for `ip`. Both tables describe the same cache,
    /// so the older one is only read when the newer one had no IPv4 rows or
    /// stopped early.
    static func deviceARP(_ client: SNMPClient, ip: String, maxRows: Int) async throws -> ARPResult {
        var res = ARPResult()
        let phys = try await SNMPNeighbors.optionalColumn(client, ipNetToPhysicalPhysAddress, maxRows: maxRows)
        var sawIPv4 = false
        for idx in phys.order {
            guard let e = physicalIndex(idx) else { continue }
            sawIPv4 = true
            if e.ip == ip, let m = macValue(phys.values[idx]) { res.mac = m; return res }
        }
        if sawIPv4 && phys.end == .complete { return res }

        let media = try await SNMPNeighbors.optionalColumn(client, ipNetToMediaPhysAddress, maxRows: maxRows)
        for idx in media.order {
            guard let e = mediaIndex(idx) else { continue }
            if e.ip == ip, let m = macValue(media.values[idx]) { res.mac = m; return res }
        }
        // The older table, when it has rows, says whether the cache was read
        // to the end; else the newer one does.
        res.end = media.order.isEmpty ? phys.end : media.end
        return res
    }

    /// ipNetToPhysicalTable index: ifIndex, address type (1 = IPv4), then the
    /// address as a length-prefixed string (ifIndex.1.4.a.b.c.d). Some agents
    /// leave the length out (ifIndex.1.a.b.c.d).
    static func physicalIndex(_ idx: [UInt32]) -> (ifIndex: UInt32, ip: String)? {
        guard idx.count >= 6, idx[1] == 1 else { return nil }
        let rest = Array(idx[2...])
        let octets: [UInt32]
        if rest.count == 5, rest[0] == 4 { octets = Array(rest[1...]) }
        else if rest.count == 4 { octets = rest }
        else { return nil }
        guard octets.allSatisfy({ $0 <= 255 }) else { return nil }
        return (idx[0], octets.map(String.init).joined(separator: "."))
    }

    /// ipNetToMediaTable index: ifIndex.a.b.c.d.
    static func mediaIndex(_ idx: [UInt32]) -> (ifIndex: UInt32, ip: String)? {
        guard idx.count == 5, idx[1...].allSatisfy({ $0 <= 255 }) else { return nil }
        return (idx[0], idx[1...].map(String.init).joined(separator: "."))
    }

    /// A 6-byte physical address that isn't all zeros (an unresolved entry).
    static func macValue(_ v: SNMPValue?) -> [UInt8]? {
        guard let d = v?.bytes, d.count == 6 else { return nil }
        let b = Array(d)
        return b.contains(where: { $0 != 0 }) ? b : nil
    }

    /// This Mac's ARP cache entry for `ip`, read with arp -n.
    static func macFromThisMac(_ ip: String) async -> [UInt8]? {
        guard case .ip? = SNMPLocateQuery.parse(ip) else { return nil }
        let raw = await Shell.run("/usr/sbin/arp", args: ["-n", ip], timeout: 5)
        // The ARP Table tool's parser. It lives on that view, so on the main actor.
        let entries = await MainActor.run { ARPTableView.parseARP(raw, gateway: nil) }
        for e in entries where e.ip == ip {
            if let m = parseMAC(e.mac), m.contains(where: { $0 != 0 }) { return m }
        }
        return nil
    }

    // MARK: MAC addresses

    /// aa:bb:cc:dd:ee:ff, lowercase.
    static func formatMAC(_ b: [UInt8]) -> String {
        b.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    /// Six groups of one or two hex digits separated by : or - (macOS's arp
    /// drops leading zeros), or 12 hex digits with or without . separators.
    static func parseMAC(_ text: String) -> [UInt8]? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty, s.allSatisfy({ $0.isASCII && ($0.isHexDigit || ":-.".contains($0)) }) else { return nil }
        let groups = s.split(omittingEmptySubsequences: false, whereSeparator: { $0 == ":" || $0 == "-" })
        if groups.count == 6, groups.allSatisfy({ (1...2).contains($0.count) && $0.allSatisfy(\.isHexDigit) }) {
            let b = groups.compactMap { UInt8($0, radix: 16) }
            return b.count == 6 ? b : nil
        }
        let hex = s.filter { $0 != ":" && $0 != "-" && $0 != "." }
        guard hex.count == 12 else { return nil }
        var out: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let byte = UInt8(hex[i..<j], radix: 16) else { return nil }
            out.append(byte)
            i = j
        }
        return out
    }

    /// The locally administered bit. On a unicast address it means the
    /// device made the address up (a private, randomized address), so it
    /// doesn't name a maker. Broadcast and some multicast addresses set it too.
    static func isLocallyAdministered(_ b: [UInt8]) -> Bool {
        (b.first ?? 0) & 0x02 != 0
    }

    /// A group address (multicast, or broadcast): it names no one device.
    static func isMulticast(_ b: [UInt8]) -> Bool {
        (b.first ?? 0) & 0x01 != 0
    }

    static func isBroadcast(_ b: [UInt8]) -> Bool {
        b.count == 6 && b.allSatisfy { $0 == 0xff }
    }

    // MARK: Verdict

    static func verdict(_ r: SNMPLocateReport) -> SNMPLocateVerdict {
        // The device by name when it has one: "core-sw1", else "This device"
        // at the start of a sentence and "this device" inside one.
        let device = r.deviceName ?? "This device"
        let inSentence = r.deviceName ?? "this device"
        let ciscoNote = "Cisco IOS switches keep a separate MAC table for each VLAN and answer for one VLAN at a time (with a community like public@20). SNAP doesn't ask per VLAN yet, so addresses on other VLANs may not show up."

        guard let mac = r.mac else {
            let ip = r.query.display
            var notes: [String] = []
            let partial = "SNAP read only part of \(inSentence)'s ARP table"
            switch r.arpEnd {
            case .complete:
                break
            case .limit:
                notes.append("\(partial): it stopped at the row limit. Raise the limit in Options to read more.")
            case .notIncreasing:
                notes.append("\(partial): the device sent an entry out of order, so SNAP stopped reading it.")
            case .error(_, let label):
                notes.append("\(partial): the device returned an error (\(label)) partway through.")
            }
            notes.append("This Mac only learns the MAC addresses of devices on its own subnet.")
            let lookedIn = r.arpEnd == .complete
                ? "Neither \(inSentence)'s ARP table nor this Mac's has \(ip)."
                : "SNAP didn't find \(ip) in the part of \(inSentence)'s ARP table it read, or in this Mac's."
            return SNMPLocateVerdict(
                tone: .missing,
                headline: "No MAC address found for \(ip)",
                detail: lookedIn + " Ping it first so the switch and this Mac learn its MAC address, then try again.",
                notes: notes, pingAddress: ip)
        }
        let macText = formatMAC(mac)
        var notes: [String] = []
        if isBroadcast(mac) {
            notes.append("\(macText) is the broadcast address. Switches don't learn it on a port.")
        } else if isMulticast(mac) {
            notes.append("\(macText) is a multicast address. Switches don't learn those on a port.")
        }

        if r.entryStatus == 4 {
            let on = r.locations.first.map { " It's listed on \($0.display)." } ?? ""
            return SNMPLocateVerdict(
                tone: .found,
                headline: "This is the switch's own address",
                detail: "\(macText) is one of \(inSentence)'s own addresses, not a device plugged into it.\(on)",
                notes: notes)
        }

        if let loc = r.locations.first {
            let place = loc.display + vlanSuffix(loc.vlans)
            if r.locations.count > 1 {
                let rest = r.locations.dropFirst().map { $0.display + vlanSuffix($0.vlans) }
                notes.append("Also learned on " + rest.joined(separator: "; ") + ".")
            }
            if r.neighborsUnread {
                notes.append("SNAP couldn't read \(inSentence)'s LLDP and CDP neighbors, so it can't check what's plugged into this port.")
            }
            if let n = loc.neighbors.first(where: { $0.macs.contains(mac) }) {
                return SNMPLocateVerdict(
                    tone: .found,
                    headline: "Found on \(place): it's \(n.name)",
                    detail: "\(macText) belongs to \(n.name), which is plugged straight into this port.",
                    notes: notes)
            }
            if let n = loc.neighbors.first(where: { $0.kind.forwards }) {
                let what: String
                switch n.kind {
                case .accessPoint: what = "an access point"
                case .repeater:    what = "a repeater"
                // CDP's bridge bit: Cisco access points send it as well as switches.
                case .bridge:      what = "a bridge (a switch or access point)"
                default:           what = "a switch"
                }
                let next = n.address == nil
                    ? " SNAP can't follow it: \(n.name) didn't share an IPv4 management address over LLDP or CDP."
                    : " Query \(n.name) to keep following it."
                return SNMPLocateVerdict(
                    tone: .behind,
                    headline: "Found on \(place), the link to \(n.name)",
                    detail: "\(n.name), \(what), is plugged into this port, so \(macText) is further down that link.\(next)",
                    notes: notes,
                    hop: n.address == nil ? nil : n)
            }
            if let n = loc.neighbors.first(where: { $0.kind == .phone }) {
                return SNMPLocateVerdict(
                    tone: .found,
                    headline: "Found on \(place)",
                    detail: "A phone, \(n.name), is plugged into this port, so this is the phone or a computer plugged into the phone.",
                    notes: notes)
            }
            if let count = loc.macsOnPort, count >= manyAddresses {
                let more = r.tableCut ? " or more" : ""
                // When the neighbors couldn't be read, the note says so.
                let unknown = loc.neighbors.isEmpty && !r.neighborsUnread
                    ? " Nothing on it shared LLDP or CDP, so SNAP can't tell what's there."
                    : ""
                return SNMPLocateVerdict(
                    tone: .behind,
                    headline: "Found on \(place)",
                    detail: "\(count)\(more) addresses are learned on this port, so it probably leads to another switch or an access point (or a server running virtual machines) rather than to one device.\(unknown)",
                    notes: notes)
            }
            return SNMPLocateVerdict(
                tone: .found,
                headline: "Found on \(place)",
                detail: "The switch learned \(macText) on this port: the device is plugged in there, or into something on that port such as a small unmanaged switch.",
                notes: notes)
        }

        if r.noPortLearned {
            return SNMPLocateVerdict(
                tone: .missing,
                headline: "In the MAC table, but not on a port",
                detail: "\(device) knows \(macText) but not which port it's on (the entry's port is 0, as with some addresses set by hand).",
                notes: notes)
        }

        // Only for answers from the per-VLAN BRIDGE-MIB table (or none):
        // a Q-BRIDGE table already spans every VLAN, as on Cisco Business switches.
        if r.isCisco && r.table != .qBridge { notes.append(ciscoNote) }
        var ping: String?
        if case .ip(let ip) = r.query { ping = ip }

        if !r.hasMACTable {
            let detail: String
            if r.ipInDeviceARP {
                detail = "\(device) has \(r.query.display) in its ARP table but shares no MAC address table over SNMP, so it may be a router rather than a switch. Ask the switch the device is plugged into."
            } else {
                detail = "\(device) shares no MAC address table over SNMP, so it may not be a switch, or may not support BRIDGE-MIB. Ask the switch the device is plugged into."
            }
            return SNMPLocateVerdict(tone: .problem, headline: "No MAC table on this device",
                                     detail: detail, notes: notes)
        }
        let rows = r.tableRowsRead.formatted()
        let partDetail: String?
        switch r.tableEnd {
        case .complete:
            partDetail = nil
        case .limit:
            partDetail = "SNAP stopped reading this switch's MAC table at the row limit (\(rows) entries) without finding \(macText). Raise the limit in Options and try again."
        case .notIncreasing:
            partDetail = "SNAP stopped reading this switch's MAC table after \(rows) entries because the switch sent an entry out of order, and \(macText) wasn't in the part it read. The address may still be in the rest of the table."
        case .error(_, let label):
            partDetail = "This switch returned an error (\(label)) after \(rows) entries, so SNAP read only part of its MAC table, and \(macText) wasn't in that part. Try again in a moment."
        }
        if let partDetail {
            return SNMPLocateVerdict(
                tone: .missing,
                headline: "Not in the part of the MAC table SNAP read",
                detail: partDetail,
                notes: notes, pingAddress: ping)
        }
        return SNMPLocateVerdict(
            tone: .missing,
            headline: "Not in this switch's MAC table",
            detail: "The switch hasn't seen traffic from \(macText) recently, or the device is on another switch. Switches forget idle addresses after a few minutes, so make the device send something (ping it, for example), then try again.",
            notes: notes, pingAddress: ping)
    }

    private static func vlanSuffix(_ vlans: [UInt32]) -> String {
        switch vlans.count {
        case 0:  return ""
        case 1:  return ", VLAN \(vlans[0])"
        default: return ", VLANs " + vlans.map(String.init).joined(separator: ", ")
        }
    }

    // MARK: Details

    static func details(_ r: SNMPLocateReport) -> [SNMPLocateDetail] {
        var out: [SNMPLocateDetail] = []
        if case .ip(let ip) = r.query {
            out.append(SNMPLocateDetail(label: "Looking for", value: ip, mono: true, host: ip))
        }
        if let mac = r.mac {
            out.append(SNMPLocateDetail(label: "MAC address", value: formatMAC(mac), mono: true, copyable: true))
            let vendor: String
            if isBroadcast(mac) {
                vendor = "None: the broadcast address, which stands for every device"
            } else if isMulticast(mac) {
                vendor = "None: a multicast address, which stands for a group of devices"
            } else if isLocallyAdministered(mac) {
                vendor = "None: a private address the device made up, so it doesn't name a maker"
            } else {
                vendor = r.vendor ?? "Not in SNAP's vendor list"
            }
            out.append(SNMPLocateDetail(label: "Vendor", value: vendor))
        }
        switch r.macSource {
        case .typed?:     break
        case .deviceARP?: out.append(SNMPLocateDetail(label: "MAC from", value: "\(r.deviceName ?? "This device")'s ARP table"))
        case .thisMac?:   out.append(SNMPLocateDetail(label: "MAC from", value: "This Mac's ARP cache"))
        case nil:         break
        }
        for loc in r.locations {
            out.append(SNMPLocateDetail(label: "Port", value: loc.display, mono: loc.portName != nil))
            if let i = loc.ifIndex {
                out.append(SNMPLocateDetail(label: "Interface", value: "ifIndex \(i), bridge port \(loc.bridgePort)"))
            } else {
                out.append(SNMPLocateDetail(label: "Interface", value: "Bridge port \(loc.bridgePort). The device didn't say which interface that is."))
            }
            if !loc.vlans.isEmpty {
                out.append(SNMPLocateDetail(label: loc.vlans.count == 1 ? "VLAN" : "VLANs",
                                            value: loc.vlans.map(String.init).joined(separator: ", ")))
            }
            if !loc.fdbIds.isEmpty {
                let ids = loc.fdbIds.map(String.init).joined(separator: ", ")
                let why = r.vlanTableRead ? "SNAP couldn't match it to one VLAN" : "usually the VLAN ID"
                out.append(SNMPLocateDetail(label: "Forwarding database", value: "\(ids) (\(why))"))
            }
            if let n = loc.macsOnPort {
                out.append(SNMPLocateDetail(label: "Addresses on this port",
                                            value: n.formatted() + (r.tableCut ? " or more" : "")))
            }
            for n in loc.neighbors {
                var v = n.name
                if n.kind != .unknown { v += " (\(n.kind.rawValue.lowercased()))" }
                if let a = n.address { v += ", \(a)" }
                out.append(SNMPLocateDetail(label: "Neighbor on this port", value: v, host: n.address))
            }
        }
        let table: String
        switch r.table {
        case .bridge?:  table = "BRIDGE-MIB (dot1dTpFdbTable)"
        case .qBridge?: table = "Q-BRIDGE-MIB (dot1qTpFdbTable)"
                        + (r.tableCut ? ", first \(r.tableRowsRead.formatted()) entries read" : "")
        case nil:       table = r.mac == nil ? "" : "None shared over SNMP"
        }
        if !table.isEmpty { out.append(SNMPLocateDetail(label: "MAC table", value: table)) }
        if let s = r.entryStatus, let label = statusLabel(s) {
            out.append(SNMPLocateDetail(label: "Entry", value: label))
        }
        return out
    }

    private static func statusLabel(_ s: Int64) -> String? {
        switch s {
        case 1:  return "Other"
        case 2:  return "Invalid (no longer in use)"
        case 3:  return "Learned from traffic"
        case 4:  return "The switch's own address"
        case 5:  return "Static (set by hand)"
        default: return nil
        }
    }

    // MARK: Text

    static func summary(_ r: SNMPLocateReport) -> String { verdict(r).headline }

    static func exportText(_ r: SNMPLocateReport) -> String {
        let v = verdict(r)
        var s = v.headline + "\n" + v.detail + "\n"
        for n in v.notes { s += "- \(n)\n" }
        if let hop = v.hop, let a = hop.address { s += "Next: query \(hop.name) at \(a)\n" }
        s += "\n"
        for d in details(r) {
            s += (d.label + ":").padding(toLength: 24, withPad: " ", startingAt: 0) + d.value + "\n"
        }
        return s
    }
}

// MARK: - View

struct SNMPWhereIsPane: View {
    @ObservedObject var model: SNMPQueryModel
    let report: SNMPLocateReport

    var body: some View {
        let v = SNMPWhereIs.verdict(report)
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ToolNoteCard(icon: icon(v.tone), tint: tint(v.tone), headline: v.headline,
                             detail: v.detail, notes: v.notes) {
                    actions(v)
                }
                detailsBox
            }
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    private func icon(_ t: SNMPLocateVerdict.Tone) -> String {
        switch t {
        case .found:   return "mappin.and.ellipse"
        case .behind:  return "arrow.triangle.turn.up.right.diamond"
        case .missing: return "questionmark.circle"
        case .problem: return "exclamationmark.triangle"
        }
    }

    private func tint(_ t: SNMPLocateVerdict.Tone) -> Color {
        switch t {
        case .found:   return NS.green
        case .behind:  return NS.blue
        case .missing: return NS.amber
        case .problem: return NS.red
        }
    }

    @ViewBuilder
    private func actions(_ v: SNMPLocateVerdict) -> some View {
        if v.hop?.address != nil || v.pingAddress != nil {
            HStack(spacing: 8) {
                if let n = v.hop, let ip = n.address {
                    Button {
                        // Look for the MAC on the next switch: its ARP table
                        // may not know the IP.
                        if let m = report.mac { model.locateQuery = SNMPWhereIs.formatMAC(m) }
                        model.hop(to: ip)
                    } label: {
                        Label("Query \(n.name)", systemImage: "arrow.right.circle")
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(model.isRunning)
                    .help("Look for this address on \(n.name) at \(ip), with the same community and options")
                    .hostMenu(ip)
                }
                if let ip = v.pingAddress {
                    Button {
                        ToolHandoff.shared.send(ip, to: .ping)
                    } label: {
                        Label("Send to Ping", systemImage: "dot.radiowaves.left.and.right")
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
            }
            .padding(.top, 2)
        }
    }

    private var detailsBox: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 7) {
            ForEach(Array(SNMPWhereIs.details(report).enumerated()), id: \.offset) { _, d in
                GridRow {
                    Text(verbatim: d.label)
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(NS.text3)
                        .fixedSize()
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        valueText(d)
                        if d.copyable {
                            CopyButton(getText: { d.value }).controlSize(.mini)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NS.bg3)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func valueText(_ d: SNMPLocateDetail) -> some View {
        let t = Text(verbatim: d.value)
            .font(.system(size: 12, design: d.mono ? .monospaced : .default))
            .foregroundStyle(NS.text1)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        if let h = d.host { t.hostMenu(h) } else { t }
    }
}
