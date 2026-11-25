// BonjourView.swift
// SNAP — Bonjour / mDNS Browser
// Created by Sevag Bardakjian
// Copyright © 2025-2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md

import SwiftUI
import Network
import dnssd

struct BonjourService: Identifiable, Hashable {
    let id = UUID()
    static func == (lhs: BonjourService, rhs: BonjourService) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    var name: String
    var type: String
    var domain: String
    var hostname: String = ""
    var port: Int = 0
    var addresses: [String] = []
    var txtRecord: [String: String] = [:]
}

// Named service type definitions — matches the screenshot layout
struct BonjourServiceDef: Identifiable {
    let id = UUID()
    let label: String        // Human-readable (shown in sidebar)
    let mdnsType: String     // mDNS type string to browse
    let icon: String         // SF Symbol
}

final class BonjourBrowser: ObservableObject {
    @Published var services: [BonjourService] = []
    @Published var isSearching = false
    @Published var selectedDef: BonjourServiceDef?
    /// Set when browsing can't run at all (usually Local Network access denied)
    @Published var errorMessage: String?

    static let localNetworkDeniedMessage = "SNAP couldn't search the local network. Check System Settings > Privacy & Security > Local Network and make sure SNAP is allowed."
    static let searchFailedMessage = "SNAP couldn't search the local network. Wait a moment, then choose the service again."

    /// mDNS answers arrive within a second or two; after this the spinner
    /// stops and an empty list means nothing is advertising. Browsers keep
    /// running, so a late arrival still shows up.
    static let searchWindow: TimeInterval = 5
    private var searchTimer: DispatchWorkItem?
    private var resolver: BonjourResolver?

    // All service definitions — matches the screenshot
    let serviceDefs: [BonjourServiceDef] = [
        BonjourServiceDef(label: "Web Servers (HTTP)",     mdnsType: "_http._tcp",              icon: "globe"),
        BonjourServiceDef(label: "Secure Web (HTTPS)",     mdnsType: "_https._tcp",             icon: "lock.globe"),
        BonjourServiceDef(label: "SSH",                    mdnsType: "_ssh._tcp",               icon: "terminal"),
        BonjourServiceDef(label: "SFTP",                   mdnsType: "_sftp-ssh._tcp",          icon: "arrow.up.arrow.down"),
        BonjourServiceDef(label: "AFP (Apple Filing)",     mdnsType: "_afpovertcp._tcp",        icon: "externaldrive.connected.to.line.below"),
        BonjourServiceDef(label: "SMB (Windows Sharing)",  mdnsType: "_smb._tcp",               icon: "pc"),
        BonjourServiceDef(label: "FTP",                    mdnsType: "_ftp._tcp",               icon: "arrow.up.arrow.down"),
        BonjourServiceDef(label: "Printers",               mdnsType: "_printer._tcp",           icon: "printer"),
        BonjourServiceDef(label: "IPP Printers",           mdnsType: "_ipp._tcp",               icon: "printer.filled.and.paper"),
        BonjourServiceDef(label: "AirPlay",                mdnsType: "_airplay._tcp",           icon: "airplayvideo"),
        BonjourServiceDef(label: "AirPlay Audio (RAOP)",   mdnsType: "_raop._tcp",              icon: "airplayaudio"),
        BonjourServiceDef(label: "Spotify Connect",        mdnsType: "_spotify-connect._tcp",   icon: "music.note"),
        BonjourServiceDef(label: "Google Cast",            mdnsType: "_googlecast._tcp",        icon: "tv"),
        BonjourServiceDef(label: "HomeKit",                mdnsType: "_hap._tcp",               icon: "house"),
        BonjourServiceDef(label: "Apple Remote Desktop",   mdnsType: "_net-assistant._udp",     icon: "desktopcomputer"),
        BonjourServiceDef(label: "VNC (Screen Sharing)",   mdnsType: "_rfb._tcp",               icon: "rectangle.on.rectangle"),
        BonjourServiceDef(label: "iTunes/Music Sharing",   mdnsType: "_daap._tcp",              icon: "music.note.list"),
        BonjourServiceDef(label: "Time Machine",           mdnsType: "_adisk._tcp",             icon: "clock.arrow.circlepath"),
        BonjourServiceDef(label: "Apple TV",               mdnsType: "_appletv-v2._tcp",        icon: "appletv"),
        BonjourServiceDef(label: "AirPort Base Station",   mdnsType: "_airport._tcp",           icon: "wifi.router"),
    ]

