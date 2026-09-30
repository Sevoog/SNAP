// EmptyStateView.swift
// SNAP — macOS 13-compatible empty state view
// Created by Sevag Bardakjian

import SwiftUI

/// macOS 13-compatible replacement for ContentUnavailableView (which requires macOS 14)
struct EmptyStateView: View {
    let title: String
    let systemImage: String
    var description: String = ""

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(.secondary)
            if !description.isEmpty {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
