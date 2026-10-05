// FavoritesManager.swift
// SNAP — Pinned hosts with periodic liveness check
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
//
// Stores up to 10 favorite hosts (label + host string) and re-pings each one
// every 30 seconds via a single shared `/sbin/ping -c 1 -W 1` invocation pool.
// Surfaced on the Dashboard via `FavoritesDashCard` and populated by the
// right-click "Add to Favorites" action.

import Foundation
import SwiftUI

struct Favorite: Identifiable, Hashable, Codable {
    let id: UUID
    var label: String
    var host: String
    var addedAt: Date

    init(label: String, host: String) {
        self.id = UUID()
        self.label = label
        self.host = host
        self.addedAt = Date()
    }
}

struct FavoriteStatus: Equatable {
    enum State { case unknown, ok, slow, bad }
    var state: State = .unknown
    var rttMs: Double?
    var lastChecked: Date?
}

@MainActor
final class FavoritesManager: ObservableObject {
    static let shared = FavoritesManager()
    private let key = "com.bardaklabs.snap.favorites.v1"
    static let maxFavorites = 10
    static let maxHistorySamples = 30

    @Published private(set) var items: [Favorite] = []
    @Published private(set) var status: [UUID: FavoriteStatus] = [:]
    /// Rolling RTT history per favorite. Only successful ping samples land here
    /// (timeouts are excluded so the chart isn't distorted by zero-spikes).
    @Published private(set) var history: [UUID: [Double]] = [:]

    private var timer: Timer?
    private var currentInterval: TimeInterval = 30

    private init() {
        load()
        startTimer()
    }

    // MARK: persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Favorite].self, from: data)
        else { return }
        items = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    // MARK: CRUD

    @discardableResult
    func add(label: String? = nil, host: String) -> Favorite? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if items.contains(where: { $0.host.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return nil
        }
        guard items.count < Self.maxFavorites else { return nil }
        let fav = Favorite(label: label?.isEmpty == false ? label! : trimmed, host: trimmed)
        items.append(fav); save()
        pingOne(fav)
        return fav
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        status.removeValue(forKey: id)
        save()
    }

    func contains(host: String) -> Bool {
        let t = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.contains { $0.host.caseInsensitiveCompare(t) == .orderedSame }
    }

    // MARK: ping cycle

    private func startTimer() {
        // Stagger first round slightly so it doesn't fire during view init.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.pingAll()
        }
        timer = Timer.scheduledTimer(withTimeInterval: currentInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pingAll() }
        }
    }

    /// Tightens the ping cadence to 10 s while the Status Board is visible
    /// (sparklines / latency look "live"), relaxes back to 30 s when it
    /// closes (so we don't burn pings when nobody's looking).
    func setRefreshMode(active: Bool) {
        let new: TimeInterval = active ? 10 : 30
        guard new != currentInterval else { return }
        currentInterval = new
        timer?.invalidate()
        startTimer()
    }

    private func pingAll() {
        for fav in items { pingOne(fav) }
    }

    private func pingOne(_ fav: Favorite) {
        DispatchQueue.global(qos: .utility).async {
            let result = Self.ping(host: fav.host)
            Task { @MainActor in
                self.status[fav.id] = result
                if let ms = result.rttMs {
                    var samples = self.history[fav.id, default: []]
                    samples.append(ms)
                    let cap = Self.maxHistorySamples
                    if samples.count > cap { samples.removeFirst(samples.count - cap) }
                    self.history[fav.id] = samples
                }
            }
        }
    }

    /// Synchronous single-shot ping. Returns a status with RTT if reachable.
    /// `nonisolated` — spawns `/sbin/ping` and blocks; no actor state touched,
    /// and it is deliberately called from a background queue.
    nonisolated private static func ping(host: String) -> FavoriteStatus {
        let p = Process()
        p.launchPath = "/sbin/ping"
        p.arguments = ["-c", "1", "-W", "1500", host]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch {
            return FavoriteStatus(state: .bad, rttMs: nil, lastChecked: Date())
        }
        // Drain to EOF before waiting — same pattern as Shell.run.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8),
              let r = text.range(of: "time=") else {
            return FavoriteStatus(state: .bad, rttMs: nil, lastChecked: Date())
        }
        let tail = text[r.upperBound...]
        let token = tail.split(separator: " ").first ?? ""
        let ms = Double(token) ?? 0
        let state: FavoriteStatus.State = ms < 80 ? .ok : (ms < 200 ? .slow : .bad)
        return FavoriteStatus(state: state, rttMs: ms, lastChecked: Date())
    }
}
