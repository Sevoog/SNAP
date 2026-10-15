// SNMPBoardWatch.swift
// SNAP — Status Board "SNMP Watch" tile: one watched device or port
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md
//
// "Show on Status Board" in the SNMP tab pins one device (System Info) or
// one port (Interfaces) here. While the SNMP Watch tile is on screen on an
// open Status Board, SNAP asks the device every 10 seconds with one GET:
// sysUpTime.0 and sysName.0, plus, for a port, ifAdminStatus, ifOperStatus
// and the in/out octet counters for its ifIndex. (The first poll of a port
// with no 64-bit counters takes a second GET for the 32-bit ones; later
// polls ask for those directly.) Nothing is polled while the board is
// closed, or once the window holding it closes: the tile reports when it
// appears and disappears, and polling needs at least one tile on screen.
//
// Rates come from counter deltas over the sysUpTime delta (the device's own
// clock, in hundredths of a second), so network delay doesn't skew them.
// A 32-bit counter may wrap once between polls; a 64-bit counter that goes
// down, or a device whose uptime went backwards (it restarted), gives no
// rate for that poll instead of a wild one.
//
// The pinned target is saved in UserDefaults without the community string.
// The board keeps its own copy of the community in the Keychain
// (SNMPCommunityStore.saveForBoard), separate from Remember in the SNMP tab:
// pinning doesn't tick Remember, unticking Remember doesn't stop the tile,
// and unpinning deletes the board's copy only.

import SwiftUI
import Combine

// CONTRACT (used by SNMPView.swift, SNMPInterfaces.swift, StatusBoardTiles.swift):
//   struct SNMPBoardTarget: Codable, Equatable   (fields below)
//   @MainActor final class SNMPBoardWatch: ObservableObject {
//     static let shared
//     @Published private(set) var target: SNMPBoardTarget?
//     func pin(_ target: SNMPBoardTarget, community: String)   // saves the board's copy via SNMPCommunityStore.saveForBoard
//     func unpin()                                             // deletes it via SNMPCommunityStore.forgetForBoard
//   }
//   struct SBSNMPWatchTile: View { init() }

/// What the tile watches. Never holds the community string: that's in the
/// Keychain, via SNMPCommunityStore.
struct SNMPBoardTarget: Codable, Equatable {
    var host: String
    var port: UInt16
    var version: Int64            // SNMPVersion raw value
    var deviceName: String?       // sysName at pin time
    var ifIndex: UInt32?          // nil = watch the device only
    var portName: String?
    var speedBps: UInt64?
}

extension SNMPBoardTarget {
    var snmpVersion: SNMPVersion { SNMPVersion(rawValue: version) ?? .v2c }
    var watchesPort: Bool { ifIndex != nil }
}

// MARK: - One poll (off the main actor)

enum SNMPBoardPoll {

    /// What one poll read. nil fields: the device didn't provide them.
    struct Reading: Equatable {
        var uptimeTicks: UInt32?
        var sysName: String?
        /// nil when watching the device only.
        var port: PortReading?
    }

    struct PortReading: Equatable {
        /// ifOperStatus: 1 up, 2 down, 3 testing, 4 unknown, 5 dormant,
        /// 6 notPresent, 7 lowerLayerDown. nil: no port at this ifIndex.
        var operStatus: Int64?
        /// ifAdminStatus: 1 up, 2 down (turned off), 3 testing.
        var adminStatus: Int64?
        var inOctets: UInt64?
        var outOctets: UInt64?
        /// True when both totals are 64-bit (ifHCInOctets / ifHCOutOctets).
        var counters64: Bool
    }

    static func column(_ column: OID, _ index: UInt32) -> OID {
        OID(column.components + [index])
    }

