// Fixes1510ToolsTests.swift
// SNAP: Tests for the 1.5.10 fixes to Wake-on-LAN, Bonjour, SSL/TLS, DNS Lookup, DNS Propagation and GeoIP
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md

import XCTest
import Network
import Security
import dnssd
@testable import SNAP

// MARK: - Wake-on-LAN

final class WakeOnLANFixesTests: XCTestCase {
    func test_macBytes_acceptsEverySeparatorStyle() {
        let expected: [UInt8] = [0x3C, 0x22, 0xFB, 0x12, 0x34, 0x56]
        for mac in ["3C:22:FB:12:34:56", "3c-22-fb-12-34-56", "3c22.fb12.3456", "3C22FB123456", " 3c:22:fb:12:34:56 "] {
            XCTAssertEqual(WakeOnLANSender.macBytes(mac), expected, mac)
        }
    }

    func test_macBytes_rejectsMalformed() {
        for mac in ["", "3C:22:FB:12:34", "3C:22:FB:12:34:56:78", "3C:22:FB:12:34:5G",
                    "3C:22-FB:12:34:56", "3C2:2FB:123:456", "3C22:FB12:3456", "hello"] {
            XCTAssertNil(WakeOnLANSender.macBytes(mac), mac)
        }
    }

    func test_normalizedMAC_isLowercaseColonForm() {
        XCTAssertEqual(WakeOnLANSender.normalizedMAC("3C22.FB12.3456"), "3c:22:fb:12:34:56")
        XCTAssertEqual(WakeOnLANSender.normalizedMAC("3C-22-FB-12-34-56"), "3c:22:fb:12:34:56")
    }

    func test_parsePort_rangeOneTo65535() {
        XCTAssertEqual(WakeOnLANSender.parsePort("9"), 9)
        XCTAssertEqual(WakeOnLANSender.parsePort("65535"), 65535)
        XCTAssertNil(WakeOnLANSender.parsePort("0"))
        XCTAssertNil(WakeOnLANSender.parsePort("65536"))
        XCTAssertNil(WakeOnLANSender.parsePort("nine"))
        XCTAssertNil(WakeOnLANSender.parsePort(""))
    }

    func test_parseIPv4_rejectsWhatInetAddrTurnedIntoBroadcast() {
        XCTAssertNotNil(WakeOnLANSender.parseIPv4("255.255.255.255"))
        XCTAssertNotNil(WakeOnLANSender.parseIPv4("192.168.1.255"))
        XCTAssertNil(WakeOnLANSender.parseIPv4("192.168.1.300"))
        XCTAssertNil(WakeOnLANSender.parseIPv4("broadcast"))
        XCTAssertNil(WakeOnLANSender.parseIPv4(""))
    }

    func test_send_reportsBadInputWithoutSending() {
        XCTAssertEqual(WakeOnLANSender.send(mac: "nope"), .invalidMAC)
        XCTAssertEqual(WakeOnLANSender.send(mac: "3C:22:FB:12:34:56", broadcastIP: "999.1.1.1"), .invalidAddress)
    }

    func test_failureMessages_distinguishBadMACFromSendFailure() {
        XCTAssertNil(WOLInput.failureMessage(for: .sent))
        XCTAssertEqual(WOLInput.failureMessage(for: .invalidMAC),
                       "That MAC address isn't valid. Use six pairs of hex digits, like 3C:22:FB:12:34:56.")
        XCTAssertEqual(WOLInput.failureMessage(for: .sendFailed),
                       "SNAP couldn't send the wake signal. Check that this Mac is connected to the same network as the device.")
        XCTAssertNotEqual(WOLInput.failureMessage(for: .invalidAddress), WOLInput.failureMessage(for: .invalidMAC))
    }

    func test_addSheetDevice_validatesAndNormalizes() throws {
        let d = try XCTUnwrap(WOLInput.device(name: " Desktop ", mac: "3C22FB123456", broadcast: "192.168.1.255", port: " 7 "))
        XCTAssertEqual(d.name, "Desktop")
        XCTAssertEqual(d.mac, "3c:22:fb:12:34:56")
        XCTAssertEqual(d.port, "7")
        XCTAssertNil(WOLInput.device(name: "", mac: "3C22FB123456", broadcast: "255.255.255.255", port: "9"))
        XCTAssertNil(WOLInput.device(name: "PC", mac: "3C22FB12345", broadcast: "255.255.255.255", port: "9"))
        XCTAssertNil(WOLInput.device(name: "PC", mac: "3C22FB123456", broadcast: "255.255.255", port: "9"))
        XCTAssertNil(WOLInput.device(name: "PC", mac: "3C22FB123456", broadcast: "255.255.255.255", port: "0"))
    }

