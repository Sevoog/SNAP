// UniFiControllerView.swift
// SNAP — UniFi Network Controller API integration
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
//
// Connects to a UniFi controller (modern UDM/UDM-Pro/Cloud Key running the
// Network application, or a legacy standalone controller) and pulls the
// device inventory the controller has adopted.
//
// Solves the v1.2.2 LAN-probe ceiling: gear sitting on VLANs the SNAP host
// can't reach is still visible to the controller, so we get cross-VLAN
// visibility without raw-socket tricks.
//
// Two API shapes are supported:
//
//   • Modern (UDM / Cloud Key Gen2+ / Self-hosted Network application v6+):
//       POST /api/auth/login         → cookie + X-CSRF-Token header
//       GET  /proxy/network/api/s/<site>/stat/device
//
//   • Legacy (standalone UniFi Controller pre-Network-app split):
//       POST /api/login              → unifises cookie
//       GET  /api/s/<site>/stat/device
//
// TLS is trust-on-first-use. UniFi ships a self-signed cert, so a certificate
// macOS doesn't trust is allowed only if it matches the SHA-256 fingerprint
// the user approved on first connect (`UniFiPinningDelegate`). An unknown or
// changed certificate cancels the TLS handshake — before the login request,
// and therefore the credentials, are ever sent. Publicly-trusted certs pass
// normal validation and are never pinned. Credentials are persisted to the
// macOS Keychain.

import SwiftUI
import Security
import CryptoKit

// MARK: - Device row

struct UniFiDevice: Identifiable, Hashable {
    let id: String                  // mac
    let mac: String
    let name: String
    let model: String
    let modelDescription: String?
    let ip: String
    let type: String                // uap, usw, ugw, udm, …
    let role: DeviceRole
    let firmware: String
    let adopted: Bool
    let stateLabel: String          // connected / disconnected / pending …
    let uptime: TimeInterval        // seconds
    let lastSeen: Date?
    let satelliteParent: String?    // mesh AP only
}

// MARK: - Keychain helpers

private enum UniFiKeychain {
    private static let service = "com.bardaklabs.snap.unifi"

    static func save(host: String, username: String, password: String) {
        // Stored under key "<host>|<username>" so multiple controllers can
        // coexist (one set per host+user). We only support one at a time
        // in the UI today; this keeps the door open.
        let key = "\(host)|\(username)"
        let data = password.data(using: .utf8) ?? Data()
        delete(key: key)
        let attrs: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String:   data,
        ]
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func load(host: String, username: String) -> String? {
        let key = "\(host)|\(username)"
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let s = String(data: data, encoding: .utf8) else {
            return nil
        }
        return s
    }

    static func delete(key: String) {
        let q: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(q as CFDictionary)
    }
}

// MARK: - Certificate pinning (trust on first use)

/// The leaf certificate a controller presented, reduced to what the user
/// needs to recognize it.
struct UniFiCertificate: Equatable, Sendable {
    /// SHA-256 of the DER-encoded leaf, as colon-separated uppercase hex —
    /// the same format browsers show in their certificate viewers.
    let fingerprint: String
    let subject: String

    init?(trust: SecTrust) {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        fingerprint = SHA256.hash(data: der)
            .map { String(format: "%02X", $0) }
            .joined(separator: ":")
        subject = (SecCertificateCopySubjectSummary(leaf) as String?) ?? "(no subject)"
    }
}

/// Approved fingerprints, keyed by "host:port". Fingerprints aren't secret,
/// so UserDefaults (not the Keychain) is the right home.
enum UniFiCertPins {
    private static let key = "unifi.certPins"

    private static func hostKey(_ url: URL) -> String {
        "\(url.host?.lowercased() ?? ""):\(url.port ?? 443)"
    }

    private static var all: [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    static func fingerprint(for url: URL) -> String? {
        all[hostKey(url)]
    }

    static func pin(_ fingerprint: String, for url: URL) {
        var d = all
        d[hostKey(url)] = fingerprint
        UserDefaults.standard.set(d, forKey: key)
    }

    static func forget(_ url: URL) {
        var d = all
        d.removeValue(forKey: hostKey(url))
        UserDefaults.standard.set(d, forKey: key)
    }
}

/// TLS policy for the UniFi client — replaces `PermissiveTLS` here because
/// this session carries admin credentials. A publicly-trusted certificate
/// passes normal validation. Anything else must match the pinned fingerprint;
/// otherwise the challenge is cancelled, which aborts the handshake before
/// any request body is written, and the certificate is recorded so the
/// client can ask the user about it.
final class UniFiPinningDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let pinnedFingerprint: String?
    private let lock = NSLock()
    private var rejected: UniFiCertificate?

    init(pinnedFingerprint: String?) {
        self.pinnedFingerprint = pinnedFingerprint
    }

