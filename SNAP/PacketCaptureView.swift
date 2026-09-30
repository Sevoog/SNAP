// PacketCaptureView.swift
// SNAP — Packet Capture (tcpdump wrapper)
// Created by Sevag Bardakjian

import SwiftUI

struct CapturedPacket: Identifiable , Hashable {
    let id = UUID()
    static func == (lhs: CapturedPacket, rhs: CapturedPacket) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    let timestamp: String
    let source: String
    let destination: String
    let proto: String
    let info: String
    let raw: String
    var color: Color {
        switch proto.uppercased() {
        case "TCP":  return .blue
        case "UDP":  return .green
        case "ICMP": return .orange
        case "ARP":  return .purple
        case "DNS":  return .teal
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

    private var interfaces = ["en0", "en1", "en2", "lo0", "any"]

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
            // Toolbar
            HStack(spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass").foregroundStyle(.blue)

                Picker("Interface", selection: $interface) {
                    ForEach(interfaces, id: \.self) { i in Text(i).tag(i) }
                }
                .frame(width: 130)
                .fixedSize()

                TextField("BPF Filter (e.g. tcp port 80)", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)

                Text("Max:").font(.caption).foregroundStyle(.secondary)
                TextField("", text: $maxPackets).textFieldStyle(.roundedBorder).frame(width: 50)

                Spacer()

                if isCapturing {
                    Button("Stop") { stopCapture() }
                        .buttonStyle(.bordered).tint(.red)
                    Circle().fill(.red).frame(width: 8)
                        .opacity(Double(Int(Date().timeIntervalSince1970) % 2))
                        .animation(.easeInOut(duration: 0.5).repeatForever(), value: isCapturing)
                    Text("\(packetCount) packets").font(.caption).foregroundStyle(.red)
                } else {
                    Button { packets = [] } label: { Label("Clear", systemImage: "trash") }
                        .buttonStyle(.bordered)
                    Button("Capture") { startCapture() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(NS.bg0)

            // Privilege warning
            if showPrivilegeWarning {
                HStack {
                    Image(systemName: "lock.shield").foregroundStyle(.orange)
                    Text("Packet capture requires running SNAP with elevated privileges.")
                        .font(.caption)
                    Text("Run: sudo /path/to/SNAP.app/Contents/MacOS/SNAP")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") { showPrivilegeWarning = false }.font(.caption)
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
                            Text(p.timestamp).font(.system(size: 10, design: .monospaced))
                        }.width(80)
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
                .frame(minWidth: 550)

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
        .navigationTitle("Packet Capture")
        // Tab switching recreates this view — without this, tcpdump keeps
        // sniffing in the background with no UI handle left to stop it
        .onDisappear { stopCapture() }
    }

    private func startCapture() {
        packets = []
        packetCount = 0
        isCapturing = true
        showPrivilegeWarning = false

        var args = ["-i", interface, "-n", "-l", "-tttt", "-v"]
        let maxN = Int(maxPackets) ?? 500
        args += ["-c", "\(maxN)"]
        if !filter.isEmpty { args.append(filter) }
        let id = UUID()
        runID = id

        process = Shell.stream("/usr/sbin/tcpdump", args: args,
            onLine: { [self] line in
                guard runID == id else { return }  // line from a stopped run
                if line.contains("tcpdump: no suitable device") ||
                   line.contains("Operation not permitted") {
                    DispatchQueue.main.async { showPrivilegeWarning = true; isCapturing = false }
                    return
                }
                if let pkt = parseTcpdump(line) {
                    packetCount += 1
                    packets.append(pkt)
                    if packets.count > maxN { packets.removeFirst() }
                }
            },
            onFinish: { [self] in
                if runID == id { isCapturing = false }
            }
        )
    }

    private func stopCapture() {
        runID = UUID()  // invalidate in-flight callbacks from this run
        process?.terminate()
        isCapturing = false
    }

    private func parseTcpdump(_ line: String) -> CapturedPacket? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty && !trimmed.hasPrefix("tcpdump") else { return nil }

        // Try to extract time, src/dst, protocol
        let parts = trimmed.components(separatedBy: " ").filter { !$0.isEmpty }
        guard parts.count >= 3 else { return nil }

        let ts = parts[0]
        var src = ""
        var dst = ""
        var proto = "???"
        var info = trimmed

        // Look for "IP src > dst:" or "ARP" patterns
        if let ipRange = trimmed.range(of: " IP ") {
            let after = String(trimmed[ipRange.upperBound...])
            if let arrowRange = after.range(of: " > ") {
                src = String(after[..<arrowRange.lowerBound])
                let afterArrow = String(after[arrowRange.upperBound...])
                dst = afterArrow.components(separatedBy: ":").first ?? ""
                info = afterArrow
            }
            proto = detectProto(trimmed)
        } else if trimmed.contains(" ARP") {
            proto = "ARP"
            src = parts.count > 3 ? parts[3] : ""
            dst = "broadcast"
        } else if trimmed.contains(" ICMP") {
            proto = "ICMP"
        }

        return CapturedPacket(
            timestamp: ts,
            source: src.isEmpty ? "?" : src,
            destination: dst.isEmpty ? "?" : dst,
            proto: proto,
            info: String(info.prefix(200)),
            raw: trimmed
        )
    }

    private func detectProto(_ line: String) -> String {
        if line.contains(".443 >") || line.contains("> .443") { return "TLS" }
        if line.contains(".80 >") || line.contains("> .80 ") { return "HTTP" }
        if line.contains(".53 >") || line.contains("> .53 ") { return "DNS" }
        if line.contains("UDP") { return "UDP" }
        if line.contains("TCP") || line.contains("Flags") { return "TCP" }
        return "IP"
    }
}
