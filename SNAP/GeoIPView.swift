// GeoIPView.swift
// SNAP — GeoIP Lookup
// Created by Sevag Bardakjian
// Copyright © 2025-2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md

import SwiftUI
import MapKit
import Darwin

// MARK: - Data Model

struct GeoIPResult {
    var ip: String = ""
    var ipType: String = ""         // "IPv4" / "IPv6"
    var continent: String = ""
    var continentCode: String = ""
    var country: String = ""
    var countryCode: String = ""
    var region: String = ""
    var regionCode: String = ""
    var city: String = ""
    var latitude: Double = 0
    var longitude: Double = 0
    var postal: String = ""
    var callingCode: String = ""
    var capital: String = ""
    var isEU: Bool = false
    var flagEmoji: String = ""
    // Network
    var isp: String = ""
    var org: String = ""
    var asn: String = ""
    var domain: String = ""
    // Timezone
    var timezone: String = ""
    var timezoneAbbr: String = ""
    var timezoneUTC: String = ""
    var currentTime: String = ""
    // Security signals (present on some responses)
    var isAnonymous: Bool = false
    var isProxy: Bool = false
    var isVPN: Bool = false
    var isTor: Bool = false
    var isHosting: Bool = false

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var hasSecurityFlags: Bool {
        isAnonymous || isProxy || isVPN || isTor || isHosting
    }
}

// MARK: - View Model

final class GeoIPViewModel: ObservableObject {
    @Published var result: GeoIPResult?
    @Published var isLoading = false
    @Published var errorMessage: String?

    // Camera state (macOS 13-compatible — no MapCameraPosition)
    @Published var cameraLat: Double = 20
    @Published var cameraLon: Double = 0
    @Published var cameraLatDelta: Double = 120
    @Published var cameraLonDelta: Double = 160

