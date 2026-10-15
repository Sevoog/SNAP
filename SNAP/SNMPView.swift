// SNMPView.swift
// SNAP — SNMP v1/v2c Query Tool (Advanced)
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md
//
// Read-only SNMP v1/v2c client UI. Three modes:
//
//   • System Info: sysDescr / sysObjectID / sysUpTime / sysContact / sysName /
//     sysLocation in a single round trip (one GET with six varbinds). When
//     sysObjectID matches a vendor we know, we surface vendor + role + model
//     above the varbinds.
//
//   • Interfaces: walks ifDescr, ifAdminStatus, ifOperStatus, ifSpeed /
//     ifHighSpeed and the in/out octet counters (64-bit when the device has
//     them) and joins them on the row index.
//
//   • Custom OID Walk: type any OID; we GETBULK-walk it, or GET it when it's
//     a single value.
//
// Version "Auto" asks over v2c, then once over v1 when there's no answer.
// SNAP only reads (GET, GETNEXT, GETBULK); the how-to card says so. Exports
// never include the community string.

import SwiftUI

// MARK: - Mode

enum SNMPMode: String, CaseIterable, Identifiable {
    case system     = "System Info"
    case interfaces = "Interfaces"
    case walk       = "Custom OID Walk"
    var id: String { rawValue }
}

enum SNMPVersionChoice: String, CaseIterable, Identifiable {
    case auto = "Auto", v2c = "v2c", v1 = "v1"
    var id: String { rawValue }
}

extension SNMPVersion {
    var label: String { self == .v1 ? "v1" : "v2c" }
}

// MARK: - Row models

struct SNMPInterfaceRow: Identifiable, Hashable {
    let id: UInt32              // ifIndex
    let descr: String
    let operStatus: String      // "up", "down", "disabled" (admin down), …
    let speed: String           // human-formatted
    let speedRaw: UInt64        // for sorting
    let inOctets: UInt64
    let outOctets: UInt64
    var counters64 = true       // false: 32-bit counters, which wrap every 4.29 GB
}

/// System Info values. nil = the device didn't provide it.
struct SNMPSystemInfo: Equatable {
    var sysDescr: String?
    var sysName: String?
    var sysLocation: String?
    var sysContact: String?
    var sysUpTime: String?
    var sysObjectID: String?
    var matchedVendor: String?
    var matchedRole: DeviceRole?
    var matchedModel: String?
}

/// Where the results on screen came from. Copy/Export label results with
/// this, not with whatever is in the Host field now.
struct SNMPRunInfo: Equatable {
    let host: String
    let port: UInt16
    let version: SNMPVersion
    let fellBackToV1: Bool
    let defaultCommunity: Bool
    let date: Date
}

/// Why a query failed, in a form the "why didn't it answer?" card can explain.
enum SNMPFailure: Equatable {
    /// The device never answered (over v2c, and over v1 if Auto tried it).
    case noAnswer(host: String, port: UInt16, attempts: Int, timeout: Double,
                  choice: SNMPVersionChoice, triedV1: Bool, localAddress: String?)
    /// It answered some requests, then went quiet.
    case stoppedAnswering(host: String, replies: Int)
    case unreachable(host: String, message: String)
    case refused(code: Int, label: String)
    case unreadable
}

/// Something worth saying about a walk that otherwise worked.
enum SNMPWalkNote: Equatable {
    case nothing(String)        // no values at or under this OID
    case limit(Int)             // stopped at the row limit
    case notIncreasing(Int)     // the device went out of order; stopped
    case error(Int, String)     // the device returned an error after N rows
}

// MARK: - Model

@MainActor
final class SNMPQueryModel: ObservableObject {
    @Published var host = ""
    @Published var community = "public"
    @Published var port = "161"
    @Published var mode: SNMPMode = .system
    @Published var customOID = "1.3.6.1.2.1.1"

    // Options (kept for this session only)
    @Published var versionChoice: SNMPVersionChoice = .auto
    @Published var timeoutSeconds: Double = 3
    @Published var retries = 1
    @Published var maxRows = 1000

    @Published var isRunning = false
    @Published var status = ""
    /// Problems with what was typed (bad OID, bad port). Cleared when the mode changes.
    @Published var inputError: String?

    // Results and failures, per mode: one mode's card never shows under another.
    @Published private(set) var failures: [SNMPMode: SNMPFailure] = [:]
    @Published private(set) var rawErrors: [SNMPMode: String] = [:]
    @Published var system: SNMPSystemInfo?
    @Published var interfaces: [SNMPInterfaceRow] = []
    /// Why the interface list may be incomplete, if it is.
    @Published var interfacesNote: SNMPWalkNote?
    @Published var walkRows: [OIDWalkRow] = []
    @Published var walkNote: SNMPWalkNote?
    @Published private(set) var info: [SNMPMode: SNMPRunInfo] = [:]

