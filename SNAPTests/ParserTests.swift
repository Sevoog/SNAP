// ParserTests.swift
// SNAP — Tests for pure parsing / range helpers that back several tools.
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md
//
// These cover the kind of logic most likely to silently break on an OS
// update (CLI-output parsing) or off-by-one mistakes (CIDR math, channel
// sub-band boundaries).

import XCTest
@testable import SNAP

final class ParserTests: XCTestCase {

    // MARK: - ARP cache parsing (ARP Table)

    func test_parseARP_typicalLines() {
        let raw = """
        ? (192.168.1.1) at 8c:85:90:aa:bb:cc on en0 ifscope [ethernet]
        ? (192.168.1.42) at a4:b1:97:11:22:33 on en0 ifscope [ethernet]
        ? (192.168.1.99) at (incomplete) on en0 ifscope [ethernet]
        """
        let entries = ARPTableView.parseARP(raw, gateway: "192.168.1.1")
        // The (incomplete) entry is dropped.
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first?.ip, "192.168.1.1")
        XCTAssertEqual(entries.first?.mac, "8c:85:90:aa:bb:cc")
        XCTAssertTrue(entries.first?.isGateway ?? false)
        XCTAssertEqual(entries.first?.iface, "en0")
        XCTAssertFalse(entries.last?.isGateway ?? true)
    }

    func test_parseARP_sortsByNumericIP() {
        let raw = """
        ? (192.168.1.200) at aa:aa:aa:aa:aa:aa on en0 ifscope [ethernet]
        ? (192.168.1.20) at bb:bb:bb:bb:bb:bb on en0 ifscope [ethernet]
        ? (192.168.1.100) at cc:cc:cc:cc:cc:cc on en0 ifscope [ethernet]
        """
        let ips = ARPTableView.parseARP(raw, gateway: nil).map { $0.ip }
        XCTAssertEqual(ips, ["192.168.1.20", "192.168.1.100", "192.168.1.200"])
    }

    func test_parseARP_emptyInput() {
        XCTAssertTrue(ARPTableView.parseARP("", gateway: nil).isEmpty)
    }

    // MARK: - WiFi band / channel helpers

    func test_centerFreq_24GHz() {
        XCTAssertEqual(WiFiBand.twoGHz.centerFreq(1), 2412)
        XCTAssertEqual(WiFiBand.twoGHz.centerFreq(6), 2437)
        XCTAssertEqual(WiFiBand.twoGHz.centerFreq(11), 2462)
    }

    func test_centerFreq_5and6GHz() {
        XCTAssertEqual(WiFiBand.fiveGHz.centerFreq(36), 5180)
        XCTAssertEqual(WiFiBand.fiveGHz.centerFreq(149), 5745)
        XCTAssertEqual(WiFiBand.sixGHz.centerFreq(1), 5955)
    }

    func test_subBand_5GHz_DFSboundaries() {
        XCTAssertEqual(WiFiChannelInfo.subBand(.fiveGHz, 36).0, "U-NII-1")
        XCTAssertFalse(WiFiChannelInfo.subBand(.fiveGHz, 36).1)   // not DFS
        XCTAssertEqual(WiFiChannelInfo.subBand(.fiveGHz, 52).0, "U-NII-2A")
        XCTAssertTrue(WiFiChannelInfo.subBand(.fiveGHz, 52).1)    // DFS
        XCTAssertEqual(WiFiChannelInfo.subBand(.fiveGHz, 100).0, "U-NII-2C")
        XCTAssertTrue(WiFiChannelInfo.subBand(.fiveGHz, 100).1)   // DFS
        XCTAssertEqual(WiFiChannelInfo.subBand(.fiveGHz, 149).0, "U-NII-3")
        XCTAssertFalse(WiFiChannelInfo.subBand(.fiveGHz, 149).1)  // not DFS
    }

    func test_subBand_6GHz_neverDFS() {
        XCTAssertFalse(WiFiChannelInfo.subBand(.sixGHz, 37).1)
        XCTAssertFalse(WiFiChannelInfo.subBand(.sixGHz, 200).1)
    }
}

// MARK: - iperf3 location (Speed Test)

final class IperfLocatorTests: XCTestCase {

    func test_prefersFirstInstalledCandidate() {
        let installed: Set<String> = ["/usr/local/bin/iperf3", "/usr/bin/iperf3"]
        XCTAssertEqual(IperfLocator.firstExecutable(in: IperfLocator.candidates, isExecutable: installed.contains),
                       "/usr/local/bin/iperf3")
    }

