// InfoView.swift
// SNAP — Network Info tab (full redesign in v1.2.4)
// Created by Sevag Bardakjian
// Copyright © 2025 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
//
// Two-pane layout:
//   • Left: custom dark-themed interface picker (replaces the translucent
//     native sidebar List). Each row shows status dot + display name +
//     interface code + IPv4 count chip, with an amber "Active route" pill
//     on whichever interface carries the default gateway.
//   • Right: card-based detail pane (Hardware / IPv4 / IPv6 / Wi-Fi /
//     Traffic / DHCP) using NS design tokens, matching the rest of the app.
//
// A "Connection Summary" hero card sits above both panes — the at-a-glance
// answer to "what's my internet right now?" without any clicking.

import SwiftUI
import Network
import AppKit
import CoreWLAN

struct InfoView: View {
    @StateObject private var provider = NetworkInfoProvider()
    @State private var selectedName: String? = nil
    @State private var dhcpLease: DHCPLeaseInfo? = nil
    @State private var dhcpLoading: Bool = false

    private var selectedInterface: InterfaceInfo? {
        provider.interfaces.first { $0.name == selectedName }
    }

    var body: some View {
        VStack(spacing: 0) {
            ConnectionSummaryCard()
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 4)
            Divider()
            HSplitView {
                interfaceSidebar
                detailPane
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { provider.refresh() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Re-enumerate interfaces")
            }
            ToolbarItem(placement: .primaryAction) {
                ToolActionBar("Network Info",
                              text:  { exportText() },
                              json:  { exportJSON() })
            }
        }
        .navigationTitle("Network Info")
        .onChange(of: selectedName) { _ in
            loadDHCPForSelected()
        }
        .onAppear { loadDHCPForSelected() }
    }

    private func loadDHCPForSelected() {
        guard let iface = selectedName else { dhcpLease = nil; return }
        dhcpLease = nil
        dhcpLoading = true
        Task {
            let lease = await DHCPHelper.fetchLease(iface: iface)
            await MainActor.run {
                self.dhcpLease = lease
                self.dhcpLoading = false
            }
        }
    }

    // MARK: - Sidebar

    private var interfaceSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("INTERFACES")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(NS.text3)
                    .tracking(0.5)
                Spacer()
                Text("\(provider.interfaces.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(NS.text4)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)

            Divider().background(NS.borderMid)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(provider.interfaces) { iface in
                        InterfaceRow(
                            iface: iface,
                            isSelected: selectedName == iface.name,
                            isActiveRoute: provider.activeRouteInterface == iface.name,
                            onTap: { selectedName = iface.name }
                        )
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 6)
            }