    @MainActor
    func test_deviceStore_persistsAcrossInstances() throws {
        let suite = "com.sevagbardakjian.snap.tests.wolDevices"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = WOLDeviceStore(defaults: defaults)
        XCTAssertTrue(store.devices.isEmpty)
        let pc = WOLDevice(name: "PC", mac: "3c:22:fb:12:34:56", broadcastIP: "255.255.255.255", port: "9")
        let nas = WOLDevice(name: "NAS", mac: "00:11:32:aa:bb:cc", broadcastIP: "192.168.1.255", port: "7")
        store.add(pc)
        store.add(nas)
        let woken = Date(timeIntervalSince1970: 1_800_000_000)
        store.markWoken(pc.id, at: woken)
        XCTAssertNotNil(defaults.data(forKey: WOLDeviceStore.devicesKey))
        XCTAssertEqual(WOLDeviceStore.devicesKey, "com.sevagbardakjian.snap.wol.devices.v1")

        let reloaded = WOLDeviceStore(defaults: defaults)
        XCTAssertEqual(reloaded.devices.map(\.name), ["PC", "NAS"])
        XCTAssertEqual(reloaded.devices.first?.lastWoken, woken)

        reloaded.remove(pc.id)
        XCTAssertEqual(WOLDeviceStore(defaults: defaults).devices.map(\.name), ["NAS"])
    }
}

// MARK: - Bonjour

final class BonjourFixesTests: XCTestCase {
    func test_parseTXT_keyValueAndBooleanEntries() {
        var data = Data()
        for entry in ["txtvers=1", "model=MacBookPro18,3", "secure", "path=/a=b", ""] {
            data.append(UInt8(entry.utf8.count))
            data.append(contentsOf: Array(entry.utf8))
        }
        let txt = BonjourResolver.parseTXT(data)
        XCTAssertEqual(txt["txtvers"], "1")
        XCTAssertEqual(txt["model"], "MacBookPro18,3")
        XCTAssertEqual(txt["secure"], "")
        XCTAssertEqual(txt["path"], "/a=b")
        XCTAssertEqual(txt.count, 4)
    }

    func test_parseTXT_emptyAndTruncated() {
        XCTAssertTrue(BonjourResolver.parseTXT(Data([0])).isEmpty)
        XCTAssertTrue(BonjourResolver.parseTXT(Data([9, 0x61])).isEmpty)
    }

    func test_blockingStates_includePolicyDenied() {
        XCTAssertTrue(BonjourBrowser.isBlocking(.failed(.posix(.ENETDOWN))))
        XCTAssertTrue(BonjourBrowser.isBlocking(.waiting(.dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied)))))
        XCTAssertFalse(BonjourBrowser.isBlocking(.waiting(.posix(.ENETDOWN))))
        XCTAssertFalse(BonjourBrowser.isBlocking(.ready))
        XCTAssertFalse(BonjourBrowser.isPolicyDenied(.failed(.posix(.ENETDOWN))))
        XCTAssertTrue(BonjourBrowser.isPolicyDenied(.waiting(.dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied)))))
    }

    func test_serviceTypes_ardAndScreenSharing() {
        let defs = BonjourBrowser().serviceDefs
        XCTAssertEqual(defs.first { $0.label == "Apple Remote Desktop" }?.mdnsType, "_net-assistant._udp")
        XCTAssertEqual(defs.first { $0.label == "VNC (Screen Sharing)" }?.mdnsType, "_rfb._tcp")
        XCTAssertFalse(defs.contains { $0.mdnsType == "_remote-adb._tcp" })
    }
}

// MARK: - SSL/TLS