    private var browsers: [NWBrowser] = []
    // Sentinel id for "All Services" — checked by label, not mdnsType
    let allServicesDef = BonjourServiceDef(label: "All Services", mdnsType: "__all__", icon: "square.grid.2x2")

    func browseAll() {
        reset(selecting: allServicesDef)

        // Launch a browser for every service type simultaneously
        for def in serviceDefs {
            startBrowser(type: def.mdnsType)
        }
    }

    private func reset(selecting def: BonjourServiceDef) {
        for b in browsers { b.cancel() }
        browsers = []
        resolver?.cancel()
        resolver = nil
        services = []
        errorMessage = nil
        selectedDef = def
        isSearching = true

        searchTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in self?.isSearching = false }
        searchTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.searchWindow, execute: timer)
    }

    /// True when a browser state means browsing can't work: failed outright,
    /// or waiting because Local Network access was denied.
    static func isBlocking(_ state: NWBrowser.State) -> Bool {
        if case .failed = state { return true }
        return isPolicyDenied(state)
    }

    /// Local Network access denied. A plain .failed can have other causes,
    /// such as mDNSResponder restarting, so it isn't blamed on permissions.
    static func isPolicyDenied(_ state: NWBrowser.State) -> Bool {
        let error: NWError
        switch state {
        case .waiting(let e), .failed(let e): error = e
        default: return false
        }
        if case .dns(let code) = error, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) { return true }
        return false
    }

    private func startBrowser(type mdnsType: String) {
        let descriptor = NWBrowser.Descriptor.bonjour(type: mdnsType, domain: "local.")
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: descriptor, using: params)

        browser.browseResultsChangedHandler = { [weak self, weak browser] _, changes in
            guard let self else { return }
            DispatchQueue.main.async {
                // Results from a browser replaced by a new search don't belong in its list
                guard let browser, self.browsers.contains(where: { $0 === browser }) else { return }
                for change in changes {
                    switch change {
                    case .added(let result):
                        if case let .service(name, type, domain, _) = result.endpoint {
                            let svc = BonjourService(name: name, type: type, domain: domain)
                            // Deduplicate on name+type combo for all-services view
                            if !self.services.contains(where: { $0.name == name && $0.type == type }) {
                                self.services.append(svc)
                                self.services.sort { $0.type == $1.type ? $0.name < $1.name : $0.type < $1.type }
                            }
                        }
                    case .removed(let result):
                        if case let .service(name, type, _, _) = result.endpoint {
                            self.services.removeAll { $0.name == name && $0.type == type }
                        }
                    default: break
                    }
                }
            }
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            // Handlers run on .main (see start below); ignore browsers already replaced
            guard let self, let browser, self.browsers.contains(where: { $0 === browser }) else { return }
            if Self.isBlocking(state) {
                // Used to be cancelled silently, leaving an endless spinner.
                // Services already found stay listed unless access was denied.
                if Self.isPolicyDenied(state) {
                    self.errorMessage = Self.localNetworkDeniedMessage
                } else if self.services.isEmpty {
                    self.errorMessage = Self.searchFailedMessage
                }
                self.isSearching = false
                self.searchTimer?.cancel()
                if case .failed = state { browser.cancel() }
            } else if case .ready = state, self.errorMessage != nil {
                // Access granted while waiting
                self.errorMessage = nil
            }
        }
        browser.start(queue: .main)
        browsers.append(browser)
    }

    func browse(def: BonjourServiceDef) {
        // Stop any current browsing
        reset(selecting: def)
        startBrowser(type: def.mdnsType)
    }

    func stop() {
        for b in browsers { b.cancel() }
        browsers = []
        resolver?.cancel()
        resolver = nil
        searchTimer?.cancel()
        isSearching = false
    }

    // MARK: Resolve

    /// Look up host name, port, addresses and TXT record for one service.
    /// NWBrowser results carry only the instance name, type and domain.
    func resolve(_ id: UUID?) {
        resolver?.cancel()
        resolver = nil
        guard let id, let svc = services.first(where: { $0.id == id }) else { return }
        let r = BonjourResolver(
            onResolved: { [weak self] host, port, txt in
                self?.update(id) { s in
                    s.hostname = host
                    s.port = port
                    s.txtRecord = txt
                }
            },
            onAddress: { [weak self] address, added in
                self?.update(id) { s in
                    if added {
                        if !s.addresses.contains(address) { s.addresses.append(address) }
                    } else {
                        s.addresses.removeAll { $0 == address }
                    }
                }
            })
        r.start(name: svc.name, type: svc.type, domain: svc.domain)
        resolver = r
    }

    private func update(_ id: UUID, _ change: (inout BonjourService) -> Void) {
        guard let i = services.firstIndex(where: { $0.id == id }) else { return }
        change(&services[i])
    }
}

