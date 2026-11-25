// SSLCheckerView.swift
// SNAP — SSL/TLS Checker
// Created by Sevag Bardakjian
// Copyright © 2025-2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md

import SwiftUI
import Security
import Network

struct CertInfo {
    var subject: String = ""
    var issuer: String = ""
    var serialNumber: String = ""
    var notBefore: Date?
    var notAfter: Date?
    var dnsNames: [String] = []
    var signatureAlgorithm: String = ""
    var publicKeyType: String = ""
    var isExpired: Bool = false
    var daysUntilExpiry: Int = 0
    var isSelfSigned: Bool = false
    var isTrusted: Bool = true
    var trustProblem: String = ""
    var tlsVersion: String = ""
    var cipherSuite: String = ""
    var grade: String = ""
}

struct SSLCheckerView: View {
    @State private var host = ""
    @State private var port = "443"
    @State private var certInfo: CertInfo?
    @State private var isRunning = false
    @State private var error = ""
    @State private var chainCerts: [SecCertificate] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield").foregroundStyle(.blue)
                TextField("Hostname", text: $host)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 250)
                    .onSubmit { if !host.isEmpty && !isRunning { checkSSL() } }
                Text("Port:").font(.caption).foregroundStyle(.secondary)
                TextField("", text: $port)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .onSubmit { if !host.isEmpty && !isRunning { checkSSL() } }
                Spacer()
                if let c = certInfo {
                    ToolActionBar("SSL-TLS", text: {
                        """
                        SSL/TLS check — \(host):\(port)
                        Grade:        \(c.grade)
                        Subject:      \(c.subject)
                        Issuer:       \(c.issuer)
                        Serial:       \(c.serialNumber)
                        Valid from:   \(c.notBefore.map { "\($0)" } ?? "—")
                        Valid until:  \(c.notAfter.map { "\($0)" } ?? "—")  (\(c.daysUntilExpiry) days)
                        Expired:      \(c.isExpired ? "YES" : "no")
                        Self-signed:  \(c.isSelfSigned ? "yes" : "no")
                        Trusted:      \(c.isTrusted ? "yes" : "no (\(c.trustProblem))")
                        Signature:    \(c.signatureAlgorithm)
                        Public key:   \(c.publicKeyType)
                        TLS:          \(c.tlsVersion)
                        Cipher:       \(c.cipherSuite)
                        SAN:          \(c.dnsNames.joined(separator: ", "))
                        """
                    })
                }
                if isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Check") { checkSSL() }
                        .buttonStyle(.borderedProminent)
                        .disabled(host.isEmpty)
                        .keyboardShortcut(.return)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(NS.bg0)

            Divider()

            if !error.isEmpty {
                HStack {
                    Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.red)
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Color.red.opacity(0.07))
                Divider()
            }

            ScrollView {
                if let cert = certInfo {
                    VStack(alignment: .leading, spacing: 16) {
                        // Grade badge
                        HStack {
                            gradeView(cert.grade)
                            Spacer()
                            if cert.isExpired {
                                Label("EXPIRED", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.white)
                                    .padding(6)
                                    .background(Color.red)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            } else {
                                Label("\(cert.daysUntilExpiry) \(cert.daysUntilExpiry == 1 ? "day" : "days") until expiry",
                                      systemImage: cert.daysUntilExpiry < 30 ? "exclamationmark.triangle" : "checkmark.circle")
                                    .foregroundStyle(cert.daysUntilExpiry < 30 ? .orange : .green)
                            }
                        }

                        sslSection("Certificate") {
                            sslRow("Subject", cert.subject)
                            sslRow("Issuer", cert.issuer)
                            sslRow("Serial Number", cert.serialNumber)
                            if let before = cert.notBefore {
                                sslRow("Valid From", before.formatted(date: .abbreviated, time: .shortened))
                            }
                            if let after = cert.notAfter {
                                sslRow("Expires", after.formatted(date: .abbreviated, time: .shortened))
                            }
                            sslRow("Self-Signed", cert.isSelfSigned ? "Yes ⚠️" : "No")
                            sslRow("Trusted by macOS", cert.isTrusted ? "Yes" : "No ⚠️  \(cert.trustProblem)")
                        }

                        if !cert.dnsNames.isEmpty {
                            sslSection("Subject Alternative Names") {
                                ForEach(cert.dnsNames, id: \.self) { name in
                                    sslRow("DNS", name)
                                }
                            }
                        }

                        sslSection("TLS Details") {
                            sslRow("TLS Version", cert.tlsVersion.isEmpty ? "N/A" : cert.tlsVersion)
                            sslRow("Cipher Suite", cert.cipherSuite.isEmpty ? "N/A" : cert.cipherSuite)
                            sslRow("Public Key", cert.publicKeyType)
                            sslRow("Signature Algo", cert.signatureAlgorithm)
                        }
                    }
                    .padding(20)
                } else if !isRunning && error.isEmpty {
                    EmptyStateView(title: "No Certificate Data", systemImage: "lock.shield", description: "Enter a hostname and press Check")
                }
            }
        }
        .tabNavigationTitle(.ssl)
    }

    private func checkSSL() {
        certInfo = nil
        error = ""
        // "[::1]" is how IPv6 addresses are written in URLs; the probe wants it bare.
        let targetHost = TLSProbe.unbracketed(host.trimmingCharacters(in: .whitespaces))
        // An invalid port used to become 443 silently
        guard let targetPort = TLSProbe.parsePort(port) else {
            error = TLSProbe.invalidPortMessage
            return
        }
        guard TLSProbe.isBareHost(targetHost) else {
            error = TLSProbe.notBareHostMessage
            return
        }
        isRunning = true

        Task {
            do {
                let probe = try await TLSProbe.run(host: targetHost, port: targetPort)
                guard let leaf = probe.certificates.first else {
                    throw TLSProbe.Failure(message: TLSProbe.noCertificateMessage(host: targetHost, port: targetPort))
                }
                var ci = CertParser.parse(leaf)
                ci.isTrusted = probe.trusted
                ci.trustProblem = probe.trustProblem
                ci.tlsVersion = probe.tlsVersion
                ci.cipherSuite = probe.cipherSuite
                ci.grade = computeGrade(ci)
                let result = ci
                await MainActor.run {
                    certInfo = result
                    isRunning = false
                }
            } catch {
                // Errors show only the error: no blank grade or "0 days" card
                let message = (error as? TLSProbe.Failure)?.message ?? error.localizedDescription
                await MainActor.run {
                    self.error = message
                    isRunning = false
                }
            }
        }
    }

    private func computeGrade(_ c: CertInfo) -> String {
        if c.isExpired { return "F" }
        if c.isSelfSigned || !c.isTrusted { return "C" }
        if c.daysUntilExpiry < 14 { return "B" }
        return "A"
    }

    private func gradeView(_ grade: String) -> some View {
        let color: Color = grade == "A" ? .green : grade == "B" ? .yellow : grade == "C" ? .orange : .red
        return ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(color)
                .frame(width: 60, height: 60)
            VStack(spacing: 0) {
                Text(grade).font(.system(size: 30, weight: .black)).foregroundStyle(.white)
                Text("Grade").font(.caption2).foregroundStyle(.white.opacity(0.8))
            }
        }
    }

    private func sslSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
        .padding(12)
        .background(NS.bg3)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func sslRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(key).font(.caption).foregroundStyle(.secondary).frame(width: 140, alignment: .trailing)
            Text(value).font(.caption.monospaced()).textSelection(.enabled)
            Spacer()
        }
    }
}

