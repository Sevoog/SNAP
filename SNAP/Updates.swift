// Updates.swift
// SNAP: Update checks and "What's new" (v1.5.8)
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md
//
// Update checks ask GitHub for the latest published release and compare its
// version with this one. They never download or install anything: a newer
// release opens a sheet with its notes and a button to the release page.
//
// "Check for Updates…" only contacts GitHub when clicked. Automatic checks
// (at most once a day) are off until the user turns them on; SNAP asks once,
// after the Quick Tour or the "What's new" sheet, and the choice can be
// changed any time from the SNAP menu.
//
// A check sends GitHub the request itself (so your IP address) and SNAP's
// version in the User-Agent. It uses an ephemeral session, so no cookies or
// cache are kept.

import SwiftUI
import AppKit

// MARK: - Versions and releases

enum AppVersion {
    /// True when `candidate` ("1.5.10", "v1.6") is a later version than
    /// `current`. Compares numbers part by part; missing parts count as 0.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = parts(candidate), b = parts(current)
        guard !a.isEmpty, !b.isEmpty else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// "v1.5.8" -> [1, 5, 8]. Anything after the numbers ("-beta") is ignored.
    static func parts(_ version: String) -> [Int] {
        var s = Substring(version.trimmingCharacters(in: .whitespaces))
        if s.first == "v" || s.first == "V" { s = s.dropFirst() }
        var out: [Int] = []
        for piece in s.split(separator: ".") {
            let digits = piece.prefix { $0.isNumber }
            guard let n = Int(digits) else { break }
            out.append(n)
            if digits.count != piece.count { break }
        }
        return out
    }
}

/// The parts of a GitHub release SNAP shows.
struct ReleaseInfo: Equatable, Identifiable {
    var id: String { version }
    let version: String
    let notes: String
    let pageURL: URL

    /// From GitHub's /releases/latest reply. Drafts and pre-releases are
    /// never offered (that endpoint skips them anyway).
    init?(json data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let page = (obj["html_url"] as? String).flatMap(URL.init(string:)),
              obj["draft"] as? Bool != true, obj["prerelease"] as? Bool != true,
              !AppVersion.parts(tag).isEmpty
        else { return nil }
        version = AppVersion.parts(tag).map(String.init).joined(separator: ".")
        notes = obj["body"] as? String ?? ""
        pageURL = page
    }

    init(version: String, notes: String, pageURL: URL) {
        self.version = version; self.notes = notes; self.pageURL = pageURL
    }

    /// The release notes as styled text. Text only renders inline Markdown,
    /// so headings become bold lines and list markers become bullets first.
    var styledNotes: AttributedString {
        let lines = notes.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        let converted = lines.map { raw -> String in
            let line = String(raw)
            let trimmed = line.drop { $0 == " " }
            let indent = line.count - trimmed.count
            if trimmed.hasPrefix("#") {
                let title = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                return title.isEmpty ? "" : "**\(title)**"
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                return String(repeating: " ", count: indent * 2) + (indent > 0 ? "◦ " : "• ") + trimmed.dropFirst(2)
            }
            return line
        }.joined(separator: "\n")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: converted, options: options)) ?? AttributedString(notes)
    }
}

