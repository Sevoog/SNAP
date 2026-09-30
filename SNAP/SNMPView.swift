// SNMPView.swift
// SNAP — SNMP v2c Query Tool (Advanced)
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian. All rights reserved.
//
// Read-only SNMP v2c client UI. Three modes:
//
//   • System Info — sysDescr / sysObjectID / sysUpTime / sysContact / sysName /
//     sysLocation in a single round-trip (one GET with five varbinds). When
//     sysObjectID matches a vendor we know, we surface vendor + role + model
//     above the varbinds.
//
//   • Interfaces — bulk-walks ifDescr, ifSpeed, ifOperStatus, ifInOctets,
//     ifOutOctets and joins them on the row index.
//
//   • Custom OID Walk — type any OID; we GETBULK-walk it.
//
// Defaults to community "public". The community field is editable and a
// note explains we never write.

import SwiftUI

// MARK: - Mode

enum SNMPMode: String, CaseIterable, Identifiable {
    case system     = "System Info"
    case interfaces = "Interfaces"
    case walk       = "Custom OID Walk"
    var id: String { rawValue }
}

// MARK: - Row models

struct SNMPInterfaceRow: Identifiable, Hashable {
    let id: UInt32              // ifIndex
    let descr: String
    let operStatus: String
    let speed: String           // human-formatted
    let speedRaw: UInt64        // for sorting
    let inOctets: UInt64
    let outOctets: UInt64
}

private struct OIDRow: Identifiable, Hashable {
    let id = UUID()
    let oid: String
    let typeLabel: String
    let value: String
}

// MARK: - Model

@MainActor
final class SNMPQueryModel: ObservableObject {
    @Published var host = ""
    @Published var community = "public"
    @Published var port = "161"
    @Published var mode: SNMPMode = .system
    @Published var customOID = "1.3.6.1.2.1.1"

    @Published var isRunning = false
    @Published var status = ""
    @Published var errorMessage: String?

    // System Info
    @Published var sysDescr = ""
    @Published var sysName = ""
    @Published var sysLocation = ""
    @Published var sysContact = ""
    @Published var sysUpTime = ""
    @Published var sysObjectID = ""
    @Published var matchedVendor: String?
    @Published var matchedRole: DeviceRole?
    @Published var matchedModel: String?

    // Interfaces
    @Published var interfaces: [SNMPInterfaceRow] = []

    // Walk
    @Published var walkRows: [OIDWalkRow] = []

    struct OIDWalkRow: Identifiable, Hashable {
        let id = UUID()
        let oid: String
        let typeLabel: String
        let value: String
    }

