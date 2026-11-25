// Fixes1510DashboardTests.swift
// SNAP: Tests for the 1.5.10 fixes to the Dashboard cards, Connection Summary, UniFi and SNMP
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md
//
// 1.5.10 fixes: the Dashboard cards (Wi-Fi labels, Ping and Traceroute
// summaries, lookup failures), the Connection Summary header, UniFi error
// text, and SNMP Remember when the Keychain refuses the write. The SNMP
// tests use an in-memory secret store and a test UserDefaults suite, never
// the real Keychain or preferences.

import XCTest
import CoreWLAN
@testable import SNAP

/// Stands in for the Keychain.
private final class MemorySecrets: SNMPSecretStore {
    var items: [String: String] = [:]
    var failWrites = false

    func read(account: String) -> SNMPSecretLookup {
        items[account].map { .found($0) } ?? .missing
    }

    func write(account: String, secret: String) -> Bool {
        items[account] = nil
        guard !failWrites else { return false }
        items[account] = secret
        return true
    }

    func delete(account: String) { items[account] = nil }
}

final class Fixes1510DashboardTests: XCTestCase {

    // MARK: - Wi-Fi card

    func testChannelWidthMapsEnumCasesNotRawIndexes() {
        // CWChannelWidth raw values: 0 unknown, 1 = 20, 2 = 40, 3 = 80, 4 = 160.
        XCTAssertNil(WiFiDashText.widthLabel(CWChannelWidth(rawValue: 0)!))
        XCTAssertEqual(WiFiDashText.widthLabel(CWChannelWidth(rawValue: 1)!), "20 MHz")
        XCTAssertEqual(WiFiDashText.widthLabel(CWChannelWidth(rawValue: 2)!), "40 MHz")
        XCTAssertEqual(WiFiDashText.widthLabel(CWChannelWidth(rawValue: 3)!), "80 MHz")
        XCTAssertEqual(WiFiDashText.widthLabel(CWChannelWidth(rawValue: 4)!), "160 MHz")
    }

    func testBandLabels() {
        XCTAssertEqual(WiFiDashText.bandLabel(.band2GHz, width: .width20MHz), "2.4 GHz · 20 MHz")
        XCTAssertEqual(WiFiDashText.bandLabel(.band5GHz, width: .width80MHz), "5 GHz · 80 MHz")
        XCTAssertEqual(WiFiDashText.bandLabel(.band6GHz, width: .width160MHz), "6 GHz · 160 MHz")
        // An unknown band is no longer called 6 GHz.
        XCTAssertEqual(WiFiDashText.bandLabel(.bandUnknown, width: .width40MHz), "40 MHz")
        XCTAssertEqual(WiFiDashText.bandLabel(.band5GHz, width: .widthUnknown), "5 GHz")
        XCTAssertEqual(WiFiDashText.bandLabel(.bandUnknown, width: .widthUnknown), "Wi-Fi")
    }

    func testWiFiNameStates() {
        XCTAssertEqual(WiFiDashText.name(powerOn: false, ssid: nil, associated: false, locationAllowed: true), "Wi-Fi off")
        XCTAssertEqual(WiFiDashText.name(powerOn: true, ssid: "Home", associated: true, locationAllowed: true), "Home")
        XCTAssertEqual(WiFiDashText.name(powerOn: true, ssid: nil, associated: false, locationAllowed: true), "Not connected")
        XCTAssertEqual(WiFiDashText.name(powerOn: true, ssid: nil, associated: true, locationAllowed: false),
                       "Allow Location access to see the network name")
        XCTAssertEqual(WiFiDashText.name(powerOn: true, ssid: "", associated: true, locationAllowed: true), "Hidden network")
    }

    // MARK: - Ping card