    var currentRegion: MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: cameraLat, longitude: cameraLon),
            span: MKCoordinateSpan(latitudeDelta: cameraLatDelta, longitudeDelta: cameraLonDelta)
        )
    }

    func lookupMyIP() {
        fetch(urlString: "https://ipwho.is/")
    }

    func lookup(query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }

        // ipwho.is intermittently returns 404 for hostnames (their DNS side
        // fails on some CDN-fronted domains). Pre-resolving to an IP via
        // getaddrinfo dodges that entirely — their IP path works reliably.
        if Self.looksLikeIP(q) {
            let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? q
            fetch(urlString: "https://ipwho.is/\(encoded)")
        } else {
            DispatchQueue.main.async {
                self.isLoading = true
                self.errorMessage = nil
                self.result = nil
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                if let ip = Self.resolveIPv4(q) {
                    let encoded = ip.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ip
                    self.fetch(urlString: "https://ipwho.is/\(encoded)")
                } else {
                    DispatchQueue.main.async {
                        self.isLoading = false
                        self.errorMessage = "Could not resolve hostname \(q)"
                    }
                }
            }
        }
    }

    /// Rough classifier — good enough to route between "hit the IP endpoint"
    /// and "resolve first." Accepts IPv4 dotted-decimal and IPv6 colon form.
    private static func looksLikeIP(_ s: String) -> Bool {
        var hints = addrinfo(ai_flags: AI_NUMERICHOST, ai_family: AF_UNSPEC,
                             ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        defer { if info != nil { freeaddrinfo(info) } }
        return getaddrinfo(s, nil, &hints, &info) == 0
    }

    /// Resolve hostname → first IPv4 string, or nil on failure.
    private static func resolveIPv4(_ host: String) -> String? {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET,
                             ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        defer { if info != nil { freeaddrinfo(info) } }
        guard getaddrinfo(host, nil, &hints, &info) == 0, let node = info else { return nil }
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = getnameinfo(node.pointee.ai_addr, node.pointee.ai_addrlen,
                             &buf, socklen_t(buf.count),
                             nil, 0, NI_NUMERICHOST)
        return rc == 0 ? String(cString: buf) : nil
    }

    private func fetch(urlString: String) {
        guard let url = URL(string: urlString) else {
            DispatchQueue.main.async { self.errorMessage = "Invalid URL" }
            return
        }

        DispatchQueue.main.async {
            self.isLoading = true
            self.errorMessage = nil
            self.result = nil
        }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let self else { return }
            DispatchQueue.main.async {
                self.isLoading = false

                if let error = error {
                    self.errorMessage = error.localizedDescription
                    return
                }
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.errorMessage = "Invalid response from server."
                    return
                }
                guard json["success"] as? Bool == true else {
                    self.errorMessage = json["message"] as? String ?? "Lookup failed — check the IP or hostname."
                    return
                }

                var r = GeoIPResult()
                r.ip            = json["ip"]             as? String ?? ""
                r.ipType        = json["type"]           as? String ?? ""
                r.continent     = json["continent"]      as? String ?? ""
                r.continentCode = json["continent_code"] as? String ?? ""
                r.country       = json["country"]        as? String ?? ""
                r.countryCode   = json["country_code"]   as? String ?? ""
                r.region        = json["region"]         as? String ?? ""
                r.regionCode    = json["region_code"]    as? String ?? ""
                r.city          = json["city"]           as? String ?? ""
                r.latitude      = json["latitude"]       as? Double ?? 0
                r.longitude     = json["longitude"]      as? Double ?? 0
                r.postal        = json["postal"]         as? String ?? ""
                r.callingCode   = json["calling_code"]   as? String ?? ""
                r.capital       = json["capital"]        as? String ?? ""
                r.isEU          = json["is_eu"]          as? Bool   ?? false

                if let flag = json["flag"] as? [String: Any] {
                    r.flagEmoji = flag["emoji"] as? String ?? ""
                }

                if let conn = json["connection"] as? [String: Any] {
                    r.isp    = conn["isp"]    as? String ?? ""
                    r.org    = conn["org"]    as? String ?? ""
                    r.domain = conn["domain"] as? String ?? ""
                    if let asnInt = conn["asn"] as? Int {
                        r.asn = "AS\(asnInt)"
                    } else if let asnStr = conn["asn"] as? String {
                        r.asn = asnStr.hasPrefix("AS") ? asnStr : "AS\(asnStr)"
                    }
                }

                if let tz = json["timezone"] as? [String: Any] {
                    r.timezone      = tz["id"]           as? String ?? ""
                    r.timezoneAbbr  = tz["abbr"]         as? String ?? ""
                    r.timezoneUTC   = tz["utc"]          as? String ?? ""
                    r.currentTime   = tz["current_time"] as? String ?? ""
                }

                if let sec = json["security"] as? [String: Any] {
                    r.isAnonymous = sec["anonymous"] as? Bool ?? false
                    r.isProxy     = sec["proxy"]     as? Bool ?? false
                    r.isVPN       = sec["vpn"]       as? Bool ?? false
                    r.isTor       = sec["tor"]       as? Bool ?? false
                    r.isHosting   = sec["hosting"]   as? Bool ?? false
                }

                self.result = r

                // Zoom the camera in on the result
                self.cameraLat      = r.latitude
                self.cameraLon      = r.longitude
                self.cameraLatDelta = 6
                self.cameraLonDelta = 8
            }
        }.resume()
    }
}

// MARK: - macOS 14+ Map subview

@available(macOS 14.0, *)
struct GeoIPMapView: View {
    let result: GeoIPResult
    let region: MKCoordinateRegion

    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $position) {
            Annotation("", coordinate: result.coordinate) {
                VStack(spacing: 4) {
                    ZStack {
                        Circle()
                            .fill(NS.amber)
                            .frame(width: 46, height: 46)
                            .shadow(color: .black.opacity(0.45), radius: 8, y: 3)
                        Image(systemName: "network")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    if !result.flagEmoji.isEmpty {
                        Text(result.flagEmoji)
                            .font(.system(size: 24))
                            .shadow(color: .black.opacity(0.3), radius: 2)
                    }
                    Text(result.city.isEmpty ? result.ip : result.city)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.7))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
            }
        }
        .mapStyle(.standard)
        .task(id: result.ip) {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                position = .region(region)
            }
        }
    }
}

// MARK: - Main View

