// SNMPBoardTests.swift
// SNAP — Tests
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md
//
// Remembered communities (SNMPCommunityStore) and the Status Board's SNMP
// Watch tile (SNMPBoardWatch). Everything runs against test stores: an
// in-memory secret store, a test UserDefaults suite, a test Keychain
// service, and FakeSNMPAgent in place of the network.

import XCTest
import Combine
@testable import SNAP

/// Stands in for the Keychain and counts how often it's read.
private final class MemorySecrets: SNMPSecretStore {
    var items: [String: String] = [:]
    var reads = 0
    var failReads = false
    var failWrites = false

    func read(account: String) -> SNMPSecretLookup {
        reads += 1
        if failReads { return .failed }
        return items[account].map { .found($0) } ?? .missing
    }

    func write(account: String, secret: String) -> Bool {
        items[account] = nil
        guard !failWrites else { return false }
        items[account] = secret
        return true
    }

    func delete(account: String) { items[account] = nil }
}

/// The board and network as the watch sees them, under the test's control.
private final class BoardHarness {
    var showing = false
    var hasTile = true
    var addTileCalls = 0
    let changes = PassthroughSubject<Void, Never>()
    /// Communities the watch asked with, one per poll that sent a request.
    var communities: [String] = []
    var makeClient: (SNMPBoardTarget, String) -> SNMPClient = { _, _ in
        FakeSNMPAgent([]).client()
    }

    func environment(_ defaults: UserDefaults, interval: TimeInterval = 10) -> SNMPBoardWatchEnvironment {
        SNMPBoardWatchEnvironment(
            defaults: defaults,
            isBoardShowing: { [unowned self] in self.showing },
            boardHasTile: { [unowned self] in self.hasTile },
            addTileToBoard: { [unowned self] in self.hasTile = true; self.addTileCalls += 1 },
            boardChanges: changes.eraseToAnyPublisher(),
            makeClient: { [unowned self] target, community in
                self.communities.append(community)
                return self.makeClient(target, community)
            },
            interval: interval)
    }

    /// Each poll gets the next agent; the last one repeats.
    func answer(with agents: [FakeSNMPAgent], version: SNMPVersion = .v2c) {
        var queue = agents
        makeClient = { _, _ in
            let a = queue.count > 1 ? queue.removeFirst() : queue[0]
            return a.client(version: version)
        }
    }
}