final class SSLCheckerFixesTests: XCTestCase {
    // Self-signed EC P-256, CN "SNAP Self Signed", O "SNAP Tests", valid to 2126
    // (made with: openssl req -new -x509 -key <prime256v1 key> -sha256 -days 36500)
    private let selfSignedDER = """
    MIIBUjCB+AIJAOovjVCiS9a3MAoGCCqGSM49BAMCMDAxGTAXBgNVBAMMEFNOQVAgU2VsZiBTaWdu
    ZWQxEzARBgNVBAoMClNOQVAgVGVzdHMwIBcNMjYxMTIwMjA1MzI0WhgPMjEyNjEwMjcyMDUzMjRa
    MDAxGTAXBgNVBAMMEFNOQVAgU2VsZiBTaWduZWQxEzARBgNVBAoMClNOQVAgVGVzdHMwWTATBgcq
    hkjOPQIBBggqhkjOPQMBBwNCAAQc9DeugPApMExuAuwqge9L9GWCsHMHToRivWEXm4TVKZsHuHL4
    EK7ilKRehxZRYS6vHJ+3OgURuL9VQW/k0nu0MAoGCCqGSM49BAMCA0kAMEYCIQDy5Xz312L+BsyF
    KBCCmJfyAfkldnWibXp128zrKqIIBgIhANt46e5FdZ2NfvY4OjToU/1Z/mjpGoICg7HKeLH5nlQX
    """

    // RSA 2048 leaf "leaf.snap.test" signed by "SNAP Test CA" (SHA-256), SAN
    // leaf.snap.test + www.snap.test, serial 0x1234ABCD, valid to 2126
    private let caSignedDER = """
    MIIC8TCCAdmgAwIBAgIEEjSrzTANBgkqhkiG9w0BAQsFADAsMRUwEwYDVQQDDAxTTkFQIFRlc3Qg
    Q0ExEzARBgNVBAoMClNOQVAgVGVzdHMwIBcNMjYxMTIwMjA1MzI0WhgPMjEyNjEwMjcyMDUzMjRa
    MBkxFzAVBgNVBAMMDmxlYWYuc25hcC50ZXN0MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKC
    AQEA4CGm2HVW6+2SCW6WEvRZmE0upiJnVr+9+A4h16l3dgGk/PJ4KyY6Hl5eBoGUAoFiaNW61NVW
    Av9JBFIgBqLhlSkMJbs0hjMGrNoivOpg2Wiag9jpPNAU8gmOQCowIXCZvoR4QSFCwvti0ELKE8L6
    b2UFibCZS5N/ts3lJ4YPL0p3AIx9gup6O1qTgqa74dOte166WfuIxYQ31f+SuQYSuKEEfpnTA1yl
    fPg2waI40iyno/jKid/U2v+IMaEDjX05FwiKTx0TmA2Y2BcH50DZkIayC9Lb80oOEXzdIpdk4+il
    yWCSd0DwyBCnTSRG7niGu0l6qTDXQ7P0+JUichalNwIDAQABoywwKjAoBgNVHREEITAfgg5sZWFm
    LnNuYXAudGVzdIINd3d3LnNuYXAudGVzdDANBgkqhkiG9w0BAQsFAAOCAQEAxjMZTXK8gxh6k7Nu
    f/MujTKx67UxVuMzI0rrXlEM/GsClwixr1fpYDoUeajdsSkhgeQPpzI+B1G5Wkf3CqLu4z6IvMlb
    3FWYSAzZEFHU6u7yTaDMRV3whykdGKijRfUZcVkcWJ7tMzUMO0Ymuj1KmK8/gKPHAUJMTmUU8ugw
    SGIooWysA0+4hRz6hEr1yz86/tJwnLZiNZjDZ9q3MNbUnnfhh8YrVHaTzdND1XooWaq1PSHmk2n9
    iBtvrR8L43D1rib7aYytRPhaWKEAbL9GJvhaZYQBtaE6lF+nxOmJNg6k0GQb/ZJjz9gED4UKVlhI
    hCylfLxNuyQfnx+HD5ilIw==
    """

    private func cert(_ base64: String) throws -> SecCertificate {
        let data = try XCTUnwrap(Data(base64Encoded: base64, options: .ignoreUnknownCharacters))
        return try XCTUnwrap(SecCertificateCreateWithData(nil, data as CFData))
    }

    func test_parse_selfSignedECCertificate() throws {
        let ci = CertParser.parse(try cert(selfSignedDER))
        XCTAssertEqual(ci.subject, "SNAP Self Signed")
        XCTAssertEqual(ci.issuer, "SNAP Self Signed (SNAP Tests)")
        XCTAssertTrue(ci.isSelfSigned)
        XCTAssertEqual(ci.signatureAlgorithm, "ECDSA with SHA-256")
        XCTAssertEqual(ci.publicKeyType, "EC 256-bit")
        XCTAssertEqual(ci.serialNumber, "00:EA:2F:8D:50:A2:4B:D6:B7")
        XCTAssertFalse(ci.isExpired)
        XCTAssertNotNil(ci.notAfter)
        XCTAssertTrue(ci.dnsNames.isEmpty)
    }