    struct OIDWalkRow: Identifiable, Hashable {
        let id = UUID()
        let oid: String
        let typeLabel: String
        let value: String
    }

    private enum Outcome {
        case system(SNMPSystemInfo)
        case interfaces([SNMPInterfaceRow], SNMPWalkNote?)
        case walk([OIDWalkRow], SNMPWalkNote?)
    }

    private var task: Task<Void, Never>?
    /// Bumped by every run and by Stop. A query only publishes results while
    /// its id is current, so a stopped or replaced query can't overwrite
    /// the screen later.
    private var runID = 0

    /// How long a query waits before giving up on a device that never answers.
    var worstCaseWait: Double {
        let first = Double(retries + 1) * timeoutSeconds
        return versionChoice == .auto ? first + timeoutSeconds : first
    }

    func hasResults(for mode: SNMPMode) -> Bool {
        switch mode {
        case .system:     return system != nil
        case .interfaces: return info[.interfaces] != nil
        case .walk:       return info[.walk] != nil
        }
    }

    func cancel() {
        runID += 1
        task?.cancel()
        task = nil
        isRunning = false
        status = "Stopped"
    }

    func run() {
        inputError = nil
        let host = self.host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { inputError = "Enter a host or IP address."; return }
        guard let portNum = UInt16(port.trimmingCharacters(in: .whitespaces)), portNum > 0 else {
            inputError = "The port must be a number from 1 to 65535. SNMP normally uses 161."
            return
        }
        var walkBase: OID?
        if mode == .walk {
            let trimmed = customOID.trimmingCharacters(in: .whitespaces)
            guard let base = OID(string: trimmed) else {
                inputError = "\u{201C}\(trimmed)\u{201D} isn't a valid OID. Use numbers separated by dots, like 1.3.6.1.2.1.1."
                return
            }
            walkBase = base
        }

        task?.cancel()
        runID += 1
        let id = runID
        let mode = self.mode
        let community = self.community.isEmpty ? "public" : self.community
        let choice = versionChoice, timeout = timeoutSeconds, retries = self.retries, maxRows = self.maxRows

        clearResults(for: mode)
        isRunning = true
        status = "Querying \(host)\u{2026}"
        ToolHistory.shared.add(.snmp, host)    // the host only, never the community

        func client(_ version: SNMPVersion, retries: Int) -> SNMPClient {
            SNMPClient(host: host, port: portNum, community: community,
                       version: version, timeout: timeout, retries: retries)
        }

        // Inherits the main actor: every write below happens on main, after
        // checking the run is still current.
        task = Task { [weak self] in
            var current = client(choice == .v1 ? .v1 : .v2c, retries: retries)
            var fellBack = false
            var triedV1 = false
            do {
                let outcome: Outcome
                do {
                    outcome = try await Self.perform(mode, current, walkBase: walkBase, maxRows: maxRows)
                } catch SNMPError.timeout where choice == .auto && current.repliesReceived == 0 {
                    // Not a single v2c reply: some older devices only speak v1.
                    // Ask once over v1; only if it answers, run the query over v1
                    // with the usual retries. (A timeout after v2c replies is a
                    // device that went quiet, not a v1 device.)
                    guard let self, self.runID == id else { return }
                    self.status = "No answer over v2c. Trying v1\u{2026}"
                    triedV1 = true
                    let probe = client(.v1, retries: 0)
                    do {
                        _ = try await probe.get([SNMPOID.sysUpTime])
                    } catch SNMPError.errorStatus(_, _, _) {
                        // Any reply, even an error, means v1 is spoken here.
                    } catch {
                        current = probe
                        throw error
                    }
                    current = client(.v1, retries: retries)
                    fellBack = true
                    outcome = try await Self.perform(mode, current, walkBase: walkBase, maxRows: maxRows)
                }
                guard let self, self.runID == id else { return }
                self.apply(outcome)
                self.info[mode] = SNMPRunInfo(host: host, port: portNum, version: current.version,
                                              fellBackToV1: fellBack,
                                              defaultCommunity: community == "public", date: Date())
                self.status = Self.summary(outcome) + (fellBack ? " (answered over v1)" : "")
                self.isRunning = false
            } catch {
                guard let self, self.runID == id, !(error is CancellationError) else { return }
                self.failures[mode] = Self.failure(for: error, host: host, port: portNum,
                                                   attempts: retries + 1, timeout: timeout,
                                                   choice: choice, triedV1: triedV1,
                                                   replies: current.repliesReceived,
                                                   localAddress: current.localAddress)
                self.rawErrors[mode] = "\(error)"
                self.status = ""
                self.isRunning = false
            }
        }
    }