    private var task: Task<Void, Never>?

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
        status = "Cancelled"
    }

    func run() {
        task?.cancel()
        errorMessage = nil
        guard !host.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "Enter a host"
            return
        }
        let portNum = UInt16(port) ?? 161
        let client = SNMPClient(host: host.trimmingCharacters(in: .whitespaces),
                                port: portNum,
                                community: community.isEmpty ? "public" : community,
                                version: .v2c,
                                timeout: 3.0,
                                retries: 1)
        isRunning = true
        status = "Querying \(host)…"

        switch mode {
        case .system:     runSystem(client)
        case .interfaces: runInterfaces(client)
        case .walk:       runWalk(client)
        }
    }

    private func runSystem(_ client: SNMPClient) {
        task = Task { [weak self] in
            guard let self = self else { return }
            do {
                let vbs = try await client.get([
                    SNMPOID.sysDescr, SNMPOID.sysObjectID, SNMPOID.sysUpTime,
                    SNMPOID.sysContact, SNMPOID.sysName, SNMPOID.sysLocation,
                ])
                let byOID = Dictionary(uniqueKeysWithValues: vbs.map { ($0.oid, $0.value) })
                await MainActor.run {
                    self.sysDescr     = byOID[SNMPOID.sysDescr]?.description ?? ""
                    self.sysObjectID  = byOID[SNMPOID.sysObjectID]?.description ?? ""
                    self.sysUpTime    = byOID[SNMPOID.sysUpTime]?.description ?? ""
                    self.sysContact   = byOID[SNMPOID.sysContact]?.description ?? ""
                    self.sysName      = byOID[SNMPOID.sysName]?.description ?? ""
                    self.sysLocation  = byOID[SNMPOID.sysLocation]?.description ?? ""
                    if let v = byOID[SNMPOID.sysObjectID], case .oid(let o) = v,
                       let m = SysObjectIDDatabase.match(o) {
                        self.matchedVendor = m.vendor
                        self.matchedRole = m.role
                        self.matchedModel = m.model
                    } else {
                        self.matchedVendor = nil
                        self.matchedRole = nil
                        self.matchedModel = nil
                    }
                    self.status = "System info retrieved"
                    self.isRunning = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "\(error)"
                    self.status = ""
                    self.isRunning = false
                }
            }
        }
    }

    private func runInterfaces(_ client: SNMPClient) {
        task = Task { [weak self] in
            guard let self = self else { return }
            do {
                async let descrRows  = client.bulkWalk(SNMPOID.ifDescr, maxReps: 30, maxRows: 256)
                async let speedRows  = client.bulkWalk(SNMPOID.ifSpeed, maxReps: 30, maxRows: 256)
                async let statusRows = client.bulkWalk(SNMPOID.ifOperStatus, maxReps: 30, maxRows: 256)
                async let inRows     = client.bulkWalk(SNMPOID.ifInOctets, maxReps: 30, maxRows: 256)
                async let outRows    = client.bulkWalk(SNMPOID.ifOutOctets, maxReps: 30, maxRows: 256)
                let (d, sp, st, ino, outo) = try await (descrRows, speedRows, statusRows, inRows, outRows)

                func lastSubID(_ o: OID) -> UInt32 { o.components.last ?? 0 }
                let dDict  = Dictionary(uniqueKeysWithValues: d.map { (lastSubID($0.oid), $0.value) })
                let spDict = Dictionary(uniqueKeysWithValues: sp.map { (lastSubID($0.oid), $0.value) })
                let stDict = Dictionary(uniqueKeysWithValues: st.map { (lastSubID($0.oid), $0.value) })
                let inDict = Dictionary(uniqueKeysWithValues: ino.map { (lastSubID($0.oid), $0.value) })
                let outDict = Dictionary(uniqueKeysWithValues: outo.map { (lastSubID($0.oid), $0.value) })

                let indexes = Set(dDict.keys).sorted()
                let rows: [SNMPInterfaceRow] = indexes.map { idx in
                    let speedRaw: UInt64 = {
                        switch spDict[idx] {
                        case .gauge32(let g):   return UInt64(g)
                        case .counter32(let c): return UInt64(c)
                        case .integer(let i):   return UInt64(max(0, i))
                        default: return 0
                        }
                    }()
                    let inO: UInt64 = {
                        switch inDict[idx] {
                        case .counter32(let c): return UInt64(c)
                        case .counter64(let c): return c
                        case .integer(let i):   return UInt64(max(0, i))
                        default: return 0
                        }
                    }()
                    let outO: UInt64 = {
                        switch outDict[idx] {
                        case .counter32(let c): return UInt64(c)
                        case .counter64(let c): return c
                        case .integer(let i):   return UInt64(max(0, i))
                        default: return 0
                        }
                    }()
                    return SNMPInterfaceRow(
                        id: idx,
                        descr: dDict[idx]?.description ?? "",
                        operStatus: ifStatusLabel(stDict[idx]),
                        speed: formatSpeed(speedRaw),
                        speedRaw: speedRaw,
                        inOctets: inO,
                        outOctets: outO
                    )
                }
                await MainActor.run {
                    self.interfaces = rows
                    self.status = "\(rows.count) interface\(rows.count == 1 ? "" : "s") retrieved"
                    self.isRunning = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "\(error)"
                    self.status = ""
                    self.isRunning = false
                }
            }
        }
    }

    private func runWalk(_ client: SNMPClient) {
        task = Task { [weak self] in
            guard let self = self else { return }
            let trimmed = self.customOID.trimmingCharacters(in: .whitespaces)
            guard let base = OID(string: trimmed) else {
                await MainActor.run {
                    self.errorMessage = "Invalid OID: \(trimmed)"
                    self.isRunning = false
                }
                return
            }
            do {
                let rows = try await client.bulkWalk(base, maxReps: 25, maxRows: 1024)
                let mapped: [OIDWalkRow] = rows.map {
                    OIDWalkRow(oid: $0.oid.description,
                               typeLabel: snmpTypeLabel($0.value),
                               value: $0.value.description)
                }
                await MainActor.run {
                    self.walkRows = mapped
                    self.status = "\(mapped.count) row\(mapped.count == 1 ? "" : "s") returned"
                    self.isRunning = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "\(error)"
                    self.status = ""
                    self.isRunning = false
                }
            }
        }
    }

    // MARK: Export

    func exportText() -> String {
        var s = "SNMP query: \(host) (community=\(community))\n"
        switch mode {
        case .system:
            if let v = matchedVendor {
                s += "Vendor: \(v)\n"
                if let m = matchedModel { s += "Model: \(m)\n" }
                if let r = matchedRole { s += "Role:  \(r.rawValue)\n" }
                s += "\n"
            }
            s += "sysName:     \(sysName)\nsysDescr:    \(sysDescr)\nsysObjectID: \(sysObjectID)\n"
            s += "sysUpTime:   \(sysUpTime)\nsysContact:  \(sysContact)\nsysLocation: \(sysLocation)\n"
        case .interfaces:
            s += "idx\tname\tstatus\tspeed\tin (bytes)\tout (bytes)\n"
            for r in interfaces {
                s += "\(r.id)\t\(r.descr)\t\(r.operStatus)\t\(r.speed)\t\(r.inOctets)\t\(r.outOctets)\n"
            }
        case .walk:
            for r in walkRows { s += "\(r.oid)\t\(r.typeLabel)\t\(r.value)\n" }
        }
        return s
    }
}