    func testPingUnknownHost() {
        let out = "ping: cannot resolve nosuchhost.invalid: Unknown host\n"
        XCTAssertEqual(PingDashSummary.text(host: "nosuchhost.invalid", output: out, stopped: false),
                       "Couldn't find nosuchhost.invalid. Check the spelling.")
        XCTAssertTrue(PingDashSummary.text(host: "::1", output: "ping: cannot resolve ::1: Unknown host\n",
                                           stopped: false).contains("IPv6"))
    }

    func testPingAllTimeoutsHasNoAverage() {
        // macOS ping prints no "Request timeout" line for the last packet.
        let out = """
        PING 10.255.255.1 (10.255.255.1): 56 data bytes
        Request timeout for icmp_seq 0
        Request timeout for icmp_seq 1

        --- 10.255.255.1 ping statistics ---
        3 packets transmitted, 0 packets received, 100.0% packet loss

        """
        let text = PingDashSummary.text(host: "10.255.255.1", output: out, stopped: false)
        XCTAssertEqual(text, "No replies from 10.255.255.1.")
        XCTAssertFalse(text.contains("avg"))
        XCTAssertEqual(PingDashSummary.counts(out)?.sent, 3)
        XCTAssertEqual(PingDashSummary.counts(out)?.received, 0)
    }

    /// The card's reply list comes from the full output, in order.
    func testPingSamplesComeFromTheFullOutput() {
        let out = """
        PING 1.1.1.1 (1.1.1.1): 56 data bytes
        64 bytes from 1.1.1.1: icmp_seq=0 ttl=54 time=10.000 ms
        Request timeout for icmp_seq 1
        64 bytes from 1.1.1.1: icmp_seq=2 ttl=54 time=20.000 ms

        --- 1.1.1.1 ping statistics ---
        3 packets transmitted, 2 packets received, 33.3% packet loss
        """
        XCTAssertEqual(PingDashSummary.samples(out), [10, nil, 20])
    }

    func testPingCountsTheLastTimeoutFromStatistics() {
        let out = """
        PING 1.1.1.1 (1.1.1.1): 56 data bytes
        64 bytes from 1.1.1.1: icmp_seq=0 ttl=54 time=10.000 ms
        64 bytes from 1.1.1.1: icmp_seq=1 ttl=54 time=20.000 ms
        Request timeout for icmp_seq 2

        --- 1.1.1.1 ping statistics ---
        4 packets transmitted, 2 packets received, 50.0% packet loss
        round-trip min/avg/max/stddev = 10.000/15.000/20.000/5.000 ms

        """
        XCTAssertEqual(PingDashSummary.text(host: "1.1.1.1", output: out, stopped: false),
                       "sent 4  recv 2  loss 50%  avg 15.0 ms")
    }

    func testPingStoppedBeforeAnyPacket() {
        XCTAssertEqual(PingDashSummary.text(host: "1.1.1.1", output: "PING 1.1.1.1 (1.1.1.1): 56 data bytes\n",
                                            stopped: true), "Stopped.")
    }

    // MARK: - Traceroute card

    func testTracerouteUnknownHost() {
        XCTAssertTrue(TracerouteDashText.isUnknownHost("traceroute: unknown host nosuchhost.invalid"))
        XCTAssertFalse(TracerouteDashText.isUnknownHost("traceroute to github.com (140.82.113.3), 12 hops max"))
        XCTAssertEqual(TracerouteDashText.notFoundText(host: "nosuchhost.invalid"),
                       "Couldn't find nosuchhost.invalid. Check the spelling.")
    }

    func testTracerouteKeepsTheDestinationVisible() {
        let short = (1...5).map { "\($0)  10.0.0.\($0)" }
        XCTAssertEqual(TracerouteDashText.visibleHops(short), short)

        let long = (1...12).map { "\($0)  10.0.0.\($0)" }
        let shown = TracerouteDashText.visibleHops(long)
        XCTAssertEqual(shown.count, 6)
        XCTAssertEqual(shown.first, long.first)
        XCTAssertEqual(shown.last, long.last)
        XCTAssertEqual(shown[2], "\u{2026} 7 more hops")
    }

    // MARK: - Lookup and Port Scan cards