    func test_parse_caSignedRSACertificate() throws {
        let ci = CertParser.parse(try cert(caSignedDER))
        XCTAssertEqual(ci.subject, "leaf.snap.test")
        XCTAssertEqual(ci.issuer, "SNAP Test CA (SNAP Tests)")
        XCTAssertFalse(ci.isSelfSigned)
        XCTAssertEqual(ci.signatureAlgorithm, "SHA-256 with RSA")
        XCTAssertEqual(ci.publicKeyType, "RSA 2048-bit")
        XCTAssertEqual(ci.serialNumber, "12:34:AB:CD")
        // The SAN section's "Critical: No" entry is not a DNS name
        XCTAssertEqual(ci.dnsNames, ["leaf.snap.test", "www.snap.test"])
    }

    func test_parse_expiredRelativeToNow() throws {
        let far = Date(timeIntervalSince1970: 5_000_000_000)   // 2128, after notAfter
        let ci = CertParser.parse(try cert(caSignedDER), now: far)
        XCTAssertTrue(ci.isExpired)
        XCTAssertEqual(ci.daysUntilExpiry, 0)
    }

    func test_daysUntilExpiry_roundsAndNeverShowsZeroWhileValid() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day: TimeInterval = 86400
        XCTAssertEqual(CertParser.daysUntilExpiry(now.addingTimeInterval(3600), now: now), 1)
        XCTAssertEqual(CertParser.daysUntilExpiry(now.addingTimeInterval(0.6 * day), now: now), 1)
        XCTAssertEqual(CertParser.daysUntilExpiry(now.addingTimeInterval(29.4 * day), now: now), 29)
        XCTAssertEqual(CertParser.daysUntilExpiry(now.addingTimeInterval(29.6 * day), now: now), 30)
        XCTAssertEqual(CertParser.daysUntilExpiry(now, now: now), 0)
        XCTAssertEqual(CertParser.daysUntilExpiry(now.addingTimeInterval(-day), now: now), 0)
    }

    func test_signatureAlgorithmNames() {
        XCTAssertEqual(CertParser.signatureAlgorithmName(oid: "1.2.840.113549.1.1.12"), "SHA-384 with RSA")
        XCTAssertEqual(CertParser.signatureAlgorithmName(oid: "1.2.840.10045.4.3.3"), "ECDSA with SHA-384")
        XCTAssertEqual(CertParser.signatureAlgorithmName(oid: "1.2.3.4"), "1.2.3.4")
    }

    func test_tlsVersionAndCipherSuiteNames() {
        XCTAssertEqual(TLSProbe.tlsVersionName(tls_protocol_version_t.TLSv13.rawValue), "TLS 1.3")
        XCTAssertEqual(TLSProbe.tlsVersionName(tls_protocol_version_t.TLSv12.rawValue), "TLS 1.2")
        XCTAssertEqual(TLSProbe.cipherSuiteName(tls_ciphersuite_t.AES_128_GCM_SHA256.rawValue), "TLS_AES_128_GCM_SHA256")
        XCTAssertEqual(TLSProbe.cipherSuiteName(tls_ciphersuite_t.ECDHE_RSA_WITH_AES_256_GCM_SHA384.rawValue),
                       "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384")
        XCTAssertEqual(TLSProbe.cipherSuiteName(0xABCD), "0xABCD")
    }

    func test_portAndHostValidation() {
        XCTAssertEqual(TLSProbe.parsePort("443"), 443)
        XCTAssertEqual(TLSProbe.parsePort(" 8443 "), 8443)
        XCTAssertNil(TLSProbe.parsePort("0"))
        XCTAssertNil(TLSProbe.parsePort("70000"))
        XCTAssertNil(TLSProbe.parsePort("https"))
        XCTAssertTrue(TLSProbe.isBareHost("example.com"))
        XCTAssertTrue(TLSProbe.isBareHost("2001:db8::1"))
        XCTAssertFalse(TLSProbe.isBareHost("https://example.com"))
        XCTAssertFalse(TLSProbe.isBareHost("example.com/path"))
        XCTAssertFalse(TLSProbe.isBareHost("example.com:8443"))
        XCTAssertEqual(TLSProbe.unbracketed("[::1]"), "::1")
        XCTAssertTrue(TLSProbe.isBareHost(TLSProbe.unbracketed("[2001:db8::1]")))
    }

    func test_connectionErrorMessages() {
        XCTAssertEqual(TLSProbe.message(for: .posix(.ECONNREFUSED), host: "h", port: 8443),
                       "h refused the connection on port 8443. Check the port.")
        XCTAssertEqual(TLSProbe.message(for: .dns(DNSServiceErrorType(kDNSServiceErr_NoSuchRecord)), host: "nope.test", port: 443),
                       "SNAP couldn't find nope.test. Check the name.")
        XCTAssertTrue(TLSProbe.message(for: .tls(-9836), host: "h", port: 25).contains("may not use TLS"))
    }
}