// MARK: - Certificate parsing

/// Reads the fields SNAP shows from a leaf certificate. SecCertificateCopyValues
/// returns names and the signature algorithm as sections (arrays of labelled
/// entries), not strings, so they're read entry by entry.
enum CertParser {
    static func parse(_ cert: SecCertificate, now: Date = Date()) -> CertInfo {
        var ci = CertInfo()
        if let summary = SecCertificateCopySubjectSummary(cert) {
            ci.subject = summary as String
        }
        if let serial = SecCertificateCopySerialNumberData(cert, nil) as Data? {
            ci.serialNumber = serial.map { String(format: "%02X", $0) }.joined(separator: ":")
        }
        if let vals = SecCertificateCopyValues(cert, nil, nil) as? [String: Any] {
            if let nb = vals[kSecOIDX509V1ValidityNotBefore as String] as? [String: Any],
               let nbVal = nb[kSecPropertyKeyValue as String] as? Double {
                ci.notBefore = Date(timeIntervalSinceReferenceDate: nbVal)
            }
            if let na = vals[kSecOIDX509V1ValidityNotAfter as String] as? [String: Any],
               let naVal = na[kSecPropertyKeyValue as String] as? Double {
                let notAfter = Date(timeIntervalSinceReferenceDate: naVal)
                ci.notAfter = notAfter
                ci.isExpired = notAfter <= now
                ci.daysUntilExpiry = daysUntilExpiry(notAfter, now: now)
            }
            let issuer = sectionEntries(vals, kSecOIDX509V1IssuerName)
            let cn = issuer.first { $0.label == "2.5.4.3" }?.value
            let org = issuer.first { $0.label == "2.5.4.10" }?.value
            switch (cn, org) {
            case let (c?, o?) where c != o: ci.issuer = "\(c) (\(o))"
            case let (c?, _):               ci.issuer = c
            case let (nil, o?):             ci.issuer = o
            default:                        ci.issuer = issuer.map(\.value).joined(separator: ", ")
            }
            // SAN section also holds a "Critical" entry, which used to show up as a DNS name
            ci.dnsNames = sectionEntries(vals, kSecOIDSubjectAltName)
                .filter { $0.label == "DNS Name" }
                .map(\.value)
            if let oid = sectionEntries(vals, kSecOIDX509V1SignatureAlgorithm).first(where: { $0.label == "Algorithm" })?.value {
                ci.signatureAlgorithm = signatureAlgorithmName(oid: oid)
            }
        }
        ci.isSelfSigned = isSelfSigned(cert)
        ci.publicKeyType = publicKeyDescription(cert)
        return ci
    }