    /// One GET of everything the tile shows. `use64`: ask for the 64-bit
    /// counters (v2c only). If the device has no 64-bit counters for this
    /// port, a second GET asks for the 32-bit ones, and the reading says so,
    /// so the next poll can ask for those directly.
    static func read(_ client: SNMPClient, ifIndex: UInt32?, use64: Bool) async throws -> Reading {
        var oids = [SNMPOID.sysUpTime, SNMPOID.sysName]
        let ask64 = use64 && client.version == .v2c
        if let i = ifIndex {
            oids.append(column(SNMPOID.ifAdminStatus, i))
            oids.append(column(SNMPOID.ifOperStatus, i))
            if ask64 {
                oids += [column(SNMPOID.ifHCInOctets, i), column(SNMPOID.ifHCOutOctets, i)]
            } else {
                oids += [column(SNMPOID.ifInOctets, i), column(SNMPOID.ifOutOctets, i)]
            }
        }
        var values = byOID(try await client.getTolerant(oids))

        var reading = Reading()
        if let v = values[SNMPOID.sysUpTime] {
            if case .timeTicks(let t) = v {
                reading.uptimeTicks = t
            } else if let n = v.uint64 {
                reading.uptimeTicks = UInt32(exactly: n)
            }
        }
        reading.sysName = values[SNMPOID.sysName]?.string

        guard let i = ifIndex else { return reading }
        let inOID = column(ask64 ? SNMPOID.ifHCInOctets : SNMPOID.ifInOctets, i)
        let outOID = column(ask64 ? SNMPOID.ifHCOutOctets : SNMPOID.ifOutOctets, i)
        var is64 = ask64
        if ask64 && (values[inOID]?.uint64 == nil || values[outOID]?.uint64 == nil) {
            // No 64-bit counters here (RFC 2863 only requires them on ports
            // faster than 20 Mbps): ask for the 32-bit ones.
            let more = byOID(try await client.getTolerant([column(SNMPOID.ifInOctets, i),
                                                           column(SNMPOID.ifOutOctets, i)]))
            for (k, v) in more where values[k] == nil { values[k] = v }
            is64 = false
        }
        let inV = values[is64 ? inOID : column(SNMPOID.ifInOctets, i)]
        let outV = values[is64 ? outOID : column(SNMPOID.ifOutOctets, i)]
        if is64 {
            // A device that answers ifHCInOctets with a Counter32 still wraps at 32 bits.
            is64 = inV.map(isCounter64) == true && outV.map(isCounter64) == true
        }
        reading.port = PortReading(
            operStatus: values[column(SNMPOID.ifOperStatus, i)]?.int64,
            adminStatus: values[column(SNMPOID.ifAdminStatus, i)]?.int64,
            inOctets: inV?.uint64,
            outOctets: outV?.uint64,
            counters64: is64)
        return reading
    }

    /// Varbinds by OID, without exceptions (noSuchObject and friends). A
    /// misbehaving agent can repeat a varbind; keep the first.
    private static func byOID(_ vbs: [SNMPVarBind]) -> [OID: SNMPValue] {
        var out: [OID: SNMPValue] = [:]
        for vb in vbs where out[vb.oid] == nil && !vb.value.isException {
            out[vb.oid] = vb.value
        }
        return out
    }

    private static func isCounter64(_ v: SNMPValue) -> Bool {
        if case .counter64 = v { return true }
        return false
    }
}

// MARK: - Rate math

enum SNMPWatchMath {

    /// sysUpTime is a 32-bit count of hundredths of a second: it wraps
    /// after about 497 days.
    enum UptimeChange: Equatable {
        case advanced(seconds: Double)
        /// Wrapped past 2^32 once; the seconds include the wrap.
        case wrapped(seconds: Double)
        /// Went backwards: the device (or its SNMP agent) restarted.
        case restarted
    }

    /// A drop from within this many ticks of the top to within this many
    /// ticks of zero is a wrap, not a restart (one hour).
    static let wrapWindow: UInt32 = 360_000

    static func uptimeChange(from previous: UInt32, to current: UInt32) -> UptimeChange {
        if current >= previous {
            return .advanced(seconds: Double(current - previous) / 100)
        }
        if previous >= UInt32.max - wrapWindow && current <= wrapWindow {
            let ticks = (UInt64(UInt32.max) - UInt64(previous)) + UInt64(current) + 1
            return .wrapped(seconds: Double(ticks) / 100)
        }
        return .restarted
    }

    /// Octets counted between two readings. A 32-bit counter may wrap once;
    /// a 64-bit counter never wraps in practice, so going down means it was
    /// reset, and there's no delta.
    static func octetDelta(previous: UInt64, current: UInt64, counters64: Bool) -> UInt64? {
        if current >= previous { return current - previous }
        guard !counters64, previous <= UInt64(UInt32.max), current <= UInt64(UInt32.max) else { return nil }
        return (UInt64(UInt32.max) - previous) + current + 1
    }

    /// Bits per second between two counter readings `seconds` apart. A
    /// "wrap" that would mean more than 110% of the link speed is far more
    /// likely a counter reset (someone cleared the counters), so it's dropped.
    static func bitsPerSecond(previous: UInt64?, current: UInt64?, counters64: Bool,
                              seconds: Double, linkBps: UInt64?) -> Double? {
        guard let p = previous, let c = current, seconds > 0,
              let delta = octetDelta(previous: p, current: c, counters64: counters64) else { return nil }
        let bps = Double(delta) * 8 / seconds
        if c < p, let link = linkBps, link > 0, bps > Double(link) * 1.1 { return nil }
        return bps
    }

    /// Percent of the link speed, or nil when the speed isn't known.
    static func percent(_ bps: Double?, of linkBps: UInt64?) -> Double? {
        guard let bps, let link = linkBps, link > 0 else { return nil }
        return bps / Double(link) * 100
    }

    /// The fastest rate 32-bit octet counters can show when read every
    /// `interval` seconds: past that they can wrap more than once.
    static func max32BitRate(interval: Double) -> Double {
        guard interval > 0 else { return 0 }
        return Double(UInt64(UInt32.max) + 1) * 8 / interval
    }
}

// MARK: - State

struct SNMPWatchSample: Equatable {
    let date: Date
    let inBps: Double?
    let outBps: Double?
    let replyMs: Double?
}

