// ConnectionHealthTests.swift
// SNAP — Tests for the shared System Health / Gateway Latency scoring.
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md

import XCTest
@testable import SNAP

final class ConnectionHealthTests: XCTestCase {

    private func assess(avg: Double?, jitter: Double?, loss: Double = 0, samples: Int = 30,
                        wifi: Int? = nil, alerts: Int = 0,
                        trailingTimeouts: Int = 0) -> ConnectionHealth.Assessment {
        ConnectionHealth.assess(avgMs: avg, jitterMs: jitter, lossPct: loss, samples: samples,
                                wifiQuality: wifi, recentAlerts: alerts,
                                trailingTimeouts: trailingTimeouts)
    }

    private func gateway(avg: Double?, jitter: Double?, loss: Double = 0,
                         samples: Int = 30) -> ConnectionHealth.GatewayState {
        ConnectionHealth.gatewayState(avgMs: avg, jitterMs: jitter, lossPct: loss, samples: samples)
    }

    // MARK: Regressions from real screenshots

    /// v1.5.2 marketing shot: the old score read "Excellent" beside a
    /// "Slow" gateway. Avg 37 ms, jitter 32.2 ms, no loss, Wi-Fi quality 48.
    func test_marketingScreenshot_noLongerExcellent() {
        let a = assess(avg: 37, jitter: 32.2, wifi: 48)
        XCTAssertEqual(a.score, 55)          // 100 − (13.5 latency + 25 jitter + 6 Wi-Fi)
        XCTAssertEqual(a.grade, "Fair")
        XCTAssertEqual(a.summary, "Jitter 32 ms · Latency 37 ms · Weak Wi‑Fi")
        XCTAssertEqual(gateway(avg: 37, jitter: 32.2), .degraded)
    }

    /// Unscrubbed shot: old score 98 "Excellent" with avg 50 ms, jitter
    /// 63.7 ms, Wi-Fi quality 37 — and a "Healthy" gateway label from a
    /// single 5 ms ping.
    func test_rawScreenshot_noLongerExcellent() {
        let a = assess(avg: 50, jitter: 63.7, wifi: 37)
        XCTAssertEqual(a.score, 43)          // 100 − (20 + 25 + 11.5)
        XCTAssertEqual(a.grade, "Degraded")
        XCTAssertEqual(a.summary, "Jitter 64 ms · Latency 50 ms · Weak Wi‑Fi")
        XCTAssertEqual(gateway(avg: 50, jitter: 63.7), .degraded)
    }

    // MARK: Healthy and edge states

    func test_healthyConnection() {
        let a = assess(avg: 3, jitter: 1, wifi: 80)
        XCTAssertEqual(a.score, 100)
        XCTAssertEqual(a.grade, "Excellent")
        XCTAssertEqual(a.summary, "Latency stable · No packet loss")
        XCTAssertEqual(gateway(avg: 3, jitter: 1), .healthy)
    }

    /// 1 of 30 pings lost = 3.333…% loss → cost 10.000000000000002 in raw
    /// floating point. Must stay exactly at the Excellent / Healthy line.
    func test_oneLostPing_staysOnTheLine() {
        let loss = Double(1) / Double(30) * 100
        let a = assess(avg: 3, jitter: 1, loss: loss)
        XCTAssertEqual(a.score, 90)
        XCTAssertEqual(a.grade, "Excellent")
        XCTAssertEqual(a.summary, "3% loss")
        XCTAssertEqual(gateway(avg: 3, jitter: 1, loss: loss), .healthy)
    }

    func test_noSamplesYet_isMeasuring() {
        let a = assess(avg: nil, jitter: nil, samples: 0)
        XCTAssertNil(a.score)
        XCTAssertEqual(a.grade, "Measuring")
        XCTAssertEqual(gateway(avg: nil, jitter: nil, samples: 0), .measuring)
    }

    func test_everyPingTimedOut_isRouterNotResponding() {
        let a = assess(avg: nil, jitter: nil, loss: 100)
        XCTAssertEqual(a.score, 0)
        XCTAssertEqual(a.grade, "Poor")
        XCTAssertEqual(a.summary, "Router not responding")
        XCTAssertEqual(gateway(avg: nil, jitter: nil, loss: 100), .notResponding)
    }

    func test_heavyLoss_isPoor() {
        let a = assess(avg: 3, jitter: 1, loss: 30)   // cost capped at 80
        XCTAssertEqual(a.score, 20)
        XCTAssertEqual(a.grade, "Poor")
        XCTAssertEqual(gateway(avg: 3, jitter: 1, loss: 30), .degraded)
    }

    // MARK: Wi-Fi and alerts

    func test_weakWiFiAlone_isGood_andGatewayStaysHealthy() {
        let a = assess(avg: 3, jitter: 1, wifi: 20)
        XCTAssertEqual(a.score, 80)
        XCTAssertEqual(a.grade, "Good")
        XCTAssertEqual(a.summary, "Weak Wi‑Fi · No packet loss")
        XCTAssertEqual(gateway(avg: 3, jitter: 1), .healthy)
    }

    func test_ethernet_ignoresWiFi() {
        XCTAssertEqual(assess(avg: 3, jitter: 1, wifi: nil).score, 100)
    }

