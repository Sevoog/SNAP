// ConnectionSummaryCard.swift
// SNAP — Network Info "at a glance" hero card (v1.2.4 PoC)
// Created by Sevag Bardakjian
// Copyright © 2025 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
//
// The InfoView previously required clicking an interface and reading a
// sparse detail pane. This card sits at the top and answers the *one*
// question users actually have ("what's my internet right now?") without
// any clicking — active interface, Wi-Fi SSID, public IPv4 + IPv6, ISP,
// ASN, country, gateway, gateway vendor, DNS servers, latency to gateway
// and to the public internet.
//
// PoC scope: hero card only. The existing per-interface pane is untouched
// so you can see the new design alongside the old before we commit to the
// full redesign.

import SwiftUI
import CoreWLAN
import Darwin

// MARK: - Model

@MainActor
final class ConnectionSummary: ObservableObject {
    @Published var primaryIface:         String? = nil
    @Published var primaryIfaceDisplay:  String  = "Detecting…"
    @Published var primaryMediaIcon:     String  = "network"
    @Published var ssid:                 String? = nil

    // Local network info for the primary interface
    @Published var hostname:    String  = ProcessInfo.processInfo.hostName
    @Published var localIPv4:   String? = nil
    @Published var localCIDR:   Int?    = nil
    @Published var mtu:         Int?    = nil
    @Published var macAddress:  String? = nil
    @Published var vpnActive:   Bool    = false

    // Wi-Fi specifics (CoreWLAN)
    @Published var wifiBSSID:        String? = nil
    @Published var wifiChannel:      Int?    = nil
    @Published var wifiBandLabel:    String? = nil   // "2.4 GHz" / "5 GHz" / "6 GHz"
    @Published var wifiRSSI:         Int?    = nil
    @Published var wifiTxRateMbps:   Double? = nil
    @Published var wifiSecurity:     String? = nil

    @Published var publicIPv4: String? = nil
    @Published var publicIPv6: String? = nil
    @Published var isp:        String? = nil
    @Published var asn:        String? = nil
    @Published var city:       String? = nil
    @Published var region:     String? = nil
    @Published var country:    String? = nil   // 2-letter ISO

    @Published var gatewayIP:     String? = nil
    @Published var gatewayVendor: String? = nil
    @Published var gatewayLatencyMs:  Double? = nil
    @Published var internetLatencyMs: Double? = nil

    @Published var dnsServers: [String] = []

    @Published var isRefreshing: Bool = false
    @Published var lastRefresh:  Date? = nil