            Spacer(minLength: 0)
        }
        .frame(minWidth: 230, maxWidth: 280)
        .background(NS.bg1)
        .onAppear {
            if selectedName == nil {
                selectedName = provider.activeRouteInterface ?? provider.interfaces.first?.name
            }
        }
        // The tab stays alive in the background; reload on return, as
        // opening the tab always did.
        .onTabVisibilityChange(shown: { provider.refresh() })
        .onChange(of: provider.interfaces.count, perform: { _ in
            if selectedName == nil {
                selectedName = provider.activeRouteInterface ?? provider.interfaces.first?.name
            }
        })
    }

    // MARK: - Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if let iface = selectedInterface {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(iface)
                    HardwareCard(iface: iface)
                    IPv4Card(iface: iface, isActiveRoute: provider.activeRouteInterface == iface.name)
                    IPv6Card(iface: iface)
                    if iface.mediaType == .wifi {
                        WiFiCard(iface: iface)
                    }
                    TrafficCard(iface: iface)
                    if let lease = dhcpLease {
                        DHCPCard(lease: lease, iface: iface.name)
                    } else if dhcpLoading {
                        Text("Looking up DHCP lease for \(iface.name)…")
                            .font(.system(size: 11))
                            .foregroundStyle(NS.text3)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(NS.bg0)
        } else if !provider.interfaces.isEmpty {
            EmptyStateView(title: "Select an Interface",
                           systemImage: "network",
                           description: "Choose an interface from the list to see its details")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(NS.bg0)
        } else {
            EmptyStateView(title: "Loading…",
                           systemImage: "arrow.clockwise",
                           description: "Gathering network interfaces")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(NS.bg0)
        }
    }

    private func header(_ iface: InterfaceInfo) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(iface.mediaType == .wifi ? NS.amber.opacity(0.15) : NS.blue.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: iface.mediaType.icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(iface.mediaType == .wifi ? NS.amber : NS.blue)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(iface.displayName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(NS.text1)
                Text("\(iface.mediaType.rawValue) · \(iface.name)")
                    .font(.system(size: 11))
                    .foregroundStyle(NS.text3)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                statusPill(iface)
                if provider.activeRouteInterface == iface.name {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.forward.app.fill").font(.system(size: 9))
                        Text("ACTIVE ROUTE").font(.system(size: 9, weight: .bold)).tracking(0.5)
                    }
                    .foregroundStyle(NS.amber)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(NS.amber.opacity(0.10)))
                }
            }
        }
    }

    private func statusPill(_ iface: InterfaceInfo) -> some View {
        let color: Color = iface.carrier == false ? NS.red
            : (iface.isUp ? NS.green : NS.text3)
        let label: String = iface.carrier == false ? "No carrier"
            : (iface.isUp ? "Up" : "Down")
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.10)))
    }

    // MARK: Export

    private func exportText() -> String {
        var out = "Network Info — \(Date().formatted())\n"
        out += "Hostname: \(provider.hostname)   External IP: \(provider.externalIP)\n"
        out += String(repeating: "—", count: 70) + "\n"
        for i in provider.interfaces {
            out += "\n[\(i.name)] \(i.displayName)\n"
            out += "  Status:  \(i.isUp ? "up" : "down")\(i.carrier == false ? " (no carrier)" : "")\n"
            out += "  MAC:     \(i.macAddress)\n"
            if let m = i.mtu { out += "  MTU:     \(m)\n" }
            if let s = i.linkSpeed { out += "  Speed:   \(s)\(i.duplex.map { " · \($0) duplex" } ?? "")\n" }
            if !i.ipv4Bindings.isEmpty {
                out += "  IPv4:    \(i.ipv4Bindings.map { $0.withCIDR }.joined(separator: ", "))\n"
            }
            if !i.ipv6Bindings.isEmpty {
                out += "  IPv6:    \(i.ipv6Bindings.map { $0.ip }.joined(separator: ", "))\n"
            }
            if let t = i.traffic {
                out += "  RX:      \(t.rxBytes)B / \(t.rxPackets)pkt / \(t.rxErrors)err\n"
                out += "  TX:      \(t.txBytes)B / \(t.txPackets)pkt / \(t.txErrors)err\n"
            }
        }
        return out
    }

    private func exportJSON() -> String {
        let arr: [[String: Any]] = provider.interfaces.map { i in
            var d: [String: Any] = [
                "name": i.name,
                "display_name": i.displayName,
                "media_type": i.mediaType.rawValue,
                "mac": i.macAddress,
                "up": i.isUp,
                "ipv4": i.ipv4Bindings.map { ["ip": $0.ip, "cidr": $0.cidr] as [String: Any] },
                "ipv6": i.ipv6Bindings.map { ["ip": $0.ip, "scope": $0.scope] as [String: Any] },
            ]
            if let m = i.mtu       { d["mtu"] = m }
            if let s = i.linkSpeed { d["link_speed"] = s }
            if let dup = i.duplex  { d["duplex"] = dup }
            if let c = i.carrier   { d["carrier"] = c }
            if let t = i.traffic {
                d["traffic"] = [
                    "rx_bytes": t.rxBytes, "tx_bytes": t.txBytes,
                    "rx_packets": t.rxPackets, "tx_packets": t.txPackets,
                    "rx_errors": t.rxErrors, "tx_errors": t.txErrors,
                ] as [String: Any]
            }
            return d
        }
        let payload: [String: Any] = [
            "tool": "Network Info",
            "exported_at": ISO8601DateFormatter().string(from: Date()),
            "hostname": provider.hostname,
            "external_ip": provider.externalIP,
            "active_route_interface": provider.activeRouteInterface as Any,
            "interfaces": arr,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}

// MARK: - Sidebar row

private struct InterfaceRow: View {
    let iface: InterfaceInfo
    let isSelected: Bool
    let isActiveRoute: Bool
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Circle()
                    .fill(iface.carrier == false ? NS.red : (iface.isUp ? NS.green : NS.text3))
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(iface.displayName)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? NS.text1 : NS.text2)
                            .lineLimit(1)
                        if isActiveRoute {
                            Image(systemName: "arrow.up.forward.app.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(NS.amber)
                        }
                    }
                    HStack(spacing: 4) {
                        Text(iface.name)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(NS.text3)
                        if iface.mediaType != .other {
                            Text("· \(iface.mediaType.rawValue)")
                                .font(.system(size: 10))
                                .foregroundStyle(NS.text3)
                        }
                    }
                }
                Spacer()
                if !iface.ipv4.isEmpty {
                    Text("\(iface.ipv4.count)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(NS.text3)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(NS.bg2))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected
                          ? NS.amber.opacity(0.12)
                          : (isHovered ? NS.text1.opacity(0.03) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? NS.amber.opacity(0.3) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Card primitives

private struct InfoCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11)).foregroundStyle(NS.amber)
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(NS.text3)
                    .tracking(0.5)
                Spacer()
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NS.bg2)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(NS.border, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct KVRow: View {
    let label: String
    let value: String
    var mono: Bool = true
    var color: Color = NS.text1
    var emphasized: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(NS.text3)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.system(size: emphasized ? 13 : 11,
                              weight: emphasized ? .medium : .regular,
                              design: mono ? .monospaced : .default))
                .foregroundStyle(color)
                .textSelection(.enabled)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Hardware card

private struct HardwareCard: View {
    let iface: InterfaceInfo

    var body: some View {
        InfoCard(title: "Hardware", icon: "cpu") {
            KVRow(label: "Interface",    value: iface.name)
            KVRow(label: "Friendly",     value: iface.displayName, mono: false)
            KVRow(label: "Media",        value: iface.mediaType.rawValue, mono: false)
            KVRow(label: "MAC",          value: iface.macAddress)
            if let mtu = iface.mtu { KVRow(label: "MTU", value: "\(mtu)") }
            if let s = iface.linkSpeed {
                KVRow(label: "Link speed",
                      value: iface.duplex.map { "\(s) · \($0) duplex" } ?? s,
                      mono: false)
            }
            if let c = iface.carrier {
                KVRow(label: "Carrier",
                      value: c ? "Active" : "No carrier",
                      mono: false,
                      color: c ? NS.green : NS.red)
            }
            if !iface.flags.isEmpty {
                KVRow(label: "Flags", value: iface.flags)
            }
        }
    }
}

// MARK: - IPv4 card

private struct IPv4Card: View {
    let iface: InterfaceInfo
    let isActiveRoute: Bool

    var body: some View {
        InfoCard(title: "IPv4", icon: "4.circle") {
            if iface.ipv4Bindings.isEmpty {
                Text("No IPv4 addresses assigned")
                    .font(.system(size: 11))
                    .foregroundStyle(NS.text3)
            } else {
                ForEach(Array(iface.ipv4Bindings.enumerated()), id: \.offset) { idx, b in
                    KVRow(
                        label: idx == 0 ? "Address" : " ",
                        value: b.withCIDR,
                        emphasized: idx == 0
                    )
                }
                if isActiveRoute {
                    Divider().background(NS.borderMid).padding(.vertical, 2)
                    Text("This interface carries the default route.")
                        .font(.system(size: 10))
                        .foregroundStyle(NS.amber)
                }
            }
        }
    }
}

// MARK: - IPv6 card

private struct IPv6Card: View {
    let iface: InterfaceInfo

    private var grouped: [(scope: String, ips: [String])] {
        let order = ["global", "unique-local", "link-local", "multicast", "loopback"]
        let groups = Dictionary(grouping: iface.ipv6Bindings, by: { $0.scope })
        return order.compactMap { s in
            guard let arr = groups[s], !arr.isEmpty else { return nil }
            return (scope: s, ips: arr.map { $0.ip })
        }
    }

    var body: some View {
        InfoCard(title: "IPv6", icon: "6.circle") {
            if iface.ipv6Bindings.isEmpty {
                Text("No IPv6 addresses assigned")
                    .font(.system(size: 11))
                    .foregroundStyle(NS.text3)
            } else {
                ForEach(Array(grouped.enumerated()), id: \.offset) { _, group in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.scope.uppercased())
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(NS.text3)
                            .tracking(0.5)
                        ForEach(group.ips, id: \.self) { ip in
                            Text(ip)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(NS.text1)
                                .textSelection(.enabled)
                                .lineLimit(1)
                        }
                    }
                    .padding(.bottom, 2)
                }
            }
        }
    }
}