/// What the tile shows. Updated after every poll.
struct SNMPWatchState: Equatable {
    enum Problem: Equatable {
        /// No community in the Keychain for this host.
        case noCommunity
        /// The Keychain has it, but SNAP couldn't read it.
        case communityUnreadable
        /// Timed out.
        case noAnswer
        /// The network couldn't reach the host (no route, name didn't resolve).
        case unreachable(String)
        /// The device answered with an error status.
        case refused(String)
        case unreadable
    }

    var problem: Problem?
    var lastAttempt: Date?
    var lastSuccess: Date?
    var sysName: String?
    var uptimeTicks: UInt32?
    /// When the device (or its SNMP agent) restarted: now minus its uptime.
    /// Set when SNAP sees a restart.
    var restartedAt: Date?
    /// When SNAP saw the restart: when the uptime went backwards, or the
    /// restart itself for a device first seen up less than 10 minutes.
    /// The Restarted pill shows for 10 minutes from here.
    var restartNoticedAt: Date?
    var operStatus: Int64?
    var adminStatus: Int64?
    var portMissing = false
    var counters64: Bool?
    var inBps: Double?
    var outBps: Double?
    var replyMs: Double?
    var samples: [SNMPWatchSample] = []

    static let maxSamples = 30
    /// "Restarted" shows for this long after a restart.
    static let restartWindow: TimeInterval = 600
}

/// The status pill.
enum SNMPWatchStatus: Equatable {
    case checking, noCommunity, notAnswering, error, restarted, portMissing, portDown, up

    var label: String {
        switch self {
        case .checking:     return "Checking"
        case .noCommunity:  return "No community"
        case .notAnswering: return "Not answering"
        case .error:        return "Error"
        case .restarted:    return "Restarted"
        case .portMissing:  return "Port not found"
        case .portDown:     return "Port down"
        case .up:           return "Up"
        }
    }
}

extension SNMPWatchState {
    func status(watchingPort: Bool, now: Date) -> SNMPWatchStatus {
        switch problem {
        case .noCommunity?, .communityUnreadable?:  return .noCommunity
        case .noAnswer?, .unreachable?:             return .notAnswering
        case .refused?, .unreadable?:               return .error
        case nil:                                   break
        }
        guard lastSuccess != nil else { return .checking }
        if let n = restartNoticedAt, now.timeIntervalSince(n) < Self.restartWindow { return .restarted }
        if watchingPort {
            if portMissing { return .portMissing }
            if operStatus != 1 { return .portDown }
        }
        return .up
    }

    /// Why a port that answered isn't up, in the MIB's own words. nil when
    /// it's up, missing, or not known.
    var portDownNote: String? {
        guard !portMissing, let oper = operStatus, oper != 1 else { return nil }
        if adminStatus == 2 { return "The port is turned off on the device (ifAdminStatus down)." }
        return "The port isn't up (ifOperStatus \(Self.operStatusName(oper)))."
    }

    /// RFC 2863 ifOperStatus names.
    static func operStatusName(_ v: Int64) -> String {
        switch v {
        case 1: return "up"
        case 2: return "down"
        case 3: return "testing"
        case 4: return "unknown"
        case 5: return "dormant"
        case 6: return "notPresent"
        case 7: return "lowerLayerDown"
        default: return String(v)
        }
    }
}

// MARK: - Watch

/// What the watch needs from the rest of the app. Tests pass their own.
struct SNMPBoardWatchEnvironment {
    var defaults: UserDefaults
    /// True while the Status Board is open (in the window or detached). The
    /// in-window board still counts as open after its window closes, so
    /// polling also needs a tile on screen (SNMPBoardWatch.tileAppeared).
    var isBoardShowing: @MainActor () -> Bool
    var boardHasTile: @MainActor () -> Bool
    var addTileToBoard: @MainActor () -> Void
    /// Fires when the board opens or closes, or its tiles change.
    var boardChanges: AnyPublisher<Void, Never>
    var makeClient: (SNMPBoardTarget, String) -> SNMPClient
    var interval: TimeInterval = 10

    static let targetKey = "com.bardaklabs.snap.snmpWatch.v1"

    @MainActor static var live: SNMPBoardWatchEnvironment {
        let board = StatusBoardManager.shared
        let layout = StatusBoardLayout.shared
        return SNMPBoardWatchEnvironment(
            defaults: .standard,
            isBoardShowing: { board.isPresented || board.isDetached },
            boardHasTile: { layout.tiles.contains(.snmpWatch) },
            addTileToBoard: { layout.add(.snmpWatch) },
            boardChanges: board.objectWillChange.map { _ in () }
                .merge(with: layout.objectWillChange.map { _ in () })
                .eraseToAnyPublisher(),
            makeClient: { target, community in
                SNMPClient(host: target.host, port: target.port, community: community,
                           version: target.snmpVersion, timeout: 2, retries: 1)
            })
    }
}

@MainActor
final class SNMPBoardWatch: ObservableObject {
    static let shared = SNMPBoardWatch(environment: .live)

