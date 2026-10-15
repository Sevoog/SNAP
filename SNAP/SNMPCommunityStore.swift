// SNMPCommunityStore.swift
// SNAP — Opt-in remembered SNMP community strings (Keychain)
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md
//
// Community strings are passwords, so they only live in the Keychain, as
// generic passwords under one service. Nothing is saved unless the user
// ticks Remember or pins a device to the Status Board.
//
// Remember keeps one item per "host:port". The Status Board's SNMP Watch
// tile keeps its own copy in one more item (account "status-board"), since
// it watches one target at a time. The two never touch each other: pinning
// doesn't tick Remember, unticking Remember doesn't stop the tile, and
// unpinning doesn't forget what Remember saved. Forget All removes both.
//
// A small index of the remembered "host:port" names, and the "host:port"
// the board's copy belongs to, sit in UserDefaults (no secrets), so
// hasSaved(), hasBoardCopy() and savedCount answer without touching the
// Keychain. The SNMP tab calls hasSaved() on every keystroke in the Host
// field; reading the Keychain there could raise a prompt each time.
//
// A Keychain read that failed (access denied, Keychain locked) isn't tried
// again for that item until something is saved or forgotten (the revision
// changes), so a refused prompt doesn't come back on every keystroke or poll.

import Foundation
import Security

// CONTRACT (used by SNMPView.swift and SNMPBoardWatch.swift; keep these):
//   enum SNMPCommunityStore {
//     static func hasSaved(host: String, port: UInt16) -> Bool   // index only, no Keychain access
//     static func load(host: String, port: UInt16) -> String?
//     static func save(host: String, port: UInt16, community: String)
//     static func forget(host: String, port: UInt16)
//     static func forgetAll()                                    // Remember's entries and the board's copy
//     static var savedCount: Int { get }                         // Remember's entries, plus 1 for the board's copy
//     // The Status Board's own copy, separate from Remember:
//     static func saveForBoard(community: String, host: String, port: UInt16)
//     static func loadForBoard(host: String, port: UInt16) -> String?   // nil unless saved for this host and port
//     static func forgetForBoard()
//   }

/// The result of reading one secret.
enum SNMPSecretLookup: Equatable {
    case found(String)
    /// There's no such item.
    case missing
    /// The item may exist but couldn't be read (access denied, Keychain locked).
    case failed
}

/// Where the secrets themselves go. The app uses the Keychain; tests use a
/// test service name or an in-memory store.
protocol SNMPSecretStore {
    func read(account: String) -> SNMPSecretLookup
    /// True when the secret was stored. Replaces any existing item.
    @discardableResult
    func write(account: String, secret: String) -> Bool
    func delete(account: String)
}

/// Generic passwords under one Keychain service, in the same style as the
/// UniFi controller's password storage.
struct SNMPKeychainSecrets: SNMPSecretStore {
    let service: String

    func read(account: String) -> SNMPSecretLookup {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess,
              let data = result as? Data,
              let s = String(data: data, encoding: .utf8) else { return .failed }
        return .found(s)
    }

    @discardableResult
    func write(account: String, secret: String) -> Bool {
        delete(account: account)
        let attrs: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // What Keychain Access shows in its Name column.
            kSecAttrLabel as String:   "SNAP SNMP community",
            kSecValueData as String:   Data(secret.utf8),
        ]
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    func delete(account: String) {
        let q: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
    }
}

enum SNMPCommunityStore {

    /// Everything the store reads and writes. Tests swap in their own.
    struct Backend {
        var secrets: any SNMPSecretStore
        var defaults: UserDefaults
        var indexKey: String
        /// Where the "host:port" of the board's copy is kept (no secret).
        var boardKey: String = Backend.boardHostKey

        static let keychainService = "com.bardaklabs.snap.snmp.community"
        static let rememberedHostsKey = "com.bardaklabs.snap.snmp.rememberedHosts.v1"
        static let boardHostKey = "com.bardaklabs.snap.snmp.boardCommunityHost.v1"

        static var live: Backend {
            Backend(secrets: SNMPKeychainSecrets(service: keychainService),
                    defaults: .standard,
                    indexKey: rememberedHostsKey,
                    boardKey: boardHostKey)
        }
    }

    /// The Keychain account of the Status Board's copy. Not a "host:port",
    /// so it can't collide with a remembered entry.
    static let boardAccount = "status-board"

    private static let lock = NSLock()
    private static var _backend = Backend.live
    private static var _revision = 0
    /// Keychain accounts whose last read failed, with the revision it failed at.
    private static var _failedReads: [String: Int] = [:]

    static var backend: Backend {
        get { lock.lock(); defer { lock.unlock() }; return _backend }
        set {
            lock.lock()
            _backend = newValue
            _revision += 1
            _failedReads = [:]
            lock.unlock()
        }
    }

    /// Goes up on every save or forget, so a caller holding a copy of a
    /// community (the Status Board watch) knows when to read it again.
    static var revision: Int {
        lock.lock(); defer { lock.unlock() }
        return _revision
    }

    private static func bumpRevision() {
        lock.lock()
        _revision += 1
        _failedReads = [:]
        lock.unlock()
    }

    /// The Keychain account for a host and port: "host:port", with the host
    /// trimmed and lowercased, so "Switch-1.local " and "switch-1.local"
    /// share one entry. nil for an empty host.
    static func account(host: String, port: UInt16) -> String? {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !h.isEmpty else { return nil }
        return "\(h):\(port)"
    }