// MARK: - Wi-Fi card (CoreWLAN)

private struct WiFiCard: View {
    let iface: InterfaceInfo
    @State private var snapshot: WiFiSnapshot? = nil

    var body: some View {
        InfoCard(title: "Wi-Fi", icon: "wifi") {
            if let s = snapshot {
                if let n = s.ssid    { KVRow(label: "SSID",     value: n, mono: false, emphasized: true) }
                if let n = s.bssid   { KVRow(label: "BSSID",    value: n) }
                let channelLine = [
                    s.channel.map { "Ch \($0)" },
                    s.band,
                ].compactMap { $0 }.joined(separator: " · ")
                if !channelLine.isEmpty {
                    KVRow(label: "Channel", value: channelLine, mono: false)
                }
                if let r = s.rssi    { KVRow(label: "Signal",   value: "\(r) dBm") }
                if let tx = s.txRate { KVRow(label: "TX rate",  value: String(format: "%.0f Mbps", tx)) }
                if let sec = s.security { KVRow(label: "Security", value: sec, mono: false) }
            } else {
                Text("No Wi-Fi association reported (Location permission required, or interface is in monitor mode).")
                    .font(.system(size: 11))
                    .foregroundStyle(NS.text3)
            }
        }
        .onAppear { snapshot = WiFiSnapshot.fetch() }
    }
}

