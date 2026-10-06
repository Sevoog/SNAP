// HTTPProbeView.swift
// SNAP — HTTP/HTTPS Probe
// Created by Sevag Bardakjian

import SwiftUI

struct HTTPHeader: Identifiable, Hashable {
    let id = UUID()
    static func == (lhs: HTTPHeader, rhs: HTTPHeader) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    let key: String
    let value: String
}

struct HTTPProbeView: View {
    @State private var url = "https://"
    @State private var method = "GET"
    @State private var customHeaders = ""
    @State private var requestBody = ""
    @State private var followRedirects = true
    @State private var statusCode = 0
    @State private var responseHeaders: [HTTPHeader] = []
    @State private var responseBody = ""
    @State private var responseTime = 0.0
    @State private var isRunning = false
    @State private var error = ""
    @State private var redirectChain: [String] = []

    let methods = ["GET", "POST", "PUT", "DELETE", "HEAD", "OPTIONS", "PATCH"]

    var statusColor: Color {
        switch statusCode {
        case 200...299: return .green
        case 300...399: return .yellow
        case 400...499: return .orange
        case 500...599: return .red
        default:        return .gray
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // URL bar
            HStack(spacing: 8) {
                Picker("", selection: $method) {
                    ForEach(methods, id: \.self) { m in Text(m).tag(m) }
                }
                .frame(width: 90)

                TextField("https://example.com", text: $url)
                    .textFieldStyle(.roundedBorder)
                HistoryMenuButton(key: .http) { url = $0 }

                Toggle("Follow Redirects", isOn: $followRedirects)
                    .toggleStyle(.checkbox)
                    .font(.caption)

                if statusCode != 0 {
                    ToolActionBar("HTTP-Probe", text: {
                        var s = "\(method) \(url)\nStatus: \(statusCode) · \(String(format: "%.0f ms", responseTime))\n"
                        if !redirectChain.isEmpty { s += "Redirects:\n" + redirectChain.map { "  → \($0)" }.joined(separator: "\n") + "\n" }
                        s += "\nResponse headers:\n" + responseHeaders.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
                        s += "\n\nBody:\n" + responseBody
                        return s
                    })
                }
                if isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Send") { probe() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(NS.bg0)

            Divider()

            HSplitView {
                // Request config
                VStack(alignment: .leading, spacing: 0) {
                    GroupBox("Request Headers") {
                        TextEditor(text: $customHeaders)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(height: 80)
                    }
                    .padding(10)

                    if method == "POST" || method == "PUT" || method == "PATCH" {
                        GroupBox("Request Body") {
                            TextEditor(text: $requestBody)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(height: 80)
                        }
                        .padding([.horizontal, .bottom], 10)
                    }

                    if !redirectChain.isEmpty {
                        GroupBox("Redirect Chain") {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(redirectChain.enumerated()), id: \.offset) { i, url in
                                    HStack {
                                        Image(systemName: i == redirectChain.count - 1 ? "checkmark.circle.fill" : "arrow.turn.down.right")
                                            .foregroundStyle(i == redirectChain.count - 1 ? .green : .blue)
                                            .font(.caption)
                                        Text(url).font(.caption.monospaced()).lineLimit(1)
                                    }
                                }
                            }
                        }
                        .padding([.horizontal, .bottom], 10)
                    }
                    Spacer()
                }
                .frame(minWidth: 240, maxWidth: 300)

                // Response
                VStack(spacing: 0) {
                    // Status bar
                    if statusCode > 0 {
                        HStack(spacing: 12) {
                            Text("\(statusCode)")
                                .font(.title2.bold())
                                .foregroundStyle(statusColor)
                            Text(HTTPURLResponse.localizedString(forStatusCode: statusCode))
                                .foregroundStyle(statusColor)
                            Spacer()
                            Text(String(format: "%.0fms", responseTime * 1000))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(statusColor.opacity(0.1))
                        Divider()
                    }

                    if !error.isEmpty {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                            Text(error).foregroundStyle(.red).textSelection(.enabled)
                            Spacer()
                        }
                        .padding(12)
                    }

                    // Response headers
                    if !responseHeaders.isEmpty {
                        GroupBox("Response Headers") {
                            Table(responseHeaders) {
                                TableColumn("Header") { h in
                                    Text(h.key).font(.caption.monospaced()).bold()
                                }.width(min: 150, ideal: 200)
                                TableColumn("Value") { h in
                                    Text(h.value).font(.caption.monospaced()).textSelection(.enabled)
                                }
                            }
                            .frame(height: min(CGFloat(responseHeaders.count * 22 + 30), 200))
                        }
                        .padding(10)
                    }

                    // Response body
                    GroupBox("Response Body") {
                        ScrollView {
                            Text(responseBody.isEmpty ? "No body" : responseBody)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minHeight: 150)
                    }
                    .padding(10)
                }
            }
        }
        .tabNavigationTitle(.http)
        .consumeHandoff(for: .http) { url = $0 }
    }

    private func probe() {
        let v = url.trimmingCharacters(in: .whitespaces)
        if !v.isEmpty { ToolHistory.shared.add(.http, v) }
        statusCode = 0
        responseHeaders = []
        responseBody = ""
        error = ""
        redirectChain = []
        isRunning = true

        guard let reqURL = URL(string: url) else {
            error = "Invalid URL"
            isRunning = false
            return
        }

        var request = URLRequest(url: reqURL)
        request.httpMethod = method
        request.timeoutInterval = 30

        // Parse custom headers
        for line in customHeaders.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: ":").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count >= 2 {
                request.setValue(parts[1...].joined(separator: ":"), forHTTPHeaderField: parts[0])
            }
        }

        if !requestBody.isEmpty, let bodyData = requestBody.data(using: .utf8) {
            request.httpBody = bodyData
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: config, delegate: RedirectDelegate(chain: { url in
            DispatchQueue.main.async { self.redirectChain.append(url) }
        }, follow: followRedirects), delegateQueue: nil)

        let start = Date()
        session.dataTask(with: request) { data, response, err in
            DispatchQueue.main.async {
                self.responseTime = Date().timeIntervalSince(start)
                if let e = err {
                    self.error = e.localizedDescription
                } else if let httpResp = response as? HTTPURLResponse {
                    self.statusCode = httpResp.statusCode
                    self.responseHeaders = httpResp.allHeaderFields.compactMap { (k, v) in
                        HTTPHeader(key: "\(k)", value: "\(v)")
                    }.sorted { $0.key < $1.key }
                    if let d = data {
                        let preview = String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1) ?? ""
                        self.responseBody = String(preview.prefix(10000))
                    }
                }
                self.isRunning = false
            }
        }.resume()
    }
}

class RedirectDelegate: NSObject, URLSessionTaskDelegate {
    let chain: (String) -> Void
    let follow: Bool
    init(chain: @escaping (String) -> Void, follow: Bool) {
        self.chain = chain; self.follow = follow
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        if let url = request.url?.absoluteString { chain(url) }
        completionHandler(follow ? request : nil)
    }
}