    @Published private(set) var target: SNMPBoardTarget?
    @Published private(set) var state = SNMPWatchState()

    private let env: SNMPBoardWatchEnvironment
    private var boardSub: AnyCancellable?
    private var loop: Task<Void, Never>?
    /// Bumped by pin, unpin, and every start and stop of polling. A poll only
    /// publishes while its generation is current.
    private var generation = 0
    /// The generation of the poll in flight, so two never overlap.
    private var inFlight: Int?

    /// The last reading, for counter deltas. Cleared when polling restarts,
    /// so a rate always covers one poll, not the time the board was closed.
    private var baseline: (ticks: UInt32?, inOctets: UInt64?, outOctets: UInt64?, counters64: Bool, at: Date)?
    /// The last uptime seen for this target, kept across board openings so a
    /// restart while the board was closed still shows.
    private var lastUptimeTicks: UInt32?
    /// sysUpTime wrapped past 2^32 (about 497 days) and hasn't yet counted
    /// 10 minutes since: its low value is the wrap, not a restart.
    private var uptimeWrapped = false
    /// Ask for 64-bit counters until the device shows it has none for the port.
    private var use64 = true
    private var cachedCommunity: (account: String, value: String, revision: Int)?
    /// SNMP Watch tiles on screen right now, from their onAppear and
    /// onDisappear. More than one when several windows show the board.
    private var tilesOnScreen: Set<UUID> = []

    var isPolling: Bool { loop != nil }

    init(environment: SNMPBoardWatchEnvironment) {
        env = environment
        target = Self.loadTarget(environment.defaults)
        boardSub = environment.boardChanges.sink { [weak self] _ in
            // objectWillChange fires before the value changes: look after it has.
            Task { @MainActor in self?.boardChanged() }
        }
        updatePolling()
    }

    // MARK: Tiles on screen

    /// The tile calls this from onAppear.
    func tileAppeared(_ id: UUID) {
        tilesOnScreen.insert(id)
        updatePolling()
    }

    /// The tile calls this from onDisappear: the board closed, the tile was
    /// removed, or the window holding the board closed.
    func tileDisappeared(_ id: UUID) {
        tilesOnScreen.remove(id)
        updatePolling()
    }

    private func boardChanged() {
        // With the board closed no tile can be on screen. Forgetting them
        // here means a tile whose onDisappear never came can't keep the
        // polling going later.
        if !env.isBoardShowing() { tilesOnScreen.removeAll() }
        updatePolling()
    }

    // MARK: Pin

    /// Watches `target`, saving the board's own copy of the community.
    /// Remember's saved communities aren't touched.
    func pin(_ target: SNMPBoardTarget, community: String) {
        SNMPCommunityStore.saveForBoard(community: community, host: target.host, port: target.port)
        stopPolling()
        self.target = target
        saveTarget()
        resetForNewTarget()
        if let a = SNMPCommunityStore.account(host: target.host, port: target.port),
           SNMPCommunityStore.hasBoardCopy(host: target.host, port: target.port) {
            cachedCommunity = (a, community, SNMPCommunityStore.revision)
        }
        if !env.boardHasTile() { env.addTileToBoard() }
        updatePolling()
    }

    /// Stops watching and deletes the board's copy of the community. A
    /// community saved with Remember in the SNMP tab stays.
    func unpin() {
        stopPolling()
        target = nil
        saveTarget()
        resetForNewTarget()
        SNMPCommunityStore.forgetForBoard()
    }

    private func resetForNewTarget() {
        generation += 1
        state = SNMPWatchState()
        baseline = nil
        lastUptimeTicks = nil
        uptimeWrapped = false
        use64 = true
        cachedCommunity = nil
    }

    // MARK: Persistence

    private static func loadTarget(_ defaults: UserDefaults) -> SNMPBoardTarget? {
        guard let data = defaults.data(forKey: SNMPBoardWatchEnvironment.targetKey) else { return nil }
        return try? JSONDecoder().decode(SNMPBoardTarget.self, from: data)
    }

    private func saveTarget() {
        let key = SNMPBoardWatchEnvironment.targetKey
        if let target, let data = try? JSONEncoder().encode(target) {
            env.defaults.set(data, forKey: key)
        } else {
            env.defaults.removeObject(forKey: key)
        }
    }

    // MARK: Polling

    /// Polls only while something is pinned and the board is open, has this
    /// tile, and shows it on screen.
    func updatePolling() {
        let should = target != nil && !tilesOnScreen.isEmpty
            && env.isBoardShowing() && env.boardHasTile()
        if should, loop == nil {
            startPolling()
        } else if !should, loop != nil {
            stopPolling()
        }
    }

    private func startPolling() {
        generation += 1
        baseline = nil
        state.samples = []
        state.inBps = nil
        state.outBps = nil
        let interval = max(0.01, env.interval)
        loop = Task { [weak self] in
            while !Task.isCancelled {
                let started = Date()
                // Holds the watch only for the poll itself, not while sleeping.
                if await self?.pollNow() == nil { return }
                let wait = max(0.01, interval - Date().timeIntervalSince(started))
                do {
                    try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                } catch {
                    return
                }
            }
        }
    }