private struct WiFiSnapshot {
    let ssid: String?
    let bssid: String?
    let channel: Int?
    let band: String?
    let rssi: Int?
    let txRate: Double?
    let security: String?

    static func fetch() -> WiFiSnapshot? {
        guard let iface = CWWiFiClient.shared().interface(), iface.ssid() != nil else {
            return nil
        }
        let chan = iface.wlanChannel()
        let bandLabel: String? = {
            guard let b = chan?.channelBand else { return nil }
            switch b {
            case .band2GHz: return "2.4 GHz"
            case .band5GHz: return "5 GHz"
            case .band6GHz: return "6 GHz"
            case .bandUnknown: return nil
            @unknown default: return nil
            }
        }()
        let security: String = {
            switch iface.security() {
            case .none:                return "Open"
            case .WEP:                 return "WEP"
            case .wpaPersonal,
                 .wpaPersonalMixed:    return "WPA"
            case .wpa2Personal:        return "WPA2"
            case .wpaEnterprise,
                 .wpaEnterpriseMixed:  return "WPA Enterprise"
            case .wpa2Enterprise:      return "WPA2 Enterprise"
            case .wpa3Personal:        return "WPA3"
            case .wpa3Enterprise:      return "WPA3 Enterprise"
            case .wpa3Transition:      return "WPA2/WPA3"
            case .personal:            return "Personal"
            case .enterprise:          return "Enterprise"
            case .dynamicWEP:          return "Dynamic WEP"
            default:                   return "Unknown"
            }
        }()
        return WiFiSnapshot(
            ssid:    DemoMode.isActive ? DemoMode.ssid : iface.ssid(),
            bssid:   DemoMode.isActive ? DemoMode.macAddress : iface.bssid(),
            channel: chan.map { Int($0.channelNumber) },
            band:    bandLabel,
            rssi:    iface.rssiValue() != 0 ? Int(iface.rssiValue()) : nil,
            txRate:  iface.transmitRate() > 0 ? iface.transmitRate() : nil,
            security: security
        )
    }
}