    /// Whole days left, rounded to the nearest day, and never 0 while the
    /// certificate is still valid (truncating showed "0 days" on the last day).
    static func daysUntilExpiry(_ notAfter: Date, now: Date) -> Int {
        let seconds = notAfter.timeIntervalSince(now)
        guard seconds > 0 else { return 0 }
        return max(1, Int((seconds / 86400).rounded()))
    }

    /// Issuer and subject are the same name. Compared as normalized DER, not
    /// display strings (the subject summary is only the common name).
    static func isSelfSigned(_ cert: SecCertificate) -> Bool {
        guard let issuer = SecCertificateCopyNormalizedIssuerSequence(cert) as Data?,
              let subject = SecCertificateCopyNormalizedSubjectSequence(cert) as Data? else { return false }
        return issuer == subject
    }

    static func publicKeyDescription(_ cert: SecCertificate) -> String {
        guard let key = SecCertificateCopyKey(cert),
              let attrs = SecKeyCopyAttributes(key) as? [String: Any] else { return "" }
        let type = attrs[kSecAttrKeyType as String] as? String
        let bits = (attrs[kSecAttrKeySizeInBits as String] as? NSNumber)?.intValue ?? 0
        let name: String
        if type == kSecAttrKeyTypeRSA as String {
            name = "RSA"
        } else if type == kSecAttrKeyTypeECSECPrimeRandom as String {
            name = "EC"
        } else {
            name = "Unknown"
        }
        return bits > 0 ? "\(name) \(bits)-bit" : name
    }

