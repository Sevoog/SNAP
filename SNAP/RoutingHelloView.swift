// RoutingHelloView.swift
// SNAP — Passive Routing / First-Hop Redundancy listener
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md
//
// Passive multicast listener for the FHRP/routing protocols we can see
// without privileged raw-socket access (UDP-encapsulated only):
//
//   • HSRPv1 on 224.0.0.2:1985 (UDP) — Cisco gateway redundancy
//   • HSRPv2 on 224.0.0.102:1985 (UDP) — same, TLV format
//   • GLBP   on 224.0.0.102:3222 (UDP) — Cisco gateway load balancing
//
// OSPF / EIGRP / VRRP / PIM run as raw IP protocols (89, 88, 112, 103)
// directly on IP without a UDP header. Capturing them requires BPF/root,
// which SNAP intentionally doesn't claim. They're listed in the limitations
// footer so users know what's NOT being detected.
//
// Speakers are deduplicated by (protocol, source IP, group). Last-seen
// timestamp updates each time a hello is received.

import SwiftUI
import Network
import dnssd

// MARK: - Detected speaker

struct RoutingSpeaker: Identifiable, Hashable {
    enum Proto: String, CaseIterable {
        case hsrpV1 = "HSRPv1"
        case hsrpV2 = "HSRPv2"
        case glbp   = "GLBP"
    }
    let id: String                 // proto|sourceIP|group
    let proto: Proto
    let sourceIP: String
    let group: Int
    var priority: Int
    var state: String
    var virtualIP: String
    var lastSeen: Date
    /// False for a GLBP packet with no Hello part (a Request/Response or
    /// Auth-only packet): it shows the router is there but says nothing
    /// about its priority, state, or virtual IP.
    var hasDetails = true

    /// `existing` updated by a newer packet from the same speaker. A packet
    /// without details only refreshes Last Seen; it used to blank the
    /// priority, state, and virtual IP the router's Hello had reported.
    static func merged(_ existing: RoutingSpeaker, with new: RoutingSpeaker) -> RoutingSpeaker {
        var out = existing
        out.lastSeen = new.lastSeen
        guard new.hasDetails else { return out }
        out.priority = new.priority
        out.state = new.state
        out.virtualIP = new.virtualIP
        out.hasDetails = true
        return out
    }
}

// MARK: - Listener model

@MainActor
final class RoutingHelloModel: ObservableObject {
    @Published var isListening = false
    @Published var speakers: [RoutingSpeaker] = []
    @Published var packetCount = 0
    @Published var startedAt: Date?
    @Published var errorMessage: String?

    private var groups: [NWConnectionGroup] = []

    deinit {
        // Backstop if the model deallocates while listening — cancel() is
        // the documented teardown for multicast joins
        for g in groups { g.cancel() }
    }

    func start() {
        guard !isListening else { return }
        errorMessage = nil
        speakers.removeAll()
        packetCount = 0
        startedAt = Date()

        let configs: [(String, UInt16, RoutingSpeaker.Proto, (Data, String) -> RoutingSpeaker?)] = [
            ("224.0.0.2",   1985, .hsrpV1, parseHSRPv1),
            ("224.0.0.102", 1985, .hsrpV2, parseHSRPv2),
            ("224.0.0.102", 3222, .glbp,   parseGLBP),
        ]

        // One group failing (two share UDP 1985) shouldn't silence the others
        for (groupAddr, port, _, parser) in configs {
            if let g = try? joinMulticast(groupAddr: groupAddr, port: port, parser: parser) {
                groups.append(g)
            }
        }
        guard !groups.isEmpty else {
            listenFailed()
            return
        }
        isListening = true
    }

    static let listenFailedMessage = "SNAP couldn't listen for router hellos on this network. Check that SNAP is allowed Local Network access in System Settings > Privacy & Security, then press Listen again."

    /// Every group failed: leave them all so the UI never says "listening" while deaf.
    private func listenFailed() {
        stop()
        errorMessage = Self.listenFailedMessage
    }

