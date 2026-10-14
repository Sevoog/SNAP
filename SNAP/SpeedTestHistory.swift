// SpeedTestHistory.swift
// SNAP v1.1 — Persistent speed test history via UserDefaults
// Created by Sevag Bardakjian
// Copyright © 2025-2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md

import Foundation
import SwiftUI

// MARK: - Persistent SpeedResult

struct SpeedResult: Identifiable, Hashable, Codable {
    static func == (lhs: SpeedResult, rhs: SpeedResult) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var id: UUID = UUID()
    var date: Date
    var download: Double
    var upload: Double
    var ping: Double
    var jitter: Double
    var provider: String
    var testSize: String
}

// MARK: - History Store

final class SpeedTestHistoryStore: ObservableObject {
    static let shared = SpeedTestHistoryStore()
    private let key = "snap_speed_history"

    @Published private(set) var results: [SpeedResult] = []

    private init() { load() }

    func add(_ result: SpeedResult) {
        results.insert(result, at: 0)   // newest first
        if results.count > 100 { results = Array(results.prefix(100)) }
        save()
    }

    func clear() {
        results = []
        UserDefaults.standard.removeObject(forKey: key)
    }

    func exportCSV() -> String {
        var csv = "Date,Provider,Size,Download (Mbps),Upload (Mbps),Ping (ms),Jitter (ms)\n"
        for r in results {
            let d = ISO8601DateFormatter().string(from: r.date)
            csv += "\(d),\(r.provider),\(r.testSize),\(String(format:"%.2f",r.download)),\(String(format:"%.2f",r.upload)),\(String(format:"%.1f",r.ping)),\(String(format:"%.1f",r.jitter))\n"
        }
        return csv
    }

    func exportJSON() -> String {
        let dicts = results.map { r -> [String: Any] in
            ["id": r.id.uuidString,
             "date": ISO8601DateFormatter().string(from: r.date),
             "provider": r.provider,
             "testSize": r.testSize,
             "download": r.download,
             "upload": r.upload,
             "ping": r.ping,
             "jitter": r.jitter]
        }
        let payload: [String: Any] = [
            "app": "SNAP",
            "exported": ISO8601DateFormatter().string(from: Date()),
            "results": dicts
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted),
              let str = String(data: data, encoding: .utf8) else { return "[]" }
        return str
    }

    private func save() {
        if let data = try? JSONEncoder().encode(results) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([SpeedResult].self, from: data) else { return }
        results = decoded
    }
}