    private func stopPolling() {
        loop?.cancel()
        loop = nil
        generation += 1
    }

    /// One poll now. The loop calls this; tests call it directly.
    func pollNow() async {
        guard let target, inFlight != generation else { return }
        let gen = generation
        guard let community = community(for: target) else { return }
        inFlight = gen
        defer { if inFlight == gen { inFlight = nil } }

        let client = env.makeClient(target, community)
        let started = Date()
        do {
            let reading = try await SNMPBoardPoll.read(client, ifIndex: target.ifIndex, use64: use64)
            guard gen == generation else { return }
            apply(reading, target: target, at: Date(), replyMs: Date().timeIntervalSince(started) * 1000)
        } catch {
            guard gen == generation, !(error is CancellationError) else { return }
            fail(Self.problem(for: error), at: Date())
        }
    }

    /// The board's copy of the community for this target: from memory while
    /// the store hasn't changed, else from the Keychain. The store doesn't
    /// retry a Keychain read that failed until something is saved or
    /// forgotten, so a refused Keychain prompt doesn't come back every
    /// 10 seconds.
    private func community(for t: SNMPBoardTarget) -> String? {
        guard let account = SNMPCommunityStore.account(host: t.host, port: t.port),
              SNMPCommunityStore.hasBoardCopy(host: t.host, port: t.port) else {
            cachedCommunity = nil
            noCommunity(.noCommunity)
            return nil
        }
        let rev = SNMPCommunityStore.revision
        if let c = cachedCommunity, c.account == account, c.revision == rev { return c.value }
        guard let value = SNMPCommunityStore.loadForBoard(host: t.host, port: t.port) else {
            // Still there but unreadable, or found missing just now.
            noCommunity(SNMPCommunityStore.hasBoardCopy(host: t.host, port: t.port)
                        ? .communityUnreadable : .noCommunity)
            cachedCommunity = nil
            return nil
        }
        cachedCommunity = (account, value, SNMPCommunityStore.revision)
        return value
    }

    private func noCommunity(_ p: SNMPWatchState.Problem) {
        guard state.problem != p || state.inBps != nil || state.outBps != nil else { return }
        state.problem = p
        state.inBps = nil
        state.outBps = nil
        baseline = nil
    }

    nonisolated static func problem(for error: Error) -> SNMPWatchState.Problem {
        switch error as? SNMPError {
        case .timeout?:                         return .noAnswer
        case .transport(let message)?:          return .unreachable(message)
        case .errorStatus(_, let label, _)?:    return .refused(label)
        default:                                return .unreadable
        }
    }

    private func fail(_ problem: SNMPWatchState.Problem, at now: Date) {
        var s = state
        s.problem = problem
        s.lastAttempt = now
        s.inBps = nil
        s.outBps = nil
        s.replyMs = nil
        if baseline != nil || !s.samples.isEmpty {
            s.samples.append(SNMPWatchSample(date: now, inBps: nil, outBps: nil, replyMs: nil))
            if s.samples.count > SNMPWatchState.maxSamples {
                s.samples.removeFirst(s.samples.count - SNMPWatchState.maxSamples)
            }
        }
        baseline = nil
        state = s
    }

    private func apply(_ r: SNMPBoardPoll.Reading, target: SNMPBoardTarget, at now: Date, replyMs: Double) {
        var s = state
        s.problem = nil
        s.lastAttempt = now
        s.lastSuccess = now
        s.replyMs = replyMs
        if let name = r.sysName, !name.isEmpty { s.sysName = name }

        var restarted = false
        var ticksSeconds: Double?
        if let ticks = r.uptimeTicks {
            let bootedAt = now.addingTimeInterval(-Double(ticks) / 100)
            let change = lastUptimeTicks.map { SNMPWatchMath.uptimeChange(from: $0, to: ticks) }
            switch change {
            case .restarted?: uptimeWrapped = false
            case .wrapped?:   uptimeWrapped = true
            default:          break
            }
            if change == .restarted {
                // Possibly long ago, while the board was closed: say when.
                restarted = true
                s.restartedAt = bootedAt
                s.restartNoticedAt = now
            } else if !uptimeWrapped, now.timeIntervalSince(bootedAt) < SNMPWatchState.restartWindow {
                // Up less than 10 minutes: it restarted, even if SNAP didn't
                // see it go. Not just after a wrap: then the device has been
                // up about 497 days longer than the counter says.
                s.restartedAt = bootedAt
                s.restartNoticedAt = max(s.restartNoticedAt ?? bootedAt, bootedAt)
            }
            if Double(ticks) / 100 >= SNMPWatchState.restartWindow { uptimeWrapped = false }
            if let b = baseline, let prev = b.ticks {
                switch SNMPWatchMath.uptimeChange(from: prev, to: ticks) {
                case .advanced(let secs), .wrapped(let secs): ticksSeconds = secs
                case .restarted: break
                }
            }
            lastUptimeTicks = ticks
            s.uptimeTicks = ticks
        }

        var inBps: Double?
        var outBps: Double?
        let hadBaseline = baseline != nil
        if let p = r.port {
            s.operStatus = p.operStatus
            s.adminStatus = p.adminStatus
            s.portMissing = p.operStatus == nil
            s.counters64 = p.inOctets == nil ? nil : p.counters64
            if !p.counters64 && p.inOctets != nil { use64 = false }
            if let b = baseline, !restarted, b.counters64 == p.counters64 {
                // The device's own clock when it has one, else this Mac's.
                let secs = (ticksSeconds ?? 0) > 0 ? (ticksSeconds ?? 0) : now.timeIntervalSince(b.at)
                inBps = SNMPWatchMath.bitsPerSecond(previous: b.inOctets, current: p.inOctets,
                                                    counters64: p.counters64, seconds: secs,
                                                    linkBps: target.speedBps)
                outBps = SNMPWatchMath.bitsPerSecond(previous: b.outOctets, current: p.outOctets,
                                                     counters64: p.counters64, seconds: secs,
                                                     linkBps: target.speedBps)
            }
            baseline = (r.uptimeTicks, p.inOctets, p.outOctets, p.counters64, now)
        } else {
            baseline = (r.uptimeTicks, nil, nil, false, now)
        }
        s.inBps = inBps
        s.outBps = outBps

        if hadBaseline || r.port == nil {
            s.samples.append(SNMPWatchSample(date: now, inBps: inBps, outBps: outBps, replyMs: replyMs))
            if s.samples.count > SNMPWatchState.maxSamples {
                s.samples.removeFirst(s.samples.count - SNMPWatchState.maxSamples)
            }
        }
        state = s
    }
}

