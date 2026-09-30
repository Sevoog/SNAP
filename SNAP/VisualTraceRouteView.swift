// VisualTraceRouteView.swift
// SNAP — Visual Trace Route with Map
// Created by Sevag Bardakjian

import SwiftUI
import MapKit

struct GeoHop: Identifiable, Hashable {
    static func == (lhs: GeoHop, rhs: GeoHop) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    let id = UUID()
    var hop: Int
    var ip: String
    var hostname: String
    var rtt: String
    var coordinate: CLLocationCoordinate2D?
    var city: String = ""
    var country: String = ""
    var countryCode: String = ""  // ISO 3166-1 alpha-2, used for the flag emoji
    var org: String = ""
}

final class VisualTraceViewModel: ObservableObject {
    @Published var hops: [GeoHop] = []
    @Published var isRunning = false
    @Published var process: Process?
    // Published as simple values so macOS 13 can observe without MapCameraPosition
    @Published var cameraLat: Double = 30
    @Published var cameraLon: Double = -40
    @Published var cameraLatDelta: Double = 80
    @Published var cameraLonDelta: Double = 120

    var currentRegion: MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: cameraLat, longitude: cameraLon),
            span: MKCoordinateSpan(latitudeDelta: cameraLatDelta, longitudeDelta: cameraLonDelta)
        )
    }

    func start(host: String) {
        hops = []
        isRunning = true
        // Reset camera to world view
        cameraLat = 30; cameraLon = -40; cameraLatDelta = 80; cameraLonDelta = 120

        process = Shell.stream("/usr/sbin/traceroute", args: ["-m", "20", "-q", "1", "-w", "3", host],
            onLine: { [weak self] line in
                guard let self else { return }
                if let hop = parseTracerouteLine(line) {
                    Task { await self.geolocate(hop: hop) }
                }
            },
            onFinish: { [weak self] in self?.isRunning = false }
        )
    }

    private func parseTracerouteLine(_ line: String) -> GeoHop? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let hopNum = trimmed.split(separator: " ").first.flatMap({ Int($0) }) else { return nil }
        let parts = trimmed.components(separatedBy: " ").filter { !$0.isEmpty }
        var ip = "", hostname = ""
        var rttMs: Double?

        for (idx, tok) in parts.enumerated() {
            if tok.hasPrefix("(") {
                ip = tok.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            } else if tok == "ms", idx > 0, let ms = Double(parts[idx - 1]) {
                if rttMs == nil { rttMs = ms }
            } else if let ms = Double(tok.replacingOccurrences(of: "ms", with: "")), ms > 0, !tok.hasPrefix("(") {
                if rttMs == nil { rttMs = ms }
            } else if idx > 0 && (tok.contains(".") || tok.contains(":")) && !tok.hasPrefix("(") {
                if hostname.isEmpty { hostname = tok }
            }
        }

        if parts.dropFirst().allSatisfy({ $0 == "*" }) {
            return GeoHop(hop: hopNum, ip: "", hostname: "No response", rtt: "* ms")
        }
        let rttStr = rttMs.map { String(format: "%.2f ms", $0) } ?? "* ms"
        return GeoHop(hop: hopNum, ip: ip, hostname: hostname.isEmpty ? ip : hostname, rtt: rttStr)
    }

    func stop() {
        if process?.isRunning == true { process?.terminate() }
        isRunning = false
    }

    private func isPrivateIP(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        if parts[0] == 10 { return true }
        if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
        if parts[0] == 192 && parts[1] == 168 { return true }
        if parts[0] == 127 { return true }
        return false
    }

    @MainActor
    private func geolocate(hop: GeoHop) async {
        var h = hop
        guard !hop.ip.isEmpty && hop.ip != "*" && !isPrivateIP(hop.ip) else {
            hops.append(h)
            hops.sort { $0.hop < $1.hop }
            return
        }
        // ipwho.is — HTTPS, same service the GeoIP Lookup tab uses reliably.
        // (Earlier ip-api.com attempt hit unclear failures on some hops;
        // ipwho.is has been consistent for our other geolocation code path.)
        guard let url = URL(string: "https://ipwho.is/\(hop.ip)") else {
            hops.append(h)
            hops.sort { $0.hop < $1.hop }
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               json["success"] as? Bool == true {
                // Cast via NSNumber so integer lat/lon (39 vs 39.0) parse too.
                if let latN = json["latitude"] as? NSNumber,
                   let lonN = json["longitude"] as? NSNumber {
                    h.coordinate = CLLocationCoordinate2D(
                        latitude: latN.doubleValue, longitude: lonN.doubleValue)
                }
                h.city        = json["city"]         as? String ?? ""
                h.country     = json["country"]      as? String ?? ""
                h.countryCode = json["country_code"] as? String ?? ""
                if let conn = json["connection"] as? [String: Any] {
                    let asn = conn["asn"].map { "AS\($0)" } ?? ""
                    let org = (conn["org"] as? String) ?? (conn["isp"] as? String) ?? ""
                    h.org = [asn, org].filter { !$0.isEmpty }.joined(separator: " ")
                }
            }
        } catch {
            NSLog("VisualTrace geolocate failed for \(hop.ip): \(error.localizedDescription)")
        }
        hops.append(h)
        hops.sort { $0.hop < $1.hop }
        updateCamera()
    }

    private func updateCamera() {
        let coords = hops.compactMap { $0.coordinate }
        guard !coords.isEmpty else { return }
        if coords.count == 1 {
            cameraLat = coords[0].latitude
            cameraLon = coords[0].longitude
            cameraLatDelta = 8
            cameraLonDelta = 8
            return
        }
        let lats = coords.map { $0.latitude }
        let lons = coords.map { $0.longitude }
        cameraLat = (lats.min()! + lats.max()!) / 2
        cameraLon = (lons.min()! + lons.max()!) / 2
        cameraLatDelta = max(5, (lats.max()! - lats.min()!) * 1.5)
        cameraLonDelta = max(10, (lons.max()! - lons.min()!) * 1.5)
    }
}