    static func signatureAlgorithmName(oid: String) -> String {
        let names: [String: String] = [
            "1.2.840.113549.1.1.4":  "MD5 with RSA",
            "1.2.840.113549.1.1.5":  "SHA-1 with RSA",
            "1.2.840.113549.1.1.10": "RSA-PSS",
            "1.2.840.113549.1.1.11": "SHA-256 with RSA",
            "1.2.840.113549.1.1.12": "SHA-384 with RSA",
            "1.2.840.113549.1.1.13": "SHA-512 with RSA",
            "1.2.840.10045.4.1":     "ECDSA with SHA-1",
            "1.2.840.10045.4.3.2":   "ECDSA with SHA-256",
            "1.2.840.10045.4.3.3":   "ECDSA with SHA-384",
            "1.2.840.10045.4.3.4":   "ECDSA with SHA-512",
            "1.3.101.112":           "Ed25519",
            "1.3.101.113":           "Ed448",
        ]
        return names[oid] ?? oid
    }

    private static func sectionEntries(_ vals: [String: Any], _ oid: CFString) -> [(label: String, value: String)] {
        guard let section = vals[oid as String] as? [String: Any],
              let entries = section[kSecPropertyKeyValue as String] as? [[String: Any]] else { return [] }
        return entries.compactMap { e in
            guard let label = e[kSecPropertyKeyLabel as String] as? String,
                  let value = e[kSecPropertyKeyValue as String] as? String else { return nil }
            return (label, value)
        }
    }
}

// MARK: - TLS handshake probe

/// Opens a TLS connection, evaluates the chain with macOS trust settings but
/// accepts it either way (so an untrusted certificate can still be shown),
/// and reads the negotiated version and cipher suite. Works on any TLS port,
/// not only HTTPS, since nothing is sent after the handshake.
enum TLSProbe {
    struct Result {
        var certificates: [SecCertificate] = []
        var trusted = false
        var trustProblem = ""
        var tlsVersion = ""
        var cipherSuite = ""
    }

    struct Failure: Error { let message: String }

    static let invalidPortMessage = "The port must be a number from 1 to 65535, like 443."
    static let notBareHostMessage = "Enter just the host name, like example.com, without https://, a path, or a port. The port goes in the Port field."

    static func parsePort(_ text: String) -> UInt16? {
        guard let p = UInt16(text.trimmingCharacters(in: .whitespaces)), p > 0 else { return nil }
        return p
    }

    /// A colon is only allowed as part of an IPv6 address: "example.com:8443"
    /// would otherwise be looked up as a name and fail with "couldn't find".
    static func isBareHost(_ host: String) -> Bool {
        guard !host.isEmpty, !host.contains("/"), !host.contains(" ") else { return false }
        return !host.contains(":") || IPv6Address(host) != nil
    }

    static func unbracketed(_ host: String) -> String {
        guard host.hasPrefix("["), host.hasSuffix("]"), host.count > 2 else { return host }
        return String(host.dropFirst().dropLast())
    }

    static func timeoutMessage(host: String, port: UInt16) -> String {
        "No reply from \(host):\(port) within 10 seconds. Check the name and port, or whether a firewall is blocking it."
    }

    static func noCertificateMessage(host: String, port: UInt16) -> String {
        "\(host):\(port) didn't send a certificate."
    }

    static func message(for error: NWError, host: String, port: UInt16) -> String {
        switch error {
        case .dns:
            return "SNAP couldn't find \(host). Check the name."
        case .posix(let code) where code == .ECONNREFUSED:
            return "\(host) refused the connection on port \(port). Check the port."
        case .tls:
            return "The TLS handshake with \(host):\(port) failed. The server may not use TLS on this port."
        default:
            return "SNAP couldn't connect to \(host):\(port). Check the name and port."
        }
    }

    static func tlsVersionName(_ raw: UInt16) -> String {
        switch raw {
        case 0x0304: return "TLS 1.3"
        case 0x0303: return "TLS 1.2"
        case 0x0302: return "TLS 1.1"
        case 0x0301: return "TLS 1.0"
        case 0xFEFD: return "DTLS 1.2"
        case 0xFEFF: return "DTLS 1.0"
        default:     return String(format: "0x%04X", raw)
        }
    }