    /// Failed, or waiting because Local Network access was denied: either
    /// way this group will never hear anything.
    nonisolated static func isDead(_ state: NWConnectionGroup.State) -> Bool {
        switch state {
        case .failed:
            return true
        case .waiting(let error):
            if case .dns(let code) = error, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) { return true }
            return false
        default:
            return false
        }
    }

    func stop() {
        for g in groups { g.cancel() }
        groups.removeAll()
        isListening = false
    }

    private func joinMulticast(groupAddr: String,
                               port: UInt16,
                               parser: @escaping (Data, String) -> RoutingSpeaker?) throws -> NWConnectionGroup {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "RoutingHello", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "invalid port"])
        }
        let host = NWEndpoint.Host(groupAddr)
        let mc = try NWMulticastGroup(for: [.hostPort(host: host, port: nwPort)])
        let group = NWConnectionGroup(with: mc, using: .udp)

        group.setReceiveHandler(maximumMessageSize: 2048, rejectOversizedMessages: true) {
            [weak self] message, content, _ in
            guard let self = self, let data = content else { return }
            // Source IP comes back as the remote endpoint on the message.
            let src: String = {
                if case let .hostPort(host: host, port: _) = message.remoteEndpoint {
                    return "\(host)"
                }
                return "?"
            }()
            DispatchQueue.main.async {
                self.packetCount += 1
                if let sp = parser(data, src) {
                    self.upsert(sp)
                }
            }
        }
        group.stateUpdateHandler = { [weak self, weak group] state in
            guard Self.isDead(state) else { return }
            DispatchQueue.main.async {
                // Ignore a group from an earlier session that already stopped
                guard let self, let group, self.groups.contains(where: { $0 === group }) else { return }
                group.cancel()
                self.groups.removeAll { $0 === group }
                if self.groups.isEmpty { self.listenFailed() }
            }
        }
        group.start(queue: DispatchQueue.global(qos: .utility))
        return group
    }

    private func upsert(_ sp: RoutingSpeaker) {
        if let idx = speakers.firstIndex(where: { $0.id == sp.id }) {
            speakers[idx] = RoutingSpeaker.merged(speakers[idx], with: sp)
        } else {
            speakers.append(sp)
        }
    }

    func exportText() -> String {
        var s = "Routing/FHRP listener\n"
        if let t = startedAt { s += "started: \(t)\n" }
        s += "packets observed: \(packetCount)\nspeakers: \(speakers.count)\n\n"
        s += "proto\tsource\tgroup\tpriority\tstate\tvirtual IP\tlast seen\n"
        for sp in speakers {
            s += "\(sp.proto.rawValue)\t\(sp.sourceIP)\t\(sp.group)\t\(sp.priority)\t\(sp.state)\t\(sp.virtualIP)\t\(sp.lastSeen)\n"
        }
        return s
    }
}

// MARK: - Parsers

private func parseHSRPv1(_ data: Data, _ src: String) -> RoutingSpeaker? {
    // RFC 2281: 20-byte fixed header.
    guard data.count >= 20 else { return nil }
    let b = [UInt8](data)
    let version = b[0]
    guard version == 0 else { return nil }       // v1 only
    let state = b[2]
    let priority = b[5]
    let groupNum = b[6]
    let vipBytes = b[16..<20]
    let vip = vipBytes.map(String.init).joined(separator: ".")
    let id = "HSRPv1|\(src)|\(groupNum)"
    return RoutingSpeaker(id: id,
                          proto: .hsrpV1,
                          sourceIP: src,
                          group: Int(groupNum),
                          priority: Int(priority),
                          state: hsrpStateLabel(state),
                          virtualIP: vip,
                          lastSeen: Date())
}

// Internal (not private) so tests can check the no-TLV case
func parseHSRPv2(_ data: Data, _ src: String) -> RoutingSpeaker? {
    // RFC 5798 / Cisco HSRPv2 uses a TLV format. First byte = type (0x01
    // for Group State TLV), second = length. We scan TLVs for the Group
    // State TLV (40 bytes) which carries group number, state, priority,
    // and virtual IP.
    let b = [UInt8](data)
    var i = 0
    while i + 2 <= b.count {
        let type = b[i]
        let length = Int(b[i + 1])
        if length == 0 || i + 2 + length > b.count { break }
        if type == 0x01 && length >= 38 {
            // Group State TLV layout from packet captures:
            // ver(1) opCode(1) state(1) ipVer(1) group(2) ...
            // priority is at offset i+11, vip-byte-count varies.
            let state = b[i + 4]
            let groupHi = b[i + 6], groupLo = b[i + 7]
            let groupNum = (Int(groupHi) << 8) | Int(groupLo)
            let priority = b[i + 11]
            // Virtual IPv4 is at offset i + 16 in most encodings.
            var vip = "—"
            if length >= 22 {
                vip = b[(i+16)..<(i+20)].map(String.init).joined(separator: ".")
            }
            return RoutingSpeaker(
                id: "HSRPv2|\(src)|\(groupNum)",
                proto: .hsrpV2,
                sourceIP: src,
                group: groupNum,
                priority: Int(priority),
                state: hsrpStateLabel(state),
                virtualIP: vip,
                lastSeen: Date()
            )
        }
        i += 2 + length
    }
    // No Group State TLV recognized: the packet still counts toward the
    // packet total, but a made-up group 0 / priority 0 row would read as a real speaker
    return nil
}

private func hsrpStateLabel(_ s: UInt8) -> String {
    switch s {
    case 0:  return "Initial"
    case 1:  return "Learn"
    case 2:  return "Listen"
    case 4:  return "Speak"
    case 8:  return "Standby"
    case 16: return "Active"
    default: return "state(\(s))"
    }
}

