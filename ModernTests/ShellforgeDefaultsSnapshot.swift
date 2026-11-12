//
//  ShellforgeDefaultsSnapshot.swift
//  ModernTests
//
//  The app's defaults the Shellforge tests change — the sidebar's width, whether it is hidden, its
//  text size, Match the terminal, the theme, the tab style and position — as they were before a test,
//  put back after it, so no test hands the next one a sidebar left hidden, a terminal left matched or
//  a theme left on.
//

import Foundation
@testable import iTerm2SharedARC

@MainActor
struct ShellforgeDefaultsSnapshot {
    /// `TerminalMatchSettings.defaultsKey`.
    private static let matchKey = "ShellforgeMatchTerminal"
    private static let keys = ["ShellforgeSidebarWidth", "ShellforgeSidebarHidden", "ShellforgeSidebarScale",
                               Self.matchKey, kPreferenceKeyTabStyle, kPreferenceKeyTabPosition,
                               // `ThemeSettings`' keys.
                               "ShellforgeThemeFollowsMac", "ShellforgeThemeLight", "ShellforgeThemeDark", "ShellforgeTheme"]
    private let values: [String: Any]
    private let matched: Bool
    private let theme: (followsMac: Bool, light: String, dark: String, single: String)

    init() {
        let defaults = iTermUserDefaults.userDefaults()
        values = Dictionary(uniqueKeysWithValues: Self.keys.compactMap { key in defaults.object(forKey: key).map { (key, $0) } })
        matched = defaults.bool(forKey: Self.matchKey)
        theme = iTermShellforgeThemes.savedChoice
    }

    /// Match and the theme go back through the app, so its terminals and the app's appearance are
    /// as saved; the rest as stored.
    func restore() {
        iTermShellforgeTerminalMatch.setOn(matched)
        iTermShellforgeThemes.save(followsMac: theme.followsMac, light: theme.light, dark: theme.dark, single: theme.single)
        let defaults = iTermUserDefaults.userDefaults()
        for key in Self.keys {
            if let value = values[key] { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
    }
}