    func test_alertsAreNamed() {
        let a = assess(avg: 3, jitter: 1, alerts: 2)
        XCTAssertEqual(a.score, 92)
        XCTAssertEqual(a.summary, "2 alerts this hour · No packet loss")
    }

    // MARK: Calibration — score and gateway label cross together

    func test_latencyThreshold() {
        XCTAssertEqual(assess(avg: 30, jitter: 0).score, 90)
        XCTAssertEqual(gateway(avg: 30, jitter: 0), .healthy)
        XCTAssertEqual(assess(avg: 31, jitter: 0).score, 89)
        XCTAssertEqual(gateway(avg: 31, jitter: 0), .slow)
    }

    func test_jitterThreshold() {
        XCTAssertEqual(assess(avg: 3, jitter: 15).score, 90)
        XCTAssertEqual(gateway(avg: 3, jitter: 15), .healthy)
        XCTAssertEqual(assess(avg: 3, jitter: 16).score, 89)
        XCTAssertEqual(gateway(avg: 3, jitter: 16), .unstable)
    }

    func test_slowVersusUnstable() {
        XCTAssertEqual(gateway(avg: 45, jitter: 2), .slow)
        XCTAssertEqual(gateway(avg: 5, jitter: 20), .unstable)
    }

    // MARK: Menu bar dot — replaying real ping histories

    /// The dot's color, computed exactly as `MenuBarMonitor.pingHealth` does.
    private func dot(_ history: [Double?]) -> MenuBarMonitor.Health {
        let s = MenuBarMonitor.LatencyStats(history: history)
        return MenuBarMonitor.dotHealth(ConnectionHealth.gatewayState(
            avgMs: s.avg, jitterMs: s.jitter, lossPct: s.lossPct,
            samples: s.sampleCount, trailingTimeouts: s.trailingTimeouts))
    }

    /// Rolls a 30-sample window the way `MenuBarMonitor` does.
    private func push(_ window: inout [Double?], _ sample: Double?) {
        window.append(sample)
        if window.count > MenuBarMonitor.latencyHistoryMax { window.removeFirst() }
    }

    func test_dot_outageAndRecoveryTimeline() {
        var w: [Double?] = Array(repeating: 3, count: 30)
        XCTAssertEqual(dot(w), .good)

        push(&w, nil)                 // one dropped ping: used to turn the dot red
        XCTAssertEqual(dot(w), .good)

        push(&w, nil)                 // two in a row (~20 s): router is down now
        XCTAssertEqual(dot(w), .bad)
        XCTAssertEqual(MenuBarMonitor.LatencyStats(history: w).trailingTimeouts, 2)

        push(&w, 3)                   // back, but 2/30 lost in the window
        XCTAssertEqual(dot(w), .warn)

        for _ in 0..<28 { push(&w, 3) }   // one timeout still in the window
        XCTAssertEqual(dot(w), .good)     // 1/30 lost — same as a single drop
        push(&w, 3)                       // both timeouts have rolled out
        XCTAssertEqual(MenuBarMonitor.LatencyStats(history: w).lossPct, 0)
        XCTAssertEqual(dot(w), .good)
    }

    /// Latest ping 3 ms — the old single-ping rule said green — but six
    /// 200 ms spikes in the window put jitter at 63 ms.
    func test_dot_spikyGatewayIsRedEvenWhenLatestPingIsFast() {
        let w: [Double?] = Array(repeating: 200, count: 6) + Array(repeating: 3, count: 24)
        let s = MenuBarMonitor.LatencyStats(history: w)
        XCTAssertEqual(s.avg!, 42.4, accuracy: 0.001)
        XCTAssertEqual(s.jitter!, 63.04, accuracy: 0.001)
        XCTAssertEqual(dot(w), .bad)
    }

    func test_dot_emptyHistoryIsUnknown() {
        XCTAssertEqual(dot([]), .unknown)
    }

    func test_dotHealthMapping() {
        XCTAssertEqual(MenuBarMonitor.dotHealth(.measuring), .unknown)
        XCTAssertEqual(MenuBarMonitor.dotHealth(.healthy), .good)
        XCTAssertEqual(MenuBarMonitor.dotHealth(.slow), .warn)
        XCTAssertEqual(MenuBarMonitor.dotHealth(.unstable), .warn)
        XCTAssertEqual(MenuBarMonitor.dotHealth(.degraded), .bad)
        XCTAssertEqual(MenuBarMonitor.dotHealth(.notResponding), .bad)
    }

    func test_twoTimeoutsInARow_healthTileAgreesWithDot() {
        let a = assess(avg: 3, jitter: 1, loss: 6.7, trailingTimeouts: 2)
        XCTAssertEqual(a.summary, "Router not responding")
        XCTAssertEqual(a.score, 0)
    }

    // MARK: Wi-Fi quality mapping (shared with the Wi-Fi tile)

    func test_wifiQualityMapping() {
        XCTAssertEqual(ConnectionHealth.wifiQuality(rssi: -40), 100)
        XCTAssertEqual(ConnectionHealth.wifiQuality(rssi: -30), 100)   // clamped
        XCTAssertEqual(ConnectionHealth.wifiQuality(rssi: -62), 51)
        XCTAssertEqual(ConnectionHealth.wifiQuality(rssi: -85), 0)
        XCTAssertEqual(ConnectionHealth.wifiQuality(rssi: 0), 0)       // not associated
    }
}