func parseGLBP(_ data: Data, _ src: String) -> RoutingSpeaker? {
    // GLBP is also TLV. Header is:
    //   version(1) reserved(1) group(2) reserved(2) sender_id(6) ...
    // Followed by TLVs (Hello, Request/Response, Auth, etc.).
    guard data.count >= 12 else { return nil }
    let b = [UInt8](data)
    let group = (Int(b[2]) << 8) | Int(b[3])

    // Walk TLVs starting at offset 12 looking for Hello TLV (type 1) which
    // carries priority + state. GLBP TLV: type(1) length(1) body…
    var priority = 0
    var state = "—"
    var vip = "—"
    var sawHello = false
    var i = 12
    while i + 2 <= b.count {
        let type = b[i]
        let length = Int(b[i + 1])
        if length < 2 || i + length > b.count { break }
        if type == 1 && length >= 12 {           // Hello TLV
            sawHello = true
            state = glbpStateLabel(b[i + 6])
            priority = Int(b[i + 7])
            // Hello can include a virtual IPv4 address near the tail.
            if length >= 18 {
                vip = b[(i+length-4)..<(i+length)].map(String.init).joined(separator: ".")
            }
            break
        }
        i += length
    }
    return RoutingSpeaker(
        id: "GLBP|\(src)|\(group)",
        proto: .glbp,
        sourceIP: src,
        group: group,
        priority: priority,
        state: state,
        virtualIP: vip,
        lastSeen: Date(),
        hasDetails: sawHello
    )
}

private func glbpStateLabel(_ s: UInt8) -> String {
    switch s {
    case 1:  return "Disabled"
    case 2:  return "Initial"
    case 4:  return "Listen"
    case 8:  return "Speak"
    case 16: return "Standby"
    case 32: return "Active"
    default: return "state(\(s))"
    }
}

// MARK: - View

struct RoutingHelloView: View {
    @StateObject private var model = RoutingHelloModel()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let err = model.errorMessage { errorBanner(err) }
            speakersTable
            Divider().background(NS.borderMid)
            limitationsFooter
        }
        .tabNavigationTitle(.routingHello)
        // Runs when the window closes (tabs now stay alive across switches) — leave the
        // multicast groups cleanly instead of leaking the joins
        .onDisappear { model.stop() }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(NS.blue)
            Text("Routing / FHRP listener")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(NS.text1)
            if model.isListening, let t = model.startedAt {
                Text("listening since \(t.formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 11)).foregroundStyle(NS.text3)
            }
            Text("\(model.packetCount) pkts")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(NS.text3)
            Spacer()
            ToolActionBar("Routing", text: { model.exportText() })
            if model.isListening {
                Button("Stop") { model.stop() }
                    .buttonStyle(.bordered).tint(.red)
            } else {
                // Plain Return: Listen has no text field to submit from
                Button("Listen") { model.start() }
                    .buttonStyle(.borderedProminent)
                    // ⌘Return, not plain Return: with no text field here, plain
                    // Return would also fire from the sidebar's search box.
                    .keyboardShortcut(.return)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(NS.bg0)
    }

    private func errorBanner(_ s: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(NS.red)
            Text(s).font(.system(size: 11, design: .monospaced)).foregroundStyle(NS.text1)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(NS.red.opacity(0.08))
    }

    private var speakersTable: some View {
        Group {
            if model.speakers.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "wave.3.right")
                        .font(.system(size: 36))
                        .foregroundStyle(NS.text3)
                    Text(model.isListening
                         ? "Listening for FHRP hellos…\nNothing seen yet."
                         : "Press Listen to passively detect HSRP / GLBP speakers.")
                        .multilineTextAlignment(.center)
                        .font(.system(size: 12))
                        .foregroundStyle(NS.text2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(model.speakers) {
                    TableColumn("Protocol") { Text($0.proto.rawValue).font(.system(.body, design: .monospaced)) }
                        .width(70)
                    TableColumn("Source", value: \.sourceIP).width(min: 100, ideal: 130)
                    TableColumn("Group") { Text(String($0.group)).font(.system(.body, design: .monospaced)) }
                        .width(50)
                    TableColumn("Priority") { Text(String($0.priority)) }.width(70)
                    TableColumn("State", value: \.state).width(80)
                    TableColumn("Virtual IP", value: \.virtualIP).width(min: 100, ideal: 130)
                    TableColumn("Last seen") { sp in
                        Text(sp.lastSeen.formatted(date: .omitted, time: .standard))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(NS.text3)
                    }
                    .width(90)
                }
            }
        }
    }

    private var limitationsFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle").foregroundStyle(NS.text3).font(.system(size: 11))
                Text("Detectable without privileges: HSRPv1, HSRPv2, GLBP (all UDP)")
                    .font(.system(size: 11)).foregroundStyle(NS.text3)
            }
            HStack(spacing: 6) {
                Image(systemName: "lock").foregroundStyle(NS.text3).font(.system(size: 11))
                Text("Requires raw-socket access (not enabled): OSPF, EIGRP, VRRP, PIM, IS-IS")
                    .font(.system(size: 11)).foregroundStyle(NS.text3)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(NS.bg1)
    }
}