    /// The certificate most recently refused, if any. Clears it.
    func takeRejected() -> UniFiCertificate? {
        lock.lock(); defer { lock.unlock() }
        let r = rejected
        rejected = nil
        return r
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if SecTrustEvaluateWithError(trust, nil) {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard let cert = UniFiCertificate(trust: trust) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        if let pin = pinnedFingerprint, pin == cert.fingerprint {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        lock.lock(); rejected = cert; lock.unlock()
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}

// MARK: - Controller client

actor UniFiClient {

    enum APIShape { case modern, legacy }

    enum ClientError: Error, CustomStringConvertible {
        case badURL
        case http(Int, String)
        case decode(String)
        case unauthenticated
        /// The controller requested a 2FA token. The connect UI should
        /// reveal/prompt for the TOTP / SMS code and retry.
        case twoFactorRequired
        /// The controller's certificate isn't publicly trusted and doesn't
        /// match the pinned one (`previous` is nil on first contact). The
        /// handshake was aborted; nothing was sent.
        case untrustedCertificate(UniFiCertificate, previous: String?)
        var description: String {
            switch self {
            case .badURL:                return "Bad controller URL"
            case .http(let c, let m):    return "HTTP \(c) — \(m)"
            case .decode(let m):         return "Decode failed: \(m)"
            case .unauthenticated:       return "Not authenticated"
            case .twoFactorRequired:     return "This account has 2FA enabled — enter the 6-digit code and Connect again"
            case .untrustedCertificate(_, let previous):
                return previous == nil
                    ? "Controller certificate not trusted yet — nothing was sent"
                    : "Controller certificate changed since you trusted it — nothing was sent"
            }
        }
    }

    private let host: URL
    private let username: String
    private let password: String
    private let twoFactorCode: String
    private let site: String
    private let session: URLSession
    private let tls: UniFiPinningDelegate
    private var shape: APIShape = .modern
    private var csrfToken: String?
    /// Cookies harvested from the login response, sent verbatim on every
    /// subsequent request. Bypasses URLSession's cookie jar entirely so we
    /// don't get bitten by domain/path/policy quirks.
    private var sessionCookies: [String: String] = [:]

    init(host: URL, username: String, password: String,
         twoFactorCode: String = "", site: String = "default",
         pinnedFingerprint: String?) {
        self.host = host
        self.username = username
        self.password = password
        self.twoFactorCode = twoFactorCode
        self.site = site
        let tls = UniFiPinningDelegate(pinnedFingerprint: pinnedFingerprint)
        self.tls = tls
        let config = URLSessionConfiguration.default
        // Own cookie jar so we don't pollute the user's shared storage.
        // Accept-policy MUST be .always — the default .onlyFromMainDocumentDomain
        // drops the UniFi TOKEN cookie in non-document contexts, which is
        // what causes "Not authenticated" on the first API call after login.
        config.httpCookieStorage = HTTPCookieStorage()
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        config.timeoutIntervalForRequest = 6
        self.session = URLSession(configuration: config,
                                  delegate: tls,
                                  delegateQueue: nil)
    }

    /// Every request goes through here so a refused certificate surfaces as
    /// `.untrustedCertificate` instead of a bare "cancelled" URL error.
    private func send(_ req: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: req)
        } catch {
            if let cert = tls.takeRejected() {
                throw ClientError.untrustedCertificate(cert, previous: tls.pinnedFingerprint)
            }
            throw error
        }
    }

    // MARK: Auth

    func login() async throws {
        // Try modern shape first.
        do {
            try await loginModern()
            shape = .modern
            return
        } catch ClientError.http(let code, _) where code == 404 || code == 405 {
            // Fall through to legacy — modern endpoint not present on
            // pre-Network-app controllers.
        } catch ClientError.twoFactorRequired {
            throw ClientError.twoFactorRequired
        } catch ClientError.http(let code, let m) where code == 401 {
            throw ClientError.http(code, m)
        }
        // Legacy fallback.
        try await loginLegacy()
        shape = .legacy
    }

    /// The `Origin` value the controller expects, derived from the user's
    /// configured host. UniFi OS's NGINX proxy enforces `Origin`/`Referer`
    /// checks on `/api/auth/login` and `/api/login` and rejects requests
    /// without them with **HTTP 403** before validating credentials —
    /// matching what browsers naturally send.
    private var originHeader: String {
        var s = host.scheme ?? "https"
        s += "://"
        s += host.host ?? ""
        if let p = host.port { s += ":\(p)" }
        return s
    }

    /// Stamp the headers every UniFi request needs: `Origin`, `Referer`,
    /// `User-Agent`, `Accept`, plus the CSRF token and session Cookie on
    /// follow-up calls.
    private func stamp(_ req: inout URLRequest, includeAuth: Bool = false) {
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(originHeader, forHTTPHeaderField: "Origin")
        req.setValue(originHeader + "/", forHTTPHeaderField: "Referer")
        req.setValue("SNAP/1.4 (macOS; UniFi client)", forHTTPHeaderField: "User-Agent")
        if includeAuth {
            if let c = csrfToken { req.setValue(c, forHTTPHeaderField: "X-CSRF-Token") }
            if !sessionCookies.isEmpty {
                let header = sessionCookies.map { "\($0.key)=\($0.value)" }
                                            .joined(separator: "; ")
                req.setValue(header, forHTTPHeaderField: "Cookie")
            }
        }
    }

    /// Pull every Set-Cookie out of a response into our explicit jar.
    /// UniFi controllers can emit several at once (TOKEN, csrf_token,
    /// unifises). We keep all of them so the next request has full state.
    private func captureCookies(from http: HTTPURLResponse) {
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { acc, kv in
            if let k = kv.key as? String, let v = kv.value as? String { acc[k] = v }
        }
        let baseURL = http.url ?? host
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: baseURL)
        for c in cookies {
            sessionCookies[c.name] = c.value
        }
    }