    private func clearResults(for mode: SNMPMode) {
        info[mode] = nil
        failures[mode] = nil
        rawErrors[mode] = nil
        switch mode {
        case .system:     system = nil
        case .interfaces: interfaces = []; interfacesNote = nil
        case .walk:       walkRows = []; walkNote = nil
        }
    }

    private func apply(_ outcome: Outcome) {
        switch outcome {
        case .system(let s):                  system = s
        case .interfaces(let rows, let note): interfaces = rows; interfacesNote = note
        case .walk(let rows, let note):       walkRows = rows; walkNote = note
        }
    }

    private static func summary(_ outcome: Outcome) -> String {
        switch outcome {
        case .system:                return "System info retrieved"
        case .interfaces(let r, _):  return "\(r.count) interface\(r.count == 1 ? "" : "s") retrieved"
        case .walk(let r, _):        return "\(r.count) row\(r.count == 1 ? "" : "s") returned"
        }
    }

    // MARK: Queries (off the main actor)

    nonisolated private static func perform(_ mode: SNMPMode, _ client: SNMPClient,
                                            walkBase: OID?, maxRows: Int) async throws -> Outcome {
        switch mode {
        case .system:
            return .system(try await querySystem(client))
        case .interfaces:
            let (rows, note) = try await queryInterfaces(client, maxRows: maxRows)
            return .interfaces(rows, note)
        case .walk:
            let base = walkBase ?? OID([1,3,6,1,2,1,1])
            let w = try await client.walkSubtree(base, maxReps: 25, maxRows: maxRows)
            let rows = w.rows.map {
                OIDWalkRow(oid: $0.oid.description, typeLabel: snmpTypeLabel($0.value), value: $0.value.description)
            }
            let note: SNMPWalkNote? = {
                if rows.isEmpty && w.end == .complete { return .nothing(base.description) }
                switch w.end {
                case .complete:              return nil
                case .limit:                 return .limit(rows.count)
                case .notIncreasing:         return .notIncreasing(rows.count)
                case .error(let c, let l):   return .error(c, l)
                }
            }()
            return .walk(rows, note)
        }
    }

    nonisolated private static func querySystem(_ client: SNMPClient) async throws -> SNMPSystemInfo {
        let vbs = try await client.getTolerant([
            SNMPOID.sysDescr, SNMPOID.sysObjectID, SNMPOID.sysUpTime,
            SNMPOID.sysContact, SNMPOID.sysName, SNMPOID.sysLocation,
        ])
        // A misbehaving agent can repeat a varbind; keep the first.
        let byOID = Dictionary(vbs.map { ($0.oid, $0.value) }, uniquingKeysWith: { first, _ in first })
        func text(_ oid: OID) -> String? {
            guard let v = byOID[oid], !v.isException else { return nil }
            return v.description
        }
        var s = SNMPSystemInfo(sysDescr: text(SNMPOID.sysDescr), sysName: text(SNMPOID.sysName),
                               sysLocation: text(SNMPOID.sysLocation), sysContact: text(SNMPOID.sysContact),
                               sysUpTime: text(SNMPOID.sysUpTime), sysObjectID: text(SNMPOID.sysObjectID))
        if let v = byOID[SNMPOID.sysObjectID], case .oid(let o) = v, let m = SysObjectIDDatabase.match(o) {
            s.matchedVendor = m.vendor
            s.matchedRole = m.role
            s.matchedModel = m.model
        }
        return s
    }

    nonisolated private static func queryInterfaces(_ client: SNMPClient, maxRows: Int) async throws -> ([SNMPInterfaceRow], SNMPWalkNote?) {
        // One column at a time: gentler on small agents than nine parallel walks.
        var note: SNMPWalkNote?
        func column(_ oid: OID) async throws -> [UInt32: SNMPValue] {
            let w = try await client.bulkWalk(oid, maxReps: 30, maxRows: maxRows)
            switch w.end {
            case .complete:             break
            case .limit:                note = note ?? .limit(maxRows)
            case .notIncreasing:        note = note ?? .notIncreasing(w.rows.count)
            case .error(let c, let l):  note = note ?? .error(c, l)
            }
            return Dictionary(w.rows.map { ($0.oid.components.last ?? 0, $0.value) },
                              uniquingKeysWith: { first, _ in first })
        }
        /// Columns older or simpler devices may not have. An error with no
        /// rows means the column isn't there; v1 can't carry 64-bit counters.
        func optionalColumn(_ oid: OID) async throws -> [UInt32: SNMPValue] {
            do { return try await column(oid) } catch SNMPError.errorStatus(_, _, _) { return [:] }
        }

        let descr  = try await column(SNMPOID.ifDescr)
        let oper   = try await column(SNMPOID.ifOperStatus)
        let admin  = try await optionalColumn(SNMPOID.ifAdminStatus)
        let speed  = try await optionalColumn(SNMPOID.ifSpeed)
        let high   = try await optionalColumn(SNMPOID.ifHighSpeed)
        let hcIn   = try await optionalColumn(SNMPOID.ifHCInOctets)
        let hcOut  = try await optionalColumn(SNMPOID.ifHCOutOctets)
        // 64-bit counters are only required on ports faster than 20 Mbps
        // (RFC 2863), so fall back per port, not only when the column is empty.
        let indexes = Set(descr.keys).union(oper.keys)
        let in32   = indexes.isSubset(of: hcIn.keys)  ? [:] : try await optionalColumn(SNMPOID.ifInOctets)
        let out32  = indexes.isSubset(of: hcOut.keys) ? [:] : try await optionalColumn(SNMPOID.ifOutOctets)

        let rows: [SNMPInterfaceRow] = indexes.sorted().map { idx in
            let speedRaw = SNMPInterfaceFormat.effectiveSpeedBps(ifSpeed: unsigned(speed[idx]),
                                                                 highSpeedMbps: high[idx].map(unsigned))
            return SNMPInterfaceRow(
                id: idx,
                descr: descr[idx]?.description ?? "",
                operStatus: SNMPInterfaceFormat.statusLabel(admin: admin[idx], oper: oper[idx]),
                speed: SNMPInterfaceFormat.formatSpeed(speedRaw),
                speedRaw: speedRaw,
                inOctets: unsigned(hcIn[idx] ?? in32[idx]),
                outOctets: unsigned(hcOut[idx] ?? out32[idx]),
                counters64: hcIn[idx] != nil && hcOut[idx] != nil
            )
        }
        return (rows, note)
    }

