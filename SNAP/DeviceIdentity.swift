// DeviceIdentity.swift
// SNAP — Device identity types + role classification heuristics
// Created by Sevag Bardakjian
// Copyright © 2025 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md
//
// Extracted from DeviceIdentifier.swift in v1.5.1 as part of the god-file split.
// Contains:
//   • DeviceRole, DeviceGroup, IdentitySignal enums
//   • DeviceIdentity struct (the merged best-guess for one device)
//   • Heuristic helpers that turn vendor / hostname strings into roles

import Foundation
import Network
import Darwin

// MARK: - Identity types

enum DeviceRole: String, Codable, Hashable {
    case router          = "Router"
    case accessPoint     = "Access Point"
    case mac             = "Mac"
    case iPhone          = "iPhone"
    case iPad            = "iPad"
    case appleTV         = "Apple TV"
    case homePod         = "HomePod"
    case appleWatch      = "Apple Watch"
    case appleDevice     = "Apple Device"
    case airPlaySpeaker  = "AirPlay Speaker"
    case chromecast      = "Chromecast"
    case googleHome      = "Google Home"
    case nestDevice      = "Nest"
    case homeKitHub      = "HomeKit Hub"
    case sonos           = "Sonos"
    case smartTV         = "Smart TV"
    case fireTV          = "Fire TV"
    case roku            = "Roku"
    case androidPhone    = "Android Phone"
    case windowsPC       = "Windows PC"
    case linux           = "Linux"
    case printer         = "Printer"
    case nas             = "NAS"
    case ipCamera        = "IP Camera"
    case iot             = "IoT Device"
    case gameConsole     = "Game Console"
    case raspberryPi     = "Raspberry Pi"
    case voipPhone       = "VoIP Phone"
    // Enterprise infrastructure roles (v1.3)
    case networkSwitch   = "Switch"
    case firewall        = "Firewall"
    case loadBalancer    = "Load Balancer"
    case wirelessCtrl    = "WLAN Controller"
    case serverHardware  = "Server"
    case unknown         = "Device"

    var icon: String {
        switch self {
        case .router, .accessPoint:   return "wifi.router"
        case .mac:                    return "desktopcomputer"
        case .iPhone:                 return "iphone"
        case .iPad:                   return "ipad"
        case .appleTV:                return "appletv"
        case .homePod:                return "homepod"
        case .appleWatch:             return "applewatch"
        case .appleDevice:            return "applelogo"
        case .airPlaySpeaker:         return "hifispeaker"
        case .chromecast, .googleHome:return "tv.and.mediabox"
        case .nestDevice:             return "thermometer.medium"
        case .homeKitHub:             return "homekit"
        case .sonos:                  return "hifispeaker.2"
        case .smartTV, .fireTV, .roku:return "tv"
        case .androidPhone:           return "candybarphone"
        case .windowsPC:              return "pc"
        case .linux:                  return "terminal"
        case .printer:                return "printer"
        case .nas:                    return "externaldrive.connected.to.line.below"
        case .ipCamera:               return "video"
        case .iot:                    return "lightbulb"
        case .gameConsole:            return "gamecontroller"
        case .raspberryPi:            return "cpu"
        case .voipPhone:              return "phone.connection"
        case .networkSwitch:          return "rectangle.connected.to.line.below"
        case .firewall:               return "shield.lefthalf.filled"
        case .loadBalancer:           return "arrow.triangle.branch"
        case .wirelessCtrl:           return "antenna.radiowaves.left.and.right.circle"
        case .serverHardware:         return "server.rack"
        case .unknown:                return "questionmark.circle"
        }
    }

    /// Grouping bucket for the Visual constellation layout.
    var group: DeviceGroup {
        switch self {
        case .router, .accessPoint:                                return .infrastructure
        case .networkSwitch, .firewall, .loadBalancer, .wirelessCtrl:
            return .infrastructure
        case .serverHardware:                                      return .computer
        case .mac, .windowsPC, .linux, .raspberryPi:               return .computer
        case .iPhone, .iPad, .appleWatch, .androidPhone:           return .mobile
        case .appleTV, .smartTV, .fireTV, .roku, .chromecast:      return .media
        case .homePod, .sonos, .airPlaySpeaker, .googleHome:       return .audio
        case .printer, .nas:                                       return .peripheral
        case .ipCamera, .nestDevice, .homeKitHub, .iot:            return .iot
        case .gameConsole:                                         return .gaming
        case .voipPhone:                                           return .infrastructure
        case .appleDevice, .unknown:                               return .other
        }
    }
}

