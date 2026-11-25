// Fixes1510ScanTests.swift
// SNAP: Tests for the 1.5.10 scanner fixes (Port Scan, MTU Discovery,
// Multi-Host Compare, Visual Trace Route, MTR, Bulk Discovery)
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md

import XCTest
import Network
import Darwin
@testable import SNAP

final class Fixes1510ScanTests: XCTestCase {

    // MARK: - Port Scan

    func test_portScan_parsePorts() {
        XCTAssertEqual(PortScan.parsePorts("22,80,443"), [22, 80, 443])
        XCTAssertEqual(PortScan.parsePorts("443, 22 ,22"), [22, 443])
        XCTAssertEqual(PortScan.parsePorts("1-3"), [1, 2, 3])
        XCTAssertEqual(PortScan.parsePorts("1 - 3,80"), [1, 2, 3, 80])
        XCTAssertEqual(PortScan.parsePorts("65534-70000"), [65534, 65535])
    }

    /// These used to start a scan of zero ports that ended with nothing shown.
    func test_portScan_parsePorts_emptyOrInvalid() {
        XCTAssertEqual(PortScan.parsePorts(""), [])
        XCTAssertEqual(PortScan.parsePorts("   "), [])
        XCTAssertEqual(PortScan.parsePorts("http"), [])
        XCTAssertEqual(PortScan.parsePorts("0,65536"), [])
        XCTAssertEqual(PortScan.parsePorts("8080-80"), [])
    }

    func test_portScan_insertionIndexKeepsOrder() {
        var results: [PortResult] = []
        for port in [443, 22, 8080, 80, 1] {
            let r = PortResult(port: port, service: "", status: .open)
            results.insert(r, at: PortScan.insertionIndex(of: port, in: results))
        }
        XCTAssertEqual(results.map(\.port), [1, 22, 80, 443, 8080])
    }

    /// A refused connection shows up as `.waiting`, and must read Closed.
    func test_portScan_statusForState() {
        XCTAssertEqual(PortScan.status(for: .ready), .open)
        XCTAssertEqual(PortScan.status(for: .waiting(.posix(.ECONNREFUSED))), .closed)
        XCTAssertEqual(PortScan.status(for: .failed(.posix(.ECONNREFUSED))), .closed)
        XCTAssertNil(PortScan.status(for: .waiting(.posix(.ENETDOWN))))
        XCTAssertEqual(PortScan.status(for: .failed(.posix(.EHOSTUNREACH))), .filtered)
        XCTAssertNil(PortScan.status(for: .preparing))
        XCTAssertNil(PortScan.status(for: .setup))
    }

    func test_portScan_resolve() async {
        let local = await PortScan.resolve("127.0.0.1")
        XCTAssertEqual(local, "127.0.0.1")
        // .invalid never resolves (RFC 2606)
        let missing = await PortScan.resolve("no-such-host.invalid")
        XCTAssertNil(missing)
        // localhost lists ::1 first; IPv4 is preferred when a name has both
        let loopback = await PortScan.resolve("localhost")
        XCTAssertEqual(loopback, "127.0.0.1")
    }

    /// Against a listener on this Mac: Open while it listens, Closed (not
    /// Filtered after the timeout) once it's gone.
    func test_portScan_probe_openThenClosed() async throws {
        let listener = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        XCTAssertGreaterThanOrEqual(listener, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { p -> Bool in
                Darwin.bind(listener, p, len) == 0 && listen(listener, 4) == 0
                    && getsockname(listener, p, &len) == 0
            }
        }
        XCTAssertTrue(bound)
        let port = Int(UInt16(bigEndian: addr.sin_port))

        let open = await PortScan.probe(host: "127.0.0.1", port: port, timeout: 3)
        XCTAssertEqual(open, .open)

        Darwin.close(listener)
        let began = Date()
        let closed = await PortScan.probe(host: "127.0.0.1", port: port, timeout: 3)
        XCTAssertEqual(closed, .closed)
        XCTAssertLessThan(Date().timeIntervalSince(began), 2, "refused should not wait for the timeout")
    }