// MARK: - dns_sd resolver

/// Resolves one Bonjour instance with the dns_sd API: DNSServiceResolve for
/// host, port and TXT, then DNSServiceGetAddrInfo for the host's addresses.
/// Callbacks run on the main queue; cancel() stops them before release.
final class BonjourResolver {
    private var resolveRef: DNSServiceRef?
    private var addrRef: DNSServiceRef?
    private var resolvedHost: String?
    private let onResolved: (String, Int, [String: String]) -> Void
    private let onAddress: (String, Bool) -> Void

    init(onResolved: @escaping (String, Int, [String: String]) -> Void,
         onAddress: @escaping (String, Bool) -> Void) {
        self.onResolved = onResolved
        self.onAddress = onAddress
    }

    deinit { cancel() }

    func start(name: String, type: String, domain: String) {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        var ref: DNSServiceRef?
        let err = DNSServiceResolve(&ref, DNSServiceFlags(kDNSServiceFlagsIncludeP2P), 0,
                                    name, type, domain.isEmpty ? "local." : domain,
                                    { _, _, _, err, _, host, port, txtLen, txt, ctx in
            guard err == DNSServiceErrorType(kDNSServiceErr_NoError), let ctx, let host else { return }
            let me = Unmanaged<BonjourResolver>.fromOpaque(ctx).takeUnretainedValue()
            let txtData = txt.map { Data(bytes: $0, count: Int(txtLen)) } ?? Data()
            me.didResolve(host: String(cString: host), port: Int(UInt16(bigEndian: port)),
                          txt: BonjourResolver.parseTXT(txtData))
        }, ctx)
        guard err == DNSServiceErrorType(kDNSServiceErr_NoError), let ref else { return }
        DNSServiceSetDispatchQueue(ref, .main)
        resolveRef = ref
    }

    func cancel() {
        if let r = resolveRef { DNSServiceRefDeallocate(r) }
        if let r = addrRef { DNSServiceRefDeallocate(r) }
        resolveRef = nil
        addrRef = nil
    }

    private func didResolve(host: String, port: Int, txt: [String: String]) {
        let display = host.hasSuffix(".") ? String(host.dropLast()) : host
        onResolved(display, port, txt)
        // One address lookup per host name (resolve can reply once per interface)
        guard resolvedHost != host else { return }
        resolvedHost = host
        if let r = addrRef { DNSServiceRefDeallocate(r) }
        addrRef = nil

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        var ref: DNSServiceRef?
        let err = DNSServiceGetAddrInfo(&ref, DNSServiceFlags(kDNSServiceFlagsIncludeP2P), 0,
                                        DNSServiceProtocol(kDNSServiceProtocol_IPv4 | kDNSServiceProtocol_IPv6),
                                        host, { _, flags, _, err, _, addr, _, ctx in
            guard err == DNSServiceErrorType(kDNSServiceErr_NoError), let ctx, let addr,
                  let text = BonjourResolver.numericHost(addr) else { return }
            let me = Unmanaged<BonjourResolver>.fromOpaque(ctx).takeUnretainedValue()
            me.onAddress(text, flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0)
        }, ctx)
        guard err == DNSServiceErrorType(kDNSServiceErr_NoError), let ref else { return }
        DNSServiceSetDispatchQueue(ref, .main)
        addrRef = ref
    }

    private static func numericHost(_ addr: UnsafePointer<sockaddr>) -> String? {
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = getnameinfo(addr, socklen_t(addr.pointee.sa_len), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST)
        return rc == 0 ? String(cString: buf) : nil
    }