struct GeoIPView: View {
    @State private var query = ""
    @StateObject private var model = GeoIPViewModel()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            mainContent
        }
        .background(NS.bg0)
        .tabNavigationTitle(.geoIP)
        .consumeHandoff(for: .geoIP) { query = $0 }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "globe.americas")
                .foregroundStyle(NS.amber)
                .font(.system(size: 14))

            TextField("IP address or hostname…", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 290)
                .onSubmit { performLookup() }
            HistoryMenuButton(key: .geoIP) { query = $0 }

            Button("Lookup") { performLookup() }
                .buttonStyle(.borderedProminent)
                .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || model.isLoading)

            Button("My IP") {
                query = ""
                model.lookupMyIP()
            }
            .buttonStyle(.bordered)
            .disabled(model.isLoading)

            if model.isLoading {
                ProgressView().controlSize(.small)
                Text("Looking up…")
                    .font(.caption)
                    .foregroundStyle(NS.text3)
            }

            Spacer()
            if let r = model.result {
                ToolActionBar("GeoIP", text: {
                    """
                    GeoIP — \(r.ip) (\(r.ipType))
                    Location:  \(r.city), \(r.region), \(r.country) (\(r.countryCode))
                    ISP:       \(r.isp)
                    Org:       \(r.org)
                    ASN:       \(r.asn)
                    Timezone:  \(r.timezone) \(r.timezoneUTC)
                    """
                })
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(NS.bg0)
    }

    // MARK: Main content router

    @ViewBuilder
    private var mainContent: some View {
        if let error = model.errorMessage {
            errorState(error)
        } else if let result = model.result {
            resultView(result)
        } else if !model.isLoading {
            emptyState
        } else {
            // Loading — show a blank dark background
            NS.bg0.ignoresSafeArea()
        }
    }

    // MARK: Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "globe.americas")
                .font(.system(size: 56))
                .foregroundStyle(NS.text4)
            Text("GeoIP Lookup")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(NS.text2)
            Text("Enter an IP address or hostname above, or look up your own public IP.")
                .font(.system(size: 12))
                .foregroundStyle(NS.text3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button("Look Up My IP") { model.lookupMyIP() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NS.bg0)
    }

    // MARK: Error State

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(NS.red)
            Text("Lookup Failed")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(NS.text1)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(NS.text3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Button("Try Again") { performLookup() }
                .buttonStyle(.bordered)
                .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NS.bg0)
    }

    // MARK: Result View

    private func resultView(_ result: GeoIPResult) -> some View {
        HSplitView {
            // Left: Map
            mapPane(result)
                .frame(minWidth: 420)

            // Right: Info panel
            infoPane(result)
                .frame(minWidth: 300, maxWidth: 380)
        }
    }

    // Both branches are type-erased through AnyView so the macOS-14-only
    // `GeoIPMapView` type never appears in this function's opaque return
    // signature. Without the erasure the compiler warns that the resulting
    // `_ConditionalContent` metadata may not be instantiable on macOS 13.
    private func mapPane(_ result: GeoIPResult) -> AnyView {
        if #available(macOS 14, *) {
            return AnyView(GeoIPMapView(result: result, region: model.currentRegion))
        } else {
            return AnyView(legacyMapPane(result))
        }
    }

    /// macOS 13 fallback for `mapPane` — coordinate readout instead of a map.
    private func legacyMapPane(_ result: GeoIPResult) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Text(result.flagEmoji).font(.system(size: 48))
            Text("\(result.city), \(result.country)")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(NS.text1)
            Text(String(format: "%.4f°, %.4f°", result.latitude, result.longitude))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(NS.text3)
            Text("Map view requires macOS 14+")
                .font(.system(size: 10))
                .foregroundStyle(NS.text4)
                .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NS.bg1)
    }

    private func infoPane(_ result: GeoIPResult) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {

                // ── Header card ──────────────────────────────────────────────
                headerCard(result)

                // ── Security badges (only if any flags are set) ──────────────
                if result.hasSecurityFlags {
                    securitySection(result)
                }

                // ── Location ─────────────────────────────────────────────────
                sectionBox(title: "Location", icon: "mappin.and.ellipse") {
                    infoRow("Continent",    value: result.continent,  badge: result.continentCode)
                    infoRow("Country",      value: result.country,    badge: result.countryCode)
                    infoRow("Region",       value: result.region,     badge: result.regionCode)
                    infoRow("City",         value: result.city)
                    infoRow("Postal",       value: result.postal)
                    infoRow("Coordinates",  value: String(format: "%.4f°, %.4f°", result.latitude, result.longitude), mono: true)
                    if !result.capital.isEmpty {
                        infoRow("Capital",  value: result.capital)
                    }
                    if !result.callingCode.isEmpty {
                        infoRow("Calling Code", value: result.callingCode, mono: true)
                    }
                }

                // ── Network ──────────────────────────────────────────────────
                sectionBox(title: "Network", icon: "network") {
                    infoRow("ISP",          value: result.isp)
                    infoRow("Organization", value: result.org)
                    infoRow("ASN",          value: result.asn,    mono: true)
                    if !result.domain.isEmpty {
                        infoRow("Domain",   value: result.domain, mono: true)
                    }
                }

                // ── Timezone ─────────────────────────────────────────────────
                if !result.timezone.isEmpty {
                    sectionBox(title: "Timezone", icon: "clock") {
                        infoRow("Timezone",   value: result.timezone,     mono: true)
                        infoRow("Abbr / UTC", value: "\(result.timezoneAbbr)  (\(result.timezoneUTC))", mono: true)
                        if !result.currentTime.isEmpty {
                            infoRow("Local Time", value: formatTime(result.currentTime))
                        }
                    }
                }
            }
            .padding(12)
        }
        .background(NS.bg1)
    }

    // MARK: Header card

    private func headerCard(_ r: GeoIPResult) -> some View {
        HStack(spacing: 14) {
            if !r.flagEmoji.isEmpty {
                Text(r.flagEmoji)
                    .font(.system(size: 44))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(r.ip)
                    .font(.system(size: 19, weight: .bold, design: .monospaced))
                    .foregroundStyle(NS.amber)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    if !r.ipType.isEmpty { ipTypeBadge(r.ipType) }
                    if r.isEU            { tagBadge("EU", color: .blue) }
                }
            }
            Spacer()
        }
        .padding(14)
        .background(NS.bg3)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(NS.border, lineWidth: 0.5))
    }

    // MARK: Security section

    private func securitySection(_ r: GeoIPResult) -> some View {
        sectionBox(title: "Security Signals", icon: "shield.lefthalf.filled") {
            HStack(spacing: 8) {
                if r.isProxy     { secBadge("Proxy",   .orange) }
                if r.isVPN       { secBadge("VPN",     .orange) }
                if r.isTor       { secBadge("Tor",     NS.red)  }
                if r.isHosting   { secBadge("Hosting", NS.text3) }
                if r.isAnonymous { secBadge("Anonymous", .orange) }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    // MARK: Section box

    @ViewBuilder
    private func sectionBox<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(NS.amber)
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(NS.text3)
                    .tracking(0.8)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(NS.bg3)
            .overlay(alignment: .bottom) {
                Rectangle().fill(NS.border).frame(height: 0.5)
            }

            content()
        }
        .background(NS.bg3)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(NS.border, lineWidth: 0.5))
    }

    // MARK: Info row

    @ViewBuilder
    private func infoRow(
        _ label: String,
        value: String,
        badge: String? = nil,
        mono: Bool = false
    ) -> some View {
        if !value.isEmpty {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(label)
                        .font(.system(size: 11))
                        .foregroundStyle(NS.text3)
                        .frame(width: 96, alignment: .trailing)
                    HStack(spacing: 5) {
                        Text(value)
                            .font(mono
                                  ? .system(size: 11, design: .monospaced)
                                  : .system(size: 11))
                            .foregroundStyle(NS.text1)
                            .textSelection(.enabled)
                        if let badge, !badge.isEmpty {
                            Text(badge)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(NS.text3)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(NS.text4.opacity(0.6))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                Rectangle().fill(NS.borderMid).frame(height: 0.5)
            }
        }
    }

    // MARK: Badges

    private func ipTypeBadge(_ type: String) -> some View {
        let color: Color = type == "IPv6" ? NS.blue : NS.green
        return Text(type)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(color.opacity(0.3), lineWidth: 0.5))
    }

    private func tagBadge(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(color.opacity(0.3), lineWidth: 0.5))
    }

    private func secBadge(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(color.opacity(0.25), lineWidth: 0.5))
    }

    // MARK: Helpers

    private func performLookup() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        ToolHistory.shared.add(.geoIP, q)
        model.lookup(query: q)
    }

    private func formatTime(_ iso: String) -> String {
        // ipwho.is returns ISO 8601 with offset, e.g. "2026-04-29T10:30:00-07:00"
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let date = f.date(from: iso) {
            let df = DateFormatter()
            df.dateFormat = "MMM d, yyyy · h:mm a"
            return df.string(from: date)
        }
        return iso
    }
}
