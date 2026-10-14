// WakeOnLANView.swift
// SNAP — Wake-on-LAN
// Created by Sevag Bardakjian
// Copyright © 2025-2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md

import SwiftUI

struct WOLDevice: Identifiable, Codable , Hashable {
    var id = UUID()
    var name: String
    var mac: String
    var broadcastIP: String
    var port: String
    var lastWoken: Date?
}

struct WakeOnLANView: View {
    @State private var devices: [WOLDevice] = []
    @State private var showAdd = false
    @State private var newName = ""
    @State private var newMAC = ""
    @State private var newBroadcast = "255.255.255.255"
    @State private var newPort = "9"
    @State private var feedback: String = ""
    @State private var feedbackIsSuccess = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "power.circle").foregroundStyle(.blue)
                Text("Wake-on-LAN").font(.subheadline.bold())
                Spacer()
                Button { showAdd = true } label: {
                    Label("Add Device", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(NS.bg0)

            Divider()

            if !feedback.isEmpty {
                HStack {
                    Image(systemName: feedbackIsSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(feedbackIsSuccess ? .green : .red)
                    Text(feedback)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 6)
                .background((feedbackIsSuccess ? Color.green : Color.red).opacity(0.1))
                Divider()
            }

            if devices.isEmpty {
                EmptyStateView(title: "No Devices", systemImage: "power.circle", description: "Add a device with its MAC address to wake it remotely")
            } else {
                List {
                    ForEach($devices) { $device in
                        HStack(spacing: 12) {
                            Image(systemName: "desktopcomputer")
                                .font(.title2).foregroundStyle(.blue)
                                .frame(width: 36)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(device.name).font(.headline)
                                Text(device.mac).font(.caption.monospaced()).foregroundStyle(.secondary)
                                Text("Broadcast: \(device.broadcastIP):\(device.port)")
                                    .font(.caption2).foregroundStyle(.tertiary)
                                if let last = device.lastWoken {
                                    Text("Last woken: \(last.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                            Button("Wake") {
                                wake(device: &device)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete { idx in devices.remove(atOffsets: idx) }
                }
            }
        }
        .sheet(isPresented: $showAdd) {
            addDeviceSheet
        }
        .tabNavigationTitle(.wakeOnLAN)
    }

    private func wake(device: inout WOLDevice) {
        let port = UInt16(device.port) ?? 9
        let success = WakeOnLANSender.send(mac: device.mac, broadcastIP: device.broadcastIP, port: port)
        device.lastWoken = success ? Date() : device.lastWoken
        feedback = success
            ? "✓ Magic packet sent to \(device.name) (\(device.mac))"
            : "✗ Failed to send packet. Check MAC address format."
        feedbackIsSuccess = success
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { feedback = "" }
    }

    private var addDeviceSheet: some View {
        VStack(spacing: 20) {
            Text("Add Device").font(.title2.bold())

            Form {
                Section("Device") {
                    TextField("Name (e.g. Desktop PC)", text: $newName)
                    TextField("MAC Address (XX:XX:XX:XX:XX:XX)", text: $newMAC)
                }
                Section("Network") {
                    TextField("Broadcast IP", text: $newBroadcast)
                    TextField("Port", text: $newPort)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") { showAdd = false }
                    .keyboardShortcut(.escape)
                Spacer()
                Button("Add") {
                    let d = WOLDevice(name: newName, mac: newMAC, broadcastIP: newBroadcast, port: newPort)
                    devices.append(d)
                    newName = ""; newMAC = ""; newBroadcast = "255.255.255.255"; newPort = "9"
                    showAdd = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(newName.isEmpty || newMAC.isEmpty)
                .keyboardShortcut(.return)
            }
        }
        .padding(24)
        .frame(width: 400)
    }
}
