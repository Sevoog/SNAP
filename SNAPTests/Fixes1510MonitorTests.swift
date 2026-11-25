// Fixes1510MonitorTests.swift
// SNAP: Tests for the 1.5.10 fixes to Packet Capture, Wi-Fi Analyzer, Active Connections, Network Health and Routing Hello
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md

import XCTest
import Network
import dnssd
import Darwin
@testable import SNAP

@MainActor
final class Fixes1510MonitorTests: XCTestCase {

    // MARK: - Packet Capture: sample output
    // Real tcpdump 4.99.1 (Apple version 161) output, made by reading a crafted
    // pcap with `tcpdump -r sample.pcap -n -l -tttt` (with and without -v).

    private let plainLines = [
        "reading from file sample.pcap, link-type EN10MB (Ethernet)",
        "2026-11-18 03:06:40.123456 IP 192.168.1.5.52344 > 142.250.80.46.443: Flags [P.], seq 1000:1010, ack 2000, win 2048, length 10",
        "2026-11-18 03:06:41.123456 IP 142.250.80.46.80 > 192.168.1.5.52345: Flags [.], ack 2000, win 2048, length 0",
        "2026-11-18 03:06:42.123456 IP 192.168.1.5.53211 > 8.8.8.8.53: 4660+ A? example.com. (29)",
        "2026-11-18 03:06:43.123456 IP 192.168.1.5 > 8.8.8.8: ICMP echo request, id 1, seq 0, length 12",
        "2026-11-18 03:06:44.123456 IP6 2001:db8::1.50000 > 2606:4700::1111.443: Flags [S], seq 1000, win 2048, length 0",
        "2026-11-18 03:06:45.123456 IP6 fe80::1.5353 > ff02::fb.5353: 4660+ A (QM)? example.com. (29)",
        "2026-11-18 03:06:46.123456 IP6 fe80::1 > fe80::2: ICMP6, echo request, id 1, seq 0, length 12",
        "2026-11-18 03:06:47.123456 ARP, Request who-has 192.168.1.1 tell 192.168.1.5, length 28",
        "2026-11-18 03:06:48.123456 ARP, Reply 192.168.1.1 is-at 11:22:33:44:55:66, length 28",
        "2026-11-18 03:06:49.123456 IP 10.0.0.2.40000 > 10.0.0.3.9999: UDP, length 5",
    ]

    private let verboseLines = [
        "tcpdump: listening on en0, link-type EN10MB (Ethernet), snapshot length 524288 bytes",
        "2026-11-18 03:06:40.123456 IP (tos 0x0, ttl 64, id 4660, offset 0, flags [DF], proto TCP (6), length 50)",
        "    192.168.1.5.52344 > 142.250.80.46.443: Flags [P.], cksum 0x0000 (incorrect -> 0xd2a6), seq 1000:1010, ack 2000, win 2048, length 10",
        "2026-11-18 03:06:41.123456 IP (tos 0x0, ttl 64, id 4660, offset 0, flags [DF], proto TCP (6), length 40)",
        "    142.250.80.46.80 > 192.168.1.5.52345: Flags [.], cksum 0x0000 (incorrect -> 0x2e7d), ack 2000, win 2048, length 0",
        "2026-11-18 03:06:42.123456 IP (tos 0x0, ttl 64, id 4660, offset 0, flags [DF], proto UDP (17), length 57)",
        "    192.168.1.5.53211 > 8.8.8.8.53: 4660+ A? example.com. (29)",
        "2026-11-18 03:06:43.123456 IP (tos 0x0, ttl 64, id 4660, offset 0, flags [DF], proto ICMP (1), length 32)",
        "    192.168.1.5 > 8.8.8.8: ICMP echo request, id 1, seq 0, length 12",
        "2026-11-18 03:06:44.123456 IP6 (hlim 64, next-header TCP (6) payload length: 20) 2001:db8::1.50000 > 2606:4700::1111.443: Flags [S], cksum 0x0000 (incorrect -> 0x2b4e), seq 1000, win 2048, length 0",
        "2026-11-18 03:06:45.123456 IP6 (hlim 64, next-header UDP (17) payload length: 37) fe80::1.5353 > ff02::fb.5353: [bad udp cksum 0x0000 -> 0xf5b0!] 4660+ A (QM)? example.com. (29)",
        "2026-11-18 03:06:46.123456 IP6 (hlim 64, next-header ICMPv6 (58) payload length: 12) fe80::1 > fe80::2: [bad icmp6 cksum 0x0000 -> 0xbdec!] ICMP6, echo request, id 1, seq 0",
        "2026-11-18 03:06:47.123456 ARP, Ethernet (len 6), IPv4 (len 4), Request who-has 192.168.1.1 tell 192.168.1.5, length 28",
        "2026-11-18 03:06:48.123456 ARP, Ethernet (len 6), IPv4 (len 4), Reply 192.168.1.1 is-at 11:22:33:44:55:66, length 28",
        "2026-11-18 03:06:49.123456 IP (tos 0x0, ttl 64, id 4660, offset 0, flags [DF], proto UDP (17), length 33)",
        "    10.0.0.2.40000 > 10.0.0.3.9999: UDP, length 5",
        "",
        "10 packets captured",
        "10 packets received by filter",
        "0 packets dropped by kernel",
    ]