    nonisolated private static func unsigned(_ v: SNMPValue?) -> UInt64 {
        switch v {
        case .gauge32(let g):   return UInt64(g)
        case .counter32(let c): return UInt64(c)
        case .counter64(let c): return c
        case .integer(let i):   return UInt64(max(0, i))
        default:                return 0
        }
    }

    nonisolated private static func failure(for error: Error, host: String, port: UInt16, attempts: Int,
                                            timeout: Double, choice: SNMPVersionChoice, triedV1: Bool,
                                            replies: Int, localAddress: String?) -> SNMPFailure {
        switch error as? SNMPError {
        case .timeout? where replies > 0:
            return .stoppedAnswering(host: host, replies: replies)
        case .timeout?:
            return .noAnswer(host: host, port: port, attempts: attempts, timeout: timeout,
                             choice: choice, triedV1: triedV1, localAddress: localAddress)
        case .transport(let message)?:
            return .unreachable(host: host, message: message)
        case .errorStatus(let code, let label, _)?:
            return .refused(code: code, label: label)
        default:
            return .unreadable
        }
    }

    // MARK: Export

    /// Results with where they came from. Never includes the community
    /// string: it's a password, and exports end up in tickets and chats.
    func exportText() -> String {
        guard let i = info[mode] else { return "No SNMP results yet." }
        var s = """
        SNAP SNMP query
        Host:      \(i.host):\(i.port)
        Version:   \(i.version.label)\(i.fellBackToV1 ? " (no answer over v2c)" : "")
        Community: \(i.defaultCommunity ? "default (public)" : "custom (not shown)")
        Mode:      \(mode.rawValue)
        Time:      \(i.date.formatted(date: .abbreviated, time: .standard))


        """
        switch mode {
        case .system:
            let sys = system ?? SNMPSystemInfo()
            if let v = sys.matchedVendor {
                s += "Vendor: \(v)\n"
                if let m = sys.matchedModel { s += "Model: \(m)\n" }
                if let r = sys.matchedRole { s += "Role:  \(r.rawValue)\n" }
                s += "\n"
            }
            func line(_ label: String, _ v: String?) -> String {
                let value = v.map { $0.isEmpty ? "(not set)" : $0 } ?? "(not provided)"
                return label.padding(toLength: 13, withPad: " ", startingAt: 0) + value + "\n"
            }
            s += line("sysName:", sys.sysName) + line("sysDescr:", sys.sysDescr)
               + line("sysObjectID:", sys.sysObjectID) + line("sysUpTime:", sys.sysUpTime)
               + line("sysContact:", sys.sysContact) + line("sysLocation:", sys.sysLocation)
        case .interfaces:
            s += "idx\tname\tstatus\tspeed\ttotal in (bytes)\ttotal out (bytes)\n"
            for r in interfaces {
                s += "\(r.id)\t\(r.descr)\t\(r.operStatus)\t\(r.speed)\t\(r.inOctets)\t\(r.outOctets)\n"
            }
            if interfaces.contains(where: { !$0.counters64 }) {
                s += "(some totals are 32-bit counters, which wrap every 4.29 GB)\n"
            }
            s += Self.exportNote(interfacesNote)
        case .walk:
            for r in walkRows { s += "\(r.oid)\t\(r.typeLabel)\t\(r.value)\n" }
            s += Self.exportNote(walkNote)
        }
        return s
    }

