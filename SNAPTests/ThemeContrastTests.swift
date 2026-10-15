// ThemeContrastTests.swift
// SNAP — Tests for theme contrast checks (menu bar popover text)
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md

import XCTest
import SwiftUI
@testable import SNAP

final class ThemeContrastTests: XCTestCase {

    func test_ratio_knownValues() {
        XCTAssertEqual(ThemeContrast.ratio(.black, on: .white), 21, accuracy: 0.01)
        XCTAssertEqual(ThemeContrast.ratio(.white, on: .white), 1, accuracy: 0.01)
        // Translucent text is blended with its background first.
        XCTAssertEqual(ThemeContrast.ratio(Color.white.opacity(0), on: .black), 1, accuracy: 0.01)
    }

    /// Every popover surface in every theme: captions and accents reach 4.5:1,
    /// icons and field borders 3:1. Faint ink at 15 to 30% measured 1.6 to 2.7.
    func test_readable_meetsTheMinimum_inEveryTheme() {
        for t in Theme.all {
            for bg in [t.bg0, t.bg2, t.bg3] {
                for c in [t.text2, t.green, t.blue, t.amber, t.red] {
                    let r = ThemeContrast.readable(c, on: bg, toward: t.text1)
                    XCTAssertGreaterThanOrEqual(ThemeContrast.ratio(r, on: bg), 4.5, "\(t.id)")
                }
                for c in [t.text3, t.blue] {
                    let r = ThemeContrast.readable(c, on: bg, toward: t.text1, minimum: 3)
                    XCTAssertGreaterThanOrEqual(ThemeContrast.ratio(r, on: bg), 3, "\(t.id)")
                }
                let badge = ThemeContrast.flatten(t.amber.opacity(0.15), over: bg)
                XCTAssertGreaterThanOrEqual(
                    ThemeContrast.ratio(ThemeContrast.readable(t.amber, on: badge, toward: t.text1), on: badge),
                    4.5, "\(t.id) badge")
            }
        }
    }

    /// A color that already passes is left exactly as the theme defines it.
    func test_readable_keepsPassingColors() {
        let t = Theme.daylight
        XCTAssertEqual(ThemeContrast.readable(t.text1, on: t.bg2, toward: t.text1), t.text1)
        XCTAssertEqual(ThemeContrast.readable(t.blue, on: t.bg2, toward: t.text1), t.blue)
    }
}