    private func ingestAll(_ lines: [String]) -> (packets: [CapturedPacket], added: Int) {
        var packets: [CapturedPacket] = []
        var added = 0
        for line in lines where TcpdumpParser.ingest(line, into: &packets) == .packet { added += 1 }
        return (packets, added)
    }

    // MARK: - Packet Capture

    func testNumberColumnCountsAndTimeColumnShowsTimeOfDay() {
        let (packets, added) = ingestAll(plainLines)
        XCTAssertEqual(added, 10)
        XCTAssertEqual(packets.map(\.number), Array(1...10))
        XCTAssertEqual(packets[0].timestamp, "03:06:40.123456")
        XCTAssertEqual(packets[9].timestamp, "03:06:49.123456")
    }

    func testVerboseTwoLinePacketsCountOnceWithAddresses() {
        let (packets, added) = ingestAll(verboseLines)
        XCTAssertEqual(added, 10, "packet count counts packets, not lines")
        XCTAssertEqual(packets.count, 10)
        XCTAssertEqual(packets[0].source, "192.168.1.5.52344")
        XCTAssertEqual(packets[0].destination, "142.250.80.46.443")
        XCTAssertEqual(packets[0].proto, "HTTPS")
        XCTAssertTrue(packets[0].raw.contains("ttl 64"), "the detail pane keeps the -v header")
        XCTAssertTrue(packets[0].info.hasPrefix("Flags [P.]"))
        XCTAssertFalse(packets.contains { $0.source == "?" && $0.proto != "ARP" })
    }

    func testContinuationKeepsRowIdentity() {
        var packets: [CapturedPacket] = []
        TcpdumpParser.ingest(verboseLines[1], into: &packets)
        let id = packets[0].id
        XCTAssertEqual(packets[0].source, "?")
        XCTAssertEqual(TcpdumpParser.ingest(verboseLines[2], into: &packets), .continuation)
        XCTAssertEqual(packets.count, 1)
        XCTAssertEqual(packets[0].id, id)
        XCTAssertEqual(packets[0].number, 1)
        XCTAssertEqual(packets[0].source, "192.168.1.5.52344")
    }

    func testIPv6IsParsed() {
        for lines in [plainLines, verboseLines] {
            let packets = ingestAll(lines).packets
            let v6 = packets[4]
            XCTAssertEqual(v6.source, "2001:db8::1.50000")
            XCTAssertEqual(v6.destination, "2606:4700::1111.443")
            XCTAssertEqual(v6.proto, "HTTPS")
            XCTAssertEqual(packets[6].source, "fe80::1")
            XCTAssertEqual(packets[6].destination, "fe80::2")
            XCTAssertEqual(packets[6].proto, "ICMP6")
        }
    }

    func testProtocolComesFromPorts() {
        for lines in [plainLines, verboseLines] {
            let protos = ingestAll(lines).packets.map(\.proto)
            XCTAssertEqual(protos, ["HTTPS", "HTTP", "DNS", "ICMP", "HTTPS", "mDNS", "ICMP6", "ARP", "ARP", "UDP"])
        }
        XCTAssertEqual(TcpdumpParser.port(of: "192.168.1.5.52344", isV6: false), 52344)
        XCTAssertNil(TcpdumpParser.port(of: "192.168.1.5", isV6: false))
        XCTAssertEqual(TcpdumpParser.port(of: "fe80::1.443", isV6: true), 443)
        XCTAssertNil(TcpdumpParser.port(of: "fe80::1", isV6: true))
        let tcp = TcpdumpParser.parse("2026-11-18 03:06:40.123456 IP 10.0.0.1.50000 > 10.0.0.2.22: Flags [S], seq 1, win 2048, length 0", number: 1)
        XCTAssertEqual(tcp?.proto, "TCP")
    }

    func testARPRows() {
        let packets = ingestAll(plainLines).packets
        XCTAssertEqual(packets[7].source, "192.168.1.5")
        XCTAssertEqual(packets[7].destination, "broadcast")
        XCTAssertEqual(packets[8].source, "192.168.1.1")
    }