// MARK: - Formatting

enum SNMPWatchFormat {
    /// "12d 4h", "3h 12m", "8m", "40s" from sysUpTime ticks.
    static func uptime(_ ticks: UInt32) -> String {
        let s = Int(ticks / 100)
        let d = s / 86_400, h = (s % 86_400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(s)s"
    }

    /// "1 Gbps", "2.5 Gbps", "100 Mbps". Decimal units.
    static func speed(_ bps: UInt64) -> String {
        func f(_ v: Double, _ unit: String) -> String {
            String(format: v == v.rounded() ? "%.0f %@" : "%.1f %@", v, unit)
        }
        if bps >= 1_000_000_000 { return f(Double(bps) / 1e9, "Gbps") }
        if bps >= 1_000_000 { return f(Double(bps) / 1e6, "Mbps") }
        if bps >= 1_000 { return f(Double(bps) / 1e3, "kbps") }
        return "\(bps) bps"
    }

    /// "94%", "<1%" (for any traffic under 1%), "0%".
    static func percent(_ pct: Double) -> String {
        if pct > 0 && pct < 1 { return "<1%" }
        return "\(Int(pct.rounded()))%"
    }

    static func ms(_ ms: Double) -> String {
        ms < 10 ? String(format: "%.1f ms", ms) : String(format: "%.0f ms", ms)
    }
}

// MARK: - Tile

struct SBSNMPWatchTile: View {
    @ObservedObject private var watch = SNMPBoardWatch.shared
    private var themeMgr = ThemeManager.shared
    @State private var tileID = UUID()

    init() {}

    var body: some View {
        // One container, so switching between pinned and empty doesn't
        // count as the tile leaving the screen.
        ZStack {
            if let target = watch.target {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    SNMPWatchTileContent(target: target, state: watch.state, now: context.date,
                                         unpin: { watch.unpin() })
                }
            } else {
                SNMPWatchEmptyState()
            }
        }
        // The watch polls only while a tile is on screen, so closing the
        // window that holds the board stops it.
        .onAppear { watch.tileAppeared(tileID) }
        .onDisappear { watch.tileDisappeared(tileID) }
    }
}

/// Nothing pinned: how to pin something.
struct SNMPWatchEmptyState: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "pin.slash")
                .font(.system(size: 34)).foregroundStyle(NS.text4)
            Text("Nothing pinned yet")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(NS.text2)
            Text("In the SNMP tab, query a device and click Show on Status Board: in System Info to watch the device, or in Interfaces to watch one port.")
                .font(.system(size: 11)).foregroundStyle(NS.text3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 300)
            Button {
                openSNMP()
            } label: {
                Label("Open SNMP", systemImage: "network.badge.shield.half.filled")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderedProminent).controlSize(.small).tint(NS.amber)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The in-window board covers the tabs, so it closes first; a detached
    /// board stays up in its own window.
    private func openSNMP() {
        if !StatusBoardManager.shared.isDetached {
            StatusBoardManager.shared.isPresented = false
        }
        ToolHandoff.shared.goto(.snmp)
    }
}

/// A pinned device or port. Takes `now` so the relative times and the
/// Restarted pill's 10 minutes tick over.
struct SNMPWatchTileContent: View {
    let target: SNMPBoardTarget
    let state: SNMPWatchState
    let now: Date
    let unpin: () -> Void