    /// Stop cancels the scan task; in-flight probes must end right away.
    func test_portScan_probe_endsWhenCancelled() async {
        let began = Date()
        // TEST-NET-1: never answers
        let task = Task { await PortScan.probe(host: "192.0.2.1", port: 81, timeout: 20) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        _ = await task.value
        XCTAssertLessThan(Date().timeIntervalSince(began), 5)
    }

    // MARK: - MTU Discovery

    func test_mtu_pingPassed() {
        XCTAssertTrue(MTUDiscoveryView.pingPassed("""
            PING 1.1.1.1 (1.1.1.1): 56 data bytes
            64 bytes from 1.1.1.1: icmp_seq=0 ttl=57 time=12.3 ms

            --- 1.1.1.1 ping statistics ---
            1 packets transmitted, 1 packets received, 0.0% packet loss
            """))
        XCTAssertFalse(MTUDiscoveryView.pingPassed("""
            --- 1.1.1.1 ping statistics ---
            1 packets transmitted, 0 packets received, 100.0% packet loss
            """))
        XCTAssertFalse(MTUDiscoveryView.pingPassed("ping: sendto: Message too long"))
        XCTAssertFalse(MTUDiscoveryView.pingPassed("ping: cannot resolve nope.invalid: Unknown host"))
        XCTAssertFalse(MTUDiscoveryView.pingPassed(""))
    }

    func test_mtu_noAnswerMessage() {
        XCTAssertEqual(MTUDiscoveryView.noAnswerMessage(host: "10.9.9.9"),
                       "10.9.9.9 didn't answer a ping, so SNAP can't measure the path. Check the address, or try a host that answers ping, such as 1.1.1.1.")
        XCTAssertLessThan(MTUDiscoveryView.reachabilityPayload, 1200)
    }

    // MARK: - Multi-Host Compare

    func test_multiHost_pingCount() {
        XCTAssertEqual(MultiHostCompareView.pingCount("5"), 5)
        XCTAssertEqual(MultiHostCompareView.pingCount(" 1 "), 1)
        XCTAssertEqual(MultiHostCompareView.pingCount("50"), 50)
        XCTAssertNil(MultiHostCompareView.pingCount("0"))
        XCTAssertNil(MultiHostCompareView.pingCount("-3"))
        XCTAssertNil(MultiHostCompareView.pingCount("51"))
        XCTAssertNil(MultiHostCompareView.pingCount(""))
        XCTAssertNil(MultiHostCompareView.pingCount("five"))
    }

    func test_multiHost_parsePorts() {
        XCTAssertEqual(MultiHostCompareView.parsePorts("80,443"), [80, 443])
        XCTAssertEqual(MultiHostCompareView.parsePorts("443, 80, 443, ssh, 0, 70000"), [443, 80])
        XCTAssertEqual(MultiHostCompareView.parsePorts(""), [])
    }

    /// Unresolved or silent hosts used to get a green check.
    func test_multiHost_failure() {
        XCTAssertNotNil(MultiHostCompareView.failure(found: false, pingReplies: 0, httpStatus: nil, portOpen: [:]))
        XCTAssertNotNil(MultiHostCompareView.failure(found: true, pingReplies: 0, httpStatus: nil, portOpen: [80: false]))
        XCTAssertNil(MultiHostCompareView.failure(found: true, pingReplies: 3, httpStatus: nil, portOpen: [:]))
        // ICMP blocked but the web server answers: not a failure
        XCTAssertNil(MultiHostCompareView.failure(found: true, pingReplies: 0, httpStatus: 200, portOpen: [:]))
        XCTAssertNil(MultiHostCompareView.failure(found: true, pingReplies: 0, httpStatus: nil, portOpen: [443: true]))
    }

    func test_multiHost_portText() {
        let ports = [443: true, 80: false, 22: true]
        XCTAssertEqual(MultiHostCompareView.portSummary(ports), "22, 443")
        XCTAssertEqual(MultiHostCompareView.portSummary([80: false]), "None")
        XCTAssertNil(MultiHostCompareView.portSummary([:]))
        XCTAssertEqual(MultiHostCompareView.portDetail(ports), "22 open, 80 not open, 443 open")
        XCTAssertEqual(MultiHostCompareView.ports(ports, open: true), "22;443")
        XCTAssertEqual(MultiHostCompareView.ports(ports, open: false), "80")
    }

    // MARK: - Visual Trace Route

    private func reply(_ json: String) -> VisualTraceViewModel.GeoReply {
        VisualTraceViewModel.parseGeoReply(Data(json.utf8))
    }

    func test_visualTrace_parseGeoReply() {
        // Shapes taken from live ipwho.is replies
        XCTAssertEqual(reply(#"{"ip":"10.0.0.1","success":false,"message":"Reserved range"}"#), .noLocation)
        XCTAssertEqual(reply(#"{"ip":"1.1.1.1","success":false,"message":"You've hit the monthly limit"}"#), .failed)
        XCTAssertEqual(reply("<html>Bad gateway</html>"), .failed)
        XCTAssertEqual(reply(#"{"success":true,"latitude":39,"longitude":-77.5,"city":"Ashburn","country":"United States","country_code":"US","connection":{"asn":13335,"org":"Cloudflare"}}"#),
                       .located(lat: 39, lon: -77.5, city: "Ashburn", country: "United States",
                                countryCode: "US", org: "AS13335 Cloudflare"))
    }

    func test_visualTrace_failureMessage() {
        XCTAssertNil(VisualTraceViewModel.failureMessage(0))
        XCTAssertEqual(VisualTraceViewModel.failureMessage(1),
                       "Couldn't place 1 hop on the map. The location service didn't answer. Try again in a minute.")
        XCTAssertEqual(VisualTraceViewModel.failureMessage(3),
                       "Couldn't place 3 hops on the map. The location service didn't answer. Try again in a minute.")
    }

    // MARK: - MTR

    /// Stop while the path is still being discovered: no hops, and no
    /// pings started once the traceroute would have returned.
    @MainActor
    func test_mtr_stopDuringDiscoveryNeverStartsPings() async {
        let model = MTRModel()
        model.target = "127.0.0.1"
        model.start()
        XCTAssertEqual(model.phase, .discovering)
        model.stop()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertTrue(model.hops.isEmpty)
        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(model.phase, .stopped)
    }

    // MARK: - Bulk Discovery

    /// A cancelled run used to carry on and overwrite "Cancelled" with "Done".
    @MainActor
    func test_bulk_cancelStaysCancelled() async {
        let model = BulkDiscoveryModel()
        model.cidr = "127.0.0.1"
        model.includePortScan = false
        model.probeSNMP = false
        model.start()
        XCTAssertTrue(model.isRunning)
        model.cancel()
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(model.status, "Cancelled")
        XCTAssertTrue(model.assets.isEmpty)
    }

    // MARK: Bulk Discovery: a refusing host is alive

    func testBulkDiscoveryCountsARefusalAsAnAnswer() {
        XCTAssertTrue(BulkDiscoveryModel.answered(.open))
        XCTAssertTrue(BulkDiscoveryModel.answered(.closed))      // refused: host is up
        XCTAssertFalse(BulkDiscoveryModel.answered(.filtered))   // no answer
    }

    func testRefusedLocalPortReadsClosedNotFiltered() async {
        // Nothing listens on port 1 here, so the kernel refuses at once
        let status = await PortScan.probe(host: "127.0.0.1", port: 1, timeout: 2)
        XCTAssertEqual(status, .closed)
        XCTAssertTrue(BulkDiscoveryModel.answered(status))
    }

    // MARK: Multi-Host Stop: a cancelled ping ends at once

    func testShellRunStopsOnCancelWhenAsked() async {
        let started = Date()
        let task = Task { await Shell.run("/bin/sleep", args: ["30"], stopsOnCancel: true) }
        try? await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        _ = await task.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testShellRunCancelledBeforeStartRunsNothing() async {
        let started = Date()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await Shell.run("/bin/sleep", args: ["30"], stopsOnCancel: true)
        }
        let out = await task.value
        XCTAssertEqual(out, "")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testShellRunWithoutStopsOnCancelStillFinishes() async {
        let task = Task { await Shell.run("/bin/echo", args: ["hello"]) }
        task.cancel()
        let out = await task.value
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
    }
}