    /// `force` (the Refresh button) also repeats the public-IP and ISP
    /// lookups, which are otherwise cached — see `PublicInfoCache`.
    func refresh(force: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // Stage 1: cheap local detection
        let (iface, display, icon) = Self.detectPrimaryInterface()
        primaryIface = iface
        primaryIfaceDisplay = display
        primaryMediaIcon = icon
        hostname = DemoMode.isActive ? DemoMode.hostname : ProcessInfo.processInfo.hostName

        // Local interface details (IP, mask, MTU, MAC) for the primary iface
        if let name = iface, let detail = Self.fetchLocalDetail(iface: name) {
            localIPv4  = detail.ip
            localCIDR  = detail.cidr
            mtu        = detail.mtu
            macAddress = DemoMode.isActive ? DemoMode.macAddress : detail.mac
        } else {
            localIPv4 = nil; localCIDR = nil; mtu = nil; macAddress = nil
        }

        vpnActive = Self.hasActiveVPNTunnel()

        // Wi-Fi specifics if the primary iface is en* and CoreWLAN reports a join
        if iface?.hasPrefix("en") == true, let info = Self.fetchWiFi() {
            ssid = info.ssid
            wifiBSSID      = info.bssid
            wifiChannel    = info.channel
            wifiBandLabel  = info.band
            wifiRSSI       = info.rssi
            wifiTxRateMbps = info.txRate
            wifiSecurity   = info.security
            // If we have an SSID + channel, refine the icon to plain wifi vs ethernet
            primaryMediaIcon = "wifi"
        } else {
            ssid = nil
            wifiBSSID = nil; wifiChannel = nil; wifiBandLabel = nil
            wifiRSSI = nil; wifiTxRateMbps = nil; wifiSecurity = nil
            // No SSID + en* iface → most likely Ethernet
            if iface?.hasPrefix("en") == true {
                primaryMediaIcon = "cable.connector"
            }
        }

        // Stage 2: gateway (netstat) + DNS (scutil) + ARP for vendor lookup
        async let gwPair: (ip: String?, vendor: String?) = Self.detectGateway()
        async let dnsList: [String] = Self.fetchSystemDNS()

        let (gw, dns) = await (gwPair, dnsList)
        gatewayIP = gw.ip
        gatewayVendor = gw.vendor
        dnsServers = dns

        // Stage 3: public network. The latency pings run every refresh — they
        // feed the live readouts. The public-IP and ISP lookups are cached
        // and repeated only when the network changes, every 10 min, or on a
        // manual Refresh.
        let cache = PublicInfoCache.shared
        cache.noteNetwork([iface, localIPv4, gw.ip, ssid, vpnActive ? "vpn" : nil]
                            .map { $0 ?? "-" }.joined(separator: "|"))
        let now = Date()
        async let inetPing: Double? = Self.pingOnce("1.1.1.1")

        if PublicLookupPolicy.needsIPCheck(force: force, lastCheck: cache.ipCheckedAt, now: now) {
            async let v4Task: String? = Self.fetchPublicIPv4()
            async let v6Task: String? = Self.fetchPublicIPv6()
            let (v4, v6) = await (v4Task, v6Task)
            // Only a successful lookup counts; a failure retries next refresh.
            if v4 != nil || v6 != nil {
                cache.publicIPv4 = v4
                cache.publicIPv6 = v6
                cache.ipCheckedAt = now
            }
        }
        if let ip = cache.publicIPv4,
           PublicLookupPolicy.needsGeo(force: force, publicIPv4: ip,
                                       fetchedAt: cache.geoByIP[ip]?.fetchedAt,
                                       failedAt: cache.geoFailedAt[ip], now: now) {
            if let fields = await Self.fetchGeo(ip: ip) {
                cache.geoByIP[ip] = (fields, now)
                cache.geoFailedAt[ip] = nil
            } else {
                cache.geoFailedAt[ip] = now
            }
        }
        let geo = cache.publicIPv4.flatMap { cache.geoByIP[$0]?.fields }

        let inetMs = await inetPing
        let gwMs: Double? = (gw.ip != nil) ? await Self.pingOnce(gw.ip!) : nil
        publicIPv4 = DemoMode.isActive ? DemoMode.publicIPv4 : cache.publicIPv4
        publicIPv6 = cache.publicIPv6
        isp = geo?.isp
        asn = geo?.asn
        city = geo?.city
        region = geo?.region
        country = geo?.country
        gatewayLatencyMs  = gwMs
        internetLatencyMs = inetMs

        lastRefresh = Date()
    }

    fileprivate struct GeoFields {
        let isp: String?
        let asn: String?
        let city: String?
        let region: String?
        let country: String?
    }

    // MARK: Local detection

    /// Picks the interface carrying the default IPv4 route. The 4th
    /// whitespace-separated field of netstat's "default" line is the
    /// netif. Returns (name, friendly, sf-symbol).
    private static func detectPrimaryInterface() -> (String?, String, String) {
        guard let name = RouteInfo.defaultInterface() else {
            return (nil, "Offline", "network.slash")
        }
        return (name, friendly(name), mediaIcon(name))
    }

    private static func friendly(_ ifname: String) -> String {
        if ifname.hasPrefix("en") {
            return "Connected via Ethernet / Wi-Fi (\(ifname))"
        }
        if ifname.hasPrefix("utun") {
            return "Connected via VPN tunnel (\(ifname))"
        }
        if ifname.hasPrefix("bridge") {
            return "Connected via bridge (\(ifname))"
        }
        if ifname.hasPrefix("ppp") {
            return "Connected via PPP (\(ifname))"
        }
        return "Connected via \(ifname)"
    }