    private var status: SNMPWatchStatus { state.status(watchingPort: target.watchesPort, now: now) }

    private var title: String {
        if let n = state.sysName, !n.isEmpty { return n }
        if let n = target.deviceName, !n.isEmpty { return n }
        return target.host
    }

    /// Readings are hidden while there's nothing current to show.
    private var showsReadings: Bool {
        state.problem == nil && !(target.watchesPort && state.portMissing && state.lastSuccess != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let note = notice {
                Text(verbatim: note.text)
                    .font(.system(size: 11))
                    .foregroundStyle(note.color)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showsReadings {
                if target.watchesPort { rates } else { replyTime }
            }
            Group {
                if target.watchesPort {
                    SNMPWatchSparkline(series: [(state.samples.map(\.inBps), NS.green),
                                                (state.samples.map(\.outBps), NS.blue)])
                } else {
                    SNMPWatchSparkline(series: [(state.samples.map(\.replyMs), NS.amber)])
                }
            }
            .frame(maxWidth: .infinity, minHeight: 28, maxHeight: .infinity)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(NS.text1)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                StatusPill(text: status.label.uppercased(), color: statusColor,
                           pulse: status == .up)
                    .fixedSize()
            }
            Text(verbatim: subtitle)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(NS.text3)
                .lineLimit(1).truncationMode(.middle)
        }
    }

    /// "Gi1/0/24 · 1 Gbps · 10.0.0.2" for a port; "10.0.0.2 · v2c" for a device.
    private var subtitle: String {
        var parts: [String] = []
        let hostPart = target.port == 161 ? target.host : "\(target.host):\(target.port)"
        if let i = target.ifIndex {
            parts.append(target.portName.flatMap { $0.isEmpty ? nil : $0 } ?? "ifIndex \(i)")
            if let sp = target.speedBps, sp > 0 { parts.append(SNMPWatchFormat.speed(sp)) }
            parts.append(hostPart)
        } else {
            parts.append(hostPart)
            parts.append(target.snmpVersion.label)
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    private var statusColor: Color {
        switch status {
        case .up:                       return NS.green
        case .restarted, .portMissing,
             .noCommunity:              return NS.amber
        case .portDown:                 return state.adminStatus == 2 ? NS.amber : NS.red
        case .notAnswering, .error:     return NS.red
        case .checking:                 return NS.text3
        }
    }

    /// One line under the header: a problem (red; amber when it's about the
    /// saved community), or something worth knowing (amber or gray).
    private var notice: (text: String, color: Color)? {
        switch state.problem {
        case .noCommunity?:
            return ("The community isn't saved. Pin it again from the SNMP tab.", NS.amber)
        case .communityUnreadable?:
            return ("SNAP couldn't read the community from your Keychain. Pin it again from the SNMP tab.", NS.amber)
        case .noAnswer?:
            if let last = state.lastSuccess {
                return ("No answer to the last request. Last answer \(SNMPFormat.ago(now.timeIntervalSince(last))).", NS.red)
            }
            return ("No answer yet. Check that the device is on and still accepts SNMP from this Mac.", NS.red)
        case .unreachable(let message)?:
            return ("Couldn't reach \(target.host): \(message).", NS.red)
        case .refused(let label)?:
            return ("The device refused the request (\(label)).", NS.red)
        case .unreadable?:
            return ("The reply couldn't be read as SNMP.", NS.red)
        case nil:
            break
        }
        if target.watchesPort, state.portMissing, state.lastSuccess != nil {
            let index = target.ifIndex.map { String($0) } ?? ""
            return ("No port with ifIndex \(index) now. Port numbers can change after a restart: pin the port again from Interfaces.", NS.amber)
        }
        if target.watchesPort, let note = state.portDownNote {
            return (note, state.adminStatus == 2 ? NS.amber : NS.red)
        }
        if status == .restarted, let r = state.restartedAt {
            return ("Restarted \(SNMPFormat.ago(max(0, now.timeIntervalSince(r)))).", NS.amber)
        }
        if target.watchesPort, state.counters64 == false, let sp = target.speedBps,
           Double(sp) > SNMPWatchMath.max32BitRate(interval: 10) {
            return ("32-bit counters: rates above \(SNMPFormat.rate(SNMPWatchMath.max32BitRate(interval: 10))) read low.", NS.text3)
        }
        return nil
    }

    // MARK: Rates

    private var rates: some View {
        HStack(alignment: .top, spacing: 16) {
            rateCell("IN \u{2193}", state.inBps, NS.green, alignment: .leading)
            rateCell("OUT \u{2191}", state.outBps, NS.blue, alignment: .trailing)
        }
    }

    private func rateCell(_ label: String, _ bps: Double?, _ color: Color,
                          alignment: HorizontalAlignment) -> some View {
        let pct = SNMPWatchMath.percent(bps, of: target.speedBps)
        let frameAlign: Alignment = alignment == .leading ? .leading : .trailing
        return VStack(alignment: alignment, spacing: 2) {
            Text(label).font(.system(size: 9, weight: .bold)).tracking(0.5)
                .foregroundStyle(NS.text3)
            Text(verbatim: bps.map(SNMPFormat.rate) ?? "\u{2026}")
                .font(.system(size: 26, weight: .heavy, design: .monospaced))
                .foregroundStyle(bps == nil ? NS.text3 : color)
                .lineLimit(1).minimumScaleFactor(0.55)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(NS.bg3)
                    Capsule().fill(color)
                        .frame(width: geo.size.width * CGFloat(min(1, max(0, (pct ?? 0) / 100))))
                }
            }
            .frame(height: 4)
            Text(verbatim: rateCaption(bps: bps, pct: pct))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(NS.text3)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: frameAlign)
    }