enum DeviceGroup: String, CaseIterable {
    case infrastructure = "Infrastructure"
    case computer       = "Computers"
    case mobile         = "Mobile"
    case media          = "Streaming"
    case audio          = "Audio"
    case peripheral     = "Peripherals"
    case iot            = "Smart Home"
    case gaming         = "Gaming"
    case other          = "Other"

    /// Angle in radians the group occupies on the constellation ring,
    /// measured from the right (3 o'clock) clockwise.
    var anchorAngle: Double {
        let i = Double(DeviceGroup.allCases.firstIndex(of: self) ?? 0)
        return i / Double(DeviceGroup.allCases.count) * 2 * .pi - .pi / 2
    }
}

enum IdentitySignal: Hashable {
    case mDNS(service: String, model: String?, friendly: String?, hostname: String?)
    case ssdp(server: String?, model: String?, location: String?)
    case netbios(name: String, isServer: Bool)
    case reverseDNS(hostname: String)
    case httpBanner(server: String?, title: String?)
    case oui(vendor: String, hintedRole: DeviceRole)
    /// Ubiquiti / UniFi UDP/10001 discovery response — strongest possible
    /// signal for UniFi gear (model + hostname + firmware come straight from
    /// the device, not guessed).
    case ubnt(model: String?, firmware: String?, hostname: String?)
    case selfDetected
    case gatewayDetected

    var label: String {
        switch self {
        case .mDNS(let svc, _, _, _):  return "mDNS · \(svc)"
        case .ssdp:                    return "SSDP / UPnP"
        case .netbios:                 return "NetBIOS"
        case .reverseDNS:              return "Reverse DNS"
        case .httpBanner:              return "HTTP banner"
        case .oui:                     return "MAC OUI"
        case .ubnt:                    return "UBNT discovery"
        case .selfDetected:            return "This Mac"
        case .gatewayDetected:         return "Default gateway"
        }
    }

    /// One-line human-readable summary of what this signal told us.
    var summary: String {
        switch self {
        case let .mDNS(svc, model, friendly, _):
            let m = model ?? friendly ?? "—"
            return "\(svc) → \(m)"
        case let .ssdp(server, model, _):
            return [model, server].compactMap { $0 }.joined(separator: " · ")
        case let .netbios(name, isServer):
            return "\(name)\(isServer ? " (server)" : "")"
        case .reverseDNS(let h):       return h
        case let .httpBanner(server, title):
            return [server, title].compactMap { $0 }.joined(separator: " · ")
        case .oui(let vendor, _):      return vendor
        case let .ubnt(model, firmware, hostname):
            let parts = [model, hostname, firmware].compactMap { $0 }
            return parts.isEmpty ? "UniFi device" : parts.joined(separator: " · ")
        case .selfDetected:            return "This is your Mac"
        case .gatewayDetected:         return "This is your gateway"
        }
    }
}

/// Summarised identity derived by merging all signals.
struct DeviceIdentity: Hashable {
    var displayName: String?
    var model: String?
    var manufacturer: String?
    var role: DeviceRole = .unknown
    var signals: [IdentitySignal] = []

    var bestLabel: String {
        if let n = displayName, !n.isEmpty { return n }
        if let m = model, !m.isEmpty       { return m }
        if let v = manufacturer, !v.isEmpty { return "\(v) \(role.rawValue)" }
        return role.rawValue
    }

    /// Confidence proxy: more *distinct kinds* of signals → higher.
    var confidence: Double {
        let kinds = Set(signals.map { String(describing: type(of: $0)) + "\($0.label)" })
        return min(1.0, Double(kinds.count) / 3.0)
    }

    mutating func merge(_ signal: IdentitySignal) {
        signals.append(signal)
        apply(signal)
    }

