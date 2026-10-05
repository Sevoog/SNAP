// MTUDiscoveryView.swift
// SNAP — Path MTU Discovery
// Created by Sevag Bardakjian
// Copyright © 2025 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
//
// Binary-searches the largest ICMP echo payload that traverses the path with
// the Don't-Fragment bit set. The path MTU is payload + 28 (IPv4 + ICMP
// headers). Useful for diagnosing VPN/tunnel issues and odd MSS clamping.

import SwiftUI

struct MTUDiscoveryView: View {
    @State private var host: String = "1.1.1.1"
    @State private var lowerBound: Int = 1200   // payload bytes (conservative starting low)
    @State private var upperBound: Int = 1472   // 1500 - 28
    @State private var steps: [MTUStep] = []
    @State private var isRunning = false
    @State private var bestPayload: Int? = nil
    @State private var error = ""

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if !error.isEmpty { errorBar }
            Divider()
            HSplitView {
                stepLog.frame(minWidth: 440)
                resultPanel.frame(minWidth: 260, idealWidth: 300)
            }
        }
        .navigationTitle("MTU Discovery")
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.left.and.right.square").foregroundStyle(.cyan)
            TextField("Host or IP", text: $host)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
            HStack(spacing: 4) {
                Text("Range").font(.caption).foregroundStyle(.secondary)
                TextField("", value: $lowerBound, format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 60)
                Text("–").foregroundStyle(.secondary)
                TextField("", value: $upperBound, format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 60)
            }
            Spacer()
            if !steps.isEmpty {
                ToolActionBar("MTU Discovery",
                              text: { exportText() })
            }
            Button(isRunning ? "Searching…" : "Discover") { run() }
                .buttonStyle(.borderedProminent)
                .disabled(isRunning || host.isEmpty)
                .keyboardShortcut(.return)
            if isRunning { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(NS.bg0)
    }

    private var errorBar: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(error).foregroundStyle(.red).font(.caption)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(Color.red.opacity(0.05))
    }

    private var stepLog: some View {
        Group {
            if steps.isEmpty && !isRunning {
                EmptyStateView(title: "Path MTU Discovery",
                               systemImage: "arrow.left.and.right.square",
                               description: "SNAP pings the host with the Don't-Fragment bit set and binary-searches for the largest payload that gets through. Useful for diagnosing VPN MTU issues.")
            } else {
                Table(steps) {
                    TableColumn("Step") { s in
                        Text("\(s.attempt)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }.width(50)
                    TableColumn("Payload") { s in
                        Text("\(s.payload) B")
                            .font(.system(size: 11, design: .monospaced))
                    }.width(90)
                    TableColumn("MTU") { s in
                        Text("\(s.payload + 28)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(NS.text3)
                    }.width(70)
                    TableColumn("Result") { s in
                        HStack(spacing: 6) {
                            Image(systemName: s.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(s.passed ? NS.green : NS.red)
                                .font(.system(size: 11))
                            Text(s.passed ? "PASSED" : "FRAGMENT/FAIL")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(s.passed ? NS.green : NS.red)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var resultPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Result").font(.headline)
            if let p = bestPayload {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Path MTU").font(.system(size: 11)).foregroundStyle(NS.text3)
                        Spacer()
                        Text("\(p + 28) bytes")
                            .font(.system(size: 18, weight: .semibold, design: .monospaced))
                            .foregroundStyle(NS.green)
                    }
                    HStack {
                        Text("Max payload").font(.system(size: 11)).foregroundStyle(NS.text3)
                        Spacer()
                        Text("\(p) bytes").font(.system(size: 12, design: .monospaced)).foregroundStyle(NS.text2)
                    }
                    Divider().background(NS.border)
                    Text(interpretation(p))
                        .font(.system(size: 11))
                        .foregroundStyle(NS.text2)
                }
                .padding(12)
                .background(NS.bg2)
                .cornerRadius(8)
            } else if isRunning {
                Text("Searching…").foregroundStyle(.secondary).font(.system(size: 11))
            } else {
                Text("No result yet").foregroundStyle(.tertiary).font(.system(size: 11))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(NS.bg1)
    }

    private func interpretation(_ p: Int) -> String {
        let mtu = p + 28
        switch mtu {
        case 1500:        return "Standard Ethernet MTU — no encapsulation in the path."
        case 1492:        return "PPPoE encapsulation in the path (1500 − 8)."
        case 1480:        return "Likely IP-in-IP or 6in4 tunnel (1500 − 20)."
        case 1476...1478: return "Likely GRE tunnel."
        case 1380...1440: return "VPN encapsulation (WireGuard / IPsec) in the path."
        case 1280:        return "Possibly minimum IPv6 MTU."
        case ..<1280:     return "Unusually low. Check VPN MTU or MSS clamping upstream."
        default:          return "Non-standard. Inspect intermediate links."
        }
    }

    private func run() {
        steps = []
        bestPayload = nil
        error = ""

        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard lowerBound > 0 && upperBound > lowerBound else {
            error = "Invalid bound range"; return
        }
        let lo = lowerBound
        let hi = upperBound

        isRunning = true

        Task {
            // Binary search: largest payload that passes with DF set
            var low = lo
            var high = hi
            var best: Int? = nil
            var attempt = 0

            // Sanity check: lower bound first
            attempt += 1
            let loPassed = await Self.pingDF(host: h, payload: low)
            await MainActor.run {
                steps.append(MTUStep(attempt: attempt, payload: low, passed: loPassed))
            }
            if !loPassed {
                await MainActor.run {
                    error = "Lower bound \(low) already fragments. Try a smaller lower bound."
                    isRunning = false
                }
                return
            }
            best = low

            // Sanity check: upper bound
            attempt += 1
            let hiPassed = await Self.pingDF(host: h, payload: high)
            await MainActor.run {
                steps.append(MTUStep(attempt: attempt, payload: high, passed: hiPassed))
            }
            if hiPassed {
                await MainActor.run {
                    bestPayload = high
                    isRunning = false
                }
                return
            }

            // Standard binary search
            while high - low > 1 {
                attempt += 1
                let mid = (low + high) / 2
                let ok = await Self.pingDF(host: h, payload: mid)
                await MainActor.run {
                    steps.append(MTUStep(attempt: attempt, payload: mid, passed: ok))
                }
                if ok { best = mid; low = mid } else { high = mid }
            }

            await MainActor.run {
                bestPayload = best
                isRunning = false
            }
        }
    }

    /// Sends a single DF-set ICMP echo via system ping. Returns true if it gets through.
    fileprivate static func pingDF(host: String, payload: Int) async -> Bool {
        let out = await Shell.run("/sbin/ping",
                                  args: ["-c", "1", "-W", "2000", "-D", "-s", "\(payload)", host])
        // Successful: "1 packets transmitted, 1 packets received"
        // Fail w/ DF: "Message too long" or "0 packets received"
        if out.contains("Message too long") { return false }
        if out.contains("sendto: ") { return false }
        if let range = out.range(of: #"(\d+)\s+packets received"#, options: .regularExpression) {
            let s = out[range]
            if let n = s.split(whereSeparator: { !$0.isNumber }).first.flatMap({ Int($0) }) {
                return n > 0
            }
        }
        return false
    }

    private func exportText() -> String {
        var out = "MTU Discovery — \(host)\n"
        out += String(repeating: "—", count: 60) + "\n"
        for s in steps {
            out += "step \(s.attempt): payload=\(s.payload)B  MTU=\(s.payload + 28)  \(s.passed ? "PASS" : "FAIL")\n"
        }
        if let p = bestPayload {
            out += "\nResult: Path MTU = \(p + 28) bytes (payload \(p))\n"
            out += "Interpretation: \(interpretation(p))\n"
        }
        return out
    }
}

private struct MTUStep: Identifiable {
    let id = UUID()
    let attempt: Int
    let payload: Int
    let passed: Bool
}
