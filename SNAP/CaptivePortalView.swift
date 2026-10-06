// CaptivePortalView.swift
// SNAP — Network Health (Captive Portal + DNS Hijacking + Transparent Proxy + Port Blocking)
// Created by Sevag Bardakjian
// Copyright © 2025 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
//
// What started as a captive-portal detector grew (v1.2.2) into a small
// suite of "is this network restricting me?" checks. Four categories run
// in parallel on open + on re-check:
//
//   1. Captive portal probes (Apple, Cloudflare, Google, MS, Firefox)
//   2. DNS hijacking (NXDOMAIN test + system-resolver vs DoH comparison)
//   3. Transparent proxy (strict generate_204 + Via/X-Cache header sniff)
//   4. Outbound port blocking (TCP connect to common ports against known hosts)
//
// Each category has its own status; an overall verdict aggregates them.

import SwiftUI
import Darwin

// MARK: - Top-level view

struct CaptivePortalView: View {
    @StateObject private var model = NetworkHealthModel()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let v = model.overallVerdict { verdictBanner(v) }
            content
        }
        .tabNavigationTitle(.captivePortal)
        .onAppear { model.runAll() }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
            Text("Network Health")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(NS.text1)
            if let t = model.lastChecked {
                Text("checked \(t.formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 11))
                    .foregroundStyle(NS.text3)
            }
            Spacer()
            ToolActionBar("Network Health", text: { model.exportText() })
            Button(model.isRunning ? "Checking…" : "Re-check") { model.runAll() }
                .buttonStyle(.borderedProminent)
                .disabled(model.isRunning)
                .keyboardShortcut("r", modifiers: .command)
            if model.isRunning { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(NS.bg0)
    }

    private func verdictBanner(_ v: HealthVerdict) -> some View {
        HStack(spacing: 12) {
            Image(systemName: v.icon)
                .font(.system(size: 22))
                .foregroundStyle(v.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(v.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(NS.text1)
                Text(v.detail).font(.system(size: 11)).foregroundStyle(NS.text3)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(v.color.opacity(0.08))
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                CategorySectionView(category: model.captivePortal, model: model)
                Divider().background(NS.borderMid)
                CategorySectionView(category: model.dnsHijack, model: model)
                Divider().background(NS.borderMid)
                CategorySectionView(category: model.proxy, model: model)
                Divider().background(NS.borderMid)
                CategorySectionView(category: model.portBlocking, model: model)
            }
        }
    }
}

// MARK: - Section view

private struct CategorySectionView: View {
    let category: HealthCategory
    @ObservedObject var model: NetworkHealthModel
    @State private var expanded: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                Table(category.checks) {
                    TableColumn("Check") { c in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.label).font(.system(size: 12, weight: .medium))
                            Text(c.detail).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    .width(min: 320)
                    TableColumn("Status") { c in
                        HStack(spacing: 6) {
                            Circle().fill(c.status.color).frame(width: 8, height: 8)
                            Text(c.status.label)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(c.status.color)
                        }
                    }
                    .width(140)
                    TableColumn("Result") { c in
                        Text(c.result)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(NS.text2)
                            .textSelection(.enabled)
                    }
                }
                .frame(minHeight: CGFloat(max(category.checks.count, 1)) * 36 + 28)
            }
        }
    }

    private var header: some View {
        Button { withAnimation { expanded.toggle() } } label: {
            HStack(spacing: 8) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(NS.text3)
                Image(systemName: category.icon).foregroundStyle(NS.amber)
                Text(category.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(NS.text1)
                Spacer()
                Circle().fill(category.aggregate.color).frame(width: 8, height: 8)
                Text(category.summaryText)
                    .font(.system(size: 11))
                    .foregroundStyle(NS.text3)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(NS.bg1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Status / Verdict types

enum HealthStatus {
    case pending, ok, warning, fail
    var label: String {
        switch self {
        case .pending: return "Checking…"
        case .ok:      return "Pass"
        case .warning: return "Suspicious"
        case .fail:    return "Fail"
        }
    }
    var color: Color {
        switch self {
        case .pending: return NS.text3
        case .ok:      return NS.green
        case .warning: return NS.amber
        case .fail:    return NS.red
        }
    }
    var severity: Int {
        switch self {
        case .pending: return 0
        case .ok:      return 0
        case .warning: return 1
        case .fail:    return 2
        }
    }
}

struct HealthVerdict {
    let title: String
    let detail: String
    let icon: String
    let color: Color
}

// MARK: - Check / Category types

struct HealthCheck: Identifiable {
    var id: String { label }
    let label: String
    let detail: String        // sub-line under the label (what we tested)
    var status: HealthStatus
    var result: String
}

struct HealthCategory {
    let id: String
    let title: String
    let icon: String
    var checks: [HealthCheck]

    var aggregate: HealthStatus {
        // Worst non-pending status wins. If all pending, pending.
        let nonPending = checks.filter { $0.status != .pending }
        guard !nonPending.isEmpty else { return .pending }
        if nonPending.contains(where: { $0.status == .fail })    { return .fail }
        if nonPending.contains(where: { $0.status == .warning }) { return .warning }
        return .ok
    }

    var summaryText: String {
        let pass = checks.filter { $0.status == .ok }.count
        let warn = checks.filter { $0.status == .warning }.count
        let fail = checks.filter { $0.status == .fail }.count
        if checks.contains(where: { $0.status == .pending }) { return "running…" }
        var bits: [String] = []
        if pass > 0 { bits.append("\(pass) pass") }
        if warn > 0 { bits.append("\(warn) warn") }
        if fail > 0 { bits.append("\(fail) fail") }
        return bits.joined(separator: " · ")
    }
}

// MARK: - Model

@MainActor
final class NetworkHealthModel: ObservableObject {
    @Published var captivePortal = HealthCategory(
        id: "captive",
        title: "Captive Portal",
        icon: "wifi.exclamationmark",
        checks: PortalProbes.checks.map { HealthCheck(label: $0.label, detail: $0.url, status: .pending, result: "—") }
    )
    @Published var dnsHijack = HealthCategory(
        id: "dns",
        title: "DNS Hijacking",
        icon: "arrow.triangle.swap",
        checks: [
            HealthCheck(label: "NXDOMAIN test",        detail: "Resolve a guaranteed-invalid .invalid domain. ISPs that hijack NXDOMAIN will return an IP.",     status: .pending, result: "—"),
            HealthCheck(label: "Localhost protection", detail: "Resolve localhost — should always be 127.0.0.1.",                                                  status: .pending, result: "—"),
            HealthCheck(label: "DoH comparison",       detail: "Compare system resolver vs Cloudflare DoH for example.com.",                                       status: .pending, result: "—"),
        ]
    )
    @Published var proxy = HealthCategory(
        id: "proxy",
        title: "Transparent Proxy",
        icon: "shield.lefthalf.filled.badge.checkmark",
        checks: [
            HealthCheck(label: "Strict 204",          detail: "gstatic.com/generate_204 must return exactly 204 with empty body.",                                 status: .pending, result: "—"),
            HealthCheck(label: "Proxy headers",       detail: "Look for Via / X-Forwarded-For / X-Cache on a plain HTTP request.",                                 status: .pending, result: "—"),
            HealthCheck(label: "Cloudflare trace",    detail: "1.1.1.1/cdn-cgi/trace returns a known plaintext format; unexpected wrapping suggests interception.", status: .pending, result: "—"),
        ]
    )
    @Published var portBlocking = HealthCategory(
        id: "ports",
        title: "Outbound Port Blocking",
        icon: "network",
        checks: PortBlockingChecks.checks.map { c in
            HealthCheck(label: "TCP \(c.port) \(c.serviceName)",
                        detail: "Connect to \(c.host):\(c.port).",
                        status: .pending,
                        result: "—")
        }
    )

    @Published var isRunning = false
    @Published var lastChecked: Date? = nil

    var overallVerdict: HealthVerdict? {
        guard let _ = lastChecked else { return nil }
        let categories = [captivePortal, dnsHijack, proxy, portBlocking]
        let maxSev = categories.map { $0.aggregate.severity }.max() ?? 0
        switch maxSev {
        case 0:
            return HealthVerdict(title: "Clean Network",
                                 detail: "All checks pass — direct, unrestricted internet access.",
                                 icon: "checkmark.shield.fill",
                                 color: NS.green)
        case 1:
            let warnCats = categories.filter { $0.aggregate == .warning }.map { $0.title }.joined(separator: ", ")
            return HealthVerdict(title: "Suspicious",
                                 detail: "\(warnCats): something off but not blocked outright.",
                                 icon: "exclamationmark.shield.fill",
                                 color: NS.amber)
        default:
            let failCats = categories.filter { $0.aggregate == .fail }.map { $0.title }.joined(separator: ", ")
            return HealthVerdict(title: "Restricted",
                                 detail: "\(failCats): network is filtering or intercepting traffic.",
                                 icon: "xmark.shield.fill",
                                 color: NS.red)
        }
    }

    func runAll() {
        guard !isRunning else { return }
        isRunning = true
        resetCategories()

        Task {
            async let portalDone:    Void = runCaptivePortal()
            async let dnsDone:       Void = runDNSHijack()
            async let proxyDone:     Void = runProxy()
            async let portsDone:     Void = runPortBlocking()
            _ = await (portalDone, dnsDone, proxyDone, portsDone)
            isRunning = false
            lastChecked = Date()
        }
    }

    private func resetCategories() {
        for i in captivePortal.checks.indices { captivePortal.checks[i].status = .pending; captivePortal.checks[i].result = "—" }
        for i in dnsHijack.checks.indices     { dnsHijack.checks[i].status = .pending;     dnsHijack.checks[i].result = "—" }
        for i in proxy.checks.indices         { proxy.checks[i].status = .pending;         proxy.checks[i].result = "—" }
        for i in portBlocking.checks.indices  { portBlocking.checks[i].status = .pending;  portBlocking.checks[i].result = "—" }
    }

    // MARK: 1) Captive Portal

    private func runCaptivePortal() async {
        await withTaskGroup(of: (Int, HealthStatus, String).self) { group in
            for (i, ep) in PortalProbes.checks.enumerated() {
                group.addTask { await PortalProbes.run(index: i, endpoint: ep) }
            }
            for await (i, status, result) in group {
                if i < captivePortal.checks.count {
                    captivePortal.checks[i].status = status
                    captivePortal.checks[i].result = result
                }
            }
        }
    }

    // MARK: 2) DNS Hijacking

    private func runDNSHijack() async {
        // 0: NXDOMAIN test
        let nx = await DNSHijackProbes.nxdomainTest()
        dnsHijack.checks[0].status = nx.status
        dnsHijack.checks[0].result = nx.result

        // 1: localhost
        let lh = await DNSHijackProbes.localhostTest()
        dnsHijack.checks[1].status = lh.status
        dnsHijack.checks[1].result = lh.result

        // 2: DoH comparison
        let doh = await DNSHijackProbes.dohComparison()
        dnsHijack.checks[2].status = doh.status
        dnsHijack.checks[2].result = doh.result
    }

    // MARK: 3) Transparent Proxy

    private func runProxy() async {
        let strict = await ProxyProbes.strictGenerate204()
        proxy.checks[0].status = strict.status
        proxy.checks[0].result = strict.result

        let headers = await ProxyProbes.proxyHeaders()
        proxy.checks[1].status = headers.status
        proxy.checks[1].result = headers.result

        let cf = await ProxyProbes.cloudflareTrace()
        proxy.checks[2].status = cf.status
        proxy.checks[2].result = cf.result
    }

    // MARK: 4) Port Blocking

    private func runPortBlocking() async {
        await withTaskGroup(of: (Int, HealthStatus, String).self) { group in
            for (i, c) in PortBlockingChecks.checks.enumerated() {
                group.addTask { await PortBlockingChecks.run(index: i, check: c) }
            }
            for await (i, status, result) in group {
                if i < portBlocking.checks.count {
                    portBlocking.checks[i].status = status
                    portBlocking.checks[i].result = result
                }
            }
        }
    }

    // MARK: Export

    func exportText() -> String {
        var out = "Network Health — \(lastChecked?.formatted() ?? "n/a")\n"
        if let v = overallVerdict { out += "Verdict: \(v.title) — \(v.detail)\n" }
        out += String(repeating: "—", count: 70) + "\n"
        for cat in [captivePortal, dnsHijack, proxy, portBlocking] {
            out += "\n[\(cat.title)] \(cat.summaryText)\n"
            for c in cat.checks {
                out += String(format: "  %-22s  %-10s  %@\n",
                              (c.label as NSString).utf8String!,
                              (c.status.label as NSString).utf8String!,
                              c.result)
            }
        }
        return out
    }
}

// MARK: - Probes: Captive Portal

private enum PortalProbes {
    struct Endpoint {
        let label: String
        let url: String
        let expectStatus: Int
        let expectBodyContains: String?
    }

    static let checks: [Endpoint] = [
        Endpoint(label: "Apple",       url: "http://captive.apple.com/hotspot-detect.html",
                 expectStatus: 200, expectBodyContains: "<HTML><HEAD><TITLE>Success</TITLE>"),
        Endpoint(label: "Apple HTTPS", url: "https://captive.apple.com/hotspot-detect.html",
                 expectStatus: 200, expectBodyContains: "Success"),
        Endpoint(label: "Microsoft",   url: "http://www.msftconnecttest.com/connecttest.txt",
                 expectStatus: 200, expectBodyContains: "Microsoft Connect Test"),
        Endpoint(label: "Cloudflare",  url: "http://cp.cloudflare.com/",
                 expectStatus: 204, expectBodyContains: nil),
        Endpoint(label: "Google",      url: "http://www.gstatic.com/generate_204",
                 expectStatus: 204, expectBodyContains: nil),
        Endpoint(label: "Firefox",     url: "http://detectportal.firefox.com/success.txt",
                 expectStatus: 200, expectBodyContains: "success"),
    ]

    static func run(index: Int, endpoint: Endpoint) async -> (Int, HealthStatus, String) {
        guard let url = URL(string: endpoint.url) else {
            return (index, .fail, "Bad URL")
        }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        req.timeoutInterval = 5
        req.setValue("CaptiveNetworkSupport-407.40.1 wispr", forHTTPHeaderField: "User-Agent")

        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: cfg, delegate: NoRedirectDelegate.shared, delegateQueue: nil)

        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                return (index, .fail, "Non-HTTP response")
            }
            let body = String(data: data.prefix(512), encoding: .utf8) ?? ""
            let codeMatches = http.statusCode == endpoint.expectStatus
            let bodyMatches: Bool = {
                if let needle = endpoint.expectBodyContains { return body.contains(needle) }
                return data.isEmpty
            }()
            if (300..<400).contains(http.statusCode), let loc = http.value(forHTTPHeaderField: "Location") {
                return (index, .fail, "redirect → \(loc.prefix(80))")
            }
            if codeMatches && bodyMatches {
                return (index, .ok, "expected \(http.statusCode), \(data.count)B body")
            } else {
                return (index, .fail, "got \(http.statusCode), unexpected body (\(data.count)B)")
            }
        } catch {
            return (index, .fail, error.localizedDescription)
        }
    }
}

// MARK: - Probes: DNS Hijacking

private enum DNSHijackProbes {
    struct ProbeResult { let status: HealthStatus; let result: String }

    /// Resolve a random `.invalid` subdomain via the system resolver. The
    /// `.invalid` TLD is reserved (RFC 2606) and must never resolve. If we
    /// get an A record, the resolver is hijacking NXDOMAIN — common ISP
    /// behavior for advertising / phishing-protection pages.
    static func nxdomainTest() async -> ProbeResult {
        let suffix = UUID().uuidString.split(separator: "-").first.map(String.init) ?? "test"
        let host = "snap-nxdomain-\(suffix.lowercased()).invalid"
        let ips = await systemResolveIPv4(host)
        if ips.isEmpty {
            return ProbeResult(status: .ok, result: "NXDOMAIN as expected")
        }
        return ProbeResult(status: .fail, result: "Hijacked → \(ips.joined(separator: ", "))")
    }

    /// `localhost` must resolve to 127.0.0.1 / ::1. Anything else means a
    /// resolver is wildcard-rewriting or DNS-poisoning the namespace.
    static func localhostTest() async -> ProbeResult {
        let ips = await systemResolveIPv4("localhost")
        let expected: Set<String> = ["127.0.0.1"]
        let got = Set(ips)
        if got.isEmpty {
            return ProbeResult(status: .warning, result: "system resolver couldn't resolve localhost")
        }
        if got.isSubset(of: expected) {
            return ProbeResult(status: .ok, result: ips.joined(separator: ", "))
        }
        return ProbeResult(status: .fail, result: "Unexpected → \(ips.joined(separator: ", "))")
    }

    /// Compare system resolver against Cloudflare DoH (1.1.1.1). Geo-load
    /// balancing means CDN-fronted hostnames legitimately differ, so we
    /// look for a *partial* overlap rather than exact equality. Zero
    /// overlap on a popular hostname is suspicious.
    static func dohComparison() async -> ProbeResult {
        let target = "example.com"
        let sys = Set(await systemResolveIPv4(target))
        let doh = Set(await dohResolveIPv4(target))
        if sys.isEmpty || doh.isEmpty {
            return ProbeResult(status: .warning, result: "couldn't compare (sys=\(sys.count), doh=\(doh.count))")
        }
        // For example.com (a static IANA-reserved IP set) the answer is stable.
        if sys.isDisjoint(with: doh) {
            return ProbeResult(status: .fail, result: "sys=\(sys.sorted().joined(separator: ",")) ≠ doh=\(doh.sorted().joined(separator: ","))")
        }
        return ProbeResult(status: .ok, result: "sys ∩ doh = \(sys.intersection(doh).sorted().joined(separator: ","))")
    }

    // MARK: System resolver via getaddrinfo

    private static func systemResolveIPv4(_ host: String) async -> [String] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: blockingResolve(host))
            }
        }
    }

    private static func blockingResolve(_ host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let r = res else { return [] }
        defer { freeaddrinfo(r) }
        var out: [String] = []
        var cur: UnsafeMutablePointer<addrinfo>? = r
        while let c = cur {
            defer { cur = c.pointee.ai_next }
            guard c.pointee.ai_family == AF_INET else { continue }
            var sin = c.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
            out.append(String(cString: buf))
        }
        return out
    }

    private static func dohResolveIPv4(_ host: String) async -> [String] {
        let urlStr = "https://1.1.1.1/dns-query?name=\(host)&type=A"
        guard let url = URL(string: urlStr) else { return [] }
        var req = URLRequest(url: url)
        req.setValue("application/dns-json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 5
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let answers = json["Answer"] as? [[String: Any]] else { return [] }
            return answers.compactMap { ans -> String? in
                guard (ans["type"] as? Int) == 1 else { return nil }
                return ans["data"] as? String
            }
        } catch {
            return []
        }
    }
}

