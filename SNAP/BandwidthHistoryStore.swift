// BandwidthHistoryStore.swift
// SNAP — Persistent bandwidth + quality sample store
// Created by Sevag Bardakjian
// Copyright © 2025 Sevag Bardakjian. All rights reserved.
//
// SQLite-backed rolling history of bandwidth + quality samples (RX/TX bps,
// latency, jitter, packet loss, retransmit rate, DNS latency, quality
// score) so the Bandwidth Monitor view can show:
//   • Live (last 60s)               — straight from BandwidthMonitor.samples
//   • 5 minutes  → raw samples
//   • 1 hour     → 30-second buckets
//   • 6 hours    → 2-minute buckets
//   • 24 hours   → 5-minute buckets
//   • 7 days     → 30-minute buckets
//
// Storage: ~/Library/Application Support/SNAP/bandwidth.sqlite
// Retention: 30 days, pruned on init.

import Foundation
import SQLite3

// MARK: - Public types

struct HistorySample: Hashable {
    let ts: Date
    let iface: String
    let rxBps: Double
    let txBps: Double
    let latencyMs: Double?
    let jitterMs: Double?
    let lossPct: Double?
    let retransmitPct: Double?
    let dnsLatencyMs: Double?
    let quality: Int?
}

enum HistoryRange: String, CaseIterable, Identifiable {
    case live  = "Live"
    case m5    = "5 min"
    case h1    = "1 h"
    case h6    = "6 h"
    case d1    = "24 h"
    case d7    = "7 d"

    var id: String { rawValue }

    /// Window length in seconds. Live shows ~last 60s from the in-memory buffer.
    var windowSeconds: TimeInterval {
        switch self {
        case .live: return 60
        case .m5:   return 300
        case .h1:   return 3600
        case .h6:   return 21_600
        case .d1:   return 86_400
        case .d7:   return 604_800
        }
    }

    /// Aggregation bucket size in seconds. Zero = no aggregation.
    /// Picked so each range renders ~120 points on the chart.
    var bucketSeconds: Int {
        switch self {
        case .live, .m5: return 0      // raw
        case .h1:        return 30
        case .h6:        return 120
        case .d1:        return 300
        case .d7:        return 1800
        }
    }

    /// Should the chart auto-update with live samples (true) or be frozen
    /// at the time of selection (false)?
    var isLive: Bool { self == .live }
}

// MARK: - Store