    /// TXT record wire format: length-prefixed "key=value" strings. A key
    /// with no "=" is a boolean attribute and gets an empty value.
    static func parseTXT(_ data: Data) -> [String: String] {
        var out: [String: String] = [:]
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count {
            let len = Int(bytes[i])
            i += 1
            guard len > 0 else { continue }
            guard i + len <= bytes.count else { break }
            let entry = bytes[i..<(i + len)]
            i += len
            if let eq = entry.firstIndex(of: UInt8(ascii: "=")) {
                let key = String(decoding: entry[entry.startIndex..<eq], as: UTF8.self)
                let value = String(decoding: entry[(eq + 1)...], as: UTF8.self)
                if !key.isEmpty, out[key] == nil { out[key] = value }
            } else {
                let key = String(decoding: entry, as: UTF8.self)
                if !key.isEmpty, out[key] == nil { out[key] = "" }
            }
        }
        return out
    }
}

struct BonjourView: View {
    @StateObject private var model = BonjourBrowser()
    @State private var selectedService: BonjourService?
    @State private var searchText = ""

    private var filtered: [BonjourService] {
        guard !searchText.isEmpty else { return model.services }
        return model.services.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.hostname.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        HSplitView {
            // ── Left column: service type list (like the screenshot) ───────────
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("Service Type")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    Spacer()
                }
                .background(NS.bg3)

                Divider()

                List(selection: Binding(
                    get: { model.selectedDef?.id },
                    set: { id in
                        selectedService = nil
                        if id == model.allServicesDef.id {
                            model.browseAll()
                        } else if let def = model.serviceDefs.first(where: { $0.id == id }) {
                            model.browse(def: def)
                        }
                    }
                )) {
                    // "All Services" row at the top with a divider below it
                    let allDef = model.allServicesDef
                    HStack(spacing: 10) {
                        Image(systemName: allDef.icon)
                            .frame(width: 18)
                            .foregroundStyle(.blue)
                        Text(allDef.label).font(.subheadline)
                        Spacer()
                        if model.selectedDef?.id == allDef.id && model.isSearching {
                            ProgressView().controlSize(.mini)
                        }
                    }
                    .tag(allDef.id as UUID?)

                    Divider()

                    ForEach(model.serviceDefs) { def in
                    HStack(spacing: 10) {
                        Image(systemName: def.icon)
                            .frame(width: 18)
                            .foregroundStyle(.blue)
                        Text(def.label)
                            .font(.subheadline)
                        Spacer()
                        if model.selectedDef?.id == def.id && model.isSearching {
                            ProgressView().controlSize(.mini)
                        }
                    }
                    .tag(def.id as UUID?)
                    }
                }
                .listStyle(.sidebar)
            }
            .frame(minWidth: 210, maxWidth: 240)