// MARK: - Probes: Transparent Proxy

private enum ProxyProbes {
    struct ProbeResult { let status: HealthStatus; let result: String }

    /// `generate_204` must return *exactly* status 204 with empty body. A
    /// proxy that injects an interstitial (corporate captive page, ad
    /// rewriter, etc.) will fail at least one of those.
    static func strictGenerate204() async -> ProbeResult {
        guard let url = URL(string: "http://www.gstatic.com/generate_204") else {
            return ProbeResult(status: .fail, result: "Bad URL")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let cfg = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: cfg, delegate: NoRedirectDelegate.shared, delegateQueue: nil)
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                return ProbeResult(status: .fail, result: "Non-HTTP response")
            }
            if http.statusCode == 204 && data.isEmpty {
                return ProbeResult(status: .ok, result: "204, 0 bytes")
            }
            return ProbeResult(status: .fail, result: "got \(http.statusCode), \(data.count) bytes — proxy injecting content")
        } catch {
            return ProbeResult(status: .warning, result: error.localizedDescription)
        }
    }

    /// Look for `Via:`, `X-Forwarded-For:`, `X-Cache:`, `X-Proxy-ID:` on a
    /// plain HTTP response from a known endpoint. We didn't add those, so
    /// any presence means a proxy on the path inserted them.
    static func proxyHeaders() async -> ProbeResult {
        guard let url = URL(string: "http://www.gstatic.com/generate_204") else {
            return ProbeResult(status: .fail, result: "Bad URL")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        let cfg = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: cfg, delegate: NoRedirectDelegate.shared, delegateQueue: nil)
        do {
            let (_, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                return ProbeResult(status: .fail, result: "Non-HTTP response")
            }
            let suspectHeaders = ["Via", "X-Forwarded-For", "X-Cache", "X-Proxy-ID", "X-Forwarded-By", "Proxy-Connection", "X-Cdn", "X-BlueCoat-Via"]
            var hits: [String] = []
            for h in suspectHeaders {
                if let v = http.value(forHTTPHeaderField: h), !v.isEmpty {
                    hits.append("\(h): \(v.prefix(40))")
                }
            }
            if hits.isEmpty {
                return ProbeResult(status: .ok, result: "no proxy headers present")
            }
            // Some CDNs legitimately add X-Cache (Cloudflare). gstatic doesn't.
            return ProbeResult(status: .warning, result: hits.joined(separator: " · "))
        } catch {
            return ProbeResult(status: .warning, result: error.localizedDescription)
        }
    }

    /// Cloudflare's trace endpoint returns a known plaintext format with
    /// keys like `fl=`, `h=`, `ip=`, etc. If the response is wrapped in
    /// HTML or has extra prefixes, something is intercepting.
    static func cloudflareTrace() async -> ProbeResult {
        guard let url = URL(string: "https://1.1.1.1/cdn-cgi/trace") else {
            return ProbeResult(status: .fail, result: "Bad URL")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                return ProbeResult(status: .warning, result: "trace unreachable")
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            // Body must start with "fl=" (the first key) and contain "ip=" + "h=1.1.1.1"
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("fl=") && trimmed.contains("ip=") && trimmed.contains("h=1.1.1.1") {
                return ProbeResult(status: .ok, result: "trace intact")
            }
            return ProbeResult(status: .fail, result: "trace altered: \(String(body.prefix(60)))")
        } catch {
            return ProbeResult(status: .warning, result: error.localizedDescription)
        }
    }
}