    /// Reads one item, unless reading it already failed at this revision:
    /// then it answers .failed without asking the Keychain again.
    private static func read(_ account: String, _ b: Backend) -> SNMPSecretLookup {
        lock.lock()
        let rev = _revision
        let failedBefore = _failedReads[account] == rev
        lock.unlock()
        if failedBefore { return .failed }
        let result = b.secrets.read(account: account)
        if result == .failed {
            lock.lock()
            // Only if nothing was saved or forgotten while reading.
            if _revision == rev { _failedReads[account] = rev }
            lock.unlock()
        }
        return result
    }

    // MARK: Index (UserDefaults, no secrets)

    private static func index(_ b: Backend) -> [String] {
        b.defaults.stringArray(forKey: b.indexKey) ?? []
    }

    private static func setIndex(_ list: [String], _ b: Backend) {
        let unique = Array(Set(list)).sorted()
        if unique.isEmpty {
            b.defaults.removeObject(forKey: b.indexKey)
        } else {
            b.defaults.set(unique, forKey: b.indexKey)
        }
    }

    /// The remembered "host:port" entries, sorted. Reads the index only.
    /// The board's copy isn't one of them.
    static var savedAccounts: [String] { index(backend).sorted() }

    // MARK: Contract

    /// True when Remember saved a community for this host and port. Reads
    /// the index only, never the Keychain. The board's copy doesn't count.
    static func hasSaved(host: String, port: UInt16) -> Bool {
        guard let a = account(host: host, port: port) else { return false }
        return index(backend).contains(a)
    }

    /// The remembered community, or nil. Only reads the Keychain for entries
    /// in the index. An entry whose Keychain item is gone (deleted in
    /// Keychain Access, say) is dropped from the index.
    static func load(host: String, port: UInt16) -> String? {
        let b = backend
        guard let a = account(host: host, port: port), index(b).contains(a) else { return nil }
        switch read(a, b) {
        case .found(let s):
            return s
        case .missing:
            setIndex(index(b).filter { $0 != a }, b)
            bumpRevision()
            return nil
        case .failed:
            return nil
        }
    }

    /// Saves (or replaces) the remembered community for this host and port.
    /// An empty community isn't saved: the SNMP tab sends "public" for an
    /// empty field.
    static func save(host: String, port: UInt16, community: String) {
        let b = backend
        guard let a = account(host: host, port: port), !community.isEmpty else { return }
        if b.secrets.write(account: a, secret: community) {
            setIndex(index(b) + [a], b)
        } else {
            // The old item was removed before the write failed.
            setIndex(index(b).filter { $0 != a }, b)
        }
        bumpRevision()
    }

    /// Forgets the remembered community for this host and port. The board's
    /// copy stays.
    static func forget(host: String, port: UInt16) {
        let b = backend
        guard let a = account(host: host, port: port) else { return }
        b.secrets.delete(account: a)
        setIndex(index(b).filter { $0 != a }, b)
        bumpRevision()
    }

    /// Deletes every remembered community in the index, and the board's copy.
    static func forgetAll() {
        let b = backend
        for a in index(b) { b.secrets.delete(account: a) }
        setIndex([], b)
        b.secrets.delete(account: boardAccount)
        b.defaults.removeObject(forKey: b.boardKey)
        bumpRevision()
    }

    /// Remembered communities, plus one when the board has its copy.
    static var savedCount: Int {
        let b = backend
        return index(b).count + (b.defaults.string(forKey: b.boardKey) == nil ? 0 : 1)
    }

    // MARK: The Status Board's copy

    /// The "host:port" the board's copy belongs to, or nil when there's
    /// none. Reads UserDefaults only.
    static var boardCopyAccount: String? {
        let b = backend
        return b.defaults.string(forKey: b.boardKey)
    }

    /// True when the board's copy belongs to this host and port. Reads
    /// UserDefaults only, never the Keychain.
    static func hasBoardCopy(host: String, port: UInt16) -> Bool {
        guard let a = account(host: host, port: port) else { return false }
        return boardCopyAccount == a
    }

    /// Saves the board's copy for this host and port, replacing the copy
    /// for whatever it watched before. Remember's entries aren't touched.
    /// With an empty host or community there's nothing to save, so the old
    /// copy is only deleted.
    static func saveForBoard(community: String, host: String, port: UInt16) {
        let b = backend
        guard let a = account(host: host, port: port), !community.isEmpty else {
            forgetForBoard()
            return
        }
        if b.secrets.write(account: boardAccount, secret: community) {
            b.defaults.set(a, forKey: b.boardKey)
        } else {
            // The old item was removed before the write failed.
            b.defaults.removeObject(forKey: b.boardKey)
        }
        bumpRevision()
    }

    /// The board's copy, or nil when it was saved for another host or port
    /// (or not at all). Only reads the Keychain when it was saved for this
    /// one. A copy whose Keychain item is gone is dropped.
    static func loadForBoard(host: String, port: UInt16) -> String? {
        let b = backend
        guard let a = account(host: host, port: port),
              b.defaults.string(forKey: b.boardKey) == a else { return nil }
        switch read(boardAccount, b) {
        case .found(let s):
            return s
        case .missing:
            b.defaults.removeObject(forKey: b.boardKey)
            bumpRevision()
            return nil
        case .failed:
            return nil
        }
    }

    /// Deletes the board's copy. Remember's entries stay.
    static func forgetForBoard() {
        let b = backend
        b.secrets.delete(account: boardAccount)
        b.defaults.removeObject(forKey: b.boardKey)
        bumpRevision()
    }
}