    private static func exportNote(_ note: SNMPWalkNote?) -> String {
        switch note {
        case .limit?:                 return "(stopped at the row limit)\n"
        case .notIncreasing?:         return "(stopped: the device returned an OID out of order)\n"
        case .error(_, let label)?:   return "(stopped: the device returned an error, \(label))\n"
        case .nothing(let o)?:        return "(no values at or under \(o))\n"
        case nil:                     return ""
        }
    }
}

/// Interface table helpers, kept pure for tests.
enum SNMPInterfaceFormat {
    /// ifSpeed is a Gauge32: anything over 4,294,967,295 bps reports exactly
    /// that, and RFC 2863 says to read ifHighSpeed (Mbps) instead.
    static func effectiveSpeedBps(ifSpeed: UInt64, highSpeedMbps: UInt64?) -> UInt64 {
        if ifSpeed == 0 || ifSpeed >= UInt64(UInt32.max), let hs = highSpeedMbps, hs > 0 {
            return hs * 1_000_000
        }
        return ifSpeed
    }

    /// "10 Gbps", "2.5 Gbps", "1.5 Mbps". Decimal units.
    static func formatSpeed(_ bps: UInt64) -> String {
        if bps == 0 { return "—" }
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
        default: return "—"
        }
    }
    return "—"
}

private func snmpTypeLabel(_ v: SNMPValue) -> String {
    switch v {
    case .integer:        return "INTEGER"
    case .octetString:    return v.isText ? "STRING" : "Hex-STRING"
    case .oid:            return "OID"
    case .null:           return "NULL"
    case .ipAddress:      return "IpAddress"
    case .counter32:      return "Counter32"
    case .gauge32:        return "Gauge32"
    case .timeTicks:      return "TimeTicks"
    case .opaque:         return "Opaque"
    case .counter64:      return "Counter64"
    case .noSuchObject:   return "noSuchObject"
    case .noSuchInstance: return "noSuchInstance"
    case .endOfMibView:   return "endOfMibView"
    }
}

// MARK: - View

struct SNMPView: View {
    @StateObject private var model = SNMPQueryModel()
    @State private var showOptions = false

    init() {}

    /// For previews and tests: show a model you've set up.
    init(model: SNMPQueryModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .tabNavigationTitle(.snmp)
        // "Query with SNMP" from any host's right-click menu, or ⌘K "snmp HOST"
        .consumeHandoff(for: .snmp) { model.host = $0 }
        .onChange(of: model.mode) { _ in model.inputError = nil }
        // Runs when the window closes (tabs stay alive across switches)
        .onDisappear { if model.isRunning { model.cancel() } }
    }

    private var versionLabel: String {
        switch model.versionChoice {
        case .auto: return "v2c, then v1"
        case .v2c:  return "v2c"
        case .v1:   return "v1"
        }
    }