    func test_nilWhenNotInstalled() {
        XCTAssertNil(IperfLocator.firstExecutable(in: IperfLocator.candidates, isExecutable: { _ in false }))
    }

    /// The Finder-launched app's PATH misses both Homebrew prefixes.
    func test_coversBothHomebrewPrefixes() {
        XCTAssertTrue(IperfLocator.candidates.contains("/opt/homebrew/bin/iperf3"))
        XCTAssertTrue(IperfLocator.candidates.contains("/usr/local/bin/iperf3"))
    }
}

// MARK: - iPerf3 output, link speed, verdict

/// Fixtures are real iperf3 3.22 output (loopback, 3-second runs).
final class IperfOutputParserTests: XCTestCase {

    static let upload = """
    Connecting to host 127.0.0.1, port 5299
    [  4] local 127.0.0.1 port 55378 connected to 127.0.0.1 port 5299
    [ ID] Interval           Transfer     Bitrate         Retr  Cwnd
    [  4]   0.00-1.00   sec  4.74 GBytes  40.6 Gbits/sec    0   4.00 MBytes
    [  4]   1.00-2.01   sec  4.70 GBytes  40.2 Gbits/sec    0   4.00 MBytes
    [  4]   2.01-3.00   sec  4.47 GBytes  38.4 Gbits/sec    0   4.00 MBytes
    - - - - - - - - - - - - - - - - - - - - - - - - -
    [ ID] Interval           Transfer     Bitrate         Retr
    [  4]   0.00-3.00   sec  13.9 GBytes  39.8 Gbits/sec    0            sender
    [  4]   0.00-3.01   sec  13.9 GBytes  39.8 Gbits/sec                  receiver

    iperf Done.
    """

    static let download = """
    Connecting to host 127.0.0.1, port 5299
    Reverse mode, remote host 127.0.0.1 is sending
    [  4] local 127.0.0.1 port 55380 connected to 127.0.0.1 port 5299
    [ ID] Interval           Transfer     Bitrate
    [  4]   0.00-1.00   sec  4.62 GBytes  39.7 Gbits/sec                  
    [  4]   1.00-2.00   sec  4.76 GBytes  40.9 Gbits/sec                  
    [  4]   2.00-3.01   sec  4.73 GBytes  40.5 Gbits/sec                  
    - - - - - - - - - - - - - - - - - - - - - - - - -
    [ ID] Interval           Transfer     Bitrate         Retr
    [  4]   0.00-3.01   sec  14.1 GBytes  40.3 Gbits/sec    0            sender
    [  4]   0.00-3.01   sec  14.1 GBytes  40.3 Gbits/sec                  receiver

    iperf Done.
    """