    private func rateCaption(bps: Double?, pct: Double?) -> String {
        guard state.lastSuccess != nil, state.problem == nil else { return " " }
        if bps == nil {
            return state.portMissing || state.counters64 == nil ? "No traffic counters" : "Rate after the next reading"
        }
        if let pct, let sp = target.speedBps { return "\(SNMPWatchFormat.percent(pct)) of \(SNMPWatchFormat.speed(sp))" }
        return "Link speed unknown"
    }

    // MARK: Device only

    private var replyTime: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("REPLY TIME").font(.system(size: 9, weight: .bold)).tracking(0.5)
                .foregroundStyle(NS.text3)
            Text(verbatim: state.replyMs.map(SNMPWatchFormat.ms) ?? "\u{2026}")
                .font(.system(size: 26, weight: .heavy, design: .monospaced))
                .foregroundStyle(state.replyMs == nil ? NS.text3 : NS.amber)
                .lineLimit(1).minimumScaleFactor(0.55)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(alignment: .bottom, spacing: 14) {
            cell("UPTIME", state.uptimeTicks.map(SNMPWatchFormat.uptime) ?? "\u{2026}")
            cell("UPDATED", state.lastSuccess.map { SNMPFormat.ago(now.timeIntervalSince($0)) } ?? "not yet")
            Spacer(minLength: 0)
            Button(action: unpin) {
                Label("Unpin", systemImage: "pin.slash")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.bordered).controlSize(.small)
            .help("Stop watching this on the Status Board")
        }
        .padding(.top, 8)
        .overlay(Divider().background(NS.border), alignment: .top)
    }

    private func cell(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k).font(.system(size: 9, weight: .bold)).tracking(0.5).foregroundStyle(NS.text3)
            Text(verbatim: v).font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(NS.text1).lineLimit(1)
        }
    }
}

/// Line and area sparkline for one or more series on one shared scale from
/// zero, so In and Out compare honestly. nil values leave gaps.
private struct SNMPWatchSparkline: View {
    let series: [([Double?], Color)]

    var body: some View {
        GeometryReader { geo in
            let peak = series.flatMap { $0.0.compactMap { $0 } }.max() ?? 0
            let count = series.map(\.0.count).max() ?? 0
            // All zero (an idle port) draws a flat line along the bottom.
            let scale = peak > 0 ? peak : 1
            if count >= 1, count <= SNMPWatchState.maxSamples {
                let w = geo.size.width, h = geo.size.height
                let step = w / CGFloat(SNMPWatchState.maxSamples - 1)
                // Newest sample on the right edge.
                let offset = CGFloat(SNMPWatchState.maxSamples - count) * step
                ZStack {
                    ForEach(0..<series.count, id: \.self) { s in
                        let runs = Self.runs(series[s].0, step: step, offset: offset, height: h, peak: scale)
                        ForEach(0..<runs.count, id: \.self) { r in
                            let pts = runs[r]
                            if let first = pts.first, let last = pts.last {
                                Path { p in
                                    p.move(to: CGPoint(x: first.x, y: h))
                                    for pt in pts { p.addLine(to: pt) }
                                    p.addLine(to: CGPoint(x: last.x, y: h))
                                    p.closeSubpath()
                                }
                                .fill(series[s].1.opacity(0.16))
                                Path { p in
                                    p.move(to: first)
                                    for pt in pts.dropFirst() { p.addLine(to: pt) }
                                }
                                .stroke(series[s].1, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                            }
                        }
                    }
                }
            }
        }
    }

    /// Unbroken runs of points; a nil sample ends a run.
    private static func runs(_ values: [Double?], step: CGFloat, offset: CGFloat,
                             height h: CGFloat, peak: Double) -> [[CGPoint]] {
        var out: [[CGPoint]] = []
        var current: [CGPoint] = []
        for (i, v) in values.enumerated() {
            guard let v else {
                if !current.isEmpty { out.append(current); current = [] }
                continue
            }
            let y = h - CGFloat(v / peak) * (h - 3) - 1
            current.append(CGPoint(x: offset + CGFloat(i) * step, y: y))
        }
        if !current.isEmpty { out.append(current) }
        // A lone point has no line; draw it as a short flat run.
        return out.map { $0.count == 1 ? [$0[0], CGPoint(x: $0[0].x + 1, y: $0[0].y)] : $0 }
    }
}