// MARK: - Traffic card

private struct TrafficCard: View {
    let iface: InterfaceInfo

    var body: some View {
        InfoCard(title: "Traffic since boot", icon: "arrow.up.arrow.down") {
            if let t = iface.traffic {
                HStack(spacing: 14) {
                    trafficSide(label: "RX",
                                bytes: t.rxBytes, packets: t.rxPackets,
                                errors: t.rxErrors, dropped: t.rxDropped,
                                color: NS.green)
                    Divider().frame(width: 0.5).background(NS.borderMid)
                    trafficSide(label: "TX",
                                bytes: t.txBytes, packets: t.txPackets,
                                errors: t.txErrors, dropped: 0,
                                color: NS.blue)
                }
            } else {
                Text("No traffic counters available for this interface.")
                    .font(.system(size: 11))
                    .foregroundStyle(NS.text3)
            }
        }
    }

    private func trafficSide(label: String, bytes: UInt64, packets: UInt64,
                             errors: UInt32, dropped: UInt32, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(label).font(.system(size: 10, weight: .bold)).foregroundStyle(color)
            }
            Text(formatBytes(Double(bytes)))
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .foregroundStyle(NS.text1)
            Text("\(packets.formatted()) packets")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(NS.text3)
            if errors > 0 {
                Text("\(errors) errors")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(NS.red)
            }
            if dropped > 0 {
                Text("\(dropped) dropped")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(NS.amber)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formatBytes(_ n: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var v = n; var i = 0
        while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
        return String(format: i == 0 ? "%.0f %@" : "%.2f %@", v, units[i])
    }
}

// MARK: - DHCP lease card

private struct DHCPCard: View {
    let lease: DHCPLeaseInfo
    let iface: String

    var body: some View {
        InfoCard(title: "DHCP lease", icon: "doc.text.below.ecg") {
            if let s = lease.serverIdentifier { KVRow(label: "DHCP server", value: s) }
            if let r = lease.router           { KVRow(label: "Router",      value: r) }
            if let m = lease.subnetMask       { KVRow(label: "Subnet mask", value: m) }
            if let d = lease.domainName       { KVRow(label: "Domain",      value: d, mono: false) }
            if !lease.dnsServers.isEmpty {
                KVRow(label: "DNS",
                      value: lease.dnsServers.joined(separator: ", "))
            }
            if let t = lease.leaseSeconds {
                KVRow(label: "Lease",   value: formatDuration(t), mono: false)
            }
            if let t = lease.renewalSeconds {
                KVRow(label: "Renewal", value: formatDuration(t), mono: false)
            }
            if let t = lease.rebindingSeconds {
                KVRow(label: "Rebind",  value: formatDuration(t), mono: false)
            }
            if let e = lease.leaseExpires {
                KVRow(label: "Expires",
                      value: e.formatted(date: .numeric, time: .standard),
                      mono: false,
                      color: e > Date() ? NS.text1 : NS.red)
            }
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(seconds % 60)s" }
        return "\(seconds)s"
    }
}