final class SNMPBoardTests: XCTestCase {
    private let suiteName = "com.bardaklabs.snap.tests.SNMPBoardTests"
    private let indexKey = "test.snmp.rememberedHosts"
    private var defaults: UserDefaults!
    private var secrets: MemorySecrets!
    private var liveBackend: SNMPCommunityStore.Backend?

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        secrets = MemorySecrets()
        liveBackend = SNMPCommunityStore.backend
        SNMPCommunityStore.backend = .init(secrets: secrets, defaults: defaults, indexKey: indexKey)
    }

    override func tearDown() {
        if let liveBackend { SNMPCommunityStore.backend = liveBackend }
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        secrets = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private let portTarget = SNMPBoardTarget(host: "10.0.0.2", port: 161, version: SNMPVersion.v2c.rawValue,
                                             deviceName: "core-sw1", ifIndex: 3, portName: "Gi1/0/3",
                                             speedBps: 1_000_000_000)
    private let deviceTarget = SNMPBoardTarget(host: "nas.local", port: 161, version: SNMPVersion.v1.rawValue,
                                               deviceName: nil, ifIndex: nil, portName: nil, speedBps: nil)

    /// A switch with one port at `ifIndex`. `hc`: it has 64-bit counters.
    private func agent(uptime: UInt32, inOctets: UInt64, outOctets: UInt64, ifIndex: UInt32 = 3,
                       hc: Bool = true, oper: Int64 = 1) -> FakeSNMPAgent {
        var e: [(String, SNMPValue)] = [
            ("1.3.6.1.2.1.1.3.0", .timeTicks(uptime)),
            ("1.3.6.1.2.1.1.5.0", .octetString(Data("core-sw1".utf8))),
            ("1.3.6.1.2.1.2.2.1.7.\(ifIndex)", .integer(1)),
            ("1.3.6.1.2.1.2.2.1.8.\(ifIndex)", .integer(oper)),
            ("1.3.6.1.2.1.2.2.1.10.\(ifIndex)", .counter32(UInt32(truncatingIfNeeded: inOctets))),
            ("1.3.6.1.2.1.2.2.1.16.\(ifIndex)", .counter32(UInt32(truncatingIfNeeded: outOctets))),
        ]
        if hc {
            e.append(("1.3.6.1.2.1.31.1.1.1.6.\(ifIndex)", .counter64(inOctets)))
            e.append(("1.3.6.1.2.1.31.1.1.1.10.\(ifIndex)", .counter64(outOctets)))
        }
        return FakeSNMPAgent(e)
    }

    private var getTag: UInt8 { ASN1Tag.getRequest.rawValue }

    @MainActor
    private func waitUntil(_ what: String, timeout: TimeInterval = 3,
                           _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("Timed out waiting: \(what)"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - Community store

    func test_store_saveLoadAndReplace() {
        SNMPCommunityStore.save(host: "10.0.0.2", port: 161, community: "s3cret")
        XCTAssertTrue(SNMPCommunityStore.hasSaved(host: "10.0.0.2", port: 161))
        XCTAssertEqual(SNMPCommunityStore.load(host: "10.0.0.2", port: 161), "s3cret")

        SNMPCommunityStore.save(host: "10.0.0.2", port: 161, community: "rotated")
        XCTAssertEqual(SNMPCommunityStore.load(host: "10.0.0.2", port: 161), "rotated")
        XCTAssertEqual(SNMPCommunityStore.savedCount, 1)
        XCTAssertEqual(secrets.items, ["10.0.0.2:161": "rotated"])
        XCTAssertEqual(defaults.stringArray(forKey: indexKey), ["10.0.0.2:161"])
        // The index holds names only, never the secret.
        XCTAssertFalse((defaults.stringArray(forKey: indexKey) ?? []).joined().contains("rotated"))
    }

    func test_store_normalizesHost() {
        SNMPCommunityStore.save(host: "  Core-SW1.Example.COM \n", port: 161, community: "c")
        XCTAssertEqual(Array(secrets.items.keys), ["core-sw1.example.com:161"])
        XCTAssertTrue(SNMPCommunityStore.hasSaved(host: "core-sw1.example.com", port: 161))
        XCTAssertTrue(SNMPCommunityStore.hasSaved(host: "CORE-SW1.example.com ", port: 161))
        XCTAssertFalse(SNMPCommunityStore.hasSaved(host: "core-sw1.example.com", port: 1161))
        XCTAssertEqual(SNMPCommunityStore.load(host: "Core-SW1.example.com", port: 161), "c")
        XCTAssertEqual(SNMPCommunityStore.account(host: " 10.0.0.2 ", port: 1161), "10.0.0.2:1161")
        XCTAssertNil(SNMPCommunityStore.account(host: "  ", port: 161))
    }

    func test_store_indexAnswersWithoutReadingTheKeychain() {
        SNMPCommunityStore.save(host: "10.0.0.2", port: 161, community: "c")
        secrets.reads = 0
        XCTAssertTrue(SNMPCommunityStore.hasSaved(host: "10.0.0.2", port: 161))
        XCTAssertFalse(SNMPCommunityStore.hasSaved(host: "10.0.0.3", port: 161))
        XCTAssertEqual(SNMPCommunityStore.savedCount, 1)
        XCTAssertNil(SNMPCommunityStore.load(host: "10.0.0.3", port: 161))   // not in the index
        XCTAssertEqual(secrets.reads, 0)
        XCTAssertEqual(SNMPCommunityStore.load(host: "10.0.0.2", port: 161), "c")
        XCTAssertEqual(secrets.reads, 1)
    }

    func test_store_forgetAndForgetAll() {
        SNMPCommunityStore.save(host: "a", port: 161, community: "1")
        SNMPCommunityStore.save(host: "b", port: 161, community: "2")
        SNMPCommunityStore.save(host: "b", port: 1161, community: "3")
        XCTAssertEqual(SNMPCommunityStore.savedCount, 3)

        SNMPCommunityStore.forget(host: "B", port: 161)
        XCTAssertFalse(SNMPCommunityStore.hasSaved(host: "b", port: 161))
        XCTAssertNil(SNMPCommunityStore.load(host: "b", port: 161))
        XCTAssertNil(secrets.items["b:161"])
        XCTAssertEqual(SNMPCommunityStore.savedAccounts, ["a:161", "b:1161"])

        SNMPCommunityStore.forgetAll()
        XCTAssertEqual(SNMPCommunityStore.savedCount, 0)
        XCTAssertTrue(secrets.items.isEmpty)
        XCTAssertNil(defaults.object(forKey: indexKey))
    }

    func test_store_ignoresEmptyHostAndCommunity() {
        SNMPCommunityStore.save(host: " ", port: 161, community: "c")
        SNMPCommunityStore.save(host: "10.0.0.2", port: 161, community: "")
        XCTAssertEqual(SNMPCommunityStore.savedCount, 0)
        XCTAssertTrue(secrets.items.isEmpty)
        XCTAssertFalse(SNMPCommunityStore.hasSaved(host: "", port: 161))
    }

    /// Deleted in Keychain Access: the index entry goes too, so the count
    /// and the Remember box stay honest.
    func test_store_dropsEntryWhoseKeychainItemIsGone() {
        SNMPCommunityStore.save(host: "10.0.0.2", port: 161, community: "c")
        secrets.items = [:]
        XCTAssertNil(SNMPCommunityStore.load(host: "10.0.0.2", port: 161))
        XCTAssertFalse(SNMPCommunityStore.hasSaved(host: "10.0.0.2", port: 161))
        XCTAssertEqual(SNMPCommunityStore.savedCount, 0)
    }

    /// A refused or locked Keychain isn't the same as "not saved".
    func test_store_failedReadKeepsEntry_failedWriteDropsIt() {
        SNMPCommunityStore.save(host: "10.0.0.2", port: 161, community: "c")
        secrets.failReads = true
        XCTAssertNil(SNMPCommunityStore.load(host: "10.0.0.2", port: 161))
        XCTAssertTrue(SNMPCommunityStore.hasSaved(host: "10.0.0.2", port: 161))

        secrets.failWrites = true
        SNMPCommunityStore.save(host: "10.0.0.2", port: 161, community: "new")
        XCTAssertFalse(SNMPCommunityStore.hasSaved(host: "10.0.0.2", port: 161))
    }

    func test_store_revisionChangesOnEveryWrite() {
        let r0 = SNMPCommunityStore.revision
        SNMPCommunityStore.save(host: "a", port: 161, community: "1")
        let r1 = SNMPCommunityStore.revision
        XCTAssertGreaterThan(r1, r0)
        _ = SNMPCommunityStore.hasSaved(host: "a", port: 161)
        _ = SNMPCommunityStore.load(host: "a", port: 161)
        XCTAssertEqual(SNMPCommunityStore.revision, r1)       // reads don't count
        SNMPCommunityStore.forget(host: "a", port: 161)
        XCTAssertGreaterThan(SNMPCommunityStore.revision, r1)
    }

    func test_store_liveNames() {
        XCTAssertEqual(SNMPCommunityStore.Backend.keychainService, "com.bardaklabs.snap.snmp.community")
        XCTAssertEqual(SNMPCommunityStore.Backend.rememberedHostsKey, "com.bardaklabs.snap.snmp.rememberedHosts.v1")
        XCTAssertEqual(SNMPCommunityStore.Backend.boardHostKey, "com.bardaklabs.snap.snmp.boardCommunityHost.v1")
        XCTAssertEqual(SNMPCommunityStore.Backend.live.boardKey, SNMPCommunityStore.Backend.boardHostKey)
        XCTAssertEqual(SNMPCommunityStore.boardAccount, "status-board")
        // A remembered "host:port" can't collide with it.
        XCTAssertNotEqual(SNMPCommunityStore.account(host: "status-board", port: 161), SNMPCommunityStore.boardAccount)
        XCTAssertEqual(SNMPBoardWatchEnvironment.targetKey, "com.bardaklabs.snap.snmpWatch.v1")
    }

    // MARK: - The Status Board's own copy

    /// Pinning and Remember keep separate copies: neither one's save or
    /// forget touches the other's.
    func test_store_boardCopyIsSeparateFromRemember() {
        SNMPCommunityStore.saveForBoard(community: "board", host: " Core-SW1 ", port: 161)
        XCTAssertFalse(SNMPCommunityStore.hasSaved(host: "core-sw1", port: 161))   // Remember stays unticked
        XCTAssertNil(SNMPCommunityStore.load(host: "core-sw1", port: 161))
        XCTAssertEqual(SNMPCommunityStore.savedAccounts, [])
        XCTAssertTrue(SNMPCommunityStore.hasBoardCopy(host: "CORE-SW1", port: 161))
        XCTAssertEqual(SNMPCommunityStore.loadForBoard(host: "core-sw1", port: 161), "board")
        XCTAssertEqual(secrets.items, ["status-board": "board"])
        // UserDefaults says which host it's for, never the secret.
        XCTAssertEqual(defaults.string(forKey: SNMPCommunityStore.Backend.boardHostKey), "core-sw1:161")
        XCTAssertEqual(SNMPCommunityStore.savedCount, 1)

        // Remember for the same host is its own entry.
        SNMPCommunityStore.save(host: "core-sw1", port: 161, community: "remembered")
        XCTAssertEqual(SNMPCommunityStore.load(host: "core-sw1", port: 161), "remembered")
        XCTAssertEqual(SNMPCommunityStore.loadForBoard(host: "core-sw1", port: 161), "board")
        XCTAssertEqual(SNMPCommunityStore.savedCount, 2)

        // Unticking Remember leaves the board's copy.
        SNMPCommunityStore.forget(host: "core-sw1", port: 161)
        XCTAssertEqual(SNMPCommunityStore.loadForBoard(host: "core-sw1", port: 161), "board")
        XCTAssertEqual(SNMPCommunityStore.savedCount, 1)

        // Unpinning leaves Remember's entry.
        SNMPCommunityStore.save(host: "core-sw1", port: 161, community: "remembered")
        SNMPCommunityStore.forgetForBoard()
        XCTAssertNil(SNMPCommunityStore.loadForBoard(host: "core-sw1", port: 161))
        XCTAssertFalse(SNMPCommunityStore.hasBoardCopy(host: "core-sw1", port: 161))
        XCTAssertEqual(SNMPCommunityStore.load(host: "core-sw1", port: 161), "remembered")
        XCTAssertEqual(secrets.items, ["core-sw1:161": "remembered"])
        XCTAssertNil(defaults.object(forKey: SNMPCommunityStore.Backend.boardHostKey))
        XCTAssertEqual(SNMPCommunityStore.savedCount, 1)

        // Forget All removes both.
        SNMPCommunityStore.saveForBoard(community: "board", host: "core-sw1", port: 161)
        XCTAssertEqual(SNMPCommunityStore.savedCount, 2)
        SNMPCommunityStore.forgetAll()
        XCTAssertEqual(SNMPCommunityStore.savedCount, 0)
        XCTAssertTrue(secrets.items.isEmpty)
        XCTAssertNil(SNMPCommunityStore.loadForBoard(host: "core-sw1", port: 161))
        XCTAssertNil(defaults.object(forKey: SNMPCommunityStore.Backend.boardHostKey))
        XCTAssertNil(defaults.object(forKey: indexKey))
    }

    /// The tile watches one target: its copy answers for that host and port only.
    func test_store_boardCopy_oneTargetAtATime() {
        SNMPCommunityStore.saveForBoard(community: "a", host: "10.0.0.2", port: 161)
        XCTAssertNil(SNMPCommunityStore.loadForBoard(host: "10.0.0.2", port: 1161))
        XCTAssertNil(SNMPCommunityStore.loadForBoard(host: "10.0.0.3", port: 161))
        XCTAssertNil(SNMPCommunityStore.loadForBoard(host: " ", port: 161))

        // Pinning something else replaces it.
        SNMPCommunityStore.saveForBoard(community: "b", host: "10.0.0.3", port: 161)
        XCTAssertNil(SNMPCommunityStore.loadForBoard(host: "10.0.0.2", port: 161))
        XCTAssertEqual(SNMPCommunityStore.loadForBoard(host: "10.0.0.3", port: 161), "b")
        XCTAssertEqual(secrets.items, ["status-board": "b"])
        XCTAssertEqual(SNMPCommunityStore.savedCount, 1)

        // Nothing to save: the old copy goes, since it belongs to the old target.
        SNMPCommunityStore.saveForBoard(community: "", host: "10.0.0.4", port: 161)
        XCTAssertNil(SNMPCommunityStore.loadForBoard(host: "10.0.0.3", port: 161))
        XCTAssertNil(SNMPCommunityStore.loadForBoard(host: "10.0.0.4", port: 161))
        XCTAssertTrue(secrets.items.isEmpty)
        XCTAssertEqual(SNMPCommunityStore.savedCount, 0)

        // Checks that only need to know whether it exists don't read the Keychain.
        SNMPCommunityStore.saveForBoard(community: "c", host: "10.0.0.2", port: 161)
        secrets.reads = 0
        XCTAssertTrue(SNMPCommunityStore.hasBoardCopy(host: "10.0.0.2", port: 161))
        XCTAssertFalse(SNMPCommunityStore.hasBoardCopy(host: "10.0.0.3", port: 161))
        XCTAssertEqual(SNMPCommunityStore.savedCount, 1)
        XCTAssertNil(SNMPCommunityStore.loadForBoard(host: "10.0.0.3", port: 161))
        XCTAssertEqual(secrets.reads, 0)
        XCTAssertEqual(SNMPCommunityStore.loadForBoard(host: "10.0.0.2", port: 161), "c")
        XCTAssertEqual(secrets.reads, 1)

        // Deleted in Keychain Access: the copy is dropped.
        secrets.items = [:]
        XCTAssertNil(SNMPCommunityStore.loadForBoard(host: "10.0.0.2", port: 161))
        XCTAssertFalse(SNMPCommunityStore.hasBoardCopy(host: "10.0.0.2", port: 161))
        XCTAssertEqual(SNMPCommunityStore.savedCount, 0)

        // A failed write leaves no copy behind.
        secrets.failWrites = true
        SNMPCommunityStore.saveForBoard(community: "d", host: "10.0.0.2", port: 161)
        XCTAssertFalse(SNMPCommunityStore.hasBoardCopy(host: "10.0.0.2", port: 161))
    }

    /// A refused Keychain prompt isn't raised again on every keystroke in the
    /// Host field, or on every poll, until something is saved or forgotten.
    func test_store_failedReadNotRetriedUntilSomethingChanges() {
        SNMPCommunityStore.save(host: "10.0.0.2", port: 161, community: "c")
        SNMPCommunityStore.save(host: "10.0.0.3", port: 161, community: "other")
        secrets.failReads = true
        secrets.reads = 0
        for _ in 0..<5 { XCTAssertNil(SNMPCommunityStore.load(host: "10.0.0.2", port: 161)) }
        XCTAssertEqual(secrets.reads, 1)
        XCTAssertTrue(SNMPCommunityStore.hasSaved(host: "10.0.0.2", port: 161))   // still saved

        // Only that item is held back: another one is still read.
        secrets.failReads = false
        XCTAssertNil(SNMPCommunityStore.load(host: "10.0.0.2", port: 161))
        XCTAssertEqual(SNMPCommunityStore.load(host: "10.0.0.3", port: 161), "other")
        XCTAssertEqual(secrets.reads, 2)

        // Something saved: it's read again.
        SNMPCommunityStore.save(host: "10.0.0.4", port: 161, community: "x")
        XCTAssertEqual(SNMPCommunityStore.load(host: "10.0.0.2", port: 161), "c")
        XCTAssertEqual(secrets.reads, 3)

        // The same for the board's copy.
        SNMPCommunityStore.saveForBoard(community: "board", host: "10.0.0.2", port: 161)
        secrets.failReads = true
        XCTAssertNil(SNMPCommunityStore.loadForBoard(host: "10.0.0.2", port: 161))
        XCTAssertNil(SNMPCommunityStore.loadForBoard(host: "10.0.0.2", port: 161))
        XCTAssertEqual(secrets.reads, 4)
        secrets.failReads = false
        XCTAssertNil(SNMPCommunityStore.loadForBoard(host: "10.0.0.2", port: 161))
        XCTAssertEqual(secrets.reads, 4)
        SNMPCommunityStore.forget(host: "10.0.0.4", port: 161)
        XCTAssertEqual(SNMPCommunityStore.loadForBoard(host: "10.0.0.2", port: 161), "board")
        XCTAssertEqual(secrets.reads, 5)
    }

    /// The real Keychain code, under a test-only service name.
    func test_keychainSecrets_roundTripUnderTestService() throws {
        let keychain = SNMPKeychainSecrets(service: "com.bardaklabs.snap.tests.snmp.community")
        let account = "test-\(UUID().uuidString.lowercased()):161"
        defer { keychain.delete(account: account) }
        guard keychain.write(account: account, secret: "one") else {
            throw XCTSkip("The Keychain isn't available to this test run.")
        }
        XCTAssertEqual(keychain.read(account: account), .found("one"))
        XCTAssertTrue(keychain.write(account: account, secret: "two"))     // replaces
        XCTAssertEqual(keychain.read(account: account), .found("two"))
        keychain.delete(account: account)
        XCTAssertEqual(keychain.read(account: account), .missing)
    }

    // MARK: - Target

    func test_target_codableRoundTrip_withoutCommunity() throws {
        let big = SNMPBoardTarget(host: "10.0.0.2", port: 1161, version: 1, deviceName: "core-sw1",
                                  ifIndex: 10_024, portName: "Te1/0/24", speedBps: 10_000_000_000)
        for t in [big, deviceTarget] {
            let data = try JSONEncoder().encode(t)
            XCTAssertEqual(try JSONDecoder().decode(SNMPBoardTarget.self, from: data), t)
            XCTAssertFalse(String(decoding: data, as: UTF8.self).lowercased().contains("community"))
        }
        XCTAssertEqual(deviceTarget.snmpVersion, .v1)
        XCTAssertEqual(big.snmpVersion, .v2c)
        XCTAssertFalse(deviceTarget.watchesPort)
    }

    @MainActor
    func test_watch_persistsTargetInDefaults() {
        let h = BoardHarness()
        let first = SNMPBoardWatch(environment: h.environment(defaults))
        XCTAssertNil(first.target)
        first.pin(portTarget, community: "s3cret")
        XCTAssertNotNil(defaults.data(forKey: SNMPBoardWatchEnvironment.targetKey))
        XCTAssertEqual(SNMPBoardWatch(environment: h.environment(defaults)).target, portTarget)

        first.unpin()
        XCTAssertNil(first.target)
        XCTAssertNil(defaults.data(forKey: SNMPBoardWatchEnvironment.targetKey))
        XCTAssertNil(SNMPBoardWatch(environment: h.environment(defaults)).target)
        // Unpin deletes the board's copy of the community.
        XCTAssertNil(SNMPCommunityStore.loadForBoard(host: portTarget.host, port: portTarget.port))
        XCTAssertTrue(secrets.items.isEmpty)

        defaults.set(Data("not json".utf8), forKey: SNMPBoardWatchEnvironment.targetKey)
        XCTAssertNil(SNMPBoardWatch(environment: h.environment(defaults)).target)
    }

    @MainActor
    func test_watch_pinSavesCommunityAndAddsTileOnce() {
        let h = BoardHarness()
        h.hasTile = false
        let watch = SNMPBoardWatch(environment: h.environment(defaults))
        watch.pin(portTarget, community: "s3cret")
        XCTAssertEqual(watch.target, portTarget)
        XCTAssertEqual(SNMPCommunityStore.loadForBoard(host: "10.0.0.2", port: 161), "s3cret")
        XCTAssertEqual(h.addTileCalls, 1)
        watch.pin(deviceTarget, community: "other")
        XCTAssertEqual(h.addTileCalls, 1)
        XCTAssertEqual(watch.target, deviceTarget)
        // The copy follows the target.
        XCTAssertNil(SNMPCommunityStore.loadForBoard(host: "10.0.0.2", port: 161))
        XCTAssertEqual(SNMPCommunityStore.loadForBoard(host: "nas.local", port: 161), "other")
        watch.unpin()
    }

    /// Pinning doesn't tick Remember, and unpinning doesn't forget what
    /// Remember saved, even for the same host and port.
    @MainActor
    func test_watch_pinAndUnpinLeaveRememberAlone() {
        let h = BoardHarness()
        let watch = SNMPBoardWatch(environment: h.environment(defaults))
        watch.pin(portTarget, community: "pinned")
        XCTAssertFalse(SNMPCommunityStore.hasSaved(host: portTarget.host, port: portTarget.port))
        XCTAssertNil(SNMPCommunityStore.load(host: portTarget.host, port: portTarget.port))
        watch.unpin()

        SNMPCommunityStore.save(host: portTarget.host, port: portTarget.port, community: "remembered")
        watch.pin(portTarget, community: "pinned")
        XCTAssertEqual(SNMPCommunityStore.load(host: portTarget.host, port: portTarget.port), "remembered")
        XCTAssertEqual(SNMPCommunityStore.savedAccounts, ["10.0.0.2:161"])
        watch.unpin()
        XCTAssertTrue(SNMPCommunityStore.hasSaved(host: portTarget.host, port: portTarget.port))
        XCTAssertEqual(SNMPCommunityStore.load(host: portTarget.host, port: portTarget.port), "remembered")
        XCTAssertEqual(secrets.items, ["10.0.0.2:161": "remembered"])
    }

    // MARK: - Rate math

    func test_math_counterDeltas() {
        XCTAssertEqual(SNMPWatchMath.octetDelta(previous: 100, current: 600, counters64: true), 500)
        XCTAssertEqual(SNMPWatchMath.octetDelta(previous: 100, current: 600, counters64: false), 500)
        // A 32-bit counter wraps once: 100 octets before the top, 400 after.
        XCTAssertEqual(SNMPWatchMath.octetDelta(previous: UInt64(UInt32.max) - 99, current: 400, counters64: false), 500)
        // A 64-bit counter that went down was reset: no delta.
        XCTAssertNil(SNMPWatchMath.octetDelta(previous: 1_000, current: 10, counters64: true))
        // A "32-bit" reading above 32 bits can't have wrapped.
        XCTAssertNil(SNMPWatchMath.octetDelta(previous: 5_000_000_000, current: 10, counters64: false))
    }

    func test_math_bitsPerSecondAndPercent() throws {
        // 125,000,000 bytes in 10 s is 100 Mbps.
        let bps = try XCTUnwrap(SNMPWatchMath.bitsPerSecond(previous: 0, current: 125_000_000, counters64: true,
                                                            seconds: 10, linkBps: 1_000_000_000))
        XCTAssertEqual(bps, 100_000_000, accuracy: 0.001)
        XCTAssertEqual(SNMPWatchMath.percent(bps, of: 1_000_000_000) ?? -1, 10, accuracy: 0.0001)
        XCTAssertNil(SNMPWatchMath.percent(bps, of: nil))
        XCTAssertNil(SNMPWatchMath.percent(bps, of: 0))
        XCTAssertNil(SNMPWatchMath.percent(nil, of: 1_000))

        XCTAssertNil(SNMPWatchMath.bitsPerSecond(previous: 0, current: 10, counters64: true, seconds: 0, linkBps: nil))
        XCTAssertNil(SNMPWatchMath.bitsPerSecond(previous: nil, current: 10, counters64: true, seconds: 10, linkBps: nil))
        // A real 32-bit wrap on a 1 Gbps port: kept (about 1.6 Mbps).
        let wrapped = SNMPWatchMath.bitsPerSecond(previous: 4_294_000_000, current: 1_000_000, counters64: false,
                                                  seconds: 10, linkBps: 1_000_000_000)
        XCTAssertEqual(wrapped ?? 0, Double(1_967_296 * 8) / 10, accuracy: 0.001)
        // A "wrap" that would mean 2.6 Gbps on a 1 Gbps port is a counter reset.
        XCTAssertNil(SNMPWatchMath.bitsPerSecond(previous: 4_000_000_000, current: 3_000_000_000, counters64: false,
                                                 seconds: 10, linkBps: 1_000_000_000))
        // 32-bit counters read every 10 s top out near 3.44 Gbps.
        XCTAssertEqual(SNMPWatchMath.max32BitRate(interval: 10), 3_435_973_836.8, accuracy: 0.01)
    }

    func test_math_uptime() {
        XCTAssertEqual(SNMPWatchMath.uptimeChange(from: 1_000, to: 2_000), .advanced(seconds: 10))
        XCTAssertEqual(SNMPWatchMath.uptimeChange(from: 2_000, to: 2_000), .advanced(seconds: 0))
        // sysUpTime wraps after about 497 days: 500 ticks before, 500 after.
        XCTAssertEqual(SNMPWatchMath.uptimeChange(from: UInt32.max - 499, to: 500), .wrapped(seconds: 10))
        XCTAssertEqual(SNMPWatchMath.uptimeChange(from: 5_000_000, to: 1_000), .restarted)
        XCTAssertEqual(SNMPWatchMath.uptimeChange(from: UInt32.max - 10, to: 500_000), .restarted)
    }

    func test_format() {
        XCTAssertEqual(SNMPWatchFormat.uptime(4_000), "40s")
        XCTAssertEqual(SNMPWatchFormat.uptime(30_000), "5m")
        XCTAssertEqual(SNMPWatchFormat.uptime(1_152_000), "3h 12m")
        XCTAssertEqual(SNMPWatchFormat.uptime(105_120_000), "12d 4h")
        XCTAssertEqual(SNMPWatchFormat.speed(1_000_000_000), "1 Gbps")
        XCTAssertEqual(SNMPWatchFormat.speed(2_500_000_000), "2.5 Gbps")
        XCTAssertEqual(SNMPWatchFormat.speed(100_000_000), "100 Mbps")
        XCTAssertEqual(SNMPWatchFormat.percent(0.2), "<1%")
        XCTAssertEqual(SNMPWatchFormat.percent(0), "0%")
        XCTAssertEqual(SNMPWatchFormat.percent(94.4), "94%")
    }

    func test_status() {
        let now = Date()
        var s = SNMPWatchState()
        XCTAssertEqual(s.status(watchingPort: true, now: now), .checking)
        s.lastSuccess = now
        s.operStatus = 1
        XCTAssertEqual(s.status(watchingPort: true, now: now), .up)
        XCTAssertNil(s.portDownNote)
        s.operStatus = 7
        XCTAssertEqual(s.status(watchingPort: true, now: now), .portDown)
        XCTAssertEqual(s.portDownNote, "The port isn't up (ifOperStatus lowerLayerDown).")
        XCTAssertEqual(s.status(watchingPort: false, now: now), .up)     // a device has no port status
        s.adminStatus = 2
        XCTAssertEqual(s.portDownNote, "The port is turned off on the device (ifAdminStatus down).")
        XCTAssertEqual(SNMPWatchState.operStatusName(99), "99")
        s.restartedAt = now.addingTimeInterval(-86_400)
        XCTAssertEqual(s.status(watchingPort: true, now: now), .portDown)     // only when SNAP noticed it
        s.restartNoticedAt = now.addingTimeInterval(-120)
        XCTAssertEqual(s.status(watchingPort: true, now: now), .restarted)
        XCTAssertEqual(s.status(watchingPort: true, now: now.addingTimeInterval(500)), .portDown)
        s.problem = .noAnswer
        XCTAssertEqual(s.status(watchingPort: true, now: now), .notAnswering)
        s.problem = .unreachable("no route")
        XCTAssertEqual(s.status(watchingPort: true, now: now), .notAnswering)
        s.problem = .refused("authorizationError")
        XCTAssertEqual(s.status(watchingPort: true, now: now), .error)
        s.problem = .noCommunity
        XCTAssertEqual(s.status(watchingPort: true, now: now), .noCommunity)
        s = SNMPWatchState(lastSuccess: now, portMissing: true)
        XCTAssertEqual(s.status(watchingPort: true, now: now), .portMissing)
        XCTAssertEqual(SNMPBoardWatch.problem(for: SNMPError.timeout), .noAnswer)
        XCTAssertEqual(SNMPBoardWatch.problem(for: SNMPError.transport("x")), .unreachable("x"))
        XCTAssertEqual(SNMPBoardWatch.problem(for: SNMPError.errorStatus(16, "authorizationError", 0)),
                       .refused("authorizationError"))
        XCTAssertEqual(SNMPBoardWatch.problem(for: SNMPError.truncated), .unreadable)
    }

    // MARK: - One poll against a fake agent

    func test_poll_oneGetWith64BitCounters() async throws {
        let a = agent(uptime: 123_456, inOctets: 5_000_000_000, outOctets: 42)
        let r = try await SNMPBoardPoll.read(a.client(), ifIndex: 3, use64: true)
        XCTAssertEqual(r.uptimeTicks, 123_456)
        XCTAssertEqual(r.sysName, "core-sw1")
        XCTAssertEqual(r.port, SNMPBoardPoll.PortReading(operStatus: 1, adminStatus: 1, inOctets: 5_000_000_000,
                                                         outOctets: 42, counters64: true))
        XCTAssertEqual(a.pdus, [getTag])
    }

    func test_poll_fallsBackTo32BitCounters() async throws {
        let a = agent(uptime: 100, inOctets: 7_000, outOctets: 9_000, hc: false)
        let r = try await SNMPBoardPoll.read(a.client(), ifIndex: 3, use64: true)
        XCTAssertEqual(r.port?.counters64, false)
        XCTAssertEqual(r.port?.inOctets, 7_000)
        XCTAssertEqual(r.port?.outOctets, 9_000)
        XCTAssertEqual(a.pdus, [getTag, getTag])
        // Once known, the next poll asks for the 32-bit ones in its one GET.
        let b = agent(uptime: 100, inOctets: 7_000, outOctets: 9_000, hc: false)
        _ = try await SNMPBoardPoll.read(b.client(), ifIndex: 3, use64: false)
        XCTAssertEqual(b.pdus, [getTag])
    }

    /// v1 can't carry 64-bit counters, so it doesn't ask for them.
    func test_poll_v1_uses32BitCounters() async throws {
        let a = agent(uptime: 100, inOctets: 5_000_000_000, outOctets: 1)
        a.v1 = true
        let r = try await SNMPBoardPoll.read(a.client(version: .v1), ifIndex: 3, use64: true)
        XCTAssertEqual(r.port?.counters64, false)
        XCTAssertEqual(r.port?.inOctets, UInt64(UInt32(truncatingIfNeeded: UInt64(5_000_000_000))))
        XCTAssertEqual(a.pdus, [getTag])
    }

    func test_poll_missingPort_andDeviceOnly() async throws {
        let a = agent(uptime: 100, inOctets: 1, outOctets: 1, ifIndex: 3)
        let r = try await SNMPBoardPoll.read(a.client(), ifIndex: 99, use64: true)
        XCTAssertEqual(r.uptimeTicks, 100)
        XCTAssertNil(r.port?.operStatus)
        XCTAssertNil(r.port?.inOctets)

        let v1 = agent(uptime: 100, inOctets: 1, outOctets: 1, ifIndex: 3)
        v1.v1 = true   // a missing OID fails the whole v1 GET; getTolerant asks one by one
        let r1 = try await SNMPBoardPoll.read(v1.client(version: .v1), ifIndex: 99, use64: true)
        XCTAssertEqual(r1.sysName, "core-sw1")
        XCTAssertNil(r1.port?.operStatus)

        let d = agent(uptime: 100, inOctets: 1, outOctets: 1)
        let rd = try await SNMPBoardPoll.read(d.client(), ifIndex: nil, use64: true)
        XCTAssertNil(rd.port)
        XCTAssertEqual(rd.sysName, "core-sw1")
        XCTAssertEqual(d.pdus, [getTag])
    }

    // MARK: - The watch, poll by poll

    @MainActor
    func test_watch_ratesFromCounterDeltas_thenRestart() async throws {
        let h = BoardHarness()
        let watch = SNMPBoardWatch(environment: h.environment(defaults))
        watch.pin(portTarget, community: "s3cret")
        // 10 s apart by sysUpTime: 125,000,000 bytes in (100 Mbps), 12,500,000 out (10 Mbps).
        h.answer(with: [
            agent(uptime: 100_000, inOctets: 1_000_000, outOctets: 2_000_000),
            agent(uptime: 101_000, inOctets: 126_000_000, outOctets: 14_500_000),
            agent(uptime: 3_000, inOctets: 500, outOctets: 500),           // restarted 30 s ago
        ])

        await watch.pollNow()
        XCTAssertNotNil(watch.state.lastSuccess)
        XCTAssertEqual(watch.state.sysName, "core-sw1")
        XCTAssertEqual(watch.state.uptimeTicks, 100_000)
        XCTAssertNil(watch.state.inBps)                  // a rate needs two readings
        XCTAssertEqual(watch.state.status(watchingPort: true, now: Date()), .up)

        await watch.pollNow()
        let inBps = try XCTUnwrap(watch.state.inBps)
        XCTAssertEqual(inBps, 100_000_000, accuracy: 0.5)
        XCTAssertEqual(watch.state.outBps ?? 0, 10_000_000, accuracy: 0.5)
        XCTAssertEqual(SNMPWatchMath.percent(inBps, of: portTarget.speedBps) ?? 0, 10, accuracy: 0.001)
        XCTAssertEqual(watch.state.counters64, true)
        XCTAssertEqual(watch.state.samples.count, 1)
        XCTAssertNil(watch.state.restartedAt)

        await watch.pollNow()
        XCTAssertNil(watch.state.inBps)                  // no rate across a restart
        XCTAssertEqual(watch.state.status(watchingPort: true, now: Date()), .restarted)
        let restartedAt = try XCTUnwrap(watch.state.restartedAt)
        XCTAssertEqual(Date().timeIntervalSince(restartedAt), 30, accuracy: 2)
        XCTAssertEqual(watch.state.status(watchingPort: true, now: Date().addingTimeInterval(600)), .up)
        XCTAssertEqual(h.communities, ["s3cret", "s3cret", "s3cret"])
        watch.unpin()
    }

    /// A restart that happened while the board was closed still shows,
    /// with when it happened rather than when SNAP noticed.
    @MainActor
    func test_watch_restartSeenLater_saysWhen() async throws {
        let h = BoardHarness()
        let watch = SNMPBoardWatch(environment: h.environment(defaults))
        watch.pin(portTarget, community: "c")
        h.answer(with: [
            agent(uptime: 864_000_000, inOctets: 1, outOctets: 1),     // up 100 days
            agent(uptime: 17_280_000, inOctets: 1, outOctets: 1),      // now up 2 days
        ])
        await watch.pollNow()
        XCTAssertNil(watch.state.restartNoticedAt)
        await watch.pollNow()
        XCTAssertEqual(watch.state.status(watchingPort: true, now: Date()), .restarted)
        let restartedAt = try XCTUnwrap(watch.state.restartedAt)
        XCTAssertEqual(Date().timeIntervalSince(restartedAt), 172_800, accuracy: 5)
        XCTAssertEqual(watch.state.status(watchingPort: true, now: Date().addingTimeInterval(601)), .up)
        watch.unpin()
    }

    /// First seen up 2 minutes: it restarted, though SNAP didn't see it go.
    @MainActor
    func test_watch_freshlyBootedDevice_showsRestarted() async {
        let h = BoardHarness()
        let watch = SNMPBoardWatch(environment: h.environment(defaults))
        watch.pin(deviceTarget, community: "c")
        h.answer(with: [agent(uptime: 12_000, inOctets: 0, outOctets: 0)])
        await watch.pollNow()
        XCTAssertEqual(watch.state.status(watchingPort: false, now: Date()), .restarted)
        XCTAssertEqual(watch.state.status(watchingPort: false, now: Date().addingTimeInterval(481)), .up)
        watch.unpin()
    }

    /// After about 497 days sysUpTime wraps to a small number. That's not a
    /// restart, on the poll that sees the wrap or the ones after it, but a
    /// real restart after the wrap still shows.
    @MainActor
    func test_watch_uptimeWrapIsNotARestart() async throws {
        let h = BoardHarness()
        let watch = SNMPBoardWatch(environment: h.environment(defaults))
        watch.pin(portTarget, community: "c")
        h.answer(with: [
            agent(uptime: UInt32.max - 999, inOctets: 1_000, outOctets: 1_000),   // up about 497 days
            agent(uptime: 9_000, inOctets: 125_001_000, outOctets: 1_000),        // wrapped 90 s ago
            agent(uptime: 10_000, inOctets: 125_001_000, outOctets: 1_000),       // 100 s on the counter
            agent(uptime: 5_000, inOctets: 1_000, outOctets: 1_000),              // went backwards: restarted
        ])
        await watch.pollNow()
        XCTAssertEqual(watch.state.status(watchingPort: true, now: Date()), .up)

        await watch.pollNow()
        XCTAssertEqual(watch.state.status(watchingPort: true, now: Date()), .up)
        XCTAssertNil(watch.state.restartedAt)
        XCTAssertNil(watch.state.restartNoticedAt)
        // The rate spans the wrap: 1,000 + 9,000 ticks is 100 s, 125,000,000 bytes is 10 Mbps.
        XCTAssertEqual(watch.state.inBps ?? 0, 10_000_000, accuracy: 0.5)

        await watch.pollNow()
        XCTAssertEqual(watch.state.status(watchingPort: true, now: Date()), .up)
        XCTAssertNil(watch.state.restartNoticedAt)

        await watch.pollNow()
        XCTAssertEqual(watch.state.status(watchingPort: true, now: Date()), .restarted)
        let restartedAt = try XCTUnwrap(watch.state.restartedAt)
        XCTAssertEqual(Date().timeIntervalSince(restartedAt), 50, accuracy: 2)
        watch.unpin()
    }

    @MainActor
    func test_watch_32BitWrapKept_64BitDecreaseDropped() async throws {
        let h = BoardHarness()
        let watch = SNMPBoardWatch(environment: h.environment(defaults))
        watch.pin(portTarget, community: "c")
        // No 64-bit counters: the in counter wraps between polls.
        h.answer(with: [
            agent(uptime: 100_000, inOctets: UInt64(UInt32.max) - 999, outOctets: 0, hc: false),
            agent(uptime: 101_000, inOctets: 11_500, outOctets: 0, hc: false),
        ])
        await watch.pollNow()
        await watch.pollNow()
        XCTAssertEqual(watch.state.counters64, false)
        XCTAssertEqual(watch.state.inBps ?? 0, Double(12_500 * 8) / 10, accuracy: 0.001)

        // 64-bit counters that go down (cleared) give no rate.
        let w2 = SNMPBoardWatch(environment: h.environment(defaults))
        h.answer(with: [
            agent(uptime: 100_000, inOctets: 9_000_000, outOctets: 9_000_000),
            agent(uptime: 101_000, inOctets: 1_000, outOctets: 9_100_000),
        ])
        await w2.pollNow()
        await w2.pollNow()
        XCTAssertNil(w2.state.inBps)
        XCTAssertEqual(w2.state.outBps ?? 0, 80_000, accuracy: 0.001)
        watch.unpin()
    }

    @MainActor
    func test_watch_deviceOnly_tracksReplyTime() async {
        let h = BoardHarness()
        let watch = SNMPBoardWatch(environment: h.environment(defaults))
        watch.pin(deviceTarget, community: "c")
        let a = agent(uptime: 100_000, inOctets: 0, outOctets: 0)
        a.v1 = true
        h.answer(with: [a], version: .v1)
        await watch.pollNow()
        XCTAssertEqual(watch.state.status(watchingPort: false, now: Date()), .up)
        XCTAssertNotNil(watch.state.replyMs)
        XCTAssertEqual(watch.state.samples.count, 1)
        XCTAssertNil(watch.state.inBps)
        XCTAssertEqual(a.pdus, [getTag])
        watch.unpin()
    }

    @MainActor
    func test_watch_noAnswerAndMissingPort() async {
        let h = BoardHarness()
        let watch = SNMPBoardWatch(environment: h.environment(defaults))
        watch.pin(portTarget, community: "c")
        h.makeClient = { _, _ in
            SNMPClient(host: "fake", timeout: 0.1, retries: 0, transport: { _ in throw SNMPError.timeout })
        }
        await watch.pollNow()
        XCTAssertEqual(watch.state.problem, .noAnswer)
        XCTAssertEqual(watch.state.status(watchingPort: true, now: Date()), .notAnswering)
        XCTAssertNil(watch.state.lastSuccess)

        h.answer(with: [agent(uptime: 100_000, inOctets: 1, outOctets: 1, ifIndex: 7)])
        await watch.pollNow()
        XCTAssertNil(watch.state.problem)
        XCTAssertTrue(watch.state.portMissing)
        XCTAssertEqual(watch.state.status(watchingPort: true, now: Date()), .portMissing)
        watch.unpin()
    }

    @MainActor
    func test_watch_communityFromStore() async {
        let h = BoardHarness()
        h.answer(with: [agent(uptime: 100_000, inOctets: 1, outOctets: 1)])
        let watch = SNMPBoardWatch(environment: h.environment(defaults))
        watch.pin(portTarget, community: "old")
        await watch.pollNow()
        XCTAssertEqual(h.communities, ["old"])
        XCTAssertEqual(secrets.reads, 0)                 // pin keeps it in memory

        // Remember saves a different community for the same host: the board
        // keeps asking with its own copy.
        SNMPCommunityStore.save(host: portTarget.host, port: portTarget.port, community: "remembered")
        await watch.pollNow()
        await watch.pollNow()
        XCTAssertEqual(h.communities, ["old", "old", "old"])
        XCTAssertEqual(secrets.reads, 1)                 // the store changed, so it read its copy once

        // Unticking Remember for that host doesn't stop the tile.
        SNMPCommunityStore.forget(host: portTarget.host, port: portTarget.port)
        await watch.pollNow()
        XCTAssertNil(watch.state.problem)
        XCTAssertEqual(h.communities.last, "old")
        XCTAssertEqual(h.communities.count, 4)

        // Pinned again with a new community: the watch uses it, from memory.
        watch.pin(portTarget, community: "new")
        let reads = secrets.reads
        await watch.pollNow()
        await watch.pollNow()
        XCTAssertEqual(Array(h.communities.suffix(2)), ["new", "new"])
        XCTAssertEqual(secrets.reads, reads)

        // A Keychain read that fails isn't retried every poll.
        secrets.failReads = true
        SNMPCommunityStore.save(host: "10.0.0.9", port: 161, community: "x")   // the store changed
        await watch.pollNow()
        await watch.pollNow()
        XCTAssertEqual(watch.state.problem, .communityUnreadable)
        XCTAssertEqual(watch.state.status(watchingPort: true, now: Date()), .noCommunity)
        XCTAssertEqual(secrets.reads, reads + 1)
        XCTAssertEqual(h.communities.count, 6)

        // Once the store changes again it tries again, and recovers.
        secrets.failReads = false
        SNMPCommunityStore.forget(host: "10.0.0.9", port: 161)
        await watch.pollNow()
        XCTAssertNil(watch.state.problem)
        XCTAssertEqual(h.communities.last, "new")

        // Forget All: no request goes out, and the tile says why.
        SNMPCommunityStore.forgetAll()
        await watch.pollNow()
        XCTAssertEqual(watch.state.problem, .noCommunity)
        XCTAssertEqual(watch.state.status(watchingPort: true, now: Date()), .noCommunity)
        XCTAssertEqual(h.communities.count, 7)
        watch.unpin()
    }

    /// A target saved by an earlier run gets its community from the Keychain.
    @MainActor
    func test_watch_loadsCommunityForSavedTarget() async {
        let h = BoardHarness()
        h.answer(with: [agent(uptime: 100_000, inOctets: 1, outOctets: 1)])
        SNMPBoardWatch(environment: h.environment(defaults)).pin(portTarget, community: "kept")
        let relaunched = SNMPBoardWatch(environment: h.environment(defaults))
        await relaunched.pollNow()
        XCTAssertEqual(h.communities, ["kept"])
        XCTAssertEqual(secrets.reads, 1)
        relaunched.unpin()
    }

    // MARK: - Polling only while the board shows the tile

    @MainActor
    func test_watch_pollsOnlyWhileBoardShowsTheTile() async throws {
        let h = BoardHarness()
        h.answer(with: [agent(uptime: 100_000, inOctets: 1, outOctets: 1)])
        h.showing = false
        let watch = SNMPBoardWatch(environment: h.environment(defaults, interval: 0.05))
        watch.pin(portTarget, community: "c")
        XCTAssertFalse(watch.isPolling)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(h.communities.isEmpty)

        // The board opens and its tile appears.
        h.showing = true
        h.changes.send(())
        let tile = UUID()
        watch.tileAppeared(tile)
        try await waitUntil("two polls") { h.communities.count >= 2 }
        XCTAssertTrue(watch.isPolling)

        // The tile is removed from the board.
        h.hasTile = false
        h.changes.send(())
        try await waitUntil("polling stops") { !watch.isPolling }
        let count = h.communities.count
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(h.communities.count, count)

        // Tile back, board closed: still nothing.
        h.hasTile = true
        h.showing = false
        h.changes.send(())
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(watch.isPolling)

        // Board open again, its tile on screen again: polling resumes;
        // unpinning stops it.
        h.showing = true
        h.changes.send(())
        watch.tileAppeared(tile)
        try await waitUntil("polling resumes") { watch.isPolling }
        watch.unpin()
        XCTAssertFalse(watch.isPolling)

        // Pinning while the board shows the (empty) tile starts at once.
        let opened = SNMPBoardWatch(environment: h.environment(defaults, interval: 0.05))
        opened.tileAppeared(UUID())
        XCTAssertFalse(opened.isPolling)                 // nothing pinned
        opened.pin(deviceTarget, community: "c")
        XCTAssertTrue(opened.isPolling)
        opened.unpin()
    }

    /// The in-window board still counts as open after its window closes (the
    /// app keeps running from the menu bar). The tile going away is what
    /// stops the polling.
    @MainActor
    func test_watch_stopsWhenTheTileLeavesTheScreen() async throws {
        let h = BoardHarness()
        h.answer(with: [agent(uptime: 100_000, inOctets: 1, outOctets: 1)])
        h.showing = true
        let watch = SNMPBoardWatch(environment: h.environment(defaults, interval: 0.05))
        watch.pin(portTarget, community: "c")
        // The board is open but no tile is on screen: nothing goes out.
        XCTAssertFalse(watch.isPolling)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(h.communities.isEmpty)

        let first = UUID(), second = UUID()
        watch.tileAppeared(first)
        XCTAssertTrue(watch.isPolling)
        try await waitUntil("a poll") { !h.communities.isEmpty }

        // Two windows show the board; closing one keeps polling.
        watch.tileAppeared(second)
        watch.tileDisappeared(first)
        XCTAssertTrue(watch.isPolling)

        // The last window holding the board closes. The board still says
        // it's open, but its tile is gone, so polling stops.
        watch.tileDisappeared(second)
        XCTAssertFalse(watch.isPolling)
        h.changes.send(())
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(watch.isPolling)
        let count = h.communities.count
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(h.communities.count, count)

        // A tile whose onDisappear never came doesn't keep polling once the
        // board closes, nor after the board opens again without it.
        watch.tileAppeared(first)
        XCTAssertTrue(watch.isPolling)
        h.showing = false
        h.changes.send(())
        try await waitUntil("polling stops") { !watch.isPolling }
        h.showing = true
        h.changes.send(())
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(watch.isPolling)
        // A late onDisappear for it changes nothing.
        watch.tileDisappeared(first)
        XCTAssertFalse(watch.isPolling)
        watch.unpin()
    }
}