    func testTcpdumpMessagesAreClassified() {
        // Real non-root output on macOS 27
        XCTAssertEqual(TcpdumpParser.classify("tcpdump: en0: You don't have permission to capture on that device"), .failure(.permission))
        XCTAssertEqual(TcpdumpParser.classify("((cannot open BPF device) /dev/bpf0: Permission denied)"), .failure(.permission))
        XCTAssertEqual(TcpdumpParser.classify("tcpdump: ioctl(SIOCIFCREATE): Operation not permitted"), .failure(.permission))
        // Real filter errors (tcpdump -r with a bad expression)
        XCTAssertEqual(TcpdumpParser.classify("tcpdump: can't parse filter expression: syntax error"), .failure(.badFilter))
        XCTAssertEqual(TcpdumpParser.classify("tcpdump: unknown port 'abc'"), .failure(.badFilter))
        XCTAssertEqual(TcpdumpParser.classify("tcpdump: unknown host 'nosuch.invalid'"), .failure(.badFilter))
        // tcpdump's documented wording for a missing interface (as root)
        XCTAssertEqual(TcpdumpParser.classify("tcpdump: en9: No such device exists"), .failure(.noSuchInterface))
        XCTAssertEqual(TcpdumpParser.classify("(BIOCSETIF failed: Device not configured)"), .ignore)
        // Chatter and summaries are not packets
        XCTAssertEqual(TcpdumpParser.classify("tcpdump: verbose output suppressed, use -v[v]... for full protocol decode"), .ignore)
        XCTAssertEqual(TcpdumpParser.classify("listening on en0, link-type EN10MB (Ethernet), snapshot length 524288 bytes"), .ignore)
        XCTAssertEqual(TcpdumpParser.classify("1 packet captured"), .ignore)
        XCTAssertEqual(TcpdumpParser.classify("0 packets dropped by kernel"), .ignore)
        XCTAssertEqual(TcpdumpParser.classify("tcpdump: pcap_loop: The interface disappeared"), .diagnostic("pcap_loop: The interface disappeared"))
        // A decoded packet can contain the same words as tcpdump's own errors
        XCTAssertEqual(TcpdumpParser.classify("2026-11-13 15:04:05.123456 IP6 2001:db8::1.53 > 2001:db8::2.5353: 1 1/0/0 TXT \"Permission denied\" (64)"), .packet)
    }

    func testFailureMessages() {
        XCTAssertEqual(TcpdumpParser.message(for: .badFilter, filter: "tcp prot 443", interface: "en0"),
                       "tcpdump didn't understand the filter \"tcp prot 443\". Example: tcp port 443.")
        XCTAssertEqual(TcpdumpParser.message(for: .noSuchInterface, filter: "", interface: "en2"),
                       "Interface en2 doesn't exist on this Mac. Pick another one.")
    }

    func testMaxValidation() {
        XCTAssertEqual(PacketCaptureView.parseMax("500"), 500)
        XCTAssertEqual(PacketCaptureView.parseMax(" 20 "), 20)
        XCTAssertNil(PacketCaptureView.parseMax("abc"))
        XCTAssertNil(PacketCaptureView.parseMax(""))
        XCTAssertNil(PacketCaptureView.parseMax("0"))
        XCTAssertNil(PacketCaptureView.parseMax("-5"))
        XCTAssertNil(PacketCaptureView.parseMax("1.5"))
        XCTAssertNil(PacketCaptureView.parseMax("100001"))
    }

    func testInterfaceListComesFromThisMac() {
        let names = PacketCaptureView.captureInterfaces()
        XCTAssertEqual(names.last, "any")
        XCTAssertTrue(names.contains("lo0"), "every Mac has a loopback interface")
        XCTAssertEqual(Set(names).count, names.count)
    }

    // MARK: - Active Connections

    // Layout from `netstat -anv -p tcp` on macOS 27 (addresses and names
    // replaced). Process names can contain spaces and can be truncated.
    private let netstatSample = """
    Active Internet connections (including servers)
    Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)          rxbytes      txbytes  rhiwat  shiwat          process:pid    state  options           gencnt    flags   flags1 usecnt rtncnt fltrs
    tcp6       0      0  2001:db8:1:2:3:.50759  2001:db8:9::10.443     ESTABLISHED        18174      1607442  131072  180224           curl:10694  00102 00000008 0000000000077234 00000081 04000900      2      0 000000
    tcp6       0      0  2001:db8:1:2:3:.50640  2001:db8:9::10.443     ESTABLISHED        44056       260426  131072  132104    Example Helper:7515   00102 00000008 000000000007055b 00000080 04000900      2      0 000000
    tcp6       0      0  2001:db8:1:2:3:.50637  2001:db8:9::20.443     ESTABLISHED        37714         8886  131072  131072 Example Meeting :9563   00102 00000008 00000000000704dc 00000080 04000900      2      0 000000
    tcp4       0      0  *.22                   *.*                    LISTEN                 0            0  131072  131072          launchd:1    00100 00000006 0000000000000101 00000000 00000800      1      0 000000
    """