// MARK: - Probes: Port Blocking

private enum PortBlockingChecks {
    struct Check {
        let port: UInt16
        let host: String
        let serviceName: String
    }

    /// Curated set of ports networks commonly filter. Each host is known
    /// to listen on its respective port — failure to connect = network is
    /// blocking outbound, not the host being down.
    static let checks: [Check] = [
        Check(port: 22,    host: "github.com",        serviceName: "SSH"),
        Check(port: 25,    host: "smtp.gmail.com",    serviceName: "SMTP"),
        Check(port: 53,    host: "1.1.1.1",           serviceName: "DNS"),
        Check(port: 80,    host: "cloudflare.com",    serviceName: "HTTP"),
        Check(port: 443,   host: "cloudflare.com",    serviceName: "HTTPS"),
        Check(port: 465,   host: "smtp.gmail.com",    serviceName: "SMTPS"),
        Check(port: 587,   host: "smtp.gmail.com",    serviceName: "Submission"),
        Check(port: 993,   host: "imap.gmail.com",    serviceName: "IMAPS"),
        Check(port: 995,   host: "pop.gmail.com",     serviceName: "POP3S"),
        Check(port: 3478,  host: "stun.l.google.com", serviceName: "STUN"),
    ]

    static func run(index: Int, check: Check) async -> (Int, HealthStatus, String) {
        let (ok, ms) = await tcpConnect(host: check.host, port: check.port, timeout: 3.0)
        if ok {
            return (index, .ok, "open · \(Int(ms)) ms")
        }
        // 443 / 80 to a major CDN failing is essentially a network outage;
        // surface this differently from "intentionally blocked".
        let severity: HealthStatus = (check.port == 80 || check.port == 443) ? .warning : .fail
        return (index, severity, "blocked or unreachable")
    }