final class BandwidthHistoryStore {
    static let shared = BandwidthHistoryStore()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "snap.bandwidth.history", qos: .utility)
    private let dateFile: URL

    private init() {
        let fm = FileManager.default
        let appSupport = (try? fm.url(for: .applicationSupportDirectory,
                                      in: .userDomainMask,
                                      appropriateFor: nil,
                                      create: true)) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = appSupport.appendingPathComponent("SNAP", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        dateFile = dir.appendingPathComponent("bandwidth.sqlite")

        open()
        createSchema()
        pruneOldSamples(olderThan: 30 * 86_400)
    }

    deinit {
        if let db = db { sqlite3_close(db) }
    }

    // MARK: Open / schema

    private func open() {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(dateFile.path, &db, flags, nil)
        if rc != SQLITE_OK {
            NSLog("SNAP: BandwidthHistoryStore failed to open \(dateFile.path): \(rc)")
            db = nil
        } else {
            // Larger cache + WAL for better concurrent read while writing.
            exec("PRAGMA journal_mode=WAL")
            exec("PRAGMA synchronous=NORMAL")
        }
    }

    private func createSchema() {
        exec("""
        CREATE TABLE IF NOT EXISTS samples (
            ts        REAL    NOT NULL,
            iface     TEXT    NOT NULL,
            rx_bps    REAL    NOT NULL,
            tx_bps    REAL    NOT NULL,
            lat_ms    REAL,
            jit_ms    REAL,
            loss_pct  REAL,
            retx_pct  REAL,
            dns_ms    REAL,
            quality   INTEGER
        )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_samples_ts ON samples(ts)")
        exec("CREATE INDEX IF NOT EXISTS idx_samples_iface_ts ON samples(iface, ts)")
    }

    private func pruneOldSamples(olderThan seconds: TimeInterval) {
        let cutoff = Date().addingTimeInterval(-seconds).timeIntervalSince1970
        queue.async { [weak self] in
            guard let self = self, let db = self.db else { return }
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM samples WHERE ts < ?1", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_double(stmt, 1, cutoff)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        guard let db = db else { return false }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.flatMap { String(cString: $0) } ?? "?"
            NSLog("SNAP: SQL exec failed: \(msg) — \(sql)")
            sqlite3_free(err)
            return false
        }
        return true
    }

    // MARK: Insert

    /// Insert one sample. Called from BandwidthMonitor on the main actor;
    /// the actual SQL write happens off-thread via the serial queue.
    func insert(_ s: HistorySample) {
        let ts = s.ts.timeIntervalSince1970
        let iface = s.iface
        let rx = s.rxBps
        let tx = s.txBps
        let lat = s.latencyMs
        let jit = s.jitterMs
        let loss = s.lossPct
        let retx = s.retransmitPct
        let dns = s.dnsLatencyMs
        let qual = s.quality

        queue.async { [weak self] in
            guard let self = self, let db = self.db else { return }
            var stmt: OpaquePointer?
            let sql = "INSERT INTO samples (ts, iface, rx_bps, tx_bps, lat_ms, jit_ms, loss_pct, retx_pct, dns_ms, quality) VALUES (?,?,?,?,?,?,?,?,?,?)"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, ts)
            sqlite3_bind_text(stmt, 2, iface, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 3, rx)
            sqlite3_bind_double(stmt, 4, tx)
            Self.bindOptionalDouble(stmt, 5, lat)
            Self.bindOptionalDouble(stmt, 6, jit)
            Self.bindOptionalDouble(stmt, 7, loss)
            Self.bindOptionalDouble(stmt, 8, retx)
            Self.bindOptionalDouble(stmt, 9, dns)
            if let q = qual { sqlite3_bind_int(stmt, 10, Int32(q)) } else { sqlite3_bind_null(stmt, 10) }
            sqlite3_step(stmt)
        }
    }

    // MARK: Query

    /// Synchronously fetch samples for an interface over a time range, with
    /// optional aggregation. Called off the main thread from a Task.
    func samples(iface: String, range: HistoryRange) -> [HistorySample] {
        let now = Date()
        let from = now.addingTimeInterval(-range.windowSeconds).timeIntervalSince1970
        let to   = now.timeIntervalSince1970

        return queue.sync {
            guard let db = db else { return [] }
            let bucket = range.bucketSeconds

            let sql: String
            if bucket == 0 {
                sql = """
                SELECT ts, iface, rx_bps, tx_bps, lat_ms, jit_ms, loss_pct, retx_pct, dns_ms, quality
                FROM samples
                WHERE iface = ?1 AND ts >= ?2 AND ts <= ?3
                ORDER BY ts
                """
            } else {
                // CAST(ts / bucket) * bucket gives the bucket start time.
                sql = """
                SELECT
                    CAST(ts / \(bucket) AS INTEGER) * \(bucket) AS bucket_ts,
                    iface,
                    AVG(rx_bps), AVG(tx_bps),
                    AVG(lat_ms), AVG(jit_ms), AVG(loss_pct), AVG(retx_pct), AVG(dns_ms),
                    CAST(AVG(quality) AS INTEGER)
                FROM samples
                WHERE iface = ?1 AND ts >= ?2 AND ts <= ?3
                GROUP BY bucket_ts
                ORDER BY bucket_ts
                """
            }

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, iface, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 2, from)
            sqlite3_bind_double(stmt, 3, to)

            var out: [HistorySample] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let ts    = sqlite3_column_double(stmt, 0)
                let iface = String(cString: sqlite3_column_text(stmt, 1))
                let rx    = sqlite3_column_double(stmt, 2)
                let tx    = sqlite3_column_double(stmt, 3)
                let lat   = Self.columnOptionalDouble(stmt, 4)
                let jit   = Self.columnOptionalDouble(stmt, 5)
                let loss  = Self.columnOptionalDouble(stmt, 6)
                let retx  = Self.columnOptionalDouble(stmt, 7)
                let dns   = Self.columnOptionalDouble(stmt, 8)
                let quality: Int? = sqlite3_column_type(stmt, 9) == SQLITE_NULL
                    ? nil : Int(sqlite3_column_int(stmt, 9))
                out.append(HistorySample(
                    ts: Date(timeIntervalSince1970: ts),
                    iface: iface,
                    rxBps: rx, txBps: tx,
                    latencyMs: lat, jitterMs: jit,
                    lossPct: loss, retransmitPct: retx,
                    dnsLatencyMs: dns, quality: quality
                ))
            }
            return out
        }
    }

    /// Total row count — used as a quick sanity check + storage indicator.
    func rowCount() -> Int {
        return queue.sync {
            guard let db = db else { return 0 }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM samples", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            if sqlite3_step(stmt) == SQLITE_ROW {
                return Int(sqlite3_column_int(stmt, 0))
            }
            return 0
        }
    }

    /// Wipe all rows (used by user-initiated "Clear history" action).
    func clearAll() {
        queue.async { [weak self] in
            guard let db = self?.db else { return }
            sqlite3_exec(db, "DELETE FROM samples", nil, nil, nil)
            sqlite3_exec(db, "VACUUM", nil, nil, nil)
        }
    }

    // MARK: SQLite C glue

    // SQLite needs a stable lifetime for bound text — use the magic
    // SQLITE_TRANSIENT sentinel so it makes its own copy.
    private static let SQLITE_TRANSIENT = unsafeBitCast(
        OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self
    )

    private static func bindOptionalDouble(_ stmt: OpaquePointer?,
                                           _ idx: Int32,
                                           _ value: Double?) {
        if let v = value {
            sqlite3_bind_double(stmt, idx, v)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    private static func columnOptionalDouble(_ stmt: OpaquePointer?, _ idx: Int32) -> Double? {
        if sqlite3_column_type(stmt, idx) == SQLITE_NULL { return nil }
        return sqlite3_column_double(stmt, idx)
    }
}