    func testLookupFailureText() {
        XCTAssertEqual(DashLookup.lookupText(host: "ipv6.example", type: "A", failure: nil),
                       "ipv6.example has no A records.")
        XCTAssertEqual(DashLookup.lookupText(host: "exmaple.com", type: "A", failure: .notFound),
                       "Couldn't find exmaple.com. Check the spelling.")
        XCTAssertTrue(DashLookup.lookupText(host: "example.com", type: "AAAA", failure: .offline)
                        .hasPrefix("Couldn't look up example.com."))
        XCTAssertEqual(DashLookup.portScanText(host: "nas.lan", failure: .notFound), "Couldn't find nas.lan.")
    }

    func testLookupFailureKind() {
        XCTAssertEqual(DashLookup.failure(code: EAI_NONAME, offline: false), .notFound)
        XCTAssertEqual(DashLookup.failure(code: EAI_NONAME, offline: true), .offline)
        XCTAssertEqual(DashLookup.failure(code: EAI_AGAIN, offline: false), .offline)
    }

    func testResolveNonexistentName() {
        // .invalid never resolves (RFC 2606), with or without a network.
        let r = DashLookup.resolve("nosuchhost.invalid", family: AF_UNSPEC)
        XCTAssertTrue(r.addresses.isEmpty)
        XCTAssertNotEqual(r.code, 0)
        XCTAssertEqual(DashLookup.resolve("127.0.0.1", family: AF_INET).addresses, ["127.0.0.1"])
    }

    // MARK: - Connection Summary header

    func testHeaderDoesNotRepeatTheInterfaceLine() {
        let eth = ConnectionSummary.headerText(ssid: nil, onWiFi: false,
                                               display: "Connected via Ethernet (en7)", needsLocation: false)
        XCTAssertEqual(eth.title, "Connected via Ethernet (en7)")
        XCTAssertNil(eth.subtitle)

        let named = ConnectionSummary.headerText(ssid: "Home", onWiFi: true,
                                                 display: "Connected via Wi-Fi (en0)", needsLocation: false)
        XCTAssertEqual(named.title, "Home")
        XCTAssertEqual(named.subtitle, "Connected via Wi-Fi (en0)")

        let noName = ConnectionSummary.headerText(ssid: nil, onWiFi: true,
                                                  display: "Connected via Wi-Fi (en0)", needsLocation: true)
        XCTAssertEqual(noName.title, "Wi-Fi")
        XCTAssertEqual(noName.subtitle, "Connected via Wi-Fi (en0). Allow Location access to see the network name.")
    }

    // MARK: - UniFi

    func testUniFiURLErrorsArePlainText() {
        let host = "https://192.168.1.1:8443"
        let timedOut = UniFiControllerModel.errorText(URLError(.timedOut), controller: host)
        XCTAssertEqual(timedOut, "Couldn't reach the controller at 192.168.1.1:8443. Check the address and that this Mac can reach it, then Connect again.")
        XCTAssertFalse(timedOut.contains("NSURLErrorDomain"))
        XCTAssertEqual(UniFiControllerModel.errorText(URLError(.cannotConnectToHost), controller: host), timedOut)
        XCTAssertTrue(UniFiControllerModel.errorText(URLError(.cannotFindHost), controller: "https://unifi.lan")
                        .hasPrefix("Couldn't find unifi.lan."))
        XCTAssertTrue(UniFiControllerModel.errorText(URLError(.notConnectedToInternet), controller: host)
                        .hasPrefix("This Mac isn't connected to a network."))
        XCTAssertTrue(UniFiControllerModel.errorText(URLError(.secureConnectionFailed), controller: host)
                        .hasPrefix("Couldn't set up a secure connection to 192.168.1.1:8443."))
    }

    func testUniFiClientErrorsKeepTheirWording() {
        let e = UniFiClient.ClientError.twoFactorRequired
        XCTAssertEqual(UniFiControllerModel.errorText(e, controller: "https://192.168.1.1"), e.description)
    }

