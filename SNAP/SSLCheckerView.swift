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
                Text("Port:").font(.caption).foregroundStyle(.secondary)
                TextField("", text: $port)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
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
                                Label("\(cert.daysUntilExpiry) days until expiry",
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
                } else if !isRunning {
                    EmptyStateView(title: "No Certificate Data", systemImage: "lock.shield", description: "Enter a hostname and press Check")
                }
            }
        }
        .tabNavigationTitle(.ssl)
    }

    private func checkSSL() {
        certInfo = nil
        error = ""
        isRunning = true
        let targetHost = host
        let targetPort = UInt16(port) ?? 443

        Task {
            var ci = CertInfo()
            do {
                let certs = try await fetchCertificates(host: targetHost, port: targetPort)
                if let leaf = certs.first {
                    // Extract fields using Security framework
                    if let summary = SecCertificateCopySubjectSummary(leaf) {
                        ci.subject = summary as String
                    }
                    // Values dict
                    if let vals = SecCertificateCopyValues(leaf, nil, nil) as? [String: Any] {
                        // Not-before
                        if let nb = vals[kSecOIDX509V1ValidityNotBefore as String] as? [String: Any],
                           let nbVal = nb[kSecPropertyKeyValue as String] as? Double {
                            ci.notBefore = Date(timeIntervalSinceReferenceDate: nbVal)
                        }
                        // Not-after
                        if let na = vals[kSecOIDX509V1ValidityNotAfter as String] as? [String: Any],
                           let naVal = na[kSecPropertyKeyValue as String] as? Double {
                            ci.notAfter = Date(timeIntervalSinceReferenceDate: naVal)
                            let days = Int(ci.notAfter!.timeIntervalSinceNow / 86400)
                            ci.isExpired = days < 0
                            ci.daysUntilExpiry = max(0, days)
                        }
                        // Issuer
                        if let issuer = vals[kSecOIDX509V1IssuerName as String] as? [String: Any] {
                            ci.issuer = issuer[kSecPropertyKeyValue as String] as? String ?? ""
                        }
                        // Serial
                        if let serial = vals[kSecOIDX509V1SerialNumber as String] as? [String: Any] {
                            ci.serialNumber = serial[kSecPropertyKeyValue as String] as? String ?? ""
                        }
                        // SANs
                        if let sans = vals[kSecOIDSubjectAltName as String] as? [String: Any],
                           let sanArr = sans[kSecPropertyKeyValue as String] as? [[String: Any]] {
                            ci.dnsNames = sanArr.compactMap { $0[kSecPropertyKeyValue as String] as? String }
                        }
                        // Sig algo
                        if let sigAlgo = vals[kSecOIDX509V1SignatureAlgorithm as String] as? [String: Any] {
                            ci.signatureAlgorithm = sigAlgo[kSecPropertyKeyValue as String] as? String ?? ""
                        }
                    }
                    ci.isSelfSigned = (ci.subject == ci.issuer)
                    ci.grade = computeGrade(ci)
                }
            } catch {
                await MainActor.run { self.error = error.localizedDescription }
            }

            await MainActor.run {
                certInfo = ci
                isRunning = false
            }
        }
    }

    private func fetchCertificates(host: String, port: UInt16) async throws -> [SecCertificate] {
        // Use URLSession with a custom delegate to capture the server certificate chain
        let scheme = port == 443 ? "https" : "https"
        guard let url = URL(string: "\(scheme)://\(host):\(port)") else {
            throw NSError(domain: "SNAP", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
        }
        return try await withCheckedThrowingContinuation { cont in
            let delegate = CertCaptureDelegate(continuation: cont)
            let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
            let task = session.dataTask(with: url) { _, _, error in
                // If delegate already resumed via didReceiveChallenge, this is a no-op
                if let error = error {
                    delegate.resumeOnce(with: .failure(error))
                }
            }
            task.resume()
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                delegate.resumeOnce(with: .failure(
                    NSError(domain: "SNAP", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Connection timed out"])
                ))
                task.cancel()
            }
        }
    }

    private func computeGrade(_ c: CertInfo) -> String {
        if c.isExpired { return "F" }
        if c.isSelfSigned { return "C" }
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

// MARK: - Certificate Capture Delegate
class CertCaptureDelegate: NSObject, URLSessionDelegate {
    private var continuation: CheckedContinuation<[SecCertificate], Error>
    private var hasResumed = false
    private let lock = NSLock()

    init(continuation: CheckedContinuation<[SecCertificate], Error>) {
        self.continuation = continuation
    }

    func resumeOnce(with result: Result<[SecCertificate], Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !hasResumed else { return }
        hasResumed = true
        switch result {
        case .success(let certs): continuation.resume(returning: certs)
        case .failure(let err):   continuation.resume(throwing: err)
        }
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            var certs: [SecCertificate] = []
            if #available(macOS 12, *) {
                if let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] {
                    certs = chain
                }
            } else {
                let count = SecTrustGetCertificateCount(trust)
                for i in 0..<count {
                    if let cert = SecTrustGetCertificateAtIndex(trust, i) {
                        certs.append(cert)
                    }
                }
            }
            resumeOnce(with: .success(certs))
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
