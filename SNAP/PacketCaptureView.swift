// PacketCaptureView.swift
// SNAP — Packet Capture (tcpdump wrapper)
// Created by Sevag Bardakjian
// Copyright © 2025-2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md

import SwiftUI
import Darwin

struct CapturedPacket: Identifiable , Hashable {
    // var so a row completed by -v's second line keeps its identity (and selection)
    var id = UUID()
    static func == (lhs: CapturedPacket, rhs: CapturedPacket) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    let number: Int       // 1-based position in this capture
    let timestamp: String // time of day, e.g. 10:15:32.123456
    let source: String
    let destination: String
    let proto: String
    let info: String
    let raw: String
    var color: Color {
        switch proto.uppercased() {
        case "TCP":  return .blue
        case "UDP":  return .green
        case "ICMP", "ICMP6": return .orange
        case "ARP":  return .purple
        case "DNS", "MDNS":  return .teal
        case "TLS", "HTTPS": return .green
        default:     return .gray
        }
    }
}

struct PacketCaptureView: View {
    @State private var packets: [CapturedPacket] = []
    @State private var isCapturing = false
    @State private var process: Process?
    // Invalidates buffered callbacks from a stopped run — terminate() is
    // asynchronous, so a restart could otherwise interleave stale packets
    @State private var runID = UUID()
    @State private var interface = "en0"
    @State private var filter = ""
    @State private var maxPackets = "500"
    @State private var filterText = ""
    @State private var selectedPacketIDs: Set<CapturedPacket.ID> = []
    @State private var packetCount = 0
    @State private var showPrivilegeWarning = false
    // Plain-English reason the last capture couldn't start or stopped early
    @State private var captureError: String?
    // Last unrecognized "tcpdump: ..." line, shown if the run ends with no packets
    @State private var lastDiagnostic: String?
    // Filled from getifaddrs on appear; starts with the default so the picker has a valid selection
    @State private var interfaces = ["en0", "any"]