// MARK: - macOS 14+ Map subview with its own @State MapCameraPosition
@available(macOS 14.0, *)
struct TraceMapView: View {
    let geoHops: [GeoHop]
    let polylineCoords: [CLLocationCoordinate2D]
    let region: MKCoordinateRegion

    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $position) {
            ForEach(geoHops) { hop in
                if let coord = hop.coordinate {
                    Annotation("\(hop.hop)", coordinate: coord) {
                        ZStack {
                            Circle()
                                .fill(hop.hop == geoHops.last?.hop ? Color.green : Color.blue)
                                .frame(width: 28, height: 28)
                            Text("\(hop.hop)")
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                        }
                        .shadow(radius: 3)
                    }
                }
            }
            if polylineCoords.count > 1 {
                MapPolyline(coordinates: polylineCoords)
                    .stroke(.blue.opacity(0.7), lineWidth: 2.5)
            }
        }
        .mapStyle(.standard)
        .onChange(of: region.center.latitude, perform: { _ in
            withAnimation(.easeInOut(duration: 0.6)) {
                position = .region(region)
            }
        })
        .onChange(of: region.center.longitude, perform: { _ in
            withAnimation(.easeInOut(duration: 0.6)) {
                position = .region(region)
            }
        })
    }
}

// MARK: - Main View
struct VisualTraceRouteView: View {
    @State private var host = ""
    @StateObject private var model = VisualTraceViewModel()
    @State private var selectedHop: GeoHop?