    static let upload4 = """
    Connecting to host 127.0.0.1, port 5299
    [  4] local 127.0.0.1 port 55382 connected to 127.0.0.1 port 5299
    [  6] local 127.0.0.1 port 55383 connected to 127.0.0.1 port 5299
    [  8] local 127.0.0.1 port 55384 connected to 127.0.0.1 port 5299
    [ 10] local 127.0.0.1 port 55385 connected to 127.0.0.1 port 5299
    [ ID] Interval           Transfer     Bitrate         Retr  Cwnd
    [  4]   0.00-1.01   sec   703 MBytes  5.86 Gbits/sec    0   4.00 MBytes       
    [  6]   0.00-1.01   sec   702 MBytes  5.86 Gbits/sec    0   4.00 MBytes       
    [  8]   0.00-1.01   sec   701 MBytes  5.85 Gbits/sec    0   4.00 MBytes       
    [ 10]   0.00-1.01   sec   701 MBytes  5.85 Gbits/sec    0   4.00 MBytes       
    [SUM]   0.00-1.01   sec  2.74 GBytes  23.4 Gbits/sec    0             
    - - - - - - - - - - - - - - - - - - - - - - - - -
    [  4]   1.01-2.00   sec   649 MBytes  5.46 Gbits/sec    0   4.00 MBytes       
    [  6]   1.01-2.00   sec   649 MBytes  5.46 Gbits/sec    0   4.00 MBytes       
    [  8]   1.01-2.00   sec   649 MBytes  5.46 Gbits/sec    0   4.00 MBytes       
    [ 10]   1.01-2.00   sec   649 MBytes  5.46 Gbits/sec    0   4.00 MBytes       
    [SUM]   1.01-2.00   sec  2.53 GBytes  21.8 Gbits/sec    0             
    - - - - - - - - - - - - - - - - - - - - - - - - -
    [  4]   2.00-3.00   sec   662 MBytes  5.55 Gbits/sec    0   4.00 MBytes       
    [  6]   2.00-3.00   sec   662 MBytes  5.55 Gbits/sec    0   4.00 MBytes       
    [  8]   2.00-3.00   sec   662 MBytes  5.55 Gbits/sec    0   4.00 MBytes       
    [ 10]   2.00-3.00   sec   662 MBytes  5.55 Gbits/sec    0   4.00 MBytes       
    [SUM]   2.00-3.00   sec  2.59 GBytes  22.2 Gbits/sec    0             
    - - - - - - - - - - - - - - - - - - - - - - - - -
    [ ID] Interval           Transfer     Bitrate         Retr
    [  4]   0.00-3.00   sec  1.97 GBytes  5.62 Gbits/sec    0            sender
    [  4]   0.00-3.00   sec  1.97 GBytes  5.62 Gbits/sec                  receiver
    [  6]   0.00-3.00   sec  1.97 GBytes  5.62 Gbits/sec    0            sender
    [  6]   0.00-3.00   sec  1.97 GBytes  5.62 Gbits/sec                  receiver
    [  8]   0.00-3.00   sec  1.96 GBytes  5.62 Gbits/sec    0            sender
    [  8]   0.00-3.00   sec  1.96 GBytes  5.62 Gbits/sec                  receiver
    [ 10]   0.00-3.00   sec  1.96 GBytes  5.62 Gbits/sec    0            sender
    [ 10]   0.00-3.00   sec  1.96 GBytes  5.62 Gbits/sec                  receiver
    [SUM]   0.00-3.00   sec  7.86 GBytes  22.5 Gbits/sec    0             sender
    [SUM]   0.00-3.00   sec  7.86 GBytes  22.5 Gbits/sec                  receiver

    iperf Done.
    """

    static let refused = """
    iperf3: error - unable to connect to server - server may have stopped running or use a different port, firewall issue, etc.: Connection refused
    """

    func test_upload_singleStream() {
        let r = IperfOutputParser.parse(Self.upload)
        XCTAssertEqual(r.streams, 1)
        XCTAssertFalse(r.reverse)
        XCTAssertEqual(r.intervalsBps, [40.6e9, 40.2e9, 38.4e9])
        XCTAssertEqual(r.senderBps, 39.8e9)
        XCTAssertEqual(r.receiverBps, 39.8e9)
        XCTAssertEqual(r.retransmits, 0)
        XCTAssertEqual(r.transferText, "13.9 GBytes")
        XCTAssertEqual(r.transferBytes!, 13.9 * 1_073_741_824, accuracy: 1)
        XCTAssertEqual(r.seconds!, 3.01, accuracy: 0.001)
        XCTAssertNil(r.error)
    }

    /// -R lines have no Retr column; the server's retransmits are on its sender line.
    func test_download_reverseMode() {
        let r = IperfOutputParser.parse(Self.download)
        XCTAssertTrue(r.reverse)
        XCTAssertEqual(r.intervalsBps, [39.7e9, 40.9e9, 40.5e9])
        XCTAssertEqual(r.receiverBps, 40.3e9)
        XCTAssertEqual(r.retransmits, 0)
    }

    /// With -P, only the [SUM] lines count; per-stream lines would multiply the result.
    func test_multiStream_usesSumLines() {
        let r = IperfOutputParser.parse(Self.upload4)
        XCTAssertEqual(r.streams, 4)
        XCTAssertEqual(r.intervalsBps, [23.4e9, 21.8e9, 22.2e9])
        XCTAssertEqual(r.receiverBps, 22.5e9)
        XCTAssertEqual(r.retransmits, 0)
        XCTAssertEqual(r.transferText, "7.86 GBytes")
    }

    func test_error() {
        let r = IperfOutputParser.parse(Self.refused)
        XCTAssertNil(r.receiverBps)
        XCTAssertTrue(r.error?.hasPrefix("unable to connect to server") == true)
        XCTAssertNil(IperfAdvisor.verdict(for: r, link: nil, streams: 1))
    }

    /// Mid-test output: intervals so far, no totals yet.
    func test_partialOutput() {
        let partial = Self.upload.components(separatedBy: "\n").prefix(5).joined(separator: "\n")
        let r = IperfOutputParser.parse(partial)
        XCTAssertEqual(r.intervalsBps, [40.6e9, 40.2e9])
        XCTAssertNil(r.receiverBps)
        XCTAssertNil(r.retransmits)
        XCTAssertNil(IperfAdvisor.verdict(for: r, link: nil, streams: 1))
    }