private func ifStatusLabel(_ v: SNMPValue?) -> String {
    if case .integer(let i) = v {
        switch i {
        case 1: return "up"
        case 2: return "down"
        case 3: return "testing"
        case 4: return "unknown"
        case 5: return "dormant"
        case 6: return "notPresent"
        case 7: return "lowerLayerDown"
        default: return "—"
        }
    }
    return "—"
}

private func formatSpeed(_ bps: UInt64) -> String {
    if bps == 0 { return "—" }
    if bps >= 1_000_000_000 { return String(format: "%.0f Gbps", Double(bps) / 1_000_000_000) }
    if bps >= 1_000_000     { return String(format: "%.0f Mbps", Double(bps) / 1_000_000) }
    if bps >= 1_000         { return String(format: "%.0f kbps", Double(bps) / 1_000) }
    return "\(bps) bps"
}

private func snmpTypeLabel(_ v: SNMPValue) -> String {
    switch v {
    case .integer:        return "INTEGER"
    case .octetString:    return "STRING"
    case .oid:            return "OID"
    case .null:           return "NULL"
    case .ipAddress:      return "IpAddress"
    case .counter32:      return "Counter32"
    case .gauge32:        return "Gauge32"
    case .timeTicks:      return "TimeTicks"
    case .opaque:         return "Opaque"
    case .counter64:      return "Counter64"
    case .noSuchObject:   return "noSuchObject"
    case .noSuchInstance: return "noSuchInstance"
    case .endOfMibView:   return "endOfMibView"
    }
}

// MARK: - View

