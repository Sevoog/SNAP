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

// MARK: - Saved devices

/// Devices survive relaunch (they used to be plain @State and vanished).
@MainActor
final class WOLDeviceStore: ObservableObject {
    static let shared = WOLDeviceStore()

    static let devicesKey = "com.sevagbardakjian.snap.wol.devices.v1"

    @Published private(set) var devices: [WOLDevice] = []
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.devicesKey),
           let decoded = try? JSONDecoder().decode([WOLDevice].self, from: data) {
            devices = decoded
        }
    }

    func add(_ device: WOLDevice) {
        devices.append(device)
        persist()
    }

    func remove(_ id: UUID) {
        devices.removeAll { $0.id == id }
        persist()
    }

    func remove(atOffsets offsets: IndexSet) {
        devices.remove(atOffsets: offsets)
        persist()
    }

    func markWoken(_ id: UUID, at date: Date = Date()) {
        guard let i = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[i].lastWoken = date
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(devices) {
            defaults.set(data, forKey: Self.devicesKey)
        }
    }
}

// MARK: - Add-sheet validation

enum WOLInput {
    static let invalidMACMessage = "That MAC address isn't valid. Use six pairs of hex digits, like 3C:22:FB:12:34:56."
    static let invalidPortMessage = "The port must be a number from 1 to 65535. Wake-on-LAN usually uses 9."
    static let invalidBroadcastMessage = "That broadcast address isn't valid. Use an IPv4 address like 255.255.255.255 or 192.168.1.255."
    static let sendFailedMessage = "SNAP couldn't send the wake signal. Check that this Mac is connected to the same network as the device."

    /// A device ready to save (MAC normalized to aa:bb:cc:dd:ee:ff), or nil
    /// if any field is invalid.
    static func device(name: String, mac: String, broadcast: String, port: String) -> WOLDevice? {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty,
              let normalized = WakeOnLANSender.normalizedMAC(mac),
              WakeOnLANSender.parseIPv4(broadcast) != nil,
              let p = WakeOnLANSender.parsePort(port) else { return nil }
        return WOLDevice(name: trimmedName, mac: normalized,
                         broadcastIP: broadcast.trimmingCharacters(in: .whitespaces),
                         port: String(p))
    }

    /// Message for the result of a send, nil on success.
    static func failureMessage(for result: WakeOnLANSender.SendResult) -> String? {
        switch result {
        case .sent:           return nil
        case .invalidMAC:     return invalidMACMessage
        case .invalidAddress: return invalidBroadcastMessage
        case .sendFailed:     return sendFailedMessage
        }
    }
}

struct WakeOnLANView: View {
    @ObservedObject private var store = WOLDeviceStore.shared
    @State private var showAdd = false
    @State private var newName = ""
    @State private var newMAC = ""
    @State private var newBroadcast = "255.255.255.255"
    @State private var newPort = "9"
    @State private var feedback: String = ""
    @State private var feedbackIsSuccess = false
    /// Which message is showing. Each message clears itself after 5 s, but
    /// only if it's still the one showing; a newer one used to be wiped by
    /// the older message's timer, sometimes almost at once.
    @State private var feedbackID = UUID()

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

            if store.devices.isEmpty {
                EmptyStateView(title: "No Devices", systemImage: "power.circle", description: "Add a device with its MAC address to wake it remotely")
            } else {
                List {
                    ForEach(store.devices) { device in
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
                                wake(device)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                            // .onDelete alone has no visible control on macOS
                            Button { store.remove(device.id) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(NS.text2)
                            .help("Delete \(device.name)")
                        }
                        .padding(.vertical, 4)
                        .contextMenu {
                            Button("Wake") { wake(device) }
                            Button("Delete", role: .destructive) { store.remove(device.id) }
                        }
                    }
                    .onDelete { idx in store.remove(atOffsets: idx) }
                }
            }
        }
        .sheet(isPresented: $showAdd) {
            addDeviceSheet
        }
        .tabNavigationTitle(.wakeOnLAN)
    }

    private func wake(_ device: WOLDevice) {
        let port = WakeOnLANSender.parsePort(device.port) ?? 9
        let result = WakeOnLANSender.send(mac: device.mac, broadcastIP: device.broadcastIP, port: port)
        if result == .sent { store.markWoken(device.id) }
        feedback = WOLInput.failureMessage(for: result)
            ?? "✓ Magic packet sent to \(device.name) (\(device.mac))"
        feedbackIsSuccess = result == .sent
        let id = UUID()
        feedbackID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if feedbackID == id { feedback = "" }
        }
    }

    // MARK: Add sheet

    /// Messages only for fields that have something typed in them, so an
    /// untouched MAC field doesn't open with an error.
    private var macError: String? {
        let t = newMAC.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && WakeOnLANSender.macBytes(t) == nil ? WOLInput.invalidMACMessage : nil
    }
    private var broadcastError: String? {
        WakeOnLANSender.parseIPv4(newBroadcast) == nil ? WOLInput.invalidBroadcastMessage : nil
    }
    private var portError: String? {
        WakeOnLANSender.parsePort(newPort) == nil ? WOLInput.invalidPortMessage : nil
    }
    private var newDevice: WOLDevice? {
        WOLInput.device(name: newName, mac: newMAC, broadcast: newBroadcast, port: newPort)
    }

    private func addDevice() {
        guard let d = newDevice else { return }
        store.add(d)
        newName = ""; newMAC = ""; newBroadcast = "255.255.255.255"; newPort = "9"
        showAdd = false
    }

    private var addDeviceSheet: some View {
        VStack(spacing: 20) {
            Text("Add Device").font(.title2.bold())

            Form {
                Section("Device") {
                    TextField("Name (e.g. Desktop PC)", text: $newName)
                    TextField("MAC Address (XX:XX:XX:XX:XX:XX)", text: $newMAC)
                    if let macError { fieldError(macError) }
                }
                Section("Network") {
                    TextField("Broadcast IP", text: $newBroadcast)
                    if let broadcastError { fieldError(broadcastError) }
                    TextField("Port", text: $newPort)
                    if let portError { fieldError(portError) }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") { showAdd = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add") { addDevice() }
                    .buttonStyle(.borderedProminent)
                    .disabled(newDevice == nil)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 400)
    }

    private func fieldError(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(NS.red)
            .fixedSize(horizontal: false, vertical: true)
    }
}