    /// Capture the CSRF token from a login response. UniFi has shipped
    /// three different conventions across firmware versions:
    ///
    /// 1. **Modern Network app**: `X-CSRF-Token` (or lowercase) header on
    ///    the login response.
    /// 2. **UniFi OS (UDM/UDM-Pro/Cloud Key Gen2+)**: token embedded as a
    ///    `csrfToken` claim *inside* the JWT in the `TOKEN` cookie.
    /// 3. Some hybrid versions: both.
    ///
    /// We try header first, then fall back to JWT-from-cookie. Without
    /// this, every API call after login returns 401 "Not authenticated".
    private func captureCSRF(from http: HTTPURLResponse) {
        if let h = http.value(forHTTPHeaderField: "X-CSRF-Token"), !h.isEmpty {
            self.csrfToken = h; return
        }
        if let h = http.value(forHTTPHeaderField: "x-csrf-token"), !h.isEmpty {
            self.csrfToken = h; return
        }
        // Some firmware versions ship the CSRF token as a standalone cookie
        // rather than embedding it in the JWT.
        if let v = sessionCookies["csrf_token"], !v.isEmpty {
            self.csrfToken = v; return
        }
        // UniFi OS embeds the CSRF inside the TOKEN JWT's payload.
        if let jwt = sessionCookies["TOKEN"], let csrf = Self.csrfFromJWT(jwt) {
            self.csrfToken = csrf; return
        }
    }