    private static func mediaIcon(_ ifname: String) -> String {
        if ifname.hasPrefix("utun") { return "lock.shield" }
        if ifname.hasPrefix("ppp")  { return "phone.connection" }
        if ifname.hasPrefix("bridge") { return "rectangle.connected.to.line.below" }
        if ifname.hasPrefix("en")   { return "wifi" }    // refined below if no SSID
        return "network"
    }

    /// Reads the SSID via CoreWLAN. Requires Location permission (the app
    /// already requests this at launch for the Wi-Fi Analyzer).
    private static func fetchSSID() -> String? {
        guard let iface = CWWiFiClient.shared().interface() else { return nil }
        let s = iface.ssid()
        return (s?.isEmpty == false) ? s : nil
    }

    private struct WiFiInfo {
        let ssid: String?
        let bssid: String?
        let channel: Int?
        let band: String?
        let rssi: Int?
        let txRate: Double?
        let security: String?
    }

    /// Full Wi-Fi snapshot via CoreWLAN. Returns nil if no Wi-Fi interface
    /// is active or the user hasn't granted Location permission.
    private static func fetchWiFi() -> WiFiInfo? {
        if DemoMode.isActive {
            return WiFiInfo(ssid: DemoMode.ssid, bssid: DemoMode.macAddress,
                            channel: 37, band: "6 GHz",
                            rssi: -63, txRate: 1441, security: "WPA3")
        }
        guard let iface = CWWiFiClient.shared().interface() else { return nil }
        let ssid = iface.ssid()
        guard ssid?.isEmpty == false else { return nil }
        let chan = iface.wlanChannel()
        let channelNum: Int? = chan.map { Int($0.channelNumber) }
        let band: String? = {
            guard let b = chan?.channelBand else { return nil }
            switch b {
            case .band2GHz: return "2.4 GHz"
            case .band5GHz: return "5 GHz"
            case .band6GHz: return "6 GHz"
            case .bandUnknown: return nil
            @unknown default: return nil
            }
        }()
        let rssi = iface.rssiValue() != 0 ? Int(iface.rssiValue()) : nil
        let tx   = iface.transmitRate() > 0 ? iface.transmitRate() : nil
        // Shared with the Status Board Wi-Fi tile so the two always agree.
        let sec: String? = iface.security().snapLabel
        return WiFiInfo(ssid: ssid, bssid: iface.bssid(),
                        channel: channelNum, band: band,
                        rssi: rssi, txRate: tx, security: sec)
    }

    private struct LocalDetail {
        let ip: String
        let cidr: Int
        let mtu: Int?
        let mac: String?
    }

    /// Reads the primary IPv4 + subnet mask + MTU + MAC for a given
    /// interface via a single getifaddrs walk.
    private static func fetchLocalDetail(iface targetName: String) -> LocalDetail? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ip: String? = nil
        var cidr: Int = 0
        var mtu: Int? = nil
        var mac: String? = nil

        var cur = ifaddr
        while let c = cur {
            defer { cur = c.pointee.ifa_next }
            let name = String(cString: c.pointee.ifa_name)
            guard name == targetName else { continue }
            // ifa_addr can be NULL for some pseudo-interfaces
            guard let sa = c.pointee.ifa_addr else { continue }
            let family = Int32(sa.pointee.sa_family)

            if family == AF_INET, ip == nil {
                var sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
                ip = String(cString: buf)
                // Convert netmask → CIDR via popcount
                if let maskPtr = c.pointee.ifa_netmask {
                    let msin = maskPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                    let m = UInt32(bigEndian: msin.sin_addr.s_addr)
                    cidr = m.nonzeroBitCount
                }
            }

            if family == AF_LINK {
                if let dataPtr = c.pointee.ifa_data {
                    let d = dataPtr.assumingMemoryBound(to: if_data.self).pointee
                    mtu = Int(d.ifi_mtu)
                }
                // sdl_data is a variable-length tail; bound reads by sdl_len
                // via the raw pointer so long interface names (e.g. bridge0)
                // don't overrun the Swift-imported 12-byte tuple view.
                let raw = UnsafeRawPointer(sa)
                let sdlLen  = Int(raw.load(fromByteOffset: 0, as: UInt8.self))
                let nameLen = Int(raw.load(fromByteOffset: 5, as: UInt8.self))
                let alen    = Int(raw.load(fromByteOffset: 6, as: UInt8.self))
                if alen == 6, 8 + nameLen + 6 <= sdlLen {
                    var bytes: [UInt8] = []
                    for i in 0..<6 {
                        bytes.append(raw.load(fromByteOffset: 8 + nameLen + i, as: UInt8.self))
                    }
                    mac = bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
                }
            }
        }