    func test_megabitsAndRetransmits() {
        let out = """
        [  5]   0.00-1.00   sec   112 MBytes   941 Mbits/sec   12    1.02 MBytes
        [  5]   0.00-10.00  sec  1.09 GBytes   936 Mbits/sec   57             sender
        [  5]   0.00-10.00  sec  1.09 GBytes   934 Mbits/sec                  receiver
        """
        let r = IperfOutputParser.parse(out)
        XCTAssertEqual(r.intervalsBps, [941e6])
        XCTAssertEqual(r.receiverBps, 934e6)
        XCTAssertEqual(r.retransmits, 57)
    }
}

final class IperfLinkProbeTests: XCTestCase {

    func test_interfaceFromRoute() {
        let route = """
           route to: 192.168.1.20
        destination: 192.168.1.0
               mask: 255.255.255.0
          interface: en8
              flags: <UP,DONE,CLONING>
        """
        XCTAssertEqual(IperfLinkProbe.interface(fromRoute: route), "en8")
        XCTAssertNil(IperfLinkProbe.interface(fromRoute: "route: writing to routing socket: not in table"))
    }

    func test_ethernetSpeedFromMediaLine() {
        func speed(_ media: String) -> Double? {
            IperfLinkProbe.ethernetSpeed(fromIfconfig: "en8: flags=8863<UP> mtu 1500\n\tmedia: \(media)\n\tstatus: active")?.mbps
        }
        XCTAssertEqual(speed("autoselect (10Gbase-T <full-duplex>)"), 10_000)
        XCTAssertEqual(speed("autoselect (1000baseT <full-duplex,flow-control,energy-efficient-ethernet>)"), 1000)
        XCTAssertEqual(speed("autoselect (2500Base-T <full-duplex>)"), 2500)
        XCTAssertEqual(speed("autoselect (100baseTX <full-duplex>)"), 100)
        XCTAssertNil(speed("autoselect (none)"))
        XCTAssertNil(speed("autoselect"))
        XCTAssertEqual(IperfLinkProbe.ethernetSpeed(fromIfconfig: "\tmedia: autoselect (10Gbase-T <full-duplex>)")?.media, "10Gbase-T")
    }
}

final class IperfAdvisorTests: XCTestCase {

    private func result(_ bps: Double, retransmits: Int? = 0, intervals: [Double]? = nil) -> IperfResult {
        IperfResult(intervalsBps: intervals ?? [bps, bps], senderBps: bps, receiverBps: bps, retransmits: retransmits)
    }
    private let tenGig = IperfLink(interface: "en8", kind: .ethernet, speedMbps: 10_000, media: "10Gbase-T")

    func test_formatting() {
        XCTAssertEqual(IperfAdvisor.rate(9.39e9), "9.39 Gbps")
        XCTAssertEqual(IperfAdvisor.rate(941e6), "941 Mbps")
        XCTAssertEqual(IperfAdvisor.rate(85.2e6), "85.2 Mbps")
        XCTAssertEqual(IperfAdvisor.rate(512e3), "512 Kbps")
        XCTAssertEqual(IperfAdvisor.linkRate(10_000), "10 Gbps")
        XCTAssertEqual(IperfAdvisor.linkRate(2500), "2.5 Gbps")
        XCTAssertEqual(IperfAdvisor.linkRate(1000), "1 Gbps")
        XCTAssertEqual(IperfAdvisor.linkRate(866), "866 Mbps")
        XCTAssertEqual(IperfAdvisor.bytes(14.9e9), "14.9 GB")
        XCTAssertEqual(IperfAdvisor.bytes(1.17e9), "1.17 GB")
        XCTAssertEqual(IperfAdvisor.bytes(512e6), "512 MB")
    }

    func test_steadiness() {
        let s = IperfAdvisor.steadiness([90e6, 110e6])
        XCTAssertEqual(s?.plusMinusPct ?? 0, 10, accuracy: 0.001)
        XCTAssertNil(IperfAdvisor.steadiness([100e6]))
    }

    func test_ethernet_atLineRate() {
        let v = IperfAdvisor.verdict(for: result(9.4e9), link: tenGig, streams: 1)
        XCTAssertEqual(v?.headline, "About as fast as a 10 Gbps link gets")
        XCTAssertEqual(v?.notes, [])
    }

