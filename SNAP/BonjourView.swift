// BonjourView.swift
// SNAP — Bonjour / mDNS Browser
// Created by Sevag Bardakjian

import SwiftUI
import Network

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
        BonjourServiceDef(label: "Apple Remote Desktop",   mdnsType: "_remote-adb._tcp",        icon: "desktopcomputer"),
        BonjourServiceDef(label: "VNC (Screen Sharing)",   mdnsType: "_vnc._tcp",               icon: "rectangle.on.rectangle"),
        BonjourServiceDef(label: "iTunes/Music Sharing",   mdnsType: "_daap._tcp",              icon: "music.note.list"),
        BonjourServiceDef(label: "Time Machine",           mdnsType: "_adisk._tcp",             icon: "clock.arrow.circlepath"),
        BonjourServiceDef(label: "Apple TV",               mdnsType: "_appletv-v2._tcp",        icon: "appletv"),
        BonjourServiceDef(label: "AirPort Base Station",   mdnsType: "_airport._tcp",           icon: "wifi.router"),
    ]

    private var browsers: [NWBrowser] = []
    // Sentinel id for "All Services" — checked by label, not mdnsType
    let allServicesDef = BonjourServiceDef(label: "All Services", mdnsType: "__all__", icon: "square.grid.2x2")

    func browseAll() {
        for b in browsers { b.cancel() }
        browsers = []
        services = []
        selectedDef = allServicesDef
        isSearching = true

        // Launch a browser for every service type simultaneously
        for def in serviceDefs {
            startBrowser(type: def.mdnsType)
        }
    }

    private func startBrowser(type mdnsType: String) {
        let descriptor = NWBrowser.Descriptor.bonjour(type: mdnsType, domain: "local.")
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: descriptor, using: params)

        browser.browseResultsChangedHandler = { [weak self] _, changes in
            guard let self else { return }
            DispatchQueue.main.async {
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
        browser.stateUpdateHandler = { state in
            if case .failed = state { browser.cancel() }
        }
        browser.start(queue: .main)
        browsers.append(browser)
    }

    func browse(def: BonjourServiceDef) {
        // Stop any current browsing
        for b in browsers { b.cancel() }
        browsers = []
        services = []
        selectedDef = def
        isSearching = true

        startBrowser(type: def.mdnsType)
    }

    func stop() {
        for b in browsers { b.cancel() }
        browsers = []
        isSearching = false
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
                } else if filtered.isEmpty && !model.isSearching {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: model.selectedDef?.icon ?? "network")
                            .font(.system(size: 32)).foregroundStyle(.tertiary)
                        Text("No \(model.selectedDef?.label ?? "services") found")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text("Make sure devices are on the same network")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
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
                serviceDetail(svc)
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
                        Image(systemName: model.selectedDef == nil
                              ? "network.badge.shield.half.filled"
                              : (model.services.isEmpty ? "antenna.radiowaves.left.and.right.slash" : "cursorarrow.click"))
                            .font(.system(size: 44))
                            .foregroundStyle(.tertiary)
                        Text(model.selectedDef == nil
                             ? "Choose a service type"
                             : (model.services.isEmpty ? "No \(model.selectedDef?.label ?? "services") on this network"
                                                       : "Select a service from the list"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        if model.selectedDef != nil && model.services.isEmpty && !model.isSearching {
                            Text("Devices advertise Bonjour services automatically.\nMake sure they are on the same network.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 260)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    Spacer()
                }
            }
        }
        .navigationTitle("Bonjour Browser")
        .onAppear {
            // Start with All Services selected
            model.browseAll()
        }
        .onDisappear { model.stop() }
    }

    private func serviceDetail(_ svc: BonjourService) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack(spacing: 12) {
                    Image(systemName: model.selectedDef?.icon ?? "network")
                        .font(.system(size: 36))
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(svc.name).font(.title2.bold())
                        Text(model.selectedDef?.label ?? svc.type)
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
