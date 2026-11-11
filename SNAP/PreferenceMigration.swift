// PreferenceMigration.swift
// SNAP: Moves preferences off the old com.bardaklabs.snap names (v1.5.9)
// Created by Sevag Bardakjian
// Copyright © 2026 Sevag Bardakjian
// SPDX-License-Identifier: GPL-3.0-only
// Additional attribution term (GPL-3.0 section 7(b)): see NOTICE.md
//
// Up to 1.5.8, most preferences (theme, favorites, layouts, input history,
// the Quick Tour flag, SNMP hosts) were saved under "com.bardaklabs.snap.*"
// keys. They now use "com.sevagbardakjian.snap.*", like the Keychain items
// renamed in 1.5.7. This runs at launch, before anything reads them: each old
// key is copied to its new name and then removed. A value already saved
// under the new name is kept. Running it again finds nothing to move.
//
// Older SNAP versions read only the old names, so going back to 1.5.8 or
// earlier after this runs starts those settings fresh.

import Foundation

enum PreferenceMigration {
    static let oldPrefix = "com.bardaklabs.snap."
    static let newPrefix = "com.sevagbardakjian.snap."

    /// Returns how many keys moved.
    @discardableResult
    static func run(_ defaults: UserDefaults = .standard) -> Int {
        var moved = 0
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(oldPrefix) {
            let newKey = newPrefix + key.dropFirst(oldPrefix.count)
            if defaults.object(forKey: newKey) == nil {
                defaults.set(value, forKey: newKey)
                moved += 1
            }
            defaults.removeObject(forKey: key)
        }
        return moved
    }
}