        guard let ip = ip else { return nil }
        return LocalDetail(ip: ip, cidr: cidr, mtu: mtu, mac: mac)
    }

    /// Returns true if any utun*/ipsec* tunnel has an IPv4 address bound.
    private static func hasActiveVPNTunnel() -> Bool {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return false }
        defer { freeifaddrs(ifaddr) }
        var cur = ifaddr
        while let c = cur {
            defer { cur = c.pointee.ifa_next }
            let name = String(cString: c.pointee.ifa_name)
            let isTunnel = name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp")
            guard isTunnel else { continue }
            // ifa_addr is NULL on some PPP/tunnel entries — exactly the
            // interface class this loop filters for
            if let sa = c.pointee.ifa_addr, Int32(sa.pointee.sa_family) == AF_INET {
                return true
            }
        }
        return false
    }

    /// Reads ARP for the gateway's MAC, then looks it up in OUIDatabase.
    private static func detectGateway() async -> (ip: String?, vendor: String?) {
        guard let ip = RouteInfo.defaultGateway() else { return (nil, nil) }

        // Look up MAC in ARP cache for vendor lookup
        let arp = await Shell.run("/usr/sbin/arp", args: ["-n", ip])
        var mac: String? = nil
        if let r = arp.range(of: " at ") {
            let tail = arp[r.upperBound...]
            mac = tail.split(separator: " ").first.map(String.init)
        }
        let vendor = mac.flatMap { OUIDatabase.lookup($0) }
        return (ip, vendor)
    }

    private static func fetchSystemDNS() async -> [String] {
        DNSInfo.systemResolvers()
    }

    // MARK: Network fetches

    private static func fetchPublicIPv4() async -> String? {
        await fetchText("https://api.ipify.org")
    }

    private static func fetchPublicIPv6() async -> String? {
        await fetchText("https://api6.ipify.org")
    }

    private static func fetchText(_ urlStr: String) async -> String? {
        guard let url = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 4
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (s?.isEmpty == false) ? s : nil
        } catch {
            return nil
        }
    }

    /// ipinfo.io returns JSON like:
    ///   {"ip":"…","city":"Toronto","region":"Ontario","country":"CA",
    ///    "org":"AS7922 Comcast Cable Communications, LLC", …}
    /// We split `org` on the first whitespace: `AS7922` → ASN, rest → ISP.
    /// Asks about `ip` explicitly so the cache entry is keyed to the address
    /// it describes. Returns nil on any failure — including ipinfo's
    /// rate-limit response — so nothing empty gets cached.
    private static func fetchGeo(ip: String) async -> GeoFields? {
        guard let url = URL(string: "https://ipinfo.io/\(ip)/json") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 4
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            let city    = json["city"]    as? String
            let region  = json["region"]  as? String
            let country = json["country"] as? String
            let org     = json["org"]     as? String
            var asn: String? = nil
            var isp: String? = nil
            if let org = org, !org.isEmpty {
                let parts = org.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                if let first = parts.first, first.hasPrefix("AS") {
                    asn = String(first)
                    isp = parts.count > 1 ? String(parts[1]) : nil
                } else {
                    isp = org
                }
            }
            if isp == nil && asn == nil && city == nil && country == nil { return nil }
            return GeoFields(isp: isp, asn: asn, city: city, region: region, country: country)
        } catch {
            return nil
        }
    }

    /// One-shot ping returning latency in ms, or nil on timeout/failure.
    private static func pingOnce(_ host: String) async -> Double? {
        let out = await Shell.run("/sbin/ping",
                                  args: ["-c", "1", "-W", "1000", "-t", "2", "-q", host])
        guard out.contains("bytes from") || out.contains("1 packets received") else { return nil }
        // round-trip line: "= 1.234/5.678/9.123/0.456 ms"
        if let r = out.range(of: #"=\s+[\d\.]+/([\d\.]+)/"#, options: .regularExpression) {
            let s = out[r]
            let digits = s.split(whereSeparator: { !$0.isNumber && $0 != "." })
            if digits.count >= 2 { return Double(String(digits[1])) }
        }
        return nil
    }
}