    static func cipherSuiteName(_ raw: UInt16) -> String {
        let names: [UInt16: String] = [
            0x1301: "TLS_AES_128_GCM_SHA256",
            0x1302: "TLS_AES_256_GCM_SHA384",
            0x1303: "TLS_CHACHA20_POLY1305_SHA256",
            0xC02B: "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256",
            0xC02C: "TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384",
            0xC02F: "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256",
            0xC030: "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384",
            0xCCA9: "TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256",
            0xCCA8: "TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256",
            0xC009: "TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA",
            0xC00A: "TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA",
            0xC013: "TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA",
            0xC014: "TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA",
            0xC023: "TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA256",
            0xC024: "TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA384",
            0xC027: "TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA256",
            0xC028: "TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA384",
            0x009C: "TLS_RSA_WITH_AES_128_GCM_SHA256",
            0x009D: "TLS_RSA_WITH_AES_256_GCM_SHA384",
            0x002F: "TLS_RSA_WITH_AES_128_CBC_SHA",
            0x0035: "TLS_RSA_WITH_AES_256_CBC_SHA",
            0x003C: "TLS_RSA_WITH_AES_128_CBC_SHA256",
            0x003D: "TLS_RSA_WITH_AES_256_CBC_SHA256",
            0x000A: "TLS_RSA_WITH_3DES_EDE_CBC_SHA",
        ]
        return names[raw] ?? String(format: "0x%04X", raw)
    }

    /// Mutable state shared by the handshake callbacks. Only touched on the
    /// probe's serial queue, hence unchecked.
    private final class State: @unchecked Sendable {
        var result = Result()
        var finished = false
    }

    static func run(host: String, port: UInt16, timeout: TimeInterval = 10) async throws -> Result {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw Failure(message: invalidPortMessage)
        }
        return try await withCheckedThrowingContinuation { cont in
            let queue = DispatchQueue(label: "snap.ssl-checker")
            let state = State()

            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, secTrust, complete in
                let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
                SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
                state.result.certificates = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
                // Asynchronous: evaluating can fetch intermediates or revocation
                // data, and blocking this queue would hold up the timeout too.
                SecTrustEvaluateAsyncWithError(trust, queue) { _, trusted, cfError in
                    state.result.trusted = trusted
                    if let cfError { state.result.trustProblem = CFErrorCopyDescription(cfError) as String }
                    // Accept regardless: the point is to show the certificate and
                    // say whether macOS trusts it. Nothing is sent over the connection.
                    complete(true)
                }
            }, queue)

            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort,
                                          using: NWParameters(tls: tls))

            @Sendable func finish(_ outcome: Swift.Result<Result, Error>) {
                guard !state.finished else { return }
                state.finished = true
                connection.cancel()
                cont.resume(with: outcome)
            }

            connection.stateUpdateHandler = { newState in
                switch newState {
                case .ready:
                    if let meta = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata {
                        let m = meta.securityProtocolMetadata
                        state.result.tlsVersion = tlsVersionName(sec_protocol_metadata_get_negotiated_tls_protocol_version(m).rawValue)
                        state.result.cipherSuite = cipherSuiteName(sec_protocol_metadata_get_negotiated_tls_ciphersuite(m).rawValue)
                    }
                    finish(.success(state.result))
                case .failed(let error), .waiting(let error):
                    // A handshake that fails after the certificate arrived
                    // (e.g. the server wants a client certificate) still has one to show
                    if !state.result.certificates.isEmpty {
                        finish(.success(state.result))
                    } else {
                        finish(.failure(Failure(message: message(for: error, host: host, port: port))))
                    }
                default:
                    break
                }
            }
            connection.start(queue: queue)

            queue.asyncAfter(deadline: .now() + timeout) {
                if !state.result.certificates.isEmpty {
                    finish(.success(state.result))
                } else {
                    finish(.failure(Failure(message: timeoutMessage(host: host, port: port))))
                }
            }
        }
    }
}