    // MARK: - SNMP Remember

    private let suiteName = "com.sevagbardakjian.snap.tests.Fixes1510DashboardTests"

    private func withTestStore(_ body: (MemorySecrets, UserDefaults) throws -> Void) rethrows {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let secrets = MemorySecrets()
        let live = SNMPCommunityStore.backend
        SNMPCommunityStore.backend = .init(secrets: secrets, defaults: defaults, indexKey: "test.snmp.remembered")
        defer {
            SNMPCommunityStore.backend = live
            defaults.removePersistentDomain(forName: suiteName)
        }
        try body(secrets, defaults)
    }

    func testSaveReportsAFailedKeychainWrite() {
        withTestStore { secrets, _ in
            XCTAssertTrue(SNMPCommunityStore.save(host: "10.0.0.2", port: 161, community: "c"))
            secrets.failWrites = true
            XCTAssertFalse(SNMPCommunityStore.save(host: "10.0.0.2", port: 161, community: "rotated"))
            XCTAssertFalse(SNMPCommunityStore.hasSaved(host: "10.0.0.2", port: 161))
        }
    }

    /// The Status Board's copy reports a refused write too, and leaves no
    /// copy behind for the tile to trip over.
    func testBoardSaveReportsAFailedKeychainWrite() {
        withTestStore { secrets, _ in
            XCTAssertTrue(SNMPCommunityStore.saveForBoard(community: "c", host: "10.0.0.2", port: 161))
            secrets.failWrites = true
            XCTAssertFalse(SNMPCommunityStore.saveForBoard(community: "rotated", host: "10.0.0.2", port: 161))
            XCTAssertFalse(SNMPCommunityStore.hasBoardCopy(host: "10.0.0.2", port: 161))
        }
    }

    @MainActor
    func testRememberUnticksAndSaysSoWhenTheKeychainRefuses() {
        withTestStore { secrets, _ in
            secrets.failWrites = true
            let model = SNMPQueryModel()
            model.host = "10.0.0.2"
            model.port = "161"
            model.community = "s3cret"
            model.rememberCommunity = true
            model.rememberIfTicked(host: "10.0.0.2", port: 161, community: "s3cret")
            XCTAssertFalse(model.rememberCommunity)
            XCTAssertEqual(model.saveError, "Couldn't save the community string in your Keychain.")
            XCTAssertFalse(model.saveError?.contains("s3cret") ?? true)

            // A click on Remember clears the notice.
            model.userSetRemember(true)
            XCTAssertNil(model.saveError)
        }
    }

    @MainActor
    func testRememberSavesWhenTheKeychainAccepts() {
        withTestStore { secrets, _ in
            let model = SNMPQueryModel()
            model.host = "10.0.0.2"
            model.port = "161"
            model.rememberCommunity = true
            model.rememberIfTicked(host: "10.0.0.2", port: 161, community: "s3cret")
            XCTAssertTrue(model.rememberCommunity)
            XCTAssertNil(model.saveError)
            XCTAssertEqual(secrets.items["10.0.0.2:161"], "s3cret")
        }
    }

    // MARK: UniFi: Refresh keeps adopted devices first

    private func unifi(_ name: String, adopted: Bool) -> UniFiDevice {
        UniFiDevice(id: name, mac: name, name: name, model: "", modelDescription: nil, ip: "",
                    type: "uap", role: .unknown, firmware: "", adopted: adopted,
                    stateLabel: "", uptime: 0, lastSeen: nil, satelliteParent: nil)
    }

    func testUniFiDevicesSortAdoptedFirstThenByName() {
        let sorted = UniFiDevice.sortedForDisplay([
            unifi("alpha", adopted: false), unifi("Zulu", adopted: true),
            unifi("bravo", adopted: true), unifi("Charlie", adopted: false),
        ])
        XCTAssertEqual(sorted.map(\.name), ["bravo", "Zulu", "alpha", "Charlie"])
    }
}
