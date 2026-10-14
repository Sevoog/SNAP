// SharedToolComponents.swift
// SNAP v1.1 — Reusable Copy + Export buttons for every tool view
// Created by Sevag Bardakjian
// Copyright © 2025-2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md

import SwiftUI
import AppKit

// MARK: - Copy Result Button

struct CopyButton: View {
    let getText: () -> String
    @State private var copied = false

    var body: some View {
        Button {
            let text = getText()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            withAnimation { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                withAnimation { copied = false }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
                Text(copied ? "Copied!" : "Copy")
                    .font(.system(size: 11))
            }
            .foregroundStyle(copied ? .green : .secondary)
        }
        .buttonStyle(.bordered)
        .animation(.easeInOut(duration: 0.2), value: copied)
    }
}

// MARK: - Export Button (Save panel for txt/csv/json)

struct ExportButton: View {
    let toolName: String
    let getText:  () -> String
    let getCSV:   (() -> String)?
    let getJSON:  (() -> String)?

    @State private var showMenu = false

    init(toolName: String,
         getText: @escaping () -> String,
         getCSV:  (() -> String)? = nil,
         getJSON: (() -> String)? = nil) {
        self.toolName = toolName
        self.getText  = getText
        self.getCSV   = getCSV
        self.getJSON  = getJSON
    }

    var body: some View {
        Menu {
            Button("Export as Text (.txt)") { save(getText(), ext: "txt") }
            if let csv = getCSV {
                Button("Export as CSV (.csv)")  { save(csv(), ext: "csv") }
            }
            if let json = getJSON {
                Button("Export as JSON (.json)") { save(json(), ext: "json") }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 11))
                Text("Export")
                    .font(.system(size: 11))
            }
        }
        .buttonStyle(.bordered)
    }

    private func save(_ content: String, ext: String) {
        let panel = NSSavePanel()
        panel.title = "Export \(toolName) Results"
        panel.canCreateDirectories = true
        let stamp = DateFormatter().apply {
            $0.dateFormat = "yyyyMMdd_HHmmss"
        }.string(from: Date())
        panel.nameFieldStringValue = "SNAP_\(toolName.replacingOccurrences(of: " ", with: "_"))_\(stamp).\(ext)"
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

private extension DateFormatter {
    func apply(_ configure: (DateFormatter) -> Void) -> DateFormatter {
        configure(self); return self
    }
}

// MARK: - Tool Toolbar modifier
// Adds Copy + Export to any tool's top toolbar in one line:
//   .toolToolbar(name: "Ping", text: { output })

struct ToolActionBar: View {
    let toolName: String
    let getText:  () -> String
    let getCSV:   (() -> String)?
    let getJSON:  (() -> String)?

    init(_ toolName: String,
         text: @escaping () -> String,
         csv:  (() -> String)? = nil,
         json: (() -> String)? = nil) {
        self.toolName = toolName
        self.getText  = text
        self.getCSV   = csv
        self.getJSON  = json
    }

    var body: some View {
        HStack(spacing: 6) {
            CopyButton(getText: getText)
            ExportButton(toolName: toolName, getText: getText, getCSV: getCSV, getJSON: getJSON)
        }
    }
}