// MARK: - DNS Lookup (DoH)

final class DNSLookupFixesTests: XCTestCase {
    private func bytes(_ hex: String) -> Data {
        var data = Data()
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            data.append(UInt8(hex[idx..<next], radix: 16)!)
            idx = next
        }
        return data
    }

    func test_endpoints_matchWhatEachProviderServes() {
        XCTAssertEqual(DoH.endpoint(for: "1.1.1.1"), .json("https://1.1.1.1/dns-query"))
        XCTAssertEqual(DoH.endpoint(for: "8.8.8.8"), .json("https://8.8.8.8/resolve"))
        XCTAssertEqual(DoH.endpoint(for: "9.9.9.9"), .wire(URL(string: "https://9.9.9.9/dns-query")!))
    }

    func test_reverseName_ipv4AndIPv6() {
        XCTAssertEqual(DoH.reverseName(for: "8.8.4.4"), "4.4.8.8.in-addr.arpa")
        XCTAssertEqual(DoH.reverseName(for: "192.0.2.1"), "1.2.0.192.in-addr.arpa")
        XCTAssertEqual(DoH.reverseName(for: "2001:db8::1"),
                       "1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.8.b.d.0.1.0.0.2.ip6.arpa")
        XCTAssertNil(DoH.reverseName(for: "example.com"))
        XCTAssertNil(DoH.reverseName(for: "4.4.8.8.in-addr.arpa"))
    }

    func test_wireQuery_matchesTheQueryVerifiedAgainstQuad9() {
        // Same bytes (apart from the ID) that curl POSTed to https://dns.quad9.net/dns-query
        XCTAssertEqual(DoH.wireQuery(name: "example.com", type: 1),
                       bytes("000001000001000000000000076578616d706c6503636f6d0000010001"))
        XCTAssertEqual(DoH.wireQuery(name: "example.com.", type: 1), DoH.wireQuery(name: "example.com", type: 1))
        XCTAssertNil(DoH.wireQuery(name: "a..b", type: 1))
        XCTAssertNil(DoH.wireQuery(name: String(repeating: "x", count: 64) + ".com", type: 1))
    }

    func test_parseWire_answerRecordsFromQuad9() throws {
        // Quad9's reply for example.com A (two answers plus an OPT record)
        let reply = bytes("123481800001000200000001076578616d706c6503636f6d0000010001c00c00010001000000010004ac4293f3c00c000100010000000100046814179a0000290200000000000000")
        let json = try XCTUnwrap(DoH.parseWire(reply))
        XCTAssertEqual(json["Status"] as? Int, 0)
        let answers = try XCTUnwrap(json["Answer"] as? [[String: Any]])
        XCTAssertEqual(answers.compactMap { $0["data"] as? String }, ["172.66.147.243", "104.20.23.154"])
        XCTAssertEqual(answers.first?["type"] as? Int, 1)
        XCTAssertEqual(answers.first?["TTL"] as? Int, 1)
        XCTAssertEqual(answers.first?["name"] as? String, "example.com.")
        XCTAssertNil(json["Additional"], "the OPT pseudo-record isn't data")
    }

    func test_parseWire_mxAndSOA() throws {
        let mx = try XCTUnwrap(DoH.parseWire(bytes("000081800001000100000000076578616d706c6503636f6d00000f0001c00c000f00010000012c0003000000")))
        XCTAssertEqual((mx["Answer"] as? [[String: Any]])?.first?["data"] as? String, "0 .")

        let soa = try XCTUnwrap(DoH.parseWire(bytes("0000818000010000000100000b6e78646f6d61696e2d7a7a076578616d706c6503636f6d0000010001c0180006000100000708003207656c6c696f7474026e730a636c6f7564666c617265c02003646e73c040903f7492000027100000096000093a8000000708")))
        let auth = try XCTUnwrap(soa["Authority"] as? [[String: Any]])
        XCTAssertEqual(auth.first?["type"] as? Int, 6)
        XCTAssertEqual(auth.first?["data"] as? String,
                       "elliott.ns.cloudflare.com. dns.cloudflare.com. 2420077714 10000 2400 604800 1800")
    }

    func test_parseWire_rcodeAndMalformed() {
        // NXDOMAIN header, question only
        let nx = bytes("000081830001000000000000076578616d706c6503636f6d0000010001")
        XCTAssertEqual(DoH.parseWire(nx)?["Status"] as? Int, 3)
        XCTAssertNil(DoH.parseWire(Data([0, 1, 2])))
        XCTAssertNil(DoH.parseWire(bytes("000081800001000100000000076578616d706c6503636f6d0000010001c00c0001")))
    }
}