    private mutating func apply(_ signal: IdentitySignal) {
        switch signal {
        case let .mDNS(svc, model, friendly, hostname):
            // mDNS service type is the strongest role hint
            let svcRole = roleFromMDNSService(svc, model: model)
            promote(role: svcRole)
            if let m = model, self.model == nil { self.model = m }
            if let f = friendly, displayName == nil { displayName = f }
            if displayName == nil, let h = hostname?.cleanedHostname() { displayName = h }
            if manufacturer == nil { manufacturer = manufacturerFromMDNSModel(model) }
            // Hostname can also disambiguate role (e.g. UDM-Pro via _ssh._tcp)
            if let h = hostname?.cleanedHostname(),
               let r = roleFromHostname(h) {
                promote(role: r)
            }
            if let h = hostname?.cleanedHostname(),
               let m = manufacturerFromHostname(h),
               manufacturer == nil {
                manufacturer = m
            }
        case let .ssdp(server, model, _):
            if let m = model, self.model == nil { self.model = m }
            promote(role: roleFromServerBanner(server) ?? roleFromServerBanner(model))
            if manufacturer == nil, let s = server { manufacturer = manufacturerFromBanner(s) }
        case let .netbios(name, isServer):
            if displayName == nil { displayName = name }
            promote(role: isServer ? .nas : .windowsPC)
        case .reverseDNS(let h):
            let cleaned = h.cleanedHostname()
            if displayName == nil { displayName = cleaned }
            if let r = roleFromHostname(cleaned) { promote(role: r) }
            if manufacturer == nil, let m = manufacturerFromHostname(cleaned) { manufacturer = m }
        case let .httpBanner(server, title):
            promote(role: roleFromServerBanner(server) ?? roleFromServerBanner(title))
            if let t = title, displayName == nil { displayName = t }
            if manufacturer == nil, let s = server { manufacturer = manufacturerFromBanner(s) }
            if manufacturer == nil, let t = title { manufacturer = manufacturerFromBanner(t) }
        case let .oui(vendor, hintedRole):
            if manufacturer == nil { manufacturer = vendor }
            promote(role: hintedRole, allowOverride: false)
        case let .ubnt(model, _, hostname):
            // UBNT discovery is ground truth for UniFi gear.
            if manufacturer == nil || manufacturer == "Ubiquiti" {
                manufacturer = "Ubiquiti"
            }
            if let m = model, self.model == nil { self.model = m }
            if let h = hostname?.cleanedHostname(), displayName == nil {
                displayName = h
            }
            // Derive role from model prefix (UDM/UXG → router, UAP/U6/U7 → AP,
            // USW → switch which we represent as AP-class infra, UVC → camera).
            if let m = model, let r = roleFromUBNTModel(m) {
                self.role = r   // force — UBNT model is unambiguous
            } else if let h = hostname, let r = roleFromUBNTModel(h) {
                self.role = r
            } else if role == .unknown {
                role = .accessPoint
            }
        case .selfDetected:
            // Ground truth: this IS your Mac, regardless of any other signal.
            self.role = .mac
            if displayName == nil {
                displayName = (Host.current().localizedName ?? ProcessInfo.processInfo.hostName)
            }
            if manufacturer == nil { manufacturer = "Apple" }
        case .gatewayDetected:
            // Ground truth: netstat said this is the default gateway. Only
            // step down from .router if a stronger signal already specified
            // a more specific gateway form (e.g. UBNT said UDM-Pro → still
            // a router; UniFi controller hosted on a separate box would have
            // its own gateway signal anyway).
            if role == .unknown || role == .appleDevice || role == .accessPoint {
                self.role = .router
            }
        }
    }

    /// Apply a candidate role with a priority rule: explicit > vague.
    /// `.unknown` and `.appleDevice` are "vague" and never overwrite a
    /// more specific role.
    private mutating func promote(role candidate: DeviceRole?, allowOverride: Bool = true) {
        guard let candidate = candidate, candidate != .unknown else { return }
        if role == .unknown || role == .appleDevice {
            self.role = candidate; return
        }
        if allowOverride, isMoreSpecific(candidate, than: role) {
            self.role = candidate
        }
    }

    private func isMoreSpecific(_ new: DeviceRole, than current: DeviceRole) -> Bool {
        // Treat .appleDevice as less specific than any concrete Apple form factor.
        if current == .appleDevice && [.mac, .iPhone, .iPad, .appleTV, .homePod, .appleWatch].contains(new) {
            return true
        }
        return false
    }
}

// MARK: - Heuristic helpers (string → role)