    private var displayPackets: [CapturedPacket] {
        guard !filterText.isEmpty else { return packets }
        return packets.filter {
            $0.source.contains(filterText) || $0.destination.contains(filterText) ||
            $0.proto.localizedCaseInsensitiveContains(filterText) ||
            $0.info.localizedCaseInsensitiveContains(filterText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar: one row when it fits; otherwise the capture buttons wrap to a second row
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass").foregroundStyle(.blue)
                    interfacePicker
                    bpfField.frame(width: 220)
                    maxField
                    Spacer()
                    captureControls
                }
                VStack(spacing: 8) {
                    HStack(spacing: 12) {
                        Image(systemName: "doc.text.magnifyingglass").foregroundStyle(.blue)
                        interfacePicker
                        bpfField.frame(maxWidth: .infinity)
                        maxField
                    }
                    HStack(spacing: 12) {
                        Spacer()
                        captureControls
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(NS.bg0)

            // Privilege warning
            if showPrivilegeWarning {
                HStack {
                    Image(systemName: "lock.shield").foregroundStyle(.orange)
                    // Side by side when there is room, stacked otherwise
                    ViewThatFits(in: .horizontal) {
                        HStack { privilegeMessage }
                        VStack(alignment: .leading, spacing: 2) { privilegeMessage }
                    }
                    Spacer()
                    Button("Dismiss") { showPrivilegeWarning = false }.font(.caption)
                }
                .padding(10)
                .background(Color.orange.opacity(0.1))
                Divider()
            }

            // Capture failures (bad filter, missing interface, invalid Max)
            if let err = captureError {
                HStack {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(err).font(.caption).textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") { captureError = nil }.font(.caption)
                }
                .padding(10)
                .background(Color.orange.opacity(0.1))
                Divider()
            }

            Divider()

            HSplitView {
                // Packet table
                VStack(spacing: 0) {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                        TextField("Filter displayed packets...", text: $filterText).textFieldStyle(.plain).font(.caption)
                    }
                    .padding(6)
                    .background(NS.bg3)
                    Divider()

                    Table(displayPackets, selection: $selectedPacketIDs) {
                        TableColumn("#") { p in
                            Text("\(p.number)").font(.system(size: 10, design: .monospaced))
                        }.width(44)
                        TableColumn("Time") { p in
                            Text(p.timestamp).font(.system(size: 10, design: .monospaced))
                        }.width(100)
                        TableColumn("Source") { p in
                            Text(p.source).font(.system(size: 10, design: .monospaced))
                        }.width(130)
                        TableColumn("Dest") { p in
                            Text(p.destination).font(.system(size: 10, design: .monospaced))
                        }.width(130)
                        TableColumn("Proto") { p in
                            Text(p.proto)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(p.color)
                        }.width(55)
                        TableColumn("Info") { p in
                            Text(p.info)
                                .font(.system(size: 10))
                                .lineLimit(1)
                        }
                    }
                }
                .frame(minWidth: 420)  // with the detail pane, under the narrowest tool area (650 pt)

                // Packet detail
                VStack(alignment: .leading, spacing: 0) {
                    Text("Packet Detail").font(.headline).padding(10)
                    Divider()
                    if let pkt = displayPackets.first(where: { selectedPacketIDs.contains($0.id) }) {
                        ScrollView {
                            Text(pkt.raw)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                        }
                        .background(NS.bg3)
                    } else {
                        Text("Select a packet").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 220)
            }
        }
        .tabNavigationTitle(.packetCapture)
        // Runs when the window closes (tabs now stay alive across switches) — without this, tcpdump keeps
        // sniffing in the background with no UI handle left to stop it
        .onDisappear { stopCapture() }
        .onAppear { loadInterfaces() }
    }

    /// The Mac's real interfaces, with the primary one selected if the current pick is gone.
    private func loadInterfaces() {
        interfaces = Self.captureInterfaces()
        if !interfaces.contains(interface) {
            interface = RouteInfo.defaultIPv4().interface.flatMap { interfaces.contains($0) ? $0 : nil }
                ?? interfaces.first ?? "any"
        }
    }

    private var interfacePicker: some View {
        Picker("Interface", selection: $interface) {
            ForEach(interfaces, id: \.self) { i in Text(i).tag(i) }
        }
        .frame(width: 130)
        .fixedSize()
    }

    private var bpfField: some View {
        TextField("BPF Filter (e.g. tcp port 80)", text: $filter)
            .textFieldStyle(.roundedBorder)
            .onSubmit { if !isCapturing { startCapture() } }  // same condition that shows Capture
    }

    @ViewBuilder
    private var maxField: some View {
        Text("Max:").font(.caption).foregroundStyle(.secondary).fixedSize()
        TextField("", text: $maxPackets).textFieldStyle(.roundedBorder).frame(width: 50)
            .onSubmit { if !isCapturing { startCapture() } }
    }

    @ViewBuilder
    private var captureControls: some View {
        if isCapturing {
            Button("Stop") { stopCapture() }
                .buttonStyle(.bordered).tint(.red)
                .fixedSize()
            Circle().fill(.red).frame(width: 8)
                .opacity(Double(Int(Date().timeIntervalSince1970) % 2))
                .animation(.easeInOut(duration: 0.5).repeatForever(), value: isCapturing)
            Text("\(packetCount) packets").font(.caption).foregroundStyle(.red)
                .fixedSize()
        } else {
            Button { packets = [] } label: { Label("Clear", systemImage: "trash") }
                .buttonStyle(.bordered)
                .fixedSize()
            Button("Capture") { startCapture() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
                .fixedSize()
        }
    }

    @ViewBuilder
    private var privilegeMessage: some View {
        Text("macOS only lets administrators capture packets. Quit SNAP and start it from Terminal with:")
            .font(.caption)
        Text("sudo \"\(Self.executablePath)\"")
            .font(.caption.monospaced())
            .textSelection(.enabled)
    }

    /// This copy of SNAP's own binary, so the sudo command works wherever the app lives.
    private static var executablePath: String {
        Bundle.main.executablePath ?? (Bundle.main.bundlePath + "/Contents/MacOS/SNAP")
    }

    private func startCapture() {
        stopCapture()  // never leave an earlier tcpdump running
        captureError = nil
        guard let maxN = Self.parseMax(maxPackets) else {
            captureError = "Max needs a whole number from 1 to 100,000, like 500."
            return
        }
        packets = []
        packetCount = 0
        lastDiagnostic = nil
        isCapturing = true
        showPrivilegeWarning = false

        let iface = interface
        let bpf = filter.trimmingCharacters(in: .whitespaces)
        var args = ["-i", iface, "-n", "-l", "-tttt", "-v"]
        args += ["-c", "\(maxN)"]
        if !bpf.isEmpty { args.append(bpf) }
        let id = UUID()
        runID = id

        process = Shell.stream("/usr/sbin/tcpdump", args: args,
            onLine: { [self] line in
                guard runID == id else { return }  // line from a stopped run
                switch TcpdumpParser.ingest(line, into: &packets) {
                case .packet:
                    packetCount += 1
                    if packets.count > maxN { packets.removeFirst() }
                case .failure(let failure):
                    if failure == .permission {
                        showPrivilegeWarning = true
                    } else {
                        captureError = TcpdumpParser.message(for: failure, filter: bpf, interface: iface)
                    }
                    stopCapture()
                case .diagnostic(let text):
                    lastDiagnostic = text
                case .continuation, .ignore:
                    break
                }
            },
            onFinish: { [self] in
                guard runID == id else { return }
                isCapturing = false
                // tcpdump quit on its own without a recognized reason: show what it said
                if packetCount == 0, !showPrivilegeWarning, captureError == nil, let text = lastDiagnostic {
                    captureError = "Packet capture stopped. tcpdump said: \(text)"
                }
            }
        )
    }

    private func stopCapture() {
        runID = UUID()  // invalidate in-flight callbacks from this run
        // Shell.stream hands back an unlaunched Process if tcpdump couldn't start
        if process?.isRunning == true { process?.terminate() }
        isCapturing = false
    }

    /// The Max field as a packet count, or nil if it isn't a whole number from 1 to 100,000.
    static func parseMax(_ text: String) -> Int? {
        guard let n = Int(text.trimmingCharacters(in: .whitespaces)), (1...100_000).contains(n) else { return nil }
        return n
    }

    /// Every interface name getifaddrs reports, plus tcpdump's "any".
    static func captureInterfaces() -> [String] {
        var names = Set<String>()
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            var cur = ifaddr
            while let c = cur {
                names.insert(String(cString: c.pointee.ifa_name))
                cur = c.pointee.ifa_next
            }
            freeifaddrs(ifaddr)
        }
        // en* first (where most captures happen), then the rest; en2 before en10
        let sorted = names.sorted { a, b in
            let ea = a.hasPrefix("en"), eb = b.hasPrefix("en")
            if ea != eb { return ea }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
        return sorted + ["any"]
    }
}

// MARK: - tcpdump output parsing

/// Turns tcpdump's text output (run with -n -l -tttt -v) into table rows.
/// tcpdump writes packets to stdout and its own messages to stderr; Shell.stream
/// merges both, so every line is classified first.
enum TcpdumpParser {
    enum Failure: Equatable {
        case permission       // no access to /dev/bpf (not running as root)
        case badFilter        // the BPF filter didn't compile
        case noSuchInterface  // the chosen interface isn't on this Mac
    }

    enum LineKind: Equatable {
        case packet               // a new packet row was added
        case continuation         // -v's indented second line, merged into the last row
        case failure(Failure)     // tcpdump can't capture
        case diagnostic(String)   // some other "tcpdump: ..." message
        case ignore               // banner, summary or blank line
    }

    /// What one output line means, before any packet parsing.
    static func classify(_ line: String) -> LineKind {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return .ignore }
        // -v prints each IPv4 packet's addresses on an indented line after the IP header line
        if let first = line.first, first == " " || first == "\t" { return .continuation }

        // With -tttt every packet line starts with its date. Only other lines
        // can be tcpdump's own errors: a decoded packet (a DNS TXT answer, say)
        // can contain "Permission denied" too.
        if line.first?.isNumber == true {
            // The end-of-run summary ("12 packets captured") starts with a digit too
            let words = line.split(separator: " ")
            if let n = words.first, Int(n) != nil, line.contains(" packet") { return .ignore }
            return .packet
        }
        if line.contains("You don't have permission") || line.contains("Permission denied") ||
           line.contains("Operation not permitted") || line.contains("no suitable device") {
            return .failure(.permission)
        }
        if line.hasPrefix("tcpdump:") {
            let text = line.dropFirst("tcpdump:".count).trimmingCharacters(in: .whitespaces)
            if text.contains("No such device") || text.contains("BIOCSETIF") {
                return .failure(.noSuchInterface)
            }
            let filterErrors = ["filter expression", "syntax error", "unknown host", "unknown port",
                                "unknown protocol", "unknown network", "illegal"]
            if filterErrors.contains(where: { text.contains($0) }) { return .failure(.badFilter) }
            let chatter = ["verbose output suppressed", "listening on", "WARNING", "data link type"]
            if chatter.contains(where: { text.contains($0) }) { return .ignore }
            return .diagnostic(text)
        }
        // Start-up banner, libpcap's "(...)" detail line, and the end-of-run summary
        if line.hasPrefix("listening on") || line.hasPrefix("(") || line.hasPrefix("reading from") { return .ignore }
        let words = line.split(separator: " ")
        if let n = words.first, Int(n) != nil, line.contains(" packet") { return .ignore }
        return .packet
    }

    /// Classifies `line` and applies it: a packet line appends a row, a
    /// continuation line completes the last row (keeping its number and id).
    /// Returns .packet only when a row was actually added.
    @discardableResult
    static func ingest(_ line: String, into packets: inout [CapturedPacket]) -> LineKind {
        let kind = classify(line)
        switch kind {
        case .packet:
            let number = (packets.last?.number ?? 0) + 1
            guard let pkt = parse(line, number: number) else { return .ignore }
            packets.append(pkt)
        case .continuation:
            guard let last = packets.last,
                  var pkt = parse(last.raw + "\n" + line.trimmingCharacters(in: .whitespaces), number: last.number)
            else { return .ignore }
            pkt.id = last.id
            packets[packets.count - 1] = pkt
        default:
            break
        }
        return kind
    }

    static func message(for failure: Failure, filter: String, interface: String) -> String {
        switch failure {
        case .permission:      return "You don't have permission to capture on that device."
        case .badFilter:       return "tcpdump didn't understand the filter \"\(filter)\". Example: tcp port 443."
        case .noSuchInterface: return "Interface \(interface) doesn't exist on this Mac. Pick another one."
        }
    }

    /// One packet (a single line, or a -v header line plus its continuation).
    static func parse(_ text: String, number: Int) -> CapturedPacket? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        // Parse the lines as one, so -v's two-line IPv4 form reads like the one-line form
        let flat = raw.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        let words = flat.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard words.count >= 2 else { return nil }

        // -tttt prints "2026-11-20 10:15:32.123456"; the default format is the time alone
        let hasDate = words[0].count == 10 && words[0].filter({ $0 == "-" }).count == 2
        let time = hasDate ? words[1] : words[0]
        let body = words.dropFirst(hasDate ? 2 : 1).joined(separator: " ")

        var src = "", dst = "", proto = "", info = body

        if body.hasPrefix("IP ") || body.hasPrefix("IP6 ") {
            let isV6 = body.hasPrefix("IP6 ")
            var rest = Substring(body.dropFirst(isV6 ? 4 : 3))
            // -v header: "(tos 0x0, ttl 64, ..., proto TCP (6), length 52)" before the addresses
            let header = rest.hasPrefix("(") ? String(skipParenthesized(&rest)) : ""
            rest = rest.drop(while: { $0 == " " })
            var srcPort: Int?, dstPort: Int?
            if let arrow = rest.range(of: " > ") {
                src = String(rest[..<arrow.lowerBound])
                let afterArrow = rest[arrow.upperBound...]
                // ": " ends the destination; a bare ":" can't, since IPv6 addresses contain colons
                if let colon = afterArrow.range(of: ": ") {
                    dst = String(afterArrow[..<colon.lowerBound])
                    info = String(afterArrow[colon.upperBound...])
                } else {
                    dst = String(afterArrow.hasSuffix(":") ? afterArrow.dropLast() : afterArrow)
                    info = ""
                }
                srcPort = port(of: src, isV6: isV6)
                dstPort = port(of: dst, isV6: isV6)
            } else {
                info = String(rest.isEmpty ? Substring(header) : rest)
            }
            proto = detectProto(info: info, header: header, isV6: isV6, ports: [srcPort, dstPort].compactMap { $0 })
        } else if body.hasPrefix("ARP") {
            proto = "ARP"
            info = body.hasPrefix("ARP, ") ? String(body.dropFirst(5)) : body
            let w = body.split(separator: " ").map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ",")) }
            if let tell = w.firstIndex(of: "tell"), tell + 1 < w.count {
                src = w[tell + 1]           // "Request who-has 192.168.1.1 tell 192.168.1.5"
                dst = "broadcast"
            } else if let reply = w.firstIndex(of: "Reply"), reply + 1 < w.count {
                src = w[reply + 1]          // "Reply 192.168.1.1 is-at 11:22:33:44:55:66"
            }
        } else {
            // Other link-layer traffic (LLDP, STP, ...): name it by tcpdump's first word
            proto = String((body.split(separator: " ").first ?? "").trimmingCharacters(in: CharacterSet(charactersIn: ",:")).prefix(8))
        }

        return CapturedPacket(
            number: number,
            timestamp: time,
            source: src.isEmpty ? "?" : src,
            destination: dst.isEmpty ? "?" : dst,
            proto: proto.isEmpty ? "?" : proto,
            info: String(info.prefix(200)),
            raw: raw
        )
    }

    /// Removes a leading "( ... )" group (nested parentheses allowed) from `s` and returns it.
    private static func skipParenthesized(_ s: inout Substring) -> Substring {
        var depth = 0
        for i in s.indices {
            if s[i] == "(" { depth += 1 }
            if s[i] == ")" {
                depth -= 1
                if depth == 0 {
                    let group = s[...i]
                    s = s[s.index(after: i)...]
                    return group
                }
            }
        }
        let group = s
        s = s[s.endIndex...]
        return group
    }

    /// The port tcpdump appends after the last dot: "192.168.1.5.52344" or "fe80::1.443".
    static func port(of endpoint: String, isV6: Bool) -> Int? {
        guard let dot = endpoint.lastIndex(of: ".") else { return nil }
        let address = endpoint[..<dot]
        // IPv4 "a.b.c.d" has three dots before the port; plain IPv6 has none (IPv4-mapped has three)
        let dots = address.filter { $0 == "." }.count
        guard isV6 ? (dots == 0 || dots == 3) : dots == 3 else { return nil }
        return Int(endpoint[endpoint.index(after: dot)...])
    }

    /// Application protocol from well-known ports first, then the transport.
    static func detectProto(info: String, header: String, isV6: Bool, ports: [Int]) -> String {
        if info.hasPrefix("ICMP6") || header.contains("ICMPv6") { return "ICMP6" }
        if info.hasPrefix("ICMP") || header.contains("proto ICMP") { return "ICMP" }
        if ports.contains(53) { return "DNS" }
        if ports.contains(5353) { return "mDNS" }
        if ports.contains(443) { return "HTTPS" }
        if ports.contains(80) { return "HTTP" }
        if info.hasPrefix("Flags [") || header.contains("proto TCP") || header.contains("next-header TCP") { return "TCP" }
        if !ports.isEmpty || header.contains("UDP") || info.hasPrefix("UDP") { return "UDP" }
        return isV6 ? "IP6" : "IP"
    }
}
