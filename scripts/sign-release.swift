// sign-release.swift
// SNAP: Ed25519 signatures for release zips
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md
//
// Each release zip gets a detached Ed25519 signature (SNAP-x.y.z.zip.sig,
// base64), uploaded next to it. The private key lives only in the
// maintainer's login Keychain; the public key is committed in
// scripts/release-signing-key.pub, so anyone (and a future SNAP that installs
// its own updates) can check that a zip came from the maintainer.
//
//   swift scripts/sign-release.swift genkey <public-key-file>
//   swift scripts/sign-release.swift sign <file>                  -> <file>.sig
//   swift scripts/sign-release.swift verify <file> <sig-file> <public-key-file>
//
// Back up the private key (Keychain Access, item "SNAP release signing key").
// If it's lost, later releases must be signed with a new key, and copies of
// SNAP that trust the old one can't verify them.

import CryptoKit
import Foundation
import Security

let service = "com.sevagbardakjian.snap.release-signing"
let account = "ed25519"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("sign-release: \(message)\n".utf8))
    exit(1)
}

func loadPrivateKey() -> Curve25519.Signing.PrivateKey? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: AnyObject?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
          let data = result as? Data,
          let raw = Data(base64Encoded: data) else { return nil }
    return try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
}

func readPublicKey(_ path: String) -> Curve25519.Signing.PublicKey {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    else { fail("can't read a public key from \(path)") }
    return key
}

func readFile(_ path: String) -> Data {
    guard let data = FileManager.default.contents(atPath: path) else { fail("can't read \(path)") }
    return data
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "genkey":
    guard args.count == 2, let pubPath = args.last else { fail("usage: genkey <public-key-file>") }
    if loadPrivateKey() != nil { fail("a signing key already exists in the Keychain; not replacing it") }
    let key = Curve25519.Signing.PrivateKey()
    let attrs: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecAttrLabel as String: "SNAP release signing key",
        kSecValueData as String: Data(key.rawRepresentation.base64EncodedString().utf8),
    ]
    guard SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess else { fail("couldn't save the key to the Keychain") }
    let pub = key.publicKey.rawRepresentation.base64EncodedString()
    do { try (pub + "\n").write(toFile: pubPath, atomically: true, encoding: .utf8) } catch { fail("couldn't write \(pubPath)") }
    print("Saved the private key to the Keychain (\"SNAP release signing key\"). Back it up.")
    print("Public key written to \(pubPath)")

case "sign":
    guard args.count == 2, let path = args.last else { fail("usage: sign <file>") }
    guard let key = loadPrivateKey() else { fail("no signing key in the Keychain; run genkey first") }
    let signature = try key.signature(for: readFile(path))
    guard key.publicKey.isValidSignature(signature, for: readFile(path)) else { fail("signature didn't verify") }
    do { try (signature.base64EncodedString() + "\n").write(toFile: path + ".sig", atomically: true, encoding: .utf8) }
    catch { fail("couldn't write \(path).sig") }
    print("Signed: \(path).sig")

case "verify":
    let a = Array(args)
    guard a.count == 4 else { fail("usage: verify <file> <sig-file> <public-key-file>") }
    let sigText = String(decoding: readFile(a[2]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let signature = Data(base64Encoded: sigText) else { fail("\(a[2]) isn't a base64 signature") }
    if readPublicKey(a[3]).isValidSignature(signature, for: readFile(a[1])) {
        print("Valid signature: \(a[1])")
    } else {
        fail("INVALID signature for \(a[1])")
    }

default:
    fail("usage: genkey <public-key-file> | sign <file> | verify <file> <sig-file> <public-key-file>")
}