    /// TCP connect with timeout via non-blocking socket + select().
    private static func tcpConnect(host: String, port: UInt16, timeout: TimeInterval) async -> (ok: Bool, ms: Double) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: blockingConnect(host: host, port: port, timeout: timeout))
            }
        }
    }

    private static func blockingConnect(host: String, port: UInt16, timeout: TimeInterval) -> (Bool, Double) {
        // Resolve host first via getaddrinfo (one IP — try A records only)
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        let portStr = String(port)
        guard getaddrinfo(host, portStr, &hints, &res) == 0, let r = res else { return (false, 0) }
        defer { freeaddrinfo(r) }

        let sock = Darwin.socket(r.pointee.ai_family, r.pointee.ai_socktype, r.pointee.ai_protocol)
        guard sock >= 0 else { return (false, 0) }
        defer { Darwin.close(sock) }

        // Non-blocking mode so connect() can be timed
        let flags = fcntl(sock, F_GETFL, 0)
        _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)

        let t0 = Date()
        let cr = Darwin.connect(sock, r.pointee.ai_addr, r.pointee.ai_addrlen)
        if cr == 0 {
            return (true, Date().timeIntervalSince(t0) * 1000)
        }
        // EINPROGRESS = in-flight; wait via select
        guard errno == EINPROGRESS else { return (false, 0) }

        var writeSet = fd_set()
        SnapFDZero(&writeSet)
        SnapFDSet(sock, &writeSet)
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
        let sel = select(sock + 1, nil, &writeSet, nil, &tv)
        guard sel > 0 else { return (false, 0) }

        // Verify the connect actually succeeded (SO_ERROR == 0)
        var so_err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        let go = getsockopt(sock, SOL_SOCKET, SO_ERROR, &so_err, &len)
        if go == 0 && so_err == 0 {
            return (true, Date().timeIntervalSince(t0) * 1000)
        }
        return (false, 0)
    }
}

// FD_ZERO / FD_SET aren't directly importable to Swift; replicate by hand
// using the published layout of fd_set (a fixed-size bitfield).
private func SnapFDZero(_ set: inout fd_set) {
    set.fds_bits = (0, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, 0)
}

private func SnapFDSet(_ fd: Int32, _ set: inout fd_set) {
    let intOffset = Int(fd) / 32
    let bitOffset = Int(fd) % 32
    let mask: Int32 = 1 << bitOffset
    withUnsafeMutablePointer(to: &set.fds_bits) { ptr in
        ptr.withMemoryRebound(to: Int32.self, capacity: 32) { p in
            p[intOffset] |= mask
        }
    }
}

// MARK: - URLSession delegate that refuses to follow redirects
// A redirect on a captive-portal probe URL IS the captive portal signature,
// so we need to inspect it ourselves rather than let URLSession chase it.

final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    static let shared = NoRedirectDelegate()
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