    private var toolbar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "network.badge.shield.half.filled").foregroundStyle(.cyan)
                Text("SNMP").font(.system(size: 13, weight: .semibold)).foregroundStyle(NS.text1)
                    .fixedSize()
                Text(versionLabel + " \u{00B7} read-only")
                    .font(.system(size: 11)).foregroundStyle(NS.text3).fixedSize()
                Spacer()
                if !model.status.isEmpty {
                    Text(model.status).font(.system(size: 11)).foregroundStyle(NS.text3)
                        .lineLimit(1)
                }
                ToolActionBar("SNMP", text: { model.exportText() })
                    .fixedSize()
            }
            // One row when it fits; narrow windows move the mode picker,
            // OID field and Query onto a second row.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    hostField.frame(width: 200)
                    HistoryMenuButton(key: .snmp) { model.host = $0 }
                    connectionFields
                    modePicker
                    if model.mode == .walk {
                        oidField.frame(minWidth: 160, idealWidth: 160, maxWidth: 240)
                            .layoutPriority(1)
                    }
                    Spacer()
                    optionsButton
                    runControls
                }
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        hostField.frame(minWidth: 120, maxWidth: .infinity)
                        HistoryMenuButton(key: .snmp) { model.host = $0 }
                        connectionFields
                    }
                    HStack(spacing: 8) {
                        modePicker
                        if model.mode == .walk {
                            oidField.frame(minWidth: 120, maxWidth: .infinity)
                        } else {
                            Spacer()
                        }
                        optionsButton
                        runControls
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(NS.bg0)
    }

    private var hostField: some View {
        TextField("Host or IP", text: $model.host)
            .textFieldStyle(.roundedBorder)
    }

    @ViewBuilder
    private var connectionFields: some View {
        TextField("Community", text: $model.community)
            .textFieldStyle(.roundedBorder)
            .frame(width: 110)
            .help("The community string: a read-only password set on the device. Many devices use public.")
        TextField("Port", text: $model.port)
            .textFieldStyle(.roundedBorder)
            .frame(width: 60)
            .help("SNMP normally uses UDP port 161.")
    }

    private var modePicker: some View {
        Picker("", selection: $model.mode) {
            ForEach(SNMPMode.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .fixedSize()
    }

    private var oidField: some View {
        TextField("OID (e.g. 1.3.6.1.2.1.2.2)", text: $model.customOID)
            .textFieldStyle(.roundedBorder)
    }

    private var optionsButton: some View {
        Button { showOptions.toggle() } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .buttonStyle(.bordered)
        .fixedSize()
        .help("Options: SNMP version, timeout, retries, row limit")
        .disabled(model.isRunning)
        .popover(isPresented: $showOptions, arrowEdge: .bottom) {
            SNMPOptionsForm(model: model)
        }
    }

    @ViewBuilder
    private var runControls: some View {
        if model.isRunning {
            Button("Stop") { model.cancel() }
                .buttonStyle(.bordered).tint(.red)
                .fixedSize()
            ProgressView().controlSize(.small)
        } else {
            Button("Query") { model.run() }
                .buttonStyle(.borderedProminent)
                .disabled(model.host.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.return)
                .fixedSize()
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let msg = model.inputError {
            inputBanner(msg)
        }
        if model.hasResults(for: model.mode) {
            if let i = model.info[model.mode] { sourceLine(i) }
            switch model.mode {
            case .system:     systemPane
            case .interfaces: interfacesPane
            case .walk:       walkPane
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let f = model.failures[model.mode] {
                        failureCard(f, raw: model.rawErrors[model.mode])
                    }
                    SNMPHowToCard()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        }
    }

    private func inputBanner(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(NS.red)
            Text(text).font(.system(size: 12)).foregroundStyle(NS.text1)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(NS.red.opacity(0.08))
    }

    /// Which device and when, so results never pass for the host now typed.
    private func sourceLine(_ i: SNMPRunInfo) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "clock").font(.system(size: 10))
            // verbatim: a LocalizedStringKey would print port 53114 as "53,114"
            Text(verbatim: "\(i.host):\(i.port) over \(i.version.label)\(i.fellBackToV1 ? " (it didn't answer v2c)" : ""), \(i.date.formatted(date: .omitted, time: .shortened))")
            Spacer()
        }
        .font(.system(size: 11)).foregroundStyle(NS.text3)
        .padding(.horizontal, 16).padding(.vertical, 6)
    }

    // MARK: Failure card

    @ViewBuilder
    private func failureCard(_ f: SNMPFailure, raw: String?) -> some View {
        switch f {
        case let .noAnswer(host, port, attempts, timeout, choice, triedV1, local):
            let wait = timeout == timeout.rounded() ? String(format: "%.0f", timeout) : String(format: "%.1f", timeout)
            let asked = attempts == 1 ? "asked once and waited \(wait) s" : "asked \(attempts) times, waiting \(wait) s each time"
            ToolNoteCard(
                icon: "questionmark.circle", tint: .orange,
                headline: "No answer from \(host)",
                detail: "SNAP \(asked)\(triedV1 ? ", then tried once more over v1" : ""), but got no reply. A device ignores a wrong community string without replying, so a wrong community looks exactly like SNMP being turned off.",
                notes: [
                    "SNMP is turned on in the device's admin page.",
                    "The community string matches the device's exactly. It's case-sensitive.",
                    "The device accepts SNMP from this Mac\(local.map { " (\($0))" } ?? ""). Many only answer addresses on their list.",
                    "Nothing blocks UDP port \(port) between this Mac and the device.",
                    choice == .auto ? "The device may only accept SNMPv3, which SNAP doesn't support."
                        : choice == .v2c ? "The device may only speak v1. Set Version to Auto or v1 in Options."
                        : "The device may only speak v2c. Set Version to Auto or v2c in Options.",
                ],
                footnote: nil
            ) { sendToPing(host) }
        case let .stoppedAnswering(host, replies):
            ToolNoteCard(
                icon: "pause.circle", tint: .orange,
                headline: "\(host) stopped answering partway",
                detail: "It answered \(replies == 1 ? "1 request" : "\(replies.formatted()) requests"), then went quiet. The device may be busy or limiting how fast it answers SNMP, or the network dropped packets. Try again, or raise the timeout or retries in Options.",
                notes: [],
                footnote: nil
            )
        case let .unreachable(host, message):
            ToolNoteCard(
                icon: "network.slash", tint: .red,
                headline: "Couldn't reach \(host)",
                detail: "The network reported: \(message).",
                notes: ["Check the address or name.",
                        "Check that this Mac is on a network that can reach the device."],
                footnote: nil
            ) { sendToPing(host) }
        case let .refused(code, label):
            ToolNoteCard(
                icon: "hand.raised", tint: .red,
                headline: "The device refused the request",
                detail: Self.refusalText(code: code, label: label),
                notes: [],
                footnote: raw
            )
        case .unreadable:
            ToolNoteCard(
                icon: "exclamationmark.triangle", tint: .red,
                headline: "The reply couldn't be read",
                detail: "Something answered, but SNAP couldn't read the reply as SNMP. The port may belong to another service, or the reply was damaged on the way.",
                notes: [],
                footnote: raw
            )
        }
    }

    private static func refusalText(code: Int, label: String) -> String {
        switch code {
        case 1:     return "The value is too large for the device to send in one SNMP reply (tooBig)."
        case 2:     return "The device doesn't have that OID (noSuchName)."
        case 5:     return "The device hit an internal error while answering (genErr). Try again in a moment."
        case 6, 16: return "This community isn't allowed to read that (\(label))."
        default:    return "The device answered with an error: \(label)."
        }
    }

    private func sendToPing(_ host: String) -> some View {
        Button {
            ToolHandoff.shared.send(host, to: .ping)
        } label: {
            Label("Send to Ping", systemImage: "dot.radiowaves.left.and.right")
        }
        .buttonStyle(.bordered).controlSize(.small)
        .padding(.top, 2)
    }

    // MARK: System

    private var systemPane: some View {
        let s = model.system ?? SNMPSystemInfo()
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let v = s.matchedVendor {
                    HStack(spacing: 10) {
                        Image(systemName: (s.matchedRole ?? .unknown).icon)
                            .foregroundStyle(NS.amber)
                            .font(.system(size: 22))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(v + (s.matchedModel.map { " · \($0)" } ?? ""))
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(NS.text1)
                            if let r = s.matchedRole {
                                Text("Identified by sysObjectID: \(r.rawValue)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(NS.text3)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(NS.amber.opacity(0.08))
                    Divider().background(NS.borderMid)
                }
                VStack(alignment: .leading, spacing: 12) {
                    sysRow("sysName",     s.sysName)
                    sysRow("sysDescr",    s.sysDescr)
                    sysRow("sysObjectID", s.sysObjectID)
                    sysRow("sysUpTime",   s.sysUpTime)
                    sysRow("sysContact",  s.sysContact)
                    sysRow("sysLocation", s.sysLocation)
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
            }
        }
    }

    private func sysRow(_ label: String, _ value: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(NS.text3).frame(width: 110, alignment: .leading)
            if let value, !value.isEmpty {
                Text(value)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(NS.text1)
                    .textSelection(.enabled)
            } else {
                Text(value == nil ? "Not provided by this device" : "Not set on the device")
                    .font(.system(size: 12))
                    .foregroundStyle(NS.text3)
            }
        }
    }

    // MARK: Interfaces

    private var interfacesPane: some View {
        VStack(spacing: 0) {
            if let note = model.interfacesNote {
                noteStrip(Self.interfacesNoteText(note))
            }
            Table(model.interfaces) {
                TableColumn("Idx") { r in Text(String(r.id)).font(.system(.body, design: .monospaced)) }
                    .width(40)
                TableColumn("Name", value: \.descr)
                TableColumn("Status") { r in
                    Text(r.operStatus)
                        .foregroundStyle(r.operStatus == "up" ? NS.green : (r.operStatus == "down" ? NS.red : NS.text3))
                        .help(r.operStatus == "disabled" ? "Turned off in the device's settings (ifAdminStatus down)" : "")
                }
                .width(70)
                TableColumn("Speed") { r in Text(r.speed).font(.system(.body, design: .monospaced)) }
                    .width(80)
                TableColumn("Total in") { r in
                    Text(byteFormat(r.inOctets) + (r.counters64 ? "" : "*")).font(.system(.body, design: .monospaced))
                        .help(r.counters64 ? "Bytes received since the device's counter last reset, usually at its last restart"
                                           : Self.counter32Help)
                }
                .width(84)
                TableColumn("Total out") { r in
                    Text(byteFormat(r.outOctets) + (r.counters64 ? "" : "*")).font(.system(.body, design: .monospaced))
                        .help(r.counters64 ? "Bytes sent since the device's counter last reset, usually at its last restart"
                                           : Self.counter32Help)
                }
                .width(84)
            }
        }
    }

    private static let counter32Help = "* A 32-bit counter: it starts over at zero after every 4.29 GB, so on a busy port this isn't the total since restart."

    private static func interfacesNoteText(_ note: SNMPWalkNote) -> String {
        switch note {
        case .limit(let n):          return "Some columns stopped at the row limit (\(n.formatted())), so this list may be incomplete. Raise the limit in Options."
        case .notIncreasing:         return "The device sent an OID out of order, so SNAP stopped reading one column early. This list may be incomplete."
        case .error(_, let label):   return "The device returned an error (\(label)) partway through, so this list may be incomplete."
        case .nothing:               return ""
        }
    }

    private func byteFormat(_ b: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(b); var i = 0
        while v >= 1_000 && i < units.count - 1 { v /= 1_000; i += 1 }
        return String(format: "%.1f %@", v, units[i])
    }

    // MARK: Walk

    private var walkPane: some View {
        VStack(spacing: 0) {
            switch model.walkNote {
            case .nothing(let oid)?:
                ScrollView {
                    ToolNoteCard(icon: "tray", tint: .blue,
                                 headline: "Nothing at or under \(oid)",
                                 detail: "The device answered, but has no values there. It may not support that part of the MIB, or it may hide it from this community.",
                                 notes: [])
                        .padding(16)
                }
            case .limit(let n)?:
                noteStrip("Stopped at \(n.formatted()) rows, the row limit. Raise it in Options, or walk a smaller part of the tree.")
            case .notIncreasing(let n)?:
                noteStrip("Stopped after \(n.formatted()) rows: the device sent an OID out of order, which would make the walk loop. The rows shown came before that.")
            case .error(_, let label)?:
                noteStrip("Stopped after \(model.walkRows.count.formatted()) rows: the device returned an error (\(label)). The rows shown came before that.")
            case nil:
                EmptyView()
            }
            if !model.walkRows.isEmpty {
                Table(model.walkRows) {
                    TableColumn("OID", value: \.oid)
                        .width(min: 200, ideal: 260)
                    TableColumn("Type", value: \.typeLabel).width(90)
                    TableColumn("Value") { r in
                        Text(r.value).textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func noteStrip(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(.blue)
            Text(text).font(.system(size: 11)).foregroundStyle(NS.text2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color.blue.opacity(0.06))
    }
}

// MARK: - Options

private struct SNMPOptionsForm: View {
    @ObservedObject var model: SNMPQueryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SNMP options").font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Picker("Version", selection: $model.versionChoice) {
                    ForEach(SNMPVersionChoice.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("Auto asks over v2c, then once over v1 if the device doesn't answer. Some older devices only speak v1.")
                    .font(.caption).foregroundStyle(NS.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker("Timeout", selection: $model.timeoutSeconds) {
                ForEach([1.0, 2.0, 3.0, 5.0, 10.0], id: \.self) { s in Text("\(Int(s)) s").tag(s) }
            }
            Picker("Retries", selection: $model.retries) {
                ForEach(0...3, id: \.self) { n in Text("\(n)").tag(n) }
            }
            Picker("Row limit", selection: $model.maxRows) {
                ForEach([250, 1000, 5000, 10000], id: \.self) { n in Text(n.formatted()).tag(n) }
            }

            Text("If a device never answers, a query gives up after about \(Int(model.worstCaseWait.rounded())) s.")
                .font(.caption).foregroundStyle(NS.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 320)
    }
}

// MARK: - How to use

private struct SNMPHowToCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.circle").foregroundStyle(.blue)
                Text("How to use SNMP").font(.headline).foregroundStyle(NS.text1)
            }
            Text("SNMP lets you read information from network devices: routers, switches, NAS boxes, printers, UPSes, and access points.")
                .font(.callout).foregroundStyle(NS.text2)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                step(1, "Turn SNMP on in the device.", "It's often off by default. Look for SNMP in the device's admin page and turn on v1/v2c.")
                step(2, "Use its community string.", "It works like a read-only password. Many devices ship with public; if yours uses something else, type it in the Community field.")
                step(3, "Enter the device's address and press Query.", "If nothing comes back, SNAP explains what to check.")
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                mode("System Info", "the device's name, description, maker, uptime, contact, and location.")
                mode("Interfaces", "every port, with its status, speed, and total traffic.")
                mode("Custom OID Walk", "every value under an OID you choose. 1.3.6.1.2.1.1 is the system group; 1.3.6.1.2.1.2.2 is the interface table.")
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                note("lock.open", "SNAP only reads (GET, GETNEXT, GETBULK). It never changes settings on the device.")
                note("eye", "v1 and v2c send the community string unencrypted, so anyone watching the network can see it. Use a community that can only read.")
            }
        }
        .padding(16)
        .frame(maxWidth: 640, alignment: .leading)
        .background(NS.bg3)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func step(_ n: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.caption.bold().monospacedDigit())
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.blue.opacity(0.15)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.bold()).foregroundStyle(NS.text1)
                Text(detail).font(.callout).foregroundStyle(NS.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func mode(_ name: String, _ detail: String) -> some View {
        (Text(name).bold().foregroundColor(NS.text1) + Text(" shows " + detail).foregroundColor(NS.text2))
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func note(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon).font(.caption).foregroundStyle(NS.text3).frame(width: 14)
            Text(text).font(.caption).foregroundStyle(NS.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