// MARK: - DNS Propagation consensus

final class DNSPropagationFixesTests: XCTestCase {
    private func groups(_ answers: [PropagationAnswer?]) -> [(answer: PropagationAnswer, rows: [Int])] {
        PropagationConsensus.groups(Array(answers.indices)) { answers[$0] }
    }

    func test_everyResolverAgreesNameDoesNotExist_isFullConsensus() {
        let g = groups(Array(repeating: .nxdomain, count: 8))
        XCTAssertEqual(g.count, 1)
        XCTAssertEqual(g.first?.answer, .nxdomain)
        XCTAssertEqual(PropagationConsensus.percent(top: g.first?.rows.count ?? 0, of: 8), 100)
    }

    func test_everyResolverAgreesNoRecord_isFullConsensus() {
        let g = groups(Array(repeating: .records([]), count: 5))
        XCTAssertEqual(g.count, 1)
        XCTAssertEqual(g.first?.answer, .records([]))
        XCTAssertEqual(PropagationConsensus.percent(top: g.first?.rows.count ?? 0, of: 5), 100)
    }

    func test_valuesCompareRegardlessOfOrder_failuresLeftOut() {
        let g = groups([.records(["1.1.1.1", "2.2.2.2"]), .records(["2.2.2.2", "1.1.1.1"]),
                        .records(["3.3.3.3"]), nil, .nxdomain])
        XCTAssertEqual(g.count, 3)
        XCTAssertEqual(g.first?.answer, .records(["1.1.1.1", "2.2.2.2"]))
        XCTAssertEqual(g.first?.rows, [0, 1])
        XCTAssertEqual(PropagationConsensus.percent(top: 2, of: 5), 40)
    }

    func test_percentWithNothingFinished() {
        XCTAssertEqual(PropagationConsensus.percent(top: 0, of: 0), 0)
        XCTAssertTrue(groups([nil, nil]).isEmpty)
    }
}

// MARK: - GeoIP

final class GeoIPFixesTests: XCTestCase {
    private func expected(_ zone: String, _ date: Date) -> String {
        let df = DateFormatter()
        df.timeZone = TimeZone(identifier: zone)
        df.dateFormat = "MMM d, yyyy · h:mm a"
        return df.string(from: date)
    }

    func test_localTime_usesTheTargetsTimeZone() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15 08:00 UTC
        XCTAssertEqual(GeoIPViewModel.localTime(timezoneID: "Asia/Tokyo", offset: 32400, now: now), expected("Asia/Tokyo", now))
        XCTAssertEqual(GeoIPViewModel.localTime(timezoneID: "America/Los_Angeles", offset: nil, now: now),
                       expected("America/Los_Angeles", now))
        XCTAssertNotEqual(GeoIPViewModel.localTime(timezoneID: "Asia/Tokyo", offset: nil, now: now),
                          GeoIPViewModel.localTime(timezoneID: "America/Los_Angeles", offset: nil, now: now))
    }

    func test_localTime_fallsBackToOffset() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(GeoIPViewModel.localTime(timezoneID: "", offset: 32400, now: now), expected("Asia/Tokyo", now))
        XCTAssertNil(GeoIPViewModel.localTime(timezoneID: "", offset: nil, now: now))
    }
}