    /// A 10 Gbps Mac talking to a 1 Gbps machine stops just under 1 Gbps.
    func test_ethernet_cappedBySlowerHop() {
        XCTAssertEqual(IperfAdvisor.verdict(for: result(941e6), link: tenGig, streams: 1)?.headline, "Capped near 1 Gbps")
        XCTAssertEqual(IperfAdvisor.verdict(for: result(2.35e9), link: tenGig, streams: 1)?.headline, "Capped near 2.5 Gbps")
        let fastE = IperfLink(interface: "en8", kind: .ethernet, speedMbps: 1000)
        XCTAssertEqual(IperfAdvisor.verdict(for: result(94e6), link: fastE, streams: 1)?.headline, "Capped near 100 Mbps")
    }

    func test_ethernet_belowLink_suggestsStreamsOnlyForOne() {
        let one = IperfAdvisor.verdict(for: result(4e9), link: tenGig, streams: 1)
        XCTAssertEqual(one?.headline, "Below what this Mac's link can do")
        XCTAssertTrue(one?.detail.contains("try 4 streams") == true)
        XCTAssertFalse(IperfAdvisor.verdict(for: result(4e9), link: tenGig, streams: 4)?.detail.contains("streams") == true)
    }

    func test_wifi() {
        let wifi = IperfLink(interface: "en0", kind: .wifi, speedMbps: 866)
        XCTAssertEqual(IperfAdvisor.verdict(for: result(500e6), link: wifi, streams: 1)?.headline, "Typical for this Wi-Fi connection")
        XCTAssertEqual(IperfAdvisor.verdict(for: result(100e6), link: wifi, streams: 1)?.headline, "Slower than this Wi-Fi connection usually allows")
        let noRate = IperfLink(interface: "en0", kind: .wifi)
        XCTAssertEqual(IperfAdvisor.verdict(for: result(100e6), link: noRate, streams: 1)?.headline, "100 Mbps over Wi-Fi")
    }

    /// Above the reported link: traffic stayed on this Mac, or Wi-Fi sped up after the rate was read.
    func test_fasterThanLink() {
        XCTAssertEqual(IperfAdvisor.verdict(for: result(22e9), link: tenGig, streams: 1)?.headline, "Faster than this Mac's link")
        let wifi = IperfLink(interface: "en0", kind: .wifi, speedMbps: 144)
        XCTAssertEqual(IperfAdvisor.verdict(for: result(400e6), link: wifi, streams: 1)?.headline, "400 Mbps over Wi-Fi")
    }

    func test_loopbackAndUnknown() {
        let lo = IperfLink(interface: "lo0", kind: .loopback)
        XCTAssertEqual(IperfAdvisor.verdict(for: result(40e9), link: lo, streams: 1)?.headline, "This tested your Mac against itself")
        XCTAssertEqual(IperfAdvisor.verdict(for: result(941e6), link: nil, streams: 1)?.headline, "941 Mbps measured")
    }

    func test_notes() {
        let v = IperfAdvisor.verdict(for: result(9.4e9, retransmits: 12, intervals: [9.9e9, 6e9, 9.9e9]),
                                     link: tenGig, streams: 1)
        XCTAssertEqual(v?.notes.count, 2)
        XCTAssertTrue(v?.notes.first?.hasPrefix("12 retransmits:") == true)
        XCTAssertTrue(v?.notes.last?.hasPrefix("Speed swung between 6.00 Gbps and 9.90 Gbps") == true)
        let one = IperfAdvisor.verdict(for: result(9.4e9, retransmits: 1), link: tenGig, streams: 1)
        XCTAssertTrue(one?.notes.first?.hasPrefix("1 retransmit:") == true)
    }
}

final class IperfHistoryStoreTests: XCTestCase {
    private let key = "snap_iperf_history_tests"
    override func tearDown() { UserDefaults.standard.removeObject(forKey: key) }

    func test_newestFirst_cappedAt100_persisted() {
        let store = IperfHistoryStore(key: key)
        store.clear()
        for i in 0..<105 {
            store.add(IperfHistoryEntry(date: Date(timeIntervalSince1970: Double(i)), server: "10.0.0.2", port: "5201",
                                        direction: .upload, streams: 1, seconds: 10, receiverBps: Double(i)))
        }
        XCTAssertEqual(store.entries.count, 100)
        XCTAssertEqual(store.entries.first?.receiverBps, 104)
        XCTAssertEqual(IperfHistoryStore(key: key).entries, store.entries)
        store.clear()
        XCTAssertTrue(IperfHistoryStore(key: key).entries.isEmpty)
    }
}
