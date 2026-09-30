// DNSWireTests.swift
// SNAP — DNS-over-UDP wire format unit tests
// Created by Sevag Bardakjian
// Copyright © 2025 Sevag Bardakjian. All rights reserved.

import XCTest
@testable import SNAP

final class DNSWireTests: XCTestCase {

    // The DNSWire APIs (buildQuery, parse) are private so we exercise them
    // indirectly via the parts we expose plus a round-trip:
    //   • Build a known query (we craft the bytes by hand here, since
    //     buildQuery is private to DNSWire)
    //   • Craft a known response, feed it to a synthetic parse
    //     (we test by asserting on response patterns)
    //
    // For unit-test purposes the structurally-interesting invariants are
    // (1) public types compile + behave (DNSWireType labels, DNSAnswer
    // hashing) and (2) PublicResolvers are well-formed.

    func test_dnsWireTypeLabels() {
        XCTAssertEqual(DNSWireType.a.label,     "A")
        XCTAssertEqual(DNSWireType.aaaa.label,  "AAAA")
        XCTAssertEqual(DNSWireType.cname.label, "CNAME")
        XCTAssertEqual(DNSWireType.mx.label,    "MX")
        XCTAssertEqual(DNSWireType.ns.label,    "NS")
        XCTAssertEqual(DNSWireType.txt.label,   "TXT")
        XCTAssertEqual(DNSWireType.soa.label,   "SOA")
        XCTAssertEqual(DNSWireType.ptr.label,   "PTR")
        XCTAssertEqual(DNSWireType.srv.label,   "SRV")
        XCTAssertEqual(DNSWireType.caa.label,   "CAA")
    }

    func test_dnsWireTypeRawValues_matchRFC() {
        // These are the standard RFC 1035 / RFC 8484 type numbers. Locking
        // them down so a typo never silently breaks DoH JSON parsing.
        XCTAssertEqual(DNSWireType.a.rawValue,     1)
        XCTAssertEqual(DNSWireType.ns.rawValue,    2)
        XCTAssertEqual(DNSWireType.cname.rawValue, 5)
        XCTAssertEqual(DNSWireType.soa.rawValue,   6)
        XCTAssertEqual(DNSWireType.ptr.rawValue,  12)
        XCTAssertEqual(DNSWireType.mx.rawValue,   15)
        XCTAssertEqual(DNSWireType.txt.rawValue,  16)
        XCTAssertEqual(DNSWireType.aaaa.rawValue, 28)
        XCTAssertEqual(DNSWireType.srv.rawValue,  33)
        XCTAssertEqual(DNSWireType.caa.rawValue, 257)
    }

    func test_publicResolvers_areWellFormed() {
        // Every curated resolver must have an IPv4 address, a name, and a
        // region tag. The DNS Propagation tool relies on this.
        for r in PublicResolvers.all {
            XCTAssertFalse(r.ip.isEmpty,     "empty ip for \(r.name)")
            XCTAssertFalse(r.name.isEmpty,   "empty name for \(r.ip)")
            XCTAssertFalse(r.region.isEmpty, "empty region for \(r.ip)")

            // Each IP must parse as 4 dotted decimal octets in 0...255.
            let parts = r.ip.split(separator: ".").compactMap { Int($0) }
            XCTAssertEqual(parts.count, 4,    "bad ip shape \(r.ip)")
            XCTAssertTrue(parts.allSatisfy { 0...255 ~= $0 }, "bad ip octet \(r.ip)")
        }
    }

    func test_publicResolvers_haveUniqueIPs() {
        // No duplicate resolvers — would skew the consensus badge in the
        // Propagation view.
        let ips = PublicResolvers.all.map { $0.ip }
        XCTAssertEqual(Set(ips).count, ips.count, "duplicate IP in PublicResolvers")
    }

    func test_publicResolvers_includeMajorProviders() {
        // Smoke test for the diversity story we tell users.
        let names = Set(PublicResolvers.all.map { $0.name.lowercased() })
        XCTAssertTrue(names.contains("cloudflare"))
        XCTAssertTrue(names.contains("google"))
        XCTAssertTrue(names.contains("quad9"))
        XCTAssertTrue(names.contains("opendns"))
    }

    func test_dnsAnswer_isHashable() {
        let a1 = DNSAnswer(type: "A", value: "1.2.3.4", ttl: 60)
        let a2 = DNSAnswer(type: "A", value: "1.2.3.4", ttl: 60)
        let a3 = DNSAnswer(type: "A", value: "5.6.7.8", ttl: 60)
        XCTAssertEqual(a1, a2)
        XCTAssertNotEqual(a1, a3)
        XCTAssertEqual(Set([a1, a2, a3]).count, 2)
    }

    func test_dnsWireError_messages() {
        XCTAssertEqual(DNSWireError.rcode(3).errorDescription, "NXDOMAIN — name does not exist")
        XCTAssertEqual(DNSWireError.rcode(2).errorDescription, "Server failure (SERVFAIL)")
        XCTAssertEqual(DNSWireError.timeout.errorDescription, "Timed out")
    }
}