    private var geoHops: [GeoHop] { model.hops.filter { $0.coordinate != nil } }
    private var polylineCoords: [CLLocationCoordinate2D] { geoHops.compactMap { $0.coordinate } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "map").foregroundStyle(.blue)
                TextField("Hostname or IP", text: $host)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
                    .onSubmit { if !host.isEmpty && !model.isRunning { model.start(host: host) } }
                Spacer()
                if !model.hops.isEmpty {
                    ToolActionBar("Visual-Trace",
                                  text: { "Visual trace to \(host)\n\nhop\tip\thostname\trtt\tcity\tcountry\torg\n" + model.hops.map { "\($0.hop)\t\($0.ip)\t\($0.hostname)\t\($0.rtt)\t\($0.city)\t\($0.country)\t\($0.org)" }.joined(separator: "\n") },
                                  csv: { "hop,ip,hostname,rtt,city,country,org\n" + model.hops.map { "\($0.hop),\($0.ip),\(csvEscape($0.hostname)),\($0.rtt),\(csvEscape($0.city)),\(csvEscape($0.country)),\(csvEscape($0.org))" }.joined(separator: "\n") })
                }
                if model.isRunning {
                    Button("Stop") { model.stop() }
                        .buttonStyle(.bordered).tint(.red)
                    ProgressView().controlSize(.small)
                    Text("\(model.hops.count) hops...")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Trace Route") { model.start(host: host) }
                        .buttonStyle(.borderedProminent)
                        .disabled(host.isEmpty)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(NS.bg0)

            Divider()

            HSplitView {
                // Map pane
                Group {
                    if #available(macOS 14, *) {
                        TraceMapView(
                            geoHops: geoHops,
                            polylineCoords: polylineCoords,
                            region: model.currentRegion
                        )
                    } else {
                        // macOS 13 fallback
                        List(geoHops) { hop in
                            if let c = hop.coordinate {
                                Text("\(hop.hop). \(hop.city), \(hop.country) (\(String(format: "%.2f", c.latitude)), \(String(format: "%.2f", c.longitude)))")
                                    .font(.caption.monospaced())
                            }
                        }
                    }
                }
                .frame(minWidth: 450)

                // Hop list pane
                VStack(spacing: 0) {
                    HStack {
                        Text("Route Hops").font(.headline)
                        Spacer()
                        if !geoHops.isEmpty {
                            Text("\(geoHops.count)/\(model.hops.count) geolocated")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                    Divider()
                    if model.hops.isEmpty {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "map").font(.system(size: 32)).foregroundStyle(.tertiary)
                            Text("Enter a host and tap Trace Route").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        Spacer()
                    } else {
                        List(model.hops, selection: $selectedHop) { hop in
                            hopRow(hop).tag(hop as GeoHop?)
                        }
                    }
                }
                .frame(minWidth: 240, maxWidth: 320)
            }
        }
        .navigationTitle("Visual Trace Route")
        // Tab switching recreates this view — terminate the traceroute
        // process instead of orphaning it
        .onDisappear { model.stop() }
    }

    /// Converts a 2-letter ISO country code to its flag emoji
    /// Works by mapping each letter to its Regional Indicator Symbol (U+1F1E6..U+1F1FF)
    private func flagEmoji(for countryCode: String) -> String {
        let base: UInt32 = 0x1F1E6 - 65  // 'A' is 65, Regional Indicator A is 0x1F1E6
        let code = countryCode.uppercased()
        guard code.count == 2,
              let first  = code.unicodeScalars.first?.value,
              let second = code.unicodeScalars.last?.value,
              first  >= 65 && first  <= 90,
              second >= 65 && second <= 90
        else { return "" }
        let s1 = Unicode.Scalar(base + first)!
        let s2 = Unicode.Scalar(base + second)!
        return String(s1) + String(s2)
    }

    private func hopRow(_ hop: GeoHop) -> some View {
        HStack(spacing: 8) {
            // Hop number badge
            ZStack {
                Circle()
                    .fill(hop.coordinate != nil ? Color.blue : Color.gray.opacity(0.4))
                    .frame(width: 24, height: 24)
                Text("\(hop.hop)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            }

            // IP + location info
            VStack(alignment: .leading, spacing: 2) {
                Group {
                    if hop.ip.isEmpty || hop.ip == "*" {
                        Text(hop.ip.isEmpty ? "*" : hop.ip)
                    } else {
                        Text(hop.ip).hostMenu(hop.ip)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary)
                if !hop.city.isEmpty || !hop.country.isEmpty {
                    HStack(spacing: 4) {
                        let flag = flagEmoji(for: hop.countryCode)
                        if !flag.isEmpty {
                            Text(flag).font(.system(size: 12))
                        }
                        Text([hop.city, hop.country].filter { !$0.isEmpty }.joined(separator: ", "))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                if !hop.org.isEmpty {
                    Text(hop.org)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // RTT with colour coding
            Text(hop.rtt)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(rttColor(hop.rtt))
        }
        .padding(.vertical, 3)
    }

    private func rttColor(_ rtt: String) -> Color {
        guard rtt != "* ms", rtt.contains("ms") else { return Color.secondary }
        let ms = Double(rtt.replacingOccurrences(of: " ms", with: "")) ?? 999
        if ms < 50  { return Color.green }
        if ms < 150 { return Color.orange }
        return Color.red
    }
}