// MARK: - Checker

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    static let latestReleaseURL = URL(string: "https://api.github.com/repos/Sevoog/SNAP/releases/latest")!
    static let checkInterval: TimeInterval = 24 * 60 * 60

    enum Keys {
        static let autoCheck = "com.sevagbardakjian.snap.updates.autoCheck"
        static let askedAboutAutoCheck = "com.sevagbardakjian.snap.updates.askedAboutAutoCheck"
        static let lastCheck = "com.sevagbardakjian.snap.updates.lastCheck"
        static let skippedVersion = "com.sevagbardakjian.snap.updates.skippedVersion"
    }

    /// A newer release to show in the update sheet.
    @Published var available: ReleaseInfo?
    @Published private(set) var isChecking = false
    @Published var autoCheck: Bool {
        didSet {
            defaults.set(autoCheck, forKey: Keys.autoCheck)
            startSchedule()
        }
    }

    private let defaults: UserDefaults
    private let currentVersion: String
    private var timer: Timer?

    init(defaults: UserDefaults = .standard, currentVersion: String = AppInfo.version) {
        self.defaults = defaults
        self.currentVersion = currentVersion
        autoCheck = defaults.bool(forKey: Keys.autoCheck)
    }

    // MARK: Asking once

    var hasAskedAboutAutoCheck: Bool { defaults.bool(forKey: Keys.askedAboutAutoCheck) }

    /// Asks once whether to check automatically. Called after the Quick Tour
    /// or the "What's new" sheet closes, so it never stacks on top of them.
    func askAboutAutoCheckIfNeeded() {
        guard !hasAskedAboutAutoCheck else { return }
        defaults.set(true, forKey: Keys.askedAboutAutoCheck)
        let alert = NSAlert()
        alert.messageText = "Check for updates automatically?"
        alert.informativeText = """
        SNAP can check GitHub once a day for a newer version and tell you when one is out. \
        It never downloads or installs anything on its own.

        Each check sends GitHub your IP address and SNAP's version, nothing else. \
        You can change this any time in the SNAP menu.
        """
        alert.addButton(withTitle: "Check Automatically")
        alert.addButton(withTitle: "Not Now")
        autoCheck = alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: Checking

    /// Starts the once-a-day schedule. Checks right away when one is due.
    func startSchedule() {
        timer?.invalidate()
        timer = nil
        guard autoCheck else { return }
        checkIfDue()
        // SNAP often runs for days in the menu bar, so look again every hour.
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { _ in
            Task { @MainActor in UpdateChecker.shared.checkIfDue() }
        }
    }

    func isDue(now: Date = Date()) -> Bool {
        guard autoCheck else { return false }
        let last = defaults.object(forKey: Keys.lastCheck) as? Date ?? .distantPast
        return now.timeIntervalSince(last) >= Self.checkInterval
    }

    func checkIfDue() {
        if isDue() { check(userInitiated: false) }
    }

    /// "Check for Updates…": reports the result either way.
    func checkNow() { check(userInitiated: true) }

    private func check(userInitiated: Bool) {
        guard !isChecking else { return }
        isChecking = true
        var request = URLRequest(url: Self.latestReleaseURL, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SNAP/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral)
        session.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let release = data.flatMap(ReleaseInfo.init(json:))
            Task { @MainActor in
                session.finishTasksAndInvalidate()
                self.finish(release: release, status: status, error: error, userInitiated: userInitiated)
            }
        }.resume()
    }

    private func finish(release: ReleaseInfo?, status: Int, error: Error?, userInitiated: Bool) {
        isChecking = false
        guard let release, status == 200 else {
            if userInitiated { Self.showFailure(status: status, error: error) }
            return
        }
        defaults.set(Date(), forKey: Keys.lastCheck)
        let decision = Self.decide(release: release, current: currentVersion,
                                   skipped: defaults.string(forKey: Keys.skippedVersion),
                                   userInitiated: userInitiated)
        switch decision {
        case .offer: available = release
        case .upToDate: if userInitiated { showUpToDate() }
        case .skipped: break
        }
    }

    enum Decision: Equatable { case offer, upToDate, skipped }

    /// Whether to offer `release`. A skipped version isn't offered by the
    /// automatic check, but asking by hand always shows it.
    static func decide(release: ReleaseInfo, current: String, skipped: String?, userInitiated: Bool) -> Decision {
        guard AppVersion.isNewer(release.version, than: current) else { return .upToDate }
        if !userInitiated, skipped == release.version { return .skipped }
        return .offer
    }

    // MARK: Sheet actions

    func skip(_ release: ReleaseInfo) {
        defaults.set(release.version, forKey: Keys.skippedVersion)
        available = nil
    }

    func openReleasePage(_ release: ReleaseInfo) {
        NSWorkspace.shared.open(release.pageURL)
        available = nil
    }

    // MARK: Alerts

    private func showUpToDate() {
        let alert = NSAlert()
        alert.messageText = "You're up to date"
        alert.informativeText = "SNAP \(currentVersion) is the latest version."
        alert.runModal()
    }

    private static func showFailure(status: Int, error: Error?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't check for updates"
        switch status {
        case 403, 429:
            alert.informativeText = "GitHub is limiting requests from your network right now. Try again in an hour."
        case 404:
            alert.informativeText = "GitHub didn't list a release. Try again later."
        default:
            alert.informativeText = error?.localizedDescription ?? "GitHub didn't answer. Check your connection and try again."
        }
        alert.runModal()
    }
}