// MARK: - Public lookup caching

/// When to repeat the public-IP (ipify) and ISP (ipinfo.io) lookups. Kept
/// pure so it can be unit tested. The card refreshes every 30 s, but these
/// lookups don't need to follow it.
enum PublicLookupPolicy {
    /// Re-check the public address this often even when nothing local
    /// changed — an ISP can reassign it without the LAN noticing.
    static let ipRecheckInterval: TimeInterval = 10 * 60
    /// ISP, ASN, and city for one address are effectively static.
    static let geoMaxAge: TimeInterval = 24 * 60 * 60
    /// After a failed ISP lookup (offline, rate-limited), wait this long.
    static let geoRetryAfterFailure: TimeInterval = 5 * 60

    static func needsIPCheck(force: Bool, lastCheck: Date?, now: Date) -> Bool {
        guard !force, let last = lastCheck else { return true }
        return now.timeIntervalSince(last) >= ipRecheckInterval
    }

    /// `fetchedAt` / `failedAt`: the last success and failure for this
    /// address. With no known address there's nothing to look up.
    static func needsGeo(force: Bool, publicIPv4: String?, fetchedAt: Date?,
                         failedAt: Date?, now: Date) -> Bool {
        guard publicIPv4 != nil else { return false }
        if force { return true }
        if let f = failedAt, now.timeIntervalSince(f) < geoRetryAfterFailure { return false }
        guard let at = fetchedAt else { return true }
        return now.timeIntervalSince(at) >= geoMaxAge
    }
}

/// Public-IP and ISP results, shared across refreshes and across Dashboard
/// visits (the card's model is recreated when the window is reopened). Before
/// v1.5.3 every 30 s refresh repeated all three lookups — about 2,900
/// ipinfo.io requests a day with the Dashboard open, enough for ipinfo to
/// rate-limit the user's IP.
@MainActor
final class PublicInfoCache {
    static let shared = PublicInfoCache()
    private init() {}

    private(set) var networkKey: String?
    var publicIPv4: String?
    var publicIPv6: String?
    var ipCheckedAt: Date?
    fileprivate var geoByIP: [String: (fields: ConnectionSummary.GeoFields, fetchedAt: Date)] = [:]
    var geoFailedAt: [String: Date] = [:]

    /// A different interface, local address, gateway, SSID, or VPN state can
    /// mean a different public address, so forget the old one rather than
    /// show it for the new network. ISP details stay, keyed by address.
    func noteNetwork(_ key: String) {
        guard key != networkKey else { return }
        networkKey = key
        publicIPv4 = nil
        publicIPv6 = nil
        ipCheckedAt = nil
    }
}

// MARK: - View