    func testNetstatProcessAndPIDComeFromProcessColumn() {
        let rows = ConnectionTableModel.parseNetstat(netstatSample)
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.map(\.process), ["curl", "Example Helper", "Example Meeting", "launchd"])
        XCTAssertEqual(rows.map(\.pid), ["10694", "7515", "9563", "1"], "not rhiwat (131072)")
        XCTAssertEqual(rows[0].state, "ESTABLISHED")
        XCTAssertEqual(rows[0].remotePort, "443")
        XCTAssertEqual(rows[3].state, "LISTEN")
        XCTAssertEqual(rows[3].localPort, "22")
    }

    func testNetstatWithoutProcessColumnLeavesThemEmpty() {
        let old = """
        Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)
        tcp4       0      0  10.0.0.5.50000         10.0.0.1.443           ESTABLISHED
        """
        let rows = ConnectionTableModel.parseNetstat(old)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].pid, "")
        XCTAssertEqual(rows[0].process, "")
    }

    func testLiveNetstatParses() async {
        // Live check on this Mac: the real header must give the process column
        let out = await Shell.run("/usr/sbin/netstat", args: ["-anv", "-p", "tcp"])
        guard out.contains("process:pid") else { return }
        let rows = ConnectionTableModel.parseNetstat(out)
        for r in rows where !r.pid.isEmpty {
            XCTAssertNotNil(Int(r.pid), "pid \(r.pid) should be numeric")
        }
        if !rows.isEmpty {
            XCTAssertTrue(rows.contains { !$0.pid.isEmpty && !$0.process.isEmpty }, "process:pid is read")
        }
    }

    // MARK: - Wi-Fi Analyzer

    private func net(_ id: String, channel: Int) -> WiFiNetwork {
        WiFiNetwork(ssid: id, bssid: id, vendor: "", rssi: -60, noise: -95, channel: channel, band: .twoGHz,
                    widthMHz: 20, security: "WPA2 (PSK)", isEnterprise: false, pmf: false, generation: "Wi-Fi 4",
                    modeString: "n", countryCode: "", beacon: 100, isConnected: false, colorIndex: 0, lastSeen: Date())
    }

    func testSpectrumTapUsesRealWidth() {
        let nets = [net("aa", channel: 1), net("bb", channel: 6), net("cc", channel: 11)]
        let range = (2400, 2475)
        for width in [400.0, 650.0, 900.0, 1400.0] as [CGFloat] {
            for n in nets {
                let x = SpectrumCanvas.x(forFreq: n.centerFreq, range: range, width: width)
                XCTAssertEqual(SpectrumCanvas.nearest(to: x, width: width, networks: nets, range: range)?.id, n.id,
                               "tapping \(n.ssid) at width \(width)")
            }
        }
    }

    func testOpenSettingsOnlyForLocationErrors() {
        XCTAssertTrue(WiFiAnalyzerModel.describe(scanError: "The operation was not authorized").needsLocation)
        XCTAssertFalse(WiFiAnalyzerModel.describe(scanError: "Wi-Fi power is off").needsLocation)
        XCTAssertFalse(WiFiAnalyzerModel.describe(scanError: "Operation not supported").needsLocation)
        XCTAssertFalse(WiFiAnalyzerModel.describe(scanError: "Something unexpected").needsLocation)
    }

    // MARK: - Network Health

    private func category(_ statuses: [HealthStatus]) -> HealthCategory {
        HealthCategory(id: "t", title: "Test", icon: "circle",
                       checks: statuses.enumerated().map { HealthCheck(label: "c\($0.offset)", detail: "", status: $0.element, result: "") })
    }

    func testOfflineDetection() {
        XCTAssertTrue(NetworkHealthModel.looksOffline(portalReached: [false, false], portsReached: [false]))
        XCTAssertFalse(NetworkHealthModel.looksOffline(portalReached: [false, true], portsReached: [false]))
        XCTAssertFalse(NetworkHealthModel.looksOffline(portalReached: [false], portsReached: [true]))
        XCTAssertFalse(NetworkHealthModel.looksOffline(portalReached: [], portsReached: []))
        XCTAssertTrue(NetworkHealthModel.isConnectivityError(URLError(.notConnectedToInternet)))
        XCTAssertTrue(NetworkHealthModel.isConnectivityError(URLError(.cannotFindHost)))
        XCTAssertFalse(NetworkHealthModel.isConnectivityError(URLError(.serverCertificateUntrusted)))
    }

    func testOfflineVerdictBeatsFiltering() {
        let v = NetworkHealthModel.verdict(for: [category([.fail, .fail]), category([.fail])], offline: true)
        XCTAssertEqual(v?.title, "Offline")
        XCTAssertEqual(v?.detail, "You appear to be offline. Connect to a network, then press Re-check.")
        XCTAssertEqual(NetworkHealthModel.verdict(for: [category([.fail])], offline: false)?.title, "Restricted")
    }

    func testNoVerdictWhileChecksPending() {
        XCTAssertNil(NetworkHealthModel.verdict(for: [category([.ok, .pending]), category([.ok])], offline: false))
        XCTAssertEqual(NetworkHealthModel.verdict(for: [category([.ok, .ok]), category([.ok])], offline: false)?.title, "Clean Network")
    }

    // MARK: - Routing Hello

    func testHSRPv2WithoutGroupStateIsNotASpeaker() {
        XCTAssertNil(parseHSRPv2(Data([0x02, 0x04, 0, 0, 0, 0]), "10.0.0.1"))
        XCTAssertNil(parseHSRPv2(Data(), "10.0.0.1"))
    }

    func testHSRPv2GroupStateIsParsed() {
        var tlv = [UInt8](repeating: 0, count: 42)
        tlv[0] = 0x01; tlv[1] = 40       // Group State TLV, 40 bytes
        tlv[4] = 16                      // Active
        tlv[6] = 0; tlv[7] = 10          // group 10
        tlv[11] = 110                    // priority
        tlv[16] = 10; tlv[17] = 0; tlv[18] = 0; tlv[19] = 1
        let sp = parseHSRPv2(Data(tlv), "10.0.0.2")
        XCTAssertEqual(sp?.group, 10)
        XCTAssertEqual(sp?.priority, 110)
        XCTAssertEqual(sp?.state, "Active")
        XCTAssertEqual(sp?.virtualIP, "10.0.0.1")
    }

    func testGroupStatesThatNeverHearAnything() {
        XCTAssertTrue(RoutingHelloModel.isDead(.failed(.posix(.EADDRINUSE))))
        XCTAssertTrue(RoutingHelloModel.isDead(.waiting(.dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied)))))
        XCTAssertFalse(RoutingHelloModel.isDead(.waiting(.posix(.ENETDOWN))))
        XCTAssertFalse(RoutingHelloModel.isDead(.ready))
    }

    func testListenFailureMessage() {
        XCTAssertEqual(RoutingHelloModel.listenFailedMessage,
                       "SNAP couldn't listen for router hellos on this network. Check that SNAP is allowed Local Network access in System Settings > Privacy & Security, then press Listen again.")
    }

    // MARK: Bandwidth latency rounds

    func testLatencyRoundStats() {
        let all = LatencyProbe.stats(times: [10, 20, 30, 40], probes: 4)
        XCTAssertEqual(all.loss, 0)
        XCTAssertEqual(all.avg, 25)
        XCTAssertEqual(all.jitter, 10)
        let half = LatencyProbe.stats(times: [10, 30], probes: 4)
        XCTAssertEqual(half.loss, 50)
        XCTAssertEqual(half.avg, 20)
        let none = LatencyProbe.stats(times: [], probes: 4)
        XCTAssertEqual(none.loss, 100)
        XCTAssertEqual(none.avg, 0)
    }

    func testLatencyProbeCountsARefusalAsAReply() {
        XCTAssertEqual(LatencyProbe.answered(.ready), true)
        XCTAssertEqual(LatencyProbe.answered(.waiting(.posix(.ECONNREFUSED))), true)
        XCTAssertEqual(LatencyProbe.answered(.failed(.posix(.ECONNREFUSED))), true)
        XCTAssertEqual(LatencyProbe.answered(.failed(.posix(.ETIMEDOUT))), false)
        XCTAssertEqual(LatencyProbe.answered(.cancelled), false)
        XCTAssertNil(LatencyProbe.answered(.preparing))
        XCTAssertNil(LatencyProbe.answered(.waiting(.posix(.ENETDOWN))))
    }

    func testLatencyProbeTimesARefusedLocalPort() {
        let local = LatencyTarget(host: "127.0.0.1", port: 1)
        XCTAssertNotNil(LatencyProbe.connectTime(to: local))
        XCTAssertEqual(LatencyProbe.firstAnswering([local]), local)
        XCTAssertNil(LatencyProbe.firstAnswering([]))
    }

    func testLatencyTargetsStartWithTheUsualOne() {
        XCTAssertEqual(LatencyTarget.all.first, LatencyTarget(host: "1.1.1.1", port: 80))
        XCTAssertEqual(Set(LatencyTarget.all.map(\.host)), ["1.1.1.1", "8.8.8.8"])
    }

    // MARK: Routing Hello: a GLBP packet without a Hello keeps the details

    private func glbpPacket(group: UInt16, hello: Bool) -> Data {
        var b: [UInt8] = [1, 0, UInt8(group >> 8), UInt8(group & 0xff), 0, 0, 1, 2, 3, 4, 5, 6]
        if hello {
            // type 1, length 20: ... state at +6 (32 = Active), priority at +7, VIP in the last 4
            var tlv = [UInt8](repeating: 0, count: 20)
            tlv[0] = 1; tlv[1] = 20; tlv[6] = 32; tlv[7] = 150
            tlv[16] = 192; tlv[17] = 0; tlv[18] = 2; tlv[19] = 1
            b += tlv
        } else {
            b += [2, 4, 0, 0]   // a Request/Response TLV
        }
        return Data(b)
    }

    func testGLBPHelloCarriesDetails() throws {
        let sp = try XCTUnwrap(parseGLBP(glbpPacket(group: 7, hello: true), "10.0.0.2"))
        XCTAssertTrue(sp.hasDetails)
        XCTAssertEqual(sp.priority, 150)
        XCTAssertEqual(sp.state, "Active")
        XCTAssertEqual(sp.virtualIP, "192.0.2.1")
    }

    func testGLBPPacketWithoutHelloKeepsTheSpeakersDetails() throws {
        let hello = try XCTUnwrap(parseGLBP(glbpPacket(group: 7, hello: true), "10.0.0.2"))
        let other = try XCTUnwrap(parseGLBP(glbpPacket(group: 7, hello: false), "10.0.0.2"))
        XCTAssertFalse(other.hasDetails)
        XCTAssertEqual(other.id, hello.id)
        let merged = RoutingSpeaker.merged(hello, with: other)
        XCTAssertEqual(merged.priority, 150)
        XCTAssertEqual(merged.state, "Active")
        XCTAssertEqual(merged.virtualIP, "192.0.2.1")
        XCTAssertEqual(merged.lastSeen, other.lastSeen)
        // A later Hello still updates them
        var newer = hello
        newer.priority = 90
        XCTAssertEqual(RoutingSpeaker.merged(merged, with: newer).priority, 90)
    }

    // MARK: Active Connections: full IPv6 addresses

    func testLinkLocalAddressMovesItsInterfaceToTheSuffix() {
        // fe80:1::1, with the interface (index 1, lo0) embedded in bytes 2-3
        var a = in6_addr()
        withUnsafeMutableBytes(of: &a) { b in
            b[0] = 0xfe; b[1] = 0x80; b[3] = 1; b[15] = 1
        }
        XCTAssertEqual(SocketTable.text(a, ifindex: 0), "fe80::1%lo0")
        var loopback = in6_addr()
        withUnsafeMutableBytes(of: &loopback) { $0[15] = 1 }
        XCTAssertEqual(SocketTable.text(loopback, ifindex: 0), "::1")
    }

    func testReadsThisProcesssIPv6Connection() throws {
        // A listener and a connection on ::1, both owned by this test
        let server = socket(AF_INET6, SOCK_STREAM, 0)
        let client = socket(AF_INET6, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(server, 0)
        defer { close(server); close(client) }
        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_addr = in6addr_loopback
        let len = socklen_t(MemoryLayout<sockaddr_in6>.size)
        try withUnsafeMutablePointer(to: &addr) { p in
            try p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                XCTAssertEqual(Darwin.bind(server, sa, len), 0)
                XCTAssertEqual(Darwin.listen(server, 1), 0)
                var bound = len
                XCTAssertEqual(getsockname(server, sa, &bound), 0)
                guard Darwin.connect(client, sa, len) == 0 else { throw XCTSkip("couldn't connect on ::1") }
            }
        }
        let port = UInt16(bigEndian: addr.sin6_port)
        let table = SocketTable.tcp6(pids: [getpid()])
        let sock = table.first { $0.remotePort == port }
        XCTAssertNotNil(sock)
        XCTAssertEqual(sock?.local, "::1")
        XCTAssertEqual(sock?.remote, "::1")
        XCTAssertTrue(SocketTable.allPIDs().contains(getpid()))
    }

    private func row(_ proto: String, local: String, remote: String, pid: String = "999999") -> Connection {
        Connection(proto: proto, localAddr: local, localPort: "1024",
                   remoteAddr: remote, remotePort: "443", state: "ESTABLISHED",
                   pid: pid, process: "x")
    }

    func testShortAddressesAreLeftAlone() {
        let out = ConnectionTableModel.fillInIPv6([row("tcp6", local: "::1", remote: "::1"),
                                                   row("tcp4", local: "192.168.100.100", remote: "10.0.0.1")])
        XCTAssertEqual(out.map(\.localAddr), ["::1", "192.168.100.100"])
        XCTAssertFalse(out.contains { $0.localCut || $0.remoteCut })
    }

    func testCutAddressWeCantReadIsMarked() {
        // pid 999999 doesn't exist, so the full address can't be read
        let out = ConnectionTableModel.fillInIPv6([row("tcp6", local: "fe80::cd18:d9fb:", remote: "::1")])
        XCTAssertEqual(out[0].localAddr, "fe80::cd18:d9fb:")
        XCTAssertTrue(out[0].localCut)
        XCTAssertFalse(out[0].remoteCut)
    }

    // MARK: Bandwidth: finding a blocked address sooner, and going back

    func testRoundGivesUpAfterTwoUnansweredProbes() {
        var calls = 0
        let r = LatencyProbe.round(giveUpAfter: 2) { calls += 1; return nil }
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(r.times.isEmpty)
        XCTAssertEqual(r.lost, 4)
    }

    func testRoundKeepsGoingOnceAProbeAnswers() {
        var calls = 0
        // lost, answered, lost, answered: a lossy link, not a blocked one
        let r = LatencyProbe.round(giveUpAfter: 2) { calls += 1; return calls % 2 == 0 ? 10 : nil }
        XCTAssertEqual(calls, 4)
        XCTAssertEqual(r.times, [10, 10])
        XCTAssertEqual(r.lost, 2)
    }

    func testBackupAddressChecksTheUsualOneEveryTwentyRounds() {
        let usual = LatencyTarget.all[0], backup = LatencyTarget.all[2]
        var asked = 0
        // Not time yet: stays, and doesn't even ask
        XCTAssertEqual(LatencyProbe.nextTarget(current: backup, round: 19) { asked += 1; return true }, backup)
        XCTAssertEqual(asked, 0)
        // Time to check, and it answers: back to the usual one
        XCTAssertEqual(LatencyProbe.nextTarget(current: backup, round: 20) { asked += 1; return true }, usual)
        // Time to check, still blocked: stays on the backup
        XCTAssertEqual(LatencyProbe.nextTarget(current: backup, round: 40) { false }, backup)
        // Already on the usual one: never asks
        XCTAssertEqual(LatencyProbe.nextTarget(current: usual, round: 20) { asked += 1; return false }, usual)
        XCTAssertEqual(asked, 1)
    }

    // MARK: Syslog: Start can't bind a second listener

    func testSyslogSecondStartWhileStartingDoesNothing() async throws {
        let model = SyslogReceiverModel()
        model.port = String(Int.random(in: 52_000...58_000))
        model.start()
        XCTAssertTrue(model.isActive)
        model.start()                       // the double click
        for _ in 0..<50 where !model.isListening {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(model.isListening)
        XCTAssertNil(model.errorMessage)    // a second bind would fail "address in use"
        model.stop()
        XCTAssertFalse(model.isActive)
        // The port is free again: a fresh start works
        model.start()
        for _ in 0..<50 where !model.isListening {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(model.isListening)
        XCTAssertNil(model.errorMessage)
        model.stop()
    }

    // MARK: Lists macOS withholds

    private let netstatHeadersOnly = """
    Active Internet connections (including servers)
    Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)          rxbytes      txbytes  rhiwat  shiwat          process:pid    state  options

    """

    func testConnectionsComeFromNetstatWhenItListsAnything() {
        let out = netstatHeadersOnly + "tcp4       0      0  192.168.1.20.53899     203.0.113.9.443        ESTABLISHED         8234         1139  131072  132432  curl:4242  00102 00000008\n"
        var askedOwn = false
        let r = ConnectionTableModel.read(netstat: out) { askedOwn = true; return [] }
        XCTAssertEqual(r.rows.count, 1)
        XCTAssertEqual(r.rows.first?.process, "curl")
        XCTAssertNil(r.note)
        XCTAssertNil(r.error)
        XCTAssertFalse(askedOwn)
    }

    func testEmptyNetstatFallsBackToSNAPsOwnRead() {
        let own = [Connection(proto: "tcp4", localAddr: "127.0.0.1", localPort: "5000", remoteAddr: "*",
                              remotePort: "*", state: "LISTEN", pid: "1", process: "x")]
        let r = ConnectionTableModel.read(netstat: netstatHeadersOnly) { own }
        XCTAssertEqual(r.rows.count, 1)
        XCTAssertEqual(r.note, WithheldLists.connectionsLimitedNote)
        XCTAssertNil(r.error)
    }

    func testNothingAnywhereSaysWhy() {
        let withheld = ConnectionTableModel.read(netstat: netstatHeadersOnly) { [] }
        XCTAssertTrue(withheld.rows.isEmpty)
        XCTAssertEqual(withheld.error, WithheldLists.connectionsMessage)
        let noNetstat = ConnectionTableModel.read(netstat: nil) { [] }
        XCTAssertEqual(noNetstat.error, "SNAP couldn't read the connection list from macOS. Click Refresh to try again.")
    }

    func testOwnReadListsThisProcesssListener() throws {
        let server = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(server, 0)
        defer { close(server) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                XCTAssertEqual(Darwin.bind(server, sa, len), 0)
                XCTAssertEqual(Darwin.listen(server, 1), 0)
                var bound = len
                XCTAssertEqual(getsockname(server, sa, &bound), 0)
            }
        }
        let port = String(UInt16(bigEndian: addr.sin_port))
        let rows = SocketTable.connections(pids: [getpid()])
        let row = try XCTUnwrap(rows.first { $0.localPort == port })
        XCTAssertEqual(row.proto, "tcp4")
        XCTAssertEqual(row.state, "LISTEN")
        XCTAssertEqual(row.localAddr, "127.0.0.1")
        XCTAssertEqual(row.remoteAddr, "*")
        XCTAssertEqual(row.remotePort, "*")
        XCTAssertEqual(row.pid, String(getpid()))
        XCTAssertFalse(row.process.isEmpty)
    }

    func testKernelStatesUseNetstatsNames() {
        XCTAssertEqual(SocketTable.stateName(1), "LISTEN")
        XCTAssertEqual(SocketTable.stateName(4), "ESTABLISHED")
        XCTAssertEqual(SocketTable.stateName(10), "TIME_WAIT")
        XCTAssertEqual(SocketTable.stateName(42), "state 42")
        XCTAssertEqual(SocketTable.text(in_addr(s_addr: 0)), "*")
        XCTAssertEqual(SocketTable.text(in_addr(s_addr: inet_addr("192.0.2.7"))), "192.0.2.7")
        XCTAssertEqual(SocketTable.text(in6_addr(), ifindex: 0), "*")
    }

    func testEmptyARPOutputIsRecognized() {
        XCTAssertTrue(WithheldLists.arpIsEmpty(""))
        XCTAssertTrue(WithheldLists.arpIsEmpty("\n"))
        XCTAssertFalse(WithheldLists.arpIsEmpty("? (192.0.2.1) at aa:bb:cc:dd:ee:ff on en0 ifscope [ethernet]\n"))
        XCTAssertFalse(WithheldLists.arpIsEmpty("? (192.0.2.9) at (incomplete) on en0 ifscope [ethernet]\n"))
    }

    // MARK: launchd stopgap

    private func leftoverJobs() async -> Int {
        let list = await Shell.run("/bin/launchctl", args: ["list"])
        return list.split(separator: "\n").filter { $0.contains("com.sevagbardakjian.snap.list.") }.count
    }

    func testLaunchdRunsOnlyTheListedCommands() async {
        let none = await Shell.runViaLaunchd("/bin/echo", args: ["hi"])
        XCTAssertNil(none)
        XCTAssertEqual(Shell.launchdCommands, ["/usr/sbin/arp", "/usr/sbin/netstat"])
    }

    func testLaunchdGetsTheARPTableAndCleansUp() async throws {
        guard RouteInfo.defaultGateway() != nil else { throw XCTSkip("not on a network") }
        let out = await Shell.runViaLaunchd("/usr/sbin/arp", args: ["-an"])
        XCTAssertNotNil(out)
        XCTAssertFalse(WithheldLists.arpIsEmpty(out ?? ""))   // at least the router
        let leftovers = await leftoverJobs()
        XCTAssertEqual(leftovers, 0)
        let merged = await WithheldLists.arp(["-an"])
        XCTAssertFalse(WithheldLists.arpIsEmpty(merged))
    }

    func testLaunchdGetsTheConnectionList() async throws {
        let maybe = await Shell.runViaLaunchd("/usr/sbin/netstat", args: ["-anv", "-p", "tcp"])
        let out = try XCTUnwrap(maybe)
        XCTAssertFalse(ConnectionTableModel.parseNetstat(out).isEmpty)
        let leftovers = await leftoverJobs()
        XCTAssertEqual(leftovers, 0)
    }
}