private func roleFromMDNSService(_ service: String, model: String?) -> DeviceRole? {
    let m = (model ?? "").lowercased()
    switch service {
    case "_companion-link._tcp":
        if m.contains("iphone") { return .iPhone }
        if m.contains("ipad")   { return .iPad }
        if m.contains("watch")  { return .appleWatch }
        if m.contains("appletv") || m.contains("apple tv") { return .appleTV }
        if m.contains("audioaccessory") || m.contains("homepod") { return .homePod }
        if m.contains("mac") || m.contains("imac") || m.contains("book") { return .mac }
        return .appleDevice
    case "_airplay._tcp", "_raop._tcp":
        if m.contains("appletv") { return .appleTV }
        if m.contains("homepod") { return .homePod }
        if m.contains("audioaccessory") { return .homePod }
        return .airPlaySpeaker
    case "_googlecast._tcp":
        if m.contains("home") { return .googleHome }
        return .chromecast
    case "_hap._tcp":          return .homeKitHub
    case "_ipp._tcp", "_ipps._tcp",
         "_printer._tcp", "_pdl-datastream._tcp": return .printer
    case "_sonos._tcp":        return .sonos
    case "_spotify-connect._tcp": return .airPlaySpeaker
    case "_smb._tcp",
         "_afpovertcp._tcp":   return .mac
    case "_workstation._tcp",
         "_ssh._tcp":          return .linux
    case "_androidtvremote2._tcp": return .smartTV
    case "_amzn-wplay._tcp",
         "_amzn-alexa._tcp":   return .fireTV
    case "_meshcop._udp":      return .homeKitHub
    default: return nil
    }
}

private func roleFromServerBanner(_ banner: String?) -> DeviceRole? {
    guard let s = banner?.lowercased() else { return nil }
    // UniFi web UI titles & banners — appear in <title> ("UniFi OS",
    // "UniFi Network", "UniFi Dream Machine") and SERVER headers.
    if s.contains("unifi") || s.contains("ubiquiti") {
        // Bare "unifi" without a UDM/UAP prefix nearby — assume infra. The
        // hostname-derived role from a separate signal will refine it.
        if let r = roleFromUBNTModel(s) { return r }
        return .accessPoint
    }
    if s.contains("router") || s.contains("openwrt") || s.contains("dd-wrt") ||
       s.contains("asuswrt") || s.contains("tomato") || s.contains("ubnt") ||
       s.contains("tp-link") { return .router }
    if s.contains("hue")     { return .iot }
    if s.contains("sonos")   { return .sonos }
    if s.contains("roku")    { return .roku }
    if s.contains("synology") || s.contains("qnap") || s.contains("freenas") ||
       s.contains("truenas") || s.contains("netatalk") { return .nas }
    if s.contains("axis")    { return .ipCamera }
    if s.contains("hikvision") || s.contains("dahua") { return .ipCamera }
    if s.contains("cups")    { return .printer }
    if s.contains("plex")    { return .nas }
    if s.contains("ipp")     { return .printer }
    return nil
}

private func roleFromHostname(_ host: String) -> DeviceRole? {
    let h = host.lowercased()
    // UniFi prefixes — checked first because they're high-confidence
    if let r = roleFromUBNTModel(h) { return r }
    if h.contains("pixel")    { return .androidPhone }
    if h.contains("iphone")   { return .iPhone }
    if h.contains("ipad")     { return .iPad }
    if h.contains("macbook") || h.contains("imac") || h.contains("mac-mini") { return .mac }
    if h.contains("appletv")  { return .appleTV }
    if h.contains("homepod")  { return .homePod }
    if h.contains("printer") || h.contains("hpprinter") { return .printer }
    if h.contains("synology") || h.contains("qnap") || h.contains("nas") { return .nas }
    if h.contains("chromecast") || h.contains("nest")   { return .chromecast }
    if h.contains("router") || h.contains("gateway") || h.contains("modem") { return .router }
    if h.contains("xbox")     { return .gameConsole }
    if h.contains("ps5") || h.contains("ps4") || h.contains("playstation") { return .gameConsole }
    if h.contains("switch")   { return .gameConsole }
    if h.contains("kindle") || h.contains("firetv") || h.contains("echo")   { return .fireTV }
    if h.contains("raspberrypi") || h.contains("raspi") { return .raspberryPi }
    if h.contains("android")  { return .androidPhone }
    return nil
}

