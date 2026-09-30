// DeviceIdentifier.swift
// SNAP — Multi-signal LAN device identification (orchestrator)
// Created by Sevag Bardakjian
// Copyright © 2025 Sevag Bardakjian. All rights reserved.
//
// Best-effort identification of every device on the local network using:
//   • mDNS / Bonjour service announcements + TXT records  (LAN sweep — see DiscoveryProbes.swift)
//   • SSDP / UPnP M-SEARCH responses                       (LAN sweep — see DiscoveryProbes.swift)
//   • UBNT broadcast/unicast discovery                     (LAN sweep — see DiscoveryProbes.swift)
//   • NetBIOS Node Status queries (UDP/137)                (per device — see DiscoveryProbes.swift)
//   • HTTP banner grab on 80 / 443 / 8080                  (per device — this file)
//   • Reverse DNS via getnameinfo                          (per device — this file)
//   • IEEE OUI vendor lookup                               (per device — this file)
//   • Default-gateway detection via SCDynamicStore         (LAN-wide)
//   • "This Mac" detection via primary IPv4                (LAN-wide)
//
// Results are merged into a confidence-weighted DeviceIdentity (DeviceIdentity.swift).
// Each signal is retained so the UI can surface *why* a name was chosen.
//
// v1.5.1 split: identity types → DeviceIdentity.swift, discovery probes → DiscoveryProbes.swift.

import Foundation
import Network
import Darwin

// MARK: - Probes

/// Result bundle returned by the orchestrator.
struct DeviceIdentifierResult {
    /// IP → list of signals discovered for that IP.
    let perIP: [String: [IdentitySignal]]
    /// Real default-gateway IP, if any.
    let gatewayIP: String?
    /// Primary local IPv4 (the "this Mac" IP), if any.
    let selfIP: String?
}

enum DeviceIdentifier {

    /// Runs all LAN-wide probes (mDNS, SSDP, UBNT discovery) in parallel and
    /// returns when either `wallClockTimeout` elapses or every probe has
    /// settled.
    static func runLANSweep(wallClockTimeout: TimeInterval = 6) async -> DeviceIdentifierResult {
        async let mdnsTask: [String: [IdentitySignal]] = MDNSCollector.collect(timeout: wallClockTimeout)
        async let ssdpTask: [String: [IdentitySignal]] = SSDPCollector.collect(timeout: wallClockTimeout)
        async let ubntTask: [String: [IdentitySignal]] = UBNTDiscoveryProbe.collect(timeout: min(wallClockTimeout, 4.0))
        async let gw:       String?                    = defaultGateway()
        async let me:       String?                    = primaryIPv4()
        let (mdns, ssdp, ubnt, gateway, selfIP) = await (mdnsTask, ssdpTask, ubntTask, gw, me)

        var merged: [String: [IdentitySignal]] = mdns
        for (ip, signals) in ssdp {
            merged[ip, default: []].append(contentsOf: signals)
        }
        for (ip, signals) in ubnt {
            merged[ip, default: []].append(contentsOf: signals)
        }
        return DeviceIdentifierResult(perIP: merged, gatewayIP: gateway, selfIP: selfIP)
    }

    /// Per-device probes: NetBIOS + HTTP banner + reverse DNS + unicast UBNT.
    /// Each is best-effort with short timeouts; callers should expect a few
    /// seconds. The unicast UBNT probe is the catch-all for UniFi gear that
    /// didn't surface during the broadcast LAN sweep (different VLAN, filtered
    /// broadcast, etc.).
    static func probeOne(ip: String) async -> [IdentitySignal] {
        async let nb   = NetBIOSProbe.probe(ip: ip, timeout: 1.0)
        async let http = HTTPBannerProbe.probe(ip: ip, timeout: 2.0)
        async let rdns = ReverseDNSProbe.probe(ip: ip)
        async let ubnt = UBNTUnicastProbe.probe(ip: ip, timeout: 1.5)
        let (nbSig, httpSig, rdnsSig, ubntSig) = await (nb, http, rdns, ubnt)
        return [nbSig, httpSig, rdnsSig, ubntSig].compactMap { $0 }
    }

    // MARK: System taps

    static func defaultGateway() async -> String? {
        RouteInfo.defaultGateway()
    }

    static func primaryIPv4() async -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        var cur = ifaddr
        while let c = cur {
            defer { cur = c.pointee.ifa_next }
            let name = String(cString: c.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            // ifa_addr can be NULL for some pseudo-interfaces
            guard let sa = c.pointee.ifa_addr,
                  Int32(sa.pointee.sa_family) == AF_INET else { continue }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
            let ip = String(cString: buf)
            if ip == "127.0.0.1" || ip == "0.0.0.0" { continue }
            return ip
        }
        return nil
    }
}

// MARK: - Reverse DNS

enum ReverseDNSProbe {
    static func probe(ip: String) async -> IdentitySignal? {
        let hostname: String? = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo()
                hints.ai_family   = AF_INET
                hints.ai_socktype = SOCK_STREAM
                var res: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(ip, nil, &hints, &res) == 0, let r = res else {
                    cont.resume(returning: nil); return
                }
                defer { freeaddrinfo(r) }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let rc = getnameinfo(r.pointee.ai_addr, r.pointee.ai_addrlen,
                                     &host, socklen_t(host.count),
                                     nil, 0, NI_NAMEREQD)
                cont.resume(returning: rc == 0 ? String(cString: host) : nil)
            }
        }
        if let h = hostname, !h.isEmpty, h != ip { return .reverseDNS(hostname: h) }
        return nil
    }
}

// MARK: - HTTP banner

enum HTTPBannerProbe {
    private static let ports = [80, 8080, 443]

    static func probe(ip: String, timeout: TimeInterval) async -> IdentitySignal? {
        for port in ports {
            let scheme = (port == 443) ? "https" : "http"
            guard let url = URL(string: "\(scheme)://\(ip):\(port)/") else { continue }
            if let sig = await fetch(url: url, timeout: timeout) { return sig }
        }
        return nil
    }

    private static func fetch(url: URL, timeout: TimeInterval) async -> IdentitySignal? {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // Many LAN devices have self-signed certs — accept them for banner grab.
        let session = URLSession(configuration: cfg,
                                 delegate: PermissiveTLS.shared,
                                 delegateQueue: nil)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("SNAP/1.2 LAN-scan", forHTTPHeaderField: "User-Agent")

        do {
            let (data, resp) = try await session.data(for: req)
            let http = resp as? HTTPURLResponse
            let server = http?.value(forHTTPHeaderField: "Server")
            let title  = extractTitle(data)
            if server == nil && title == nil { return nil }
            return .httpBanner(server: server, title: title)
        } catch {
            return nil
        }
    }

    private static func extractTitle(_ data: Data) -> String? {
        guard let s = String(data: data.prefix(8192), encoding: .utf8) else { return nil }
        guard let openRange = s.range(of: "<title", options: .caseInsensitive),
              let gtRange = s.range(of: ">", range: openRange.upperBound..<s.endIndex),
              let closeRange = s.range(of: "</title>", options: .caseInsensitive,
                                       range: gtRange.upperBound..<s.endIndex)
        else { return nil }
        let raw = String(s[gtRange.upperBound..<closeRange.lowerBound])
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

final class PermissiveTLS: NSObject, URLSessionDelegate {
    static let shared = PermissiveTLS()
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