    /// Best-effort `csrfToken` extraction from a JWT body. Returns nil if
    /// the payload isn't JSON-with-csrfToken — which is harmless: GET calls
    /// will simply omit the header and fail/succeed based on whether the
    /// controller enforces CSRF on reads.
    private static func csrfFromJWT(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        let payload = String(parts[1])
        // base64url → base64, with padding
        var b64 = payload.replacingOccurrences(of: "-", with: "+")
                         .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64.append("=") }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let csrf = obj["csrfToken"] as? String else {
            return nil
        }
        return csrf
    }

    /// Build the JSON login body. UniFi controllers expect different field
    /// names across versions for 2FA — we send both `token` (modern Network
    /// app) and `ubic_2fa_token` (older UniFi OS) when a code is supplied.
    private func loginBody() throws -> Data {
        var body: [String: Any] = [
            "username": username,
            "password": password,
            "remember": true,
        ]
        let code = twoFactorCode.trimmingCharacters(in: .whitespaces)
        if !code.isEmpty {
            body["token"] = code
            body["ubic_2fa_token"] = code
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// Heuristic: did the controller tell us this account needs 2FA?
    /// - HTTP 499 is NGINX's "client closed request" status that UniFi OS
    ///   reuses to signal MFA-required.
    /// - HTTP 401 with a body containing `required_2fa` or `ubic_2fa_token`
    ///   is the older Network-app shape.
    private static func bodyImpliesMFA(_ data: Data) -> Bool {
        guard let s = String(data: data, encoding: .utf8)?.lowercased() else { return false }
        return s.contains("required_2fa")
            || s.contains("ubic_2fa_token")
            || s.contains("mfa")
            || s.contains("two_factor")
    }

    /// Extract the most informative human-readable error from a UniFi
    /// response body. UniFi wraps errors in `{"meta":{"rc":"error","msg":"…"}}`
    /// for the legacy/Network-app shape and `{"errors":[{"id":"…"}]}` or
    /// `{"errorCode":N,"message":"…"}` for the UniFi OS shape.
    private static func extractErrorMessage(_ data: Data) -> String? {
        guard !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            // Fall back to raw text if the body isn't JSON.
            if let s = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                return String(s.prefix(160))
            }
            return nil
        }
        // Network-app / legacy: { meta: { rc: "error", msg: "api.err.…" } }
        if let meta = obj["meta"] as? [String: Any],
           let msg = meta["msg"] as? String, !msg.isEmpty {
            return humanizeUniFiCode(msg)
        }
        // UniFi OS new shape: { errorCode: N, message: "…" }
        if let m = obj["message"] as? String, !m.isEmpty { return m }
        if let errs = obj["errors"] as? [[String: Any]], let first = errs.first,
           let id = first["id"] as? String { return humanizeUniFiCode(id) }
        return nil
    }

    /// Translate the most common UniFi `api.err.*` codes into something a
    /// human can act on.
    private static func humanizeUniFiCode(_ raw: String) -> String {
        switch raw.lowercased() {
        case let s where s.contains("toomany"):       return "\(raw) — account temporarily locked from repeated failed logins. Wait 10-15 minutes and retry."
        case let s where s.contains("invalid"):       return "\(raw) — bad username, password, or 2FA code."
        case let s where s.contains("loginrequired"): return "\(raw) — account may be locked or session expired. Wait 10-15 minutes."
        case let s where s.contains("nopermission"):  return "\(raw) — account is disabled or lacks permission for the Network API."
        case let s where s.contains("ubic_2fa"),
             let s where s.contains("required_2fa"),
             let s where s.contains("mfa"):           return "\(raw) — 2FA required"
        default:                                       return raw
        }
    }

    private func loginModern() async throws {
        guard let url = URL(string: "/api/auth/login", relativeTo: host) else { throw ClientError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        stamp(&req)
        req.httpBody = try loginBody()
        let (data, resp) = try await send(req)
        guard let http = resp as? HTTPURLResponse else { throw ClientError.decode("not HTTP") }
        if http.statusCode == 200 {
            captureCookies(from: http)
            captureCSRF(from: http)
            return
        }
        // UniFi OS uses 499 for MFA-required. Older Network app uses 401
        // with a body hint. In both cases we surface twoFactorRequired so
        // the UI can prompt for the code.
        if http.statusCode == 499 || (http.statusCode == 401 && Self.bodyImpliesMFA(data)) {
            // Only signal "needs 2FA" if we *didn't* already supply one — if
            // we did and still got rejected, the code itself is wrong.
            if twoFactorCode.trimmingCharacters(in: .whitespaces).isEmpty {
                throw ClientError.twoFactorRequired
            }
            throw ClientError.http(http.statusCode, Self.extractErrorMessage(data) ?? "2FA code rejected")
        }
        // Surface the controller's actual error message body so users can
        // see "api.err.LoginRequired" (lockout) vs "api.err.Invalid" (bad
        // credentials) etc. instead of a generic "login failed".
        let detail = Self.extractErrorMessage(data) ?? "login failed"
        throw ClientError.http(http.statusCode, detail)
    }

    private func loginLegacy() async throws {
        guard let url = URL(string: "/api/login", relativeTo: host) else { throw ClientError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        stamp(&req)
        req.httpBody = try loginBody()
        let (data, resp) = try await send(req)
        guard let http = resp as? HTTPURLResponse else { throw ClientError.decode("not HTTP") }
        if http.statusCode == 200 {
            captureCookies(from: http)
            captureCSRF(from: http)
            return
        }
        if http.statusCode == 499 || (http.statusCode == 401 && Self.bodyImpliesMFA(data)) {
            if twoFactorCode.trimmingCharacters(in: .whitespaces).isEmpty {
                throw ClientError.twoFactorRequired
            }
            throw ClientError.http(http.statusCode, Self.extractErrorMessage(data) ?? "2FA code rejected")
        }
        let detail = Self.extractErrorMessage(data) ?? "login failed (legacy)"
        throw ClientError.http(http.statusCode, detail)
    }

    // MARK: Devices

    func devices() async throws -> [UniFiDevice] {
        let path = (shape == .modern)
            ? "/proxy/network/api/s/\(site)/stat/device"
            : "/api/s/\(site)/stat/device"
        guard let url = URL(string: path, relativeTo: host) else { throw ClientError.badURL }
        var req = URLRequest(url: url)
        stamp(&req, includeAuth: true)
        let (data, resp) = try await send(req)
        guard let http = resp as? HTTPURLResponse else { throw ClientError.decode("not HTTP") }

        // Cookies can rotate on the response (csrf_token refresh, etc.) —
        // re-harvest so the next call carries fresh state.
        captureCookies(from: http)

        if http.statusCode == 401 {
            // Surface the actual controller error rather than the generic
            // "Not authenticated" so we can tell apart "missing CSRF",
            // "session expired", "no permission for this site", etc.
            let msg = Self.extractErrorMessage(data) ?? "session not accepted"
            throw ClientError.http(401, msg)
        }
        if http.statusCode != 200 {
            let msg = Self.extractErrorMessage(data) ?? "device list HTTP \(http.statusCode)"
            throw ClientError.http(http.statusCode, msg)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["data"] as? [[String: Any]] else {
            throw ClientError.decode("device list shape — body was: \(String(data: data.prefix(200), encoding: .utf8) ?? "(binary)")")
        }

        return arr.map { Self.parseDevice($0) }
    }

    /// Best-effort JSON → UniFiDevice. Missing fields default to "—".
    private static func parseDevice(_ d: [String: Any]) -> UniFiDevice {
        let mac = (d["mac"] as? String) ?? ""
        let name = (d["name"] as? String) ?? (d["hostname"] as? String) ?? "—"
        let model = (d["model"] as? String) ?? "—"
        let modelDescr = d["model_in_eol"] as? String
            ?? d["model_in_lts"] as? String
            ?? d["model_in_xc"] as? String
        let ip = (d["ip"] as? String) ?? "—"
        let type = (d["type"] as? String) ?? "—"
        let firmware = (d["version"] as? String) ?? ""
        let adopted = (d["adopted"] as? Bool) ?? false
        let stateRaw = (d["state"] as? Int) ?? -1
        let stateLabel: String = {
            switch stateRaw {
            case 0: return "Disconnected"
            case 1: return "Connected"
            case 2: return "Pending"
            case 4: return "Upgrading"
            case 5: return "Provisioning"
            case 6: return "Heartbeat-missed"
            case 7: return "Adopting"
            case 11: return "Isolated"
            default: return adopted ? "Adopted" : "—"
            }
        }()
        let uptime = (d["uptime"] as? Double) ?? 0
        let lastSeenSec = (d["last_seen"] as? Double)
        let lastSeen = lastSeenSec.map { Date(timeIntervalSince1970: $0) }
        let satelliteParent = d["uplink_remote_port"] != nil
            ? (d["uplink"] as? [String: Any])?["uplink_mac"] as? String
            : nil

        return UniFiDevice(
            id: mac,
            mac: mac.uppercased(),
            name: name,
            model: model,
            modelDescription: modelDescr,
            ip: ip,
            type: type,
            role: roleForUniFiType(type, model: model),
            firmware: firmware,
            adopted: adopted,
            stateLabel: stateLabel,
            uptime: uptime,
            lastSeen: lastSeen,
            satelliteParent: satelliteParent
        )
    }
}

/// Maps a UniFi device `type` + model to a DeviceRole.
func roleForUniFiType(_ type: String, model: String) -> DeviceRole {
    switch type {
    case "uap": return .accessPoint
    case "usw": return .networkSwitch
    case "ugw", "udm": return .router
    case "uxg": return .router
    case "uvc": return .ipCamera
    case "uph": return .voipPhone
    default:
        let m = model.uppercased()
        if m.hasPrefix("U") && m.contains("AP") { return .accessPoint }
        if m.hasPrefix("USW") { return .networkSwitch }
        if m.hasPrefix("UDM") || m.hasPrefix("UXG") { return .router }
        return .unknown
    }
}

// MARK: - Model

@MainActor
final class UniFiControllerModel: ObservableObject {

    @Published var host: String = UserDefaults.standard.string(forKey: "unifi.host") ?? "https://192.168.1.1"
    @Published var username: String = UserDefaults.standard.string(forKey: "unifi.user") ?? ""
    @Published var password: String = ""
    @Published var twoFactorCode: String = ""
    @Published var rememberCredentials: Bool = UserDefaults.standard.bool(forKey: "unifi.remember")

    @Published var connectionStatus = "Not connected"
    @Published var isConnecting = false
    @Published var errorMessage: String?
    @Published var needsTwoFactor: Bool = false      // surfaced when controller asks for MFA
    @Published var devices: [UniFiDevice] = []
    @Published var lastRefresh: Date?
    /// Set when the controller presents a certificate the user hasn't
    /// approved; drives the trust sheet.
    @Published var pendingCertificate: PendingCertificate?

    struct PendingCertificate: Identifiable {
        let id = UUID()
        let url: URL
        let cert: UniFiCertificate
        /// The fingerprint trusted before, when the certificate *changed*.
        let previousFingerprint: String?

        var hostLabel: String {
            guard let h = url.host else { return url.absoluteString }
            if let p = url.port { return "\(h):\(p)" }
            return h
        }
    }

    private var client: UniFiClient?

    init() {
        if rememberCredentials, !username.isEmpty,
           let stored = UniFiKeychain.load(host: host, username: username) {
            self.password = stored
        }
    }

    /// Fingerprint pinned for the host currently in the Host field.
    var pinnedFingerprint: String? {
        URL(string: host).flatMap { UniFiCertPins.fingerprint(for: $0) }
    }

    func connect() {
        errorMessage = nil
        guard let url = URL(string: host), url.host != nil else {
            errorMessage = "Invalid controller URL"
            return
        }
        guard url.scheme?.lowercased() == "https" else {
            errorMessage = "Use an https:// controller URL — SNAP won't send controller credentials over plain HTTP."
            return
        }
        let user = username.trimmingCharacters(in: .whitespaces)
        let pw = password
        let totp = twoFactorCode.trimmingCharacters(in: .whitespaces)
        guard !user.isEmpty else { errorMessage = "Enter username"; return }
        let pin = UniFiCertPins.fingerprint(for: url)

        isConnecting = true
        connectionStatus = "Connecting…"

        Task {
            let c = UniFiClient(host: url, username: user, password: pw,
                                twoFactorCode: totp, pinnedFingerprint: pin)
            do {
                try await c.login()
                let devs = try await c.devices()
                await MainActor.run {
                    self.client = c
                    self.devices = devs.sorted {
                        if $0.adopted != $1.adopted { return $0.adopted && !$1.adopted }
                        return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    }
                    self.connectionStatus = "Connected · \(devs.count) device\(devs.count == 1 ? "" : "s")"
                    self.isConnecting = false
                    self.lastRefresh = Date()
                    self.needsTwoFactor = false
                    self.twoFactorCode = ""    // single-use; never persist
                    self.saveSettings()
                }
            } catch UniFiClient.ClientError.twoFactorRequired {
                await MainActor.run {
                    self.client = nil
                    self.connectionStatus = "2FA required"
                    self.needsTwoFactor = true
                    self.errorMessage = "This account has 2FA enabled — enter the 6-digit code and Connect again."
                    self.isConnecting = false
                }
            } catch UniFiClient.ClientError.untrustedCertificate(let cert, let previous) {
                await MainActor.run {
                    self.client = nil
                    self.isConnecting = false
                    self.askToTrust(cert, previous: previous, url: url)
                }
            } catch {
                await MainActor.run {
                    self.client = nil
                    self.connectionStatus = "Failed"
                    self.errorMessage = "\(error)"
                    self.isConnecting = false
                }
            }
        }
    }

    private func askToTrust(_ cert: UniFiCertificate, previous: String?, url: URL) {
        connectionStatus = previous == nil ? "Certificate not trusted yet" : "Certificate changed"
        pendingCertificate = PendingCertificate(url: url, cert: cert, previousFingerprint: previous)
    }

    /// User approved the certificate in the sheet: pin it and log in.
    func trustPendingCertificate() {
        guard let p = pendingCertificate else { return }
        UniFiCertPins.pin(p.cert.fingerprint, for: p.url)
        pendingCertificate = nil
        connect()
    }

    func rejectPendingCertificate() {
        guard let p = pendingCertificate else { return }
        pendingCertificate = nil
        connectionStatus = "Not connected"
        errorMessage = p.previousFingerprint == nil
            ? "Not connected — the certificate wasn't trusted. No credentials were sent."
            : "Not connected — the controller's certificate changed and wasn't re-trusted. No credentials were sent."
    }

    func forgetPinnedCertificate() {
        guard let url = URL(string: host) else { return }
        UniFiCertPins.forget(url)
        objectWillChange.send()   // pins live in UserDefaults, not @Published
    }

    func refresh() {
        guard let c = client else { connect(); return }
        Task {
            do {
                let devs = try await c.devices()
                await MainActor.run {
                    self.devices = devs.sorted {
                        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    }
                    self.lastRefresh = Date()
                    self.connectionStatus = "Connected · \(devs.count) device\(devs.count == 1 ? "" : "s")"
                }
            } catch UniFiClient.ClientError.unauthenticated,
                    UniFiClient.ClientError.http(401, _) {
                // Session expired or rejected — re-authenticate.
                await MainActor.run { self.client = nil }
                self.connect()
            } catch UniFiClient.ClientError.untrustedCertificate(let cert, let previous) {
                // Certificate changed mid-session — drop the session and ask.
                await MainActor.run {
                    self.client = nil
                    if let url = URL(string: self.host) {
                        self.askToTrust(cert, previous: previous, url: url)
                    }
                }
            } catch {
                await MainActor.run { self.errorMessage = "\(error)" }
            }
        }
    }

    func disconnect() {
        client = nil
        devices.removeAll()
        connectionStatus = "Not connected"
        lastRefresh = nil
        needsTwoFactor = false
        twoFactorCode = ""
    }

    private func saveSettings() {
        UserDefaults.standard.set(host, forKey: "unifi.host")
        UserDefaults.standard.set(username, forKey: "unifi.user")
        UserDefaults.standard.set(rememberCredentials, forKey: "unifi.remember")
        if rememberCredentials, !password.isEmpty {
            UniFiKeychain.save(host: host, username: username, password: password)
        }
    }

    // MARK: Export

    func exportText() -> String {
        var s = "UniFi Controller — \(host)\n"
        s += "site: default · \(devices.count) device\(devices.count == 1 ? "" : "s")\n\n"
        s += "name\tmac\tmodel\ttype\trole\tip\tstate\tfirmware\tuptime\n"
        for d in devices {
            s += "\(d.name)\t\(d.mac)\t\(d.model)\t\(d.type)\t\(d.role.rawValue)\t\(d.ip)\t\(d.stateLabel)\t\(d.firmware)\t\(formatUptime(d.uptime))\n"
        }
        return s
    }

    func exportCSV() -> String {
        var s = "name,mac,model,type,role,ip,state,firmware,uptime\n"
        for d in devices {
            let cells: [String] = [d.name, d.mac, d.model, d.type, d.role.rawValue,
                                   d.ip, d.stateLabel, d.firmware, formatUptime(d.uptime)]
            s += cells.map { csvEscape($0) }.joined(separator: ",") + "\n"
        }
        return s
    }

    func exportJSON() -> String {
        let items: [[String: Any]] = devices.map { d in
            [
                "name": d.name, "mac": d.mac, "model": d.model, "type": d.type,
                "role": d.role.rawValue, "ip": d.ip, "state": d.stateLabel,
                "firmware": d.firmware, "uptime_seconds": d.uptime,
                "adopted": d.adopted,
            ]
        }
        let payload: [String: Any] = [
            "controller": host,
            "site": "default",
            "captured_at": ISO8601DateFormatter().string(from: Date()),
            "devices": items,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}

/// CSV cell escape — wraps in quotes if the cell contains a comma, quote,
/// or newline. Shared across the inventory exports in NetworkMap, UniFi,
/// and BulkDiscovery.
func csvEscape(_ s: String) -> String {
    if s.contains(",") || s.contains("\"") || s.contains("\n") {
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    return s
}

func formatUptime(_ seconds: TimeInterval) -> String {
    let s = Int(seconds)
    let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
    if d > 0 { return "\(d)d \(h)h" }
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}

// MARK: - View

struct UniFiControllerView: View {
    @StateObject private var model = UniFiControllerModel()
    @ObservedObject private var themeMgr = ThemeManager.shared

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            credentialBar
            Divider().background(NS.borderMid)
            if let err = model.errorMessage { errorBanner(err) }
            deviceList
        }
        .tabNavigationTitle(.unifi)
        .sheet(item: $model.pendingCertificate) { p in
            CertificateTrustSheet(pending: p,
                                  onTrust: { model.trustPendingCertificate() },
                                  onCancel: { model.rejectPendingCertificate() })
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right.circle")
                .foregroundStyle(NS.blue)
            Text("UniFi Controller")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(NS.text1)
            Text(model.connectionStatus)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(model.devices.isEmpty ? NS.text3 : NS.green)
            if let t = model.lastRefresh {
                Text("· refreshed \(t.formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 11)).foregroundStyle(NS.text3)
            }
            Spacer()
            if !model.devices.isEmpty {
                ToolActionBar("UniFi",
                              text: { model.exportText() },
                              csv:  { model.exportCSV() },
                              json: { model.exportJSON() })
                Button("Refresh") { model.refresh() }
                    .buttonStyle(.bordered)
            }
            if model.isConnecting {
                ProgressView().controlSize(.small)
            } else if model.devices.isEmpty {
                Button("Connect") { model.connect() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
            } else {
                Button("Disconnect") { model.disconnect() }
                    .buttonStyle(.bordered).tint(.red)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(NS.bg0)
    }

    private var credentialBar: some View {
        HStack(spacing: 8) {
            Text("Host:").font(.system(size: 11)).foregroundStyle(NS.text3)
            TextField("https://controller", text: $model.host)
                .textFieldStyle(.roundedBorder).frame(width: 200)
                .disabled(!model.devices.isEmpty || model.isConnecting)
            Text("User:").font(.system(size: 11)).foregroundStyle(NS.text3)
            TextField("admin", text: $model.username)
                .textFieldStyle(.roundedBorder).frame(width: 110)
                .textContentType(.username)
                .disabled(!model.devices.isEmpty || model.isConnecting)
            Text("Pass:").font(.system(size: 11)).foregroundStyle(NS.text3)
            SecureField("", text: $model.password)
                .textFieldStyle(.roundedBorder).frame(width: 130)
                .textContentType(.password)
                .disabled(!model.devices.isEmpty || model.isConnecting)
            Text("2FA:")
                .font(.system(size: 11))
                .foregroundStyle(model.needsTwoFactor ? NS.amber : NS.text3)
            TextField("optional", text: $model.twoFactorCode)
                .textFieldStyle(.roundedBorder).frame(width: 80)
                .textContentType(.oneTimeCode)
                .disabled(!model.devices.isEmpty || model.isConnecting)
                .help("6-digit TOTP / SMS code. Leave blank if 2FA isn't enabled. Single-use — never stored.")
            Toggle("Remember", isOn: $model.rememberCredentials)
                .toggleStyle(.checkbox).font(.system(size: 11))
            Spacer()
            if let fp = model.pinnedFingerprint {
                HStack(spacing: 4) {
                    Image(systemName: "lock.shield").foregroundStyle(NS.green)
                    Text("Certificate pinned").foregroundStyle(NS.text3)
                    Button("Forget") { model.forgetPinnedCertificate() }
                        .buttonStyle(.link)
                        .disabled(!model.devices.isEmpty || model.isConnecting)
                }
                .font(.system(size: 10))
                .help("SHA-256 \(fp)\nSNAP won't send credentials if this controller's certificate changes.")
            } else {
                Text("Self-signed certs: trusted on first connect")
                    .font(.system(size: 10)).foregroundStyle(NS.text3)
                    .help("The first connection to a controller with a self-signed certificate shows its fingerprint and asks you to trust it. After that, a different certificate blocks the login before any credentials are sent.")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(NS.bg1)
    }

    private func errorBanner(_ s: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(NS.red)
            Text(s).font(.system(size: 11, design: .monospaced))
                .foregroundStyle(NS.text1).textSelection(.enabled)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(NS.red.opacity(0.08))
    }

    private var deviceList: some View {
        Group {
            if model.devices.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "antenna.radiowaves.left.and.right.circle")
                        .font(.system(size: 40)).foregroundStyle(NS.text3)
                    Text("Connect to a UniFi controller to see adopted devices across all VLANs.")
                        .font(.system(size: 12)).foregroundStyle(NS.text2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(model.devices) {
                    TableColumn("Name") { d in
                        HStack(spacing: 6) {
                            Image(systemName: d.role.icon).foregroundStyle(NS.amber).frame(width: 14)
                            Text(d.name).font(.system(.body))
                        }
                    }
                    .width(min: 140, ideal: 200)
                    TableColumn("Model", value: \.model).width(80)
                    TableColumn("MAC", value: \.mac).width(min: 140, ideal: 150)
                    TableColumn("IP", value: \.ip).width(min: 100, ideal: 130)
                    TableColumn("State") { d in
                        Text(d.stateLabel)
                            .foregroundStyle(d.stateLabel == "Connected" ? NS.green :
                                             (d.stateLabel == "Disconnected" ? NS.red : NS.text3))
                    }
                    .width(110)
                    TableColumn("Firmware", value: \.firmware).width(100)
                    TableColumn("Uptime") { d in
                        Text(formatUptime(d.uptime))
                            .font(.system(.body, design: .monospaced))
                    }
                    .width(80)
                }
            }
        }
    }
}

// MARK: - Trust sheet

/// Shown when a controller presents a certificate that isn't publicly
/// trusted and isn't pinned. Trusting is never the default action, so
/// Return can't approve a certificate by accident; Esc cancels.
private struct CertificateTrustSheet: View {
    let pending: UniFiControllerModel.PendingCertificate
    let onTrust: () -> Void
    let onCancel: () -> Void
    @ObservedObject private var themeMgr = ThemeManager.shared

    private var changed: Bool { pending.previousFingerprint != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: changed ? "exclamationmark.shield.fill" : "lock.shield")
                    .font(.system(size: 22))
                    .foregroundStyle(changed ? NS.red : NS.amber)
                Text(changed ? "Controller certificate changed" : "Trust this controller?")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(NS.text1)
            }

            Text(changed
                 ? "\(pending.hostLabel) presented a different certificate from the one you trusted. That's expected after a controller reset or certificate renewal, but it's also what an intercepted connection looks like. Nothing was sent."
                 : "\(pending.hostLabel) presented a certificate macOS doesn't recognize, which is normal for UniFi's built-in self-signed certificate. If you trust it, SNAP remembers it and refuses to send your credentials if it ever changes. Nothing has been sent yet.")
                .font(.system(size: 12))
                .foregroundStyle(NS.text2)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                field("Subject", pending.cert.subject)
                field(changed ? "New SHA-256" : "SHA-256", pending.cert.fingerprint)
                if let prev = pending.previousFingerprint {
                    field("Previously trusted SHA-256", prev)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(NS.bg1))

            Text("To verify, compare the fingerprint with the one your browser shows for the controller's certificate.")
                .font(.system(size: 11))
                .foregroundStyle(NS.text3)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(changed ? "Trust New Certificate" : "Trust & Connect", action: onTrust)
                    .buttonStyle(.borderedProminent)
                    .tint(changed ? NS.red : NS.blue)
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(NS.bg0)
    }

    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(NS.text3)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(NS.text1)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