struct SNMPView: View {
    @StateObject private var model = SNMPQueryModel()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .navigationTitle("SNMP")
    }

    private var toolbar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "network.badge.shield.half.filled").foregroundStyle(.cyan)
                Text("SNMP v2c").font(.system(size: 13, weight: .semibold)).foregroundStyle(NS.text1)
                Spacer()
                if !model.status.isEmpty {
                    Text(model.status).font(.system(size: 11)).foregroundStyle(NS.text3)
                }
                ToolActionBar("SNMP", text: { model.exportText() })
            }
            HStack(spacing: 8) {
                TextField("Host or IP", text: $model.host)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                TextField("community", text: $model.community)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                TextField("port", text: $model.port)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                Picker("", selection: $model.mode) {
                    ForEach(SNMPMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 320)

                if model.mode == .walk {
                    TextField("OID (e.g. 1.3.6.1.2.1.2.2)", text: $model.customOID)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                }
                Spacer()
                if model.isRunning {
                    Button("Stop") { model.cancel() }
                        .buttonStyle(.bordered).tint(.red)
                    ProgressView().controlSize(.small)
                } else {
                    Button("Query") { model.run() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.host.isEmpty)
                        .keyboardShortcut(.return)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(NS.bg0)
    }

    @ViewBuilder
    private var content: some View {
        if let err = model.errorMessage {
            errorBanner(err)
        }
        switch model.mode {
        case .system:     systemPane
        case .interfaces: interfacesPane
        case .walk:       walkPane
        }
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(NS.red)
            Text(text).font(.system(size: 12, design: .monospaced)).foregroundStyle(NS.text1)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(NS.red.opacity(0.08))
    }

    // MARK: System

    private var systemPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let v = model.matchedVendor {
                    HStack(spacing: 10) {
                        Image(systemName: (model.matchedRole ?? .unknown).icon)
                            .foregroundStyle(NS.amber)
                            .font(.system(size: 22))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(v + (model.matchedModel.map { " · \($0)" } ?? ""))
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(NS.text1)
                            if let r = model.matchedRole {
                                Text("Identified by sysObjectID — \(r.rawValue)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(NS.text3)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(NS.amber.opacity(0.08))
                    Divider().background(NS.borderMid)
                }
                VStack(alignment: .leading, spacing: 12) {
                    sysRow("sysName",     model.sysName)
                    sysRow("sysDescr",    model.sysDescr)
                    sysRow("sysObjectID", model.sysObjectID)
                    sysRow("sysUpTime",   model.sysUpTime)
                    sysRow("sysContact",  model.sysContact)
                    sysRow("sysLocation", model.sysLocation)
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
            }
        }
    }

    private func sysRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(NS.text3).frame(width: 110, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(NS.text1)
                .textSelection(.enabled)
        }
    }

    // MARK: Interfaces

    private var interfacesPane: some View {
        Table(model.interfaces) {
            TableColumn("Idx") { r in Text(String(r.id)).font(.system(.body, design: .monospaced)) }
                .width(40)
            TableColumn("Name", value: \.descr)
            TableColumn("Status") { r in
                Text(r.operStatus)
                    .foregroundStyle(r.operStatus == "up" ? NS.green : (r.operStatus == "down" ? NS.red : NS.text3))
            }
            .width(70)
            TableColumn("Speed") { r in Text(r.speed).font(.system(.body, design: .monospaced)) }
                .width(80)
            TableColumn("In") { r in Text(byteFormat(r.inOctets)).font(.system(.body, design: .monospaced)) }
                .width(80)
            TableColumn("Out") { r in Text(byteFormat(r.outOctets)).font(.system(.body, design: .monospaced)) }
                .width(80)
        }
    }

    private func byteFormat(_ b: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(b); var i = 0
        while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
        return String(format: "%.1f %@", v, units[i])
    }

    // MARK: Walk

    private var walkPane: some View {
        Table(model.walkRows) {
            TableColumn("OID", value: \.oid)
                .width(min: 200, ideal: 260)
            TableColumn("Type", value: \.typeLabel).width(90)
            TableColumn("Value") { r in
                Text(r.value).textSelection(.enabled)
            }
        }
    }
}
