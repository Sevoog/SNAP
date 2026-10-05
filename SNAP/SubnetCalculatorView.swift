// SubnetCalculatorView.swift
// SNAP — Subnet Calculator
// Created by Sevag Bardakjian

import SwiftUI

struct SubnetCalculatorView: View {
    @State private var ipAddress = "192.168.1.0"
    @State private var cidr = 24.0
    @State private var subnetMaskInput = "255.255.255.0"
    @State private var info: SubnetInfo?
    @State private var inputMode: InputMode = .cidr

    enum InputMode: String, CaseIterable { case cidr = "CIDR", mask = "Subnet Mask" }

    private var cidrFromMask: Int? {
        let parts = subnetMaskInput.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4 else { return nil }
        let maskInt = (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
        return (0..<32).reduce(0) { $0 + Int((maskInt >> (31 - $1)) & 1) }
    }

    private func calculate() {
        let c = inputMode == .cidr ? Int(cidr) : (cidrFromMask ?? Int(cidr))
        info = SubnetCalculator.calculate(ip: ipAddress, cidr: c)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Input
                GroupBox("Input") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("IP Address:").frame(width: 130, alignment: .trailing).foregroundStyle(.secondary)
                            TextField("e.g. 192.168.1.0", text: $ipAddress)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 200)
                                .onChange(of: ipAddress, perform: { _ in calculate() })
                        }

                        Picker("Input Mode", selection: $inputMode) {
                            ForEach(InputMode.allCases, id: \.self) { m in Text(m.rawValue).tag(m) }
                        }
                        .pickerStyle(.segmented)
                        // Sized to content — a fixed frame can squeeze the
                        // label until it wraps (same bug as the Network Map's
                        // "View" picker).
                        .fixedSize()

                        if inputMode == .cidr {
                            HStack {
                                Text("CIDR Prefix:").frame(width: 130, alignment: .trailing).foregroundStyle(.secondary)
                                Slider(value: $cidr, in: 0...32, step: 1)
                                    .frame(width: 200)
                                    .onChange(of: cidr, perform: { _ in calculate() })
                                Text("/\(Int(cidr))")
                                    .font(.headline.monospaced())
                                    .frame(width: 40)
                            }
                        } else {
                            HStack {
                                Text("Subnet Mask:").frame(width: 130, alignment: .trailing).foregroundStyle(.secondary)
                                TextField("e.g. 255.255.255.0", text: $subnetMaskInput)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 200)
                                    .onChange(of: subnetMaskInput, perform: { _ in calculate() })
                            }
                        }

                        Button("Calculate") { calculate() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(8)
                }

                if let s = info {
                    // Results
                    GroupBox("Results") {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                            resultCard("Network Address", s.networkAddress, color: .blue)
                            resultCard("Broadcast Address", s.broadcastAddress, color: .orange)
                            resultCard("Subnet Mask", s.subnetMask, color: .green)
                            resultCard("Wildcard Mask", s.wildcardMask, color: .purple)
                            resultCard("First Host", s.firstHost, color: .teal)
                            resultCard("Last Host", s.lastHost, color: .teal)
                            resultCard("Total Hosts", "\(s.totalHosts)", color: .indigo)
                            resultCard("Usable Hosts", "\(s.usableHosts)", color: .green)
                        }
                        .padding(8)
                    }

                    GroupBox("Details") {
                        VStack(spacing: 8) {
                            detailRow("IP Class", s.ipClass)
                            detailRow("CIDR Notation", "\(s.address)/\(s.cidr)")
                            detailRow("Address Type", s.isPrivate ? "Private (RFC 1918)" : "Public")
                            detailRow("Binary Mask", s.binaryMask)
                        }
                        .padding(8)
                    }

                    // Visual subnet map
                    GroupBox("Subnet Map") {
                        subnetBar(s)
                            .padding(8)
                    }
                }
            }
            .padding(20)
        }
        .onAppear { calculate() }
        .navigationTitle("Subnet Calculator")
    }

    private func resultCard(_ label: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.monospaced().bold())
                .textSelection(.enabled)
                .foregroundStyle(color)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(.secondary).frame(width: 140, alignment: .trailing)
            Text(value).font(.subheadline.monospaced()).textSelection(.enabled)
            Spacer()
        }
    }

    private func subnetBar(_ s: SubnetInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Address Space Visualization").font(.caption).foregroundStyle(.secondary)
            GeometryReader { geo in
                let networkWidth = geo.size.width * CGFloat(s.cidr) / 32.0
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: 24)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.blue.opacity(0.5))
                        .frame(width: networkWidth, height: 24)
                    Text("/\(s.cidr) = \(s.usableHosts) hosts")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                }
            }
            .frame(height: 24)
        }
    }
}