struct ConnectionSummaryCard: View {
    @StateObject private var summary = ConnectionSummary()
    @State private var tick: Timer?
    @ObservedObject private var themeMgr = ThemeManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider().background(NS.borderMid)
            grid
            footer
        }
        .padding(16)
        .background(NS.bg2)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(NS.border, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear { startTicking() }
        .onDisappear { stopTicking() }
        // The Dashboard stays alive in the background: no pings or lookups
        // while it's hidden, and a fresh refresh on return.
        .onTabVisibilityChange(shown: { startTicking() }, hidden: { stopTicking() })
    }

    /// Light auto-refresh every 30 s — re-pings; public-IP/ISP lookups are cached.
    private func startTicking() {
        stopTicking()
        Task { await summary.refresh() }
        let t = Timer(timeInterval: 30, repeats: true) { _ in
            Task { await summary.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        tick = t
    }

    private func stopTicking() {
        tick?.invalidate()
        tick = nil
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(NS.amber.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: summary.primaryMediaIcon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(NS.amber)
            }
            VStack(alignment: .leading, spacing: 2) {
                if let s = summary.ssid {
                    Text(s)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(NS.text1)
                } else {
                    Text(summary.primaryIfaceDisplay)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(NS.text1)
                }
                Text(summary.primaryIfaceDisplay)
                    .font(.system(size: 11))
                    .foregroundStyle(NS.text3)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(summary.primaryIface != nil ? NS.green : NS.red)
                    .frame(width: 7, height: 7)
                Text(summary.primaryIface != nil ? "Active route" : "Offline")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(summary.primaryIface != nil ? NS.green : NS.red)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(
                Capsule().fill((summary.primaryIface != nil ? NS.green : NS.red).opacity(0.10))
            )
        }
    }

    // MARK: Grid of fields

    private var grid: some View {
        VStack(spacing: 7) {
            row(label: "Hostname",
                monoText: summary.hostname,
                trailing: macTrailing)
            if summary.localIPv4 != nil {
                row(label: "Local",
                    monoText: localText,
                    trailing: ifaceTrailing)
            }
            if summary.wifiChannel != nil || summary.wifiRSSI != nil {
                row(label: "Wi-Fi",
                    monoText: wifiText,
                    trailing: wifiTrailing)
            }
            row(label: "Public v4", monoText: summary.publicIPv4, trailing: ispLine, isHost: true)
            if summary.publicIPv6 != nil {
                row(label: "Public v6", monoText: summary.publicIPv6, isHost: true)
            }
            row(label: "Gateway",
                monoText: summary.gatewayIP,
                trailing: gatewayTrailing,
                isHost: true)
            row(label: "DNS",
                monoText: summary.dnsServers.isEmpty ? nil : summary.dnsServers.joined(separator: ", "))
            row(label: "Internet",
                monoText: "1.1.1.1",
                trailing: AnyView(latencyPill(summary.internetLatencyMs)),
                isHost: true)
            if summary.vpnActive {
                row(label: "VPN",
                    monoText: "active tunnel",
                    trailing: AnyView(
                        HStack(spacing: 3) {
                            Image(systemName: "lock.shield.fill").font(.system(size: 9))
                            Text("UP").font(.system(size: 10, weight: .bold))
                        }
                        .foregroundStyle(NS.amber)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(NS.amber.opacity(0.10)))
                    ))
            }
        }
    }

    // MARK: Computed text + trailings

    private var localText: String {
        guard let ip = summary.localIPv4 else { return "—" }
        if let c = summary.localCIDR, c > 0 { return "\(ip)/\(c)" }
        return ip
    }

    private var wifiText: String {
        var parts: [String] = []
        if let ch = summary.wifiChannel { parts.append("Ch \(ch)") }
        if let band = summary.wifiBandLabel { parts.append(band) }
        if let rssi = summary.wifiRSSI { parts.append("\(rssi) dBm") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private var macTrailing: AnyView {
        guard let m = summary.macAddress else { return AnyView(EmptyView()) }
        return AnyView(
            Text(m)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(NS.text3)
                .textSelection(.enabled)
        )
    }

    private var ifaceTrailing: AnyView {
        var bits: [String] = []
        if let iface = summary.primaryIface { bits.append(iface) }
        if let mtu = summary.mtu { bits.append("MTU \(mtu)") }
        guard !bits.isEmpty else { return AnyView(EmptyView()) }
        return AnyView(
            Text(bits.joined(separator: " · "))
                .font(.system(size: 10))
                .foregroundStyle(NS.text3)
        )
    }

    private var wifiTrailing: AnyView {
        var trailing: [String] = []
        if let s = summary.wifiSecurity { trailing.append(s) }
        if let tx = summary.wifiTxRateMbps, tx > 0 {
            trailing.append(String(format: "%.0f Mbps", tx))
        }
        guard !trailing.isEmpty else { return AnyView(EmptyView()) }
        return AnyView(
            HStack(spacing: 6) {
                Text(trailing.joined(separator: " · "))
                    .font(.system(size: 10))
                    .foregroundStyle(NS.text2)
                if let rssi = summary.wifiRSSI {
                    rssiBars(rssi)
                }
            }
        )
    }

    /// Tiny 4-bar RSSI indicator. -50 and stronger → 4 bars. Steps every 10 dB.
    @ViewBuilder
    private func rssiBars(_ rssi: Int) -> some View {
        let strength: Int = {
            switch rssi {
            case (-50)...:  return 4
            case (-60)..<(-50): return 3
            case (-70)..<(-60): return 2
            case (-80)..<(-70): return 1
            default:        return 0
            }
        }()
        HStack(alignment: .bottom, spacing: 1) {
            ForEach(0..<4, id: \.self) { i in
                Rectangle()
                    .fill(i < strength ? NS.green : NS.text4)
                    .frame(width: 2, height: CGFloat(4 + i * 2))
            }
        }
    }

    private var ispLine: AnyView {
        guard summary.isp != nil || summary.asn != nil || summary.country != nil else {
            return AnyView(EmptyView())
        }
        return AnyView(
            HStack(spacing: 6) {
                if let asn = summary.asn {
                    Text(asn)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(NS.amber)
                }
                if let isp = summary.isp {
                    Text(isp).font(.system(size: 11)).foregroundStyle(NS.text2).lineLimit(1)
                }
                if let city = summary.city {
                    Text("· \(city)").font(.system(size: 10)).foregroundStyle(NS.text3)
                }
                if let c = summary.country {
                    Text(flagEmoji(c)).font(.system(size: 13))
                }
            }
        )
    }

    private var gatewayTrailing: AnyView {
        AnyView(
            HStack(spacing: 6) {
                if let v = summary.gatewayVendor {
                    Text(v).font(.system(size: 11)).foregroundStyle(NS.text3)
                }
                latencyPill(summary.gatewayLatencyMs)
            }
        )
    }

    private func row(label: String, monoText: String?, trailing: AnyView = AnyView(EmptyView()),
                     isHost: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(NS.text3)
                .frame(width: 78, alignment: .leading)
            // The value text is host-clickable when isHost && we have a value.
            // .hostMenu wraps the Text so right-click works on the value itself.
            Group {
                if isHost, let v = monoText {
                    Text(v)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(NS.text1)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .hostMenu(v)
                } else {
                    Text(monoText ?? "—")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(monoText == nil ? NS.text4 : NS.text1)
                        .textSelection(.enabled)
                        .lineLimit(1)
                }
            }
            trailing
            Spacer(minLength: 0)
        }
    }

    private func latencyPill(_ ms: Double?) -> some View {
        Group {
            if let ms = ms {
                let color: Color = ms < 10 ? NS.green : (ms < 50 ? NS.amber : NS.red)
                HStack(spacing: 3) {
                    Image(systemName: "bolt.fill").font(.system(size: 9))
                    Text(String(format: "%.1f ms", ms))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                }
                .foregroundStyle(color)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(color.opacity(0.10)))
            } else {
                Text("—").font(.system(size: 10)).foregroundStyle(NS.text4)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if let t = summary.lastRefresh {
                Text("Refreshed \(t.formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 10))
                    .foregroundStyle(NS.text4)
            }
            Spacer()
            Button {
                Task { await summary.refresh(force: true) }
            } label: {
                HStack(spacing: 4) {
                    if summary.isRefreshing {
                        ProgressView().controlSize(.mini).scaleEffect(0.6)
                    } else {
                        Image(systemName: "arrow.clockwise").font(.system(size: 10))
                    }
                    Text(summary.isRefreshing ? "Refreshing…" : "Refresh")
                        .font(.system(size: 11))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(summary.isRefreshing)
        }
    }

    // MARK: Helpers

    /// Two-letter ISO country code → flag emoji via Unicode regional indicators.
    private func flagEmoji(_ code: String) -> String {
        let upper = code.uppercased()
        guard upper.count == 2 else { return "" }
        let base: UInt32 = 127397
        var s = ""
        for scalar in upper.unicodeScalars {
            if let u = Unicode.Scalar(base + scalar.value) {
                s.unicodeScalars.append(u)
            }
        }
        return s
    }
}
