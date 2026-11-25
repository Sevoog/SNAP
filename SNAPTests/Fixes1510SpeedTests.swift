// Fixes1510SpeedTests.swift
// SNAP: Tests for the 1.5.10 Speed Test and Bandwidth Monitor fixes
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md

import XCTest
@testable import SNAP

final class Fixes1510SpeedTests: XCTestCase {

    private func http(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://speed.cloudflare.com/__down")!,
                        statusCode: status, httpVersion: "HTTP/2", headerFields: nil)!
    }

    // MARK: Failed requests don't count

    func testOnlyTwoHundredRepliesCount() {
        XCTAssertTrue(InternetSpeedTest.isSuccess(http(200)))
        XCTAssertTrue(InternetSpeedTest.isSuccess(http(204)))
        for status in [301, 403, 404, 429, 500, 503] {
            XCTAssertFalse(InternetSpeedTest.isSuccess(http(status)), "\(status)")
        }
        XCTAssertFalse(InternetSpeedTest.isSuccess(nil))
        let plain = URLResponse(url: URL(string: "https://example.com")!, mimeType: nil,
                                expectedContentLength: 0, textEncodingName: nil)
        XCTAssertFalse(InternetSpeedTest.isSuccess(plain))
    }

    func testPingStatsNeedAReply() {
        XCTAssertNil(InternetSpeedTest.pingStats([]))
        let one = InternetSpeedTest.pingStats([12])
        XCTAssertEqual(one?.avg, 12)
        XCTAssertEqual(one?.jitter, 0)
        // The slowest is dropped: 10, 12, 14 average 12 with jitter 4/3
        let many = InternetSpeedTest.pingStats([14, 10, 90, 12])
        XCTAssertEqual(many?.avg ?? 0, 12, accuracy: 0.0001)
        XCTAssertEqual(many?.jitter ?? 0, 4.0 / 3.0, accuracy: 0.0001)
    }

    /// The delegate cancels an error reply before its body arrives, and reports
    /// the chunk as failed.
    func testDownloadDelegateRejectsErrorReplies() {
        let task = URLSession.shared.dataTask(with: URL(string: "https://speed.cloudflare.com/__down?bytes=1")!)

        final class Box: @unchecked Sendable { var disposition: URLSession.ResponseDisposition? }

        func run(status: Int, error: Error?) -> (URLSession.ResponseDisposition?, Bool?) {
            let d = DownloadDelegate()
            let box = Box()
            var ok: Bool?
            d.onDone = { ok = $0 }
            d.urlSession(URLSession.shared, dataTask: task, didReceive: http(status)) { box.disposition = $0 }
            d.urlSession(URLSession.shared, task: task, didCompleteWithError: error)
            return (box.disposition, ok)
        }

        let good = run(status: 200, error: nil)
        XCTAssertEqual(good.0, .allow)
        XCTAssertEqual(good.1, true)

        let limited = run(status: 429, error: URLError(.cancelled))
        XCTAssertEqual(limited.0, .cancel)
        XCTAssertEqual(limited.1, false)

        let dropped = run(status: 200, error: URLError(.networkConnectionLost))
        XCTAssertEqual(dropped.1, false)
        task.cancel()
    }

    func testFailureMessages() {
        XCTAssertEqual(SpeedTestFailure.unreachable.message(downloadMbps: 0),
                       "Couldn't reach Cloudflare's speed test server. Check that you're online, then click Test Again. Nothing was saved to history.")
        let upload = SpeedTestFailure.upload.message(downloadMbps: 312.44)
        XCTAssertTrue(upload.hasPrefix("Download finished at 312.4 Mbps, but the upload"))
        for f in [SpeedTestFailure.unreachable, .download, .upload] {
            let m = f.message(downloadMbps: 50)
            XCTAssertTrue(m.hasSuffix("Nothing was saved to history."))
            XCTAssertFalse(m.contains("Error"))
            XCTAssertFalse(m.contains("!"))
            XCTAssertFalse(m.contains("\u{2014}") || m.contains("\u{2013}"))
        }
    }

    // MARK: Upload sends what each size promises

    func testUploadSendsThePromisedAmount() {
        for size in TestSize.allCases {
            XCTAssertEqual(size.uploadChunks * TestSize.uploadChunkBytes, size.uploadBytes, size.rawValue)
            XCTAssertEqual(size.uploadDescription, "\(size.uploadBytes / 1_000_000) MB upload")
        }
        XCTAssertEqual(TestSize.mb500.uploadChunks, 50)
        XCTAssertEqual(TestSize.gb1.uploadChunks, 75)
        XCTAssertEqual(TestSize.gb2.uploadChunks, 100)
    }

    // MARK: History chart and copy text

    private func result(_ date: Date, down: Double = 100, up: Double = 20) -> SpeedResult {
        SpeedResult(date: date, download: down, upload: up, ping: 10, jitter: 1,
                    provider: "Cloudflare", testSize: "1 GB")
    }

    func testHistoryBarsAreEvenSlotsOldestFirst() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let day1 = cal.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 9))!
        let day1Later = day1.addingTimeInterval(3_600)
        let day5 = day1.addingTimeInterval(4 * 86_400)
        // The store keeps newest first
        let results = [result(day5, down: 3), result(day1Later, down: 2), result(day1, down: 1)]
        let bars = InternetSpeedTest.historyBars(results, calendar: cal)
        XCTAssertEqual(bars.map(\.download), [1, 2, 3])
        XCTAssertEqual(bars.map(\.slot), ["0", "1", "2"])
        XCTAssertNotNil(bars[0].day)
        XCTAssertNil(bars[1].day, "same day as the test before it")
        XCTAssertNotNil(bars[2].day)

        let many = (0..<25).map { result(day1.addingTimeInterval(Double(-$0) * 60)) }
        let ten = InternetSpeedTest.historyBars(many, calendar: cal)
        XCTAssertEqual(ten.count, 10)
        XCTAssertEqual(Set(ten.map(\.slot)).count, 10)
        XCTAssertEqual(ten.last?.id, many.first?.id, "the newest test is on the right")
    }

    func testCopyTextUsesTheTestsOwnDate() {
        let when = Date(timeIntervalSince1970: 1_600_000_000)   // September 2020
        let text = InternetSpeedTest.copyText(for: result(when, down: 940.5, up: 41.25))
        XCTAssertTrue(text.contains("Date:      \(when.formatted())"))
        XCTAssertFalse(text.contains(Date().formatted(date: .numeric, time: .omitted)))
        XCTAssertTrue(text.contains("Test Size: 1 GB down · 75 MB upload"))
        XCTAssertTrue(text.contains("Download:  940.50 Mbps"))
        XCTAssertTrue(text.contains("Upload:    41.25 Mbps"))
    }

    // MARK: Bandwidth Monitor

    func testTimeAxisPerRange() {
        func axis(_ r: HistoryRange) -> BandwidthTimeAxis { .forSpan(r.windowSeconds) }
        XCTAssertEqual(axis(.live).component, .second)
        XCTAssertEqual(axis(.live).count, 15)
        XCTAssertEqual(axis(.m5).component, .minute)
        XCTAssertEqual(axis(.h1).component, .minute)
        XCTAssertEqual(axis(.h1).count, 10)
        XCTAssertEqual(axis(.h6).component, .hour)
        XCTAssertEqual(axis(.h6).count, 1)
        XCTAssertEqual(axis(.d1).component, .hour)
        XCTAssertEqual(axis(.d1).count, 3)
        XCTAssertEqual(axis(.d7).component, .day)
        // Live's rolling buffer holds two minutes
        XCTAssertEqual(BandwidthTimeAxis.forSpan(120).component, .second)
    }

    func testTimeAxisNeverDrawsTooManyGridlines() {
        var span: TimeInterval = 1
        while span <= HistoryRange.d7.windowSeconds {
            let a = BandwidthTimeAxis.forSpan(span)
            XCTAssertLessThanOrEqual(span / a.strideSeconds, 12, "span \(span)")
            span *= 1.1
        }
        XCTAssertLessThanOrEqual(HistoryRange.d7.windowSeconds / BandwidthTimeAxis.forSpan(HistoryRange.d7.windowSeconds).strideSeconds, 12)
    }

    func testTimeAxisFollowsTheDataSpan() {
        let now = Date()
        let samples = [0.0, 900, 1_800].map {
            BandwidthSample(time: now.addingTimeInterval($0), rxBps: 1, txBps: 1, interface: "en0")
        }
        XCTAssertEqual(BandwidthTimeAxis.forSamples(samples).component, .minute)
        XCTAssertEqual(BandwidthTimeAxis.forSamples(samples).count, 10)
        XCTAssertEqual(BandwidthTimeAxis.forSamples([]).component, .second)
    }

    func testReadingStateNeverSpinsWhenNothingIsComing() {
        XCTAssertEqual(MonitorReadingState.decide(isRunning: true, readings: 0, lastRoundLost: false), .measuring)
        XCTAssertEqual(MonitorReadingState.decide(isRunning: true, readings: 0, lastRoundLost: true), .unreachable)
        XCTAssertEqual(MonitorReadingState.decide(isRunning: true, readings: 1, lastRoundLost: true), .unreachable)
        XCTAssertEqual(MonitorReadingState.decide(isRunning: false, readings: 1, lastRoundLost: false), .idle)
        XCTAssertEqual(MonitorReadingState.decide(isRunning: false, readings: 0, lastRoundLost: true), .idle)
        XCTAssertEqual(MonitorReadingState.decide(isRunning: true, readings: 2, lastRoundLost: true), .chart)
        XCTAssertEqual(MonitorReadingState.decide(isRunning: false, readings: 5, lastRoundLost: false), .chart)
    }
}