// MARK: - Update sheet

struct UpdateAvailableSheet: View {
    let release: ReleaseInfo
    @ObservedObject private var checker = UpdateChecker.shared
    private var themeMgr = ThemeManager.shared

    init(release: ReleaseInfo) { self.release = release }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                AppLogo(size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text("SNAP \(release.version) is available")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(NS.text1)
                    Text("You have \(AppInfo.version). It won't change until you download the new version.")
                        .font(.system(size: 12))
                        .foregroundStyle(NS.text2)
                }
            }
            ScrollView {
                Text(release.styledNotes)
                    .font(.system(size: 12))
                    .foregroundStyle(NS.text1)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(minHeight: 220, maxHeight: 340)
            .background(NS.bg2)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Skip This Version") { checker.skip(release) }
                Spacer()
                Button("Later") { checker.available = nil }
                    .keyboardShortcut(.cancelAction)
                Button("View Release") { checker.openReleasePage(release) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(NS.bg1)
    }
}

// MARK: - What's new

/// What changed in this version, shown once after updating. Built into the
/// app, so it needs no network. Update `items` with each release.
enum WhatsNew {
    static let version = "1.5.8"
    static let items: [(symbol: String, title: String, detail: String)] = [
        ("arrow.triangle.2.circlepath", "Update checks",
         "Check for Updates… in the SNAP menu tells you when a new version is out. Daily automatic checks are optional."),
        ("door.left.hand.open", "TCP ping",
         "Ping can time a connection to a port instead, for hosts and firewalls that block ICMP."),
        ("clock.arrow.circlepath", "Network change log",
         "See when your network, IP address, router, DNS, or VPN changed: Recent Changes in the menu bar, or Window → Network Change Log."),
        ("star", "Saved iPerf3 servers",
         "Save iPerf3 servers by name, then pick one with a click from the row under the toolbar."),
        ("power", "Open at login",
         "SNAP → Open at Login starts SNAP when you log in."),
        ("ladybug", "Report a bug",
         "Help → Report a Bug… opens a GitHub issue with your SNAP and macOS versions filled in. Nothing is sent until you submit it."),
    ]

    static let lastSeenKey = "com.sevagbardakjian.snap.whatsNew.lastSeenVersion"

    /// Show the sheet after an update: not on a first install (the Quick Tour
    /// covers that), and only once per version.
    static func shouldShow(lastSeen: String?, hasOnboarded: Bool, current: String) -> Bool {
        guard hasOnboarded else { return false }
        guard let lastSeen else { return true }      // updated from 1.5.7 or earlier
        return AppVersion.isNewer(current, than: lastSeen)
    }
}

struct WhatsNewSheet: View {
    let onClose: () -> Void
    private var themeMgr = ThemeManager.shared

    init(onClose: @escaping () -> Void) { self.onClose = onClose }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                AppLogo(size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text("What's new in SNAP \(AppInfo.version)")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(NS.text1)
                    Text("Thanks for updating.")
                        .font(.system(size: 12))
                        .foregroundStyle(NS.text2)
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                ForEach(WhatsNew.items, id: \.title) { item in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 16))
                            .foregroundStyle(NS.amber)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(NS.text1)
                            Text(item.detail)
                                .font(.system(size: 12))
                                .foregroundStyle(NS.text2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            HStack {
                Button("Full Release Notes") {
                    if let url = URL(string: "https://github.com/Sevoog/SNAP/releases/tag/v\(AppInfo.version)") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Spacer()
                Button("Continue") { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(NS.bg1)
    }
}

// MARK: - Bug reports

enum IssueReport {
    /// A new GitHub issue from a template, with SNAP's and macOS's versions
    /// filled in. Nothing is sent until the user submits it on GitHub.
    static func url(template: String, snapVersion: String = AppInfo.version,
                    macOS: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> URL? {
        var c = URLComponents(string: "https://github.com/Sevoog/SNAP/issues/new")
        let os = "\(macOS.majorVersion).\(macOS.minorVersion)" + (macOS.patchVersion > 0 ? ".\(macOS.patchVersion)" : "")
        c?.queryItems = [
            URLQueryItem(name: "template", value: template),
            URLQueryItem(name: "snap-version", value: snapVersion),
            URLQueryItem(name: "macos-version", value: os),
        ]
        return c?.url
    }
}