            // ── Middle column: discovered instances ────────────────────────────
            VStack(spacing: 0) {
                // Toolbar
                HStack(spacing: 8) {
                    if let def = model.selectedDef {
                        Image(systemName: def.icon).foregroundStyle(.blue)
                        Text(def.label).font(.subheadline.bold())
                    } else {
                        Text("Select a service type")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.isSearching {
                        Text("\(model.services.count) found")
                            .font(.caption2).foregroundStyle(.secondary)
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(NS.bg3)

                Divider()

                // Search
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                    TextField("Filter...", text: $searchText).textFieldStyle(.plain).font(.caption)
                }
                .padding(6)
                .background(NS.bg3)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .padding(8)

                Divider()

                if model.selectedDef == nil {
                    Spacer()
                    Text("Choose a service type from the left")
                        .font(.caption).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                    Spacer()
                } else if let message = statusMessage {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: model.errorMessage != nil ? "exclamationmark.triangle" : (model.selectedDef?.icon ?? "network"))
                            .font(.system(size: 32)).foregroundStyle(.tertiary)
                        Text(message)
                            .font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity)
                    Spacer()
                } else if filtered.isEmpty && !model.isSearching {
                    Spacer()
                    Text("Nothing matches the filter.")
                        .font(.caption).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    List(filtered, selection: $selectedService) { svc in
                        HStack(spacing: 8) {
                            // When browsing all, show the type-specific icon
                            let typeIcon = model.serviceDefs.first(where: { $0.mdnsType == svc.type })?.icon
                                        ?? model.selectedDef?.icon ?? "network"
                            Image(systemName: typeIcon)
                                .foregroundStyle(.blue)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(svc.name).font(.subheadline)
                                // Show type label when browsing all, hostname otherwise
                                if model.selectedDef?.mdnsType == "__all__" {
                                    let typeLabel = model.serviceDefs.first(where: { $0.mdnsType == svc.type })?.label ?? svc.type
                                    Text(typeLabel).font(.caption2).foregroundStyle(.secondary)
                                } else if !svc.hostname.isEmpty {
                                    Text(svc.hostname).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if svc.port > 0 {
                                Text(":\(svc.port)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .tag(svc as BonjourService?)
                    }
                }
            }
            .frame(minWidth: 220, maxWidth: 320)

            // ── Right column: detail ──────────────────────────────────────────
            if let svc = selectedService {
                // The model copy fills in as the resolve answers arrive
                serviceDetail(model.services.first(where: { $0.id == svc.id }) ?? svc)
            } else {
                VStack(spacing: 0) {
                    // Header matches other panes
                    HStack {
                        Text("Service Details").font(.headline).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(NS.bg3)
                    Divider()

                    Spacer()
                    VStack(spacing: 16) {
                        // Don't claim "none" until the search window is over
                        Image(systemName: model.selectedDef == nil
                              ? "network.badge.shield.half.filled"
                              : (model.errorMessage != nil ? "exclamationmark.triangle"
                                 : (model.services.isEmpty
                                    ? (model.isSearching ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                                    : "cursorarrow.click")))
                            .font(.system(size: 44))
                            .foregroundStyle(.tertiary)
                        Text(model.selectedDef == nil
                             ? "Choose a service type"
                             : (statusMessage
                                ?? (model.services.isEmpty ? "Searching for \(serviceNoun)…"
                                                           : "Select a service from the list")))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 320)
                    }
                    .frame(maxWidth: .infinity)
                    Spacer()
                }
            }
        }
        .tabNavigationTitle(.bonjour)
        .onAppear {
            // Start with All Services selected
            model.browseAll()
        }
        .onChange(of: selectedService) { _, svc in model.resolve(svc?.id) }
        .onDisappear { model.stop() }
    }

    /// What's being browsed, for messages.
    private var serviceNoun: String {
        guard let def = model.selectedDef, def.id != model.allServicesDef.id else { return "Bonjour services" }
        return def.label
    }

    /// Error, or the found-nothing message once the search window is over.
    private var statusMessage: String? {
        if let e = model.errorMessage { return e }
        guard model.selectedDef != nil, model.services.isEmpty, !model.isSearching else { return nil }
        return "Nothing on this network is advertising \(serviceNoun). Devices must be on the same Wi-Fi or Ethernet network and have the service switched on."
    }

    private func serviceDetail(_ svc: BonjourService) -> some View {
        // Browsing All Services: show this service's own type, not "All Services"
        let def = model.serviceDefs.first(where: { $0.mdnsType == svc.type })
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack(spacing: 12) {
                    Image(systemName: def?.icon ?? "network")
                        .font(.system(size: 36))
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(svc.name).font(.title2.bold())
                        Text(def?.label ?? svc.type)
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                Divider()

                // Service details
                detailSection("Service Info") {
                    detailRow("Name",   svc.name)
                    detailRow("Type",   svc.type)
                    detailRow("Domain", svc.domain)
                    if svc.port > 0     { detailRow("Port",     "\(svc.port)") }
                    if !svc.hostname.isEmpty { detailRow("Hostname", svc.hostname) }
                }

                if !svc.addresses.isEmpty {
                    detailSection("Addresses") {
                        ForEach(svc.addresses, id: \.self) { addr in
                            detailRow("IP", addr).hostMenu(addr)
                        }
                    }
                }

                if !svc.txtRecord.isEmpty {
                    detailSection("TXT Record") {
                        ForEach(Array(svc.txtRecord.keys.sorted()), id: \.self) { key in
                            detailRow(key, svc.txtRecord[key] ?? "")
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private func detailSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
        .padding(12)
        .background(NS.bg3)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Spacer()
        }
    }
}