/// Maps a UniFi/UBNT model code or hostname prefix to the right role.
/// UniFi naming convention is consistent enough that the prefix alone is
/// usually all we need:
///   UDM-*  / UDR-* / UXG-* / USG-* / UCG-* → security gateway / router
///   UAP-*  / U6-*  / U7-*                  → access point
///   USW-*  / US-*                          → switch (we surface as AP-class)
///   UVC-*  / G3-*  / G4-*  / G5-*          → camera
///   UCK-*  / Cloud Key                     → NAS-class (controller)
///   UAH-*  / UA-Hub                        → IoT
private func roleFromUBNTModel(_ raw: String) -> DeviceRole? {
    let s = raw.lowercased()
    if s.hasPrefix("udm")   || s.hasPrefix("udr")   ||
       s.hasPrefix("uxg")   || s.hasPrefix("usg")   ||
       s.hasPrefix("ucg")   { return .router }
    if s.hasPrefix("uap")   || s.hasPrefix("u6-")   ||
       s.hasPrefix("u7-")   || s.hasPrefix("uap-")  ||
       s.hasPrefix("u6 ")   || s.hasPrefix("u7 ")   { return .accessPoint }
    if s.hasPrefix("usw")   || s.hasPrefix("us-")   ||
       s.hasPrefix("usw-")  || s.contains("unifi switch") { return .accessPoint }
    if s.hasPrefix("uvc")   || s.hasPrefix("g3-")   ||
       s.hasPrefix("g4-")   || s.hasPrefix("g5-")   ||
       s.contains("protect") { return .ipCamera }
    if s.hasPrefix("uck")   || s.contains("cloud key") { return .nas }
    if s.hasPrefix("uah")   || s.contains("ua-hub") { return .iot }
    // Fallback: anything tagged UniFi or Ubiquiti without a more specific
    // prefix is treated as access-point-class infrastructure.
    if s.contains("unifi") || s.contains("ubiquiti") || s.contains("ubnt") {
        return .accessPoint
    }
    return nil
}

private func manufacturerFromHostname(_ host: String) -> String? {
    let h = host.lowercased()
    if h.hasPrefix("udm") || h.hasPrefix("uap") || h.hasPrefix("usw") ||
       h.hasPrefix("uxg") || h.hasPrefix("udr") || h.hasPrefix("uvc") ||
       h.hasPrefix("uck") || h.hasPrefix("u6-") || h.hasPrefix("u7-") ||
       h.contains("unifi") || h.contains("ubiquiti") {
        return "Ubiquiti"
    }
    if h.contains("synology") { return "Synology" }
    if h.contains("qnap")     { return "QNAP" }
    if h.contains("hue")      { return "Philips Hue" }
    if h.contains("sonos")    { return "Sonos" }
    if h.contains("roku")     { return "Roku" }
    return nil
}

private func manufacturerFromMDNSModel(_ model: String?) -> String? {
    guard let m = model?.lowercased() else { return nil }
    if m.contains("appletv") || m.contains("iphone") || m.contains("ipad") ||
       m.contains("imac") || m.contains("macbook") || m.contains("homepod") ||
       m.contains("watch") { return "Apple" }
    if m.contains("nest") || m.contains("chromecast") || m.contains("googlehome") { return "Google" }
    if m.contains("sonos")    { return "Sonos" }
    return nil
}

private func manufacturerFromBanner(_ banner: String) -> String? {
    let b = banner.lowercased()
    if b.contains("unifi") || b.contains("ubiquiti") || b.contains("ubnt") { return "Ubiquiti" }
    if b.contains("openwrt")  { return "OpenWrt" }
    if b.contains("tp-link")  { return "TP-Link" }
    if b.contains("synology") { return "Synology" }
    if b.contains("qnap")     { return "QNAP" }
    if b.contains("hue")      { return "Philips Hue" }
    if b.contains("sonos")    { return "Sonos" }
    if b.contains("roku")     { return "Roku" }
    if b.contains("axis")     { return "Axis" }
    if b.contains("hikvision") { return "Hikvision" }
    if b.contains("dahua")    { return "Dahua" }
    return nil
}

private extension String {
    /// Strip the trailing `.local.` or `.lan.` and any trailing dot.
    func cleanedHostname() -> String {
        var h = self
        while h.hasSuffix(".") { h.removeLast() }
        for suffix in [".local", ".lan", ".home", ".home.arpa", ".localdomain"] {
            if h.lowercased().hasSuffix(suffix) {
                h = String(h.dropLast(suffix.count)); break
            }
        }
        return h
    }
}
