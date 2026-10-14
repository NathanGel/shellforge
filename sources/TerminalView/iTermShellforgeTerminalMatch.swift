//
//  iTermShellforgeTerminalMatch.swift
//  Shellforge
//
//  Settings › Core › Terminal's match, for iTerm2's own code: Shellforge's colours laid over the
//  profile a session loads its colours from, and iTerm2's Minimal theme, while it is on. Neither
//  the profiles nor the theme setting are ever written.
//

import AppKit
import ShellforgeDesign
import ShellforgeUI

@objc(iTermShellforgeTerminalMatch)
@MainActor
final class iTermShellforgeTerminalMatch: NSObject {
    /// The app's one switch, in iTerm2's defaults domain so a `-suite` run keeps its own. Made on
    /// first use, which also starts following the accent colour and Increase Contrast.
    static let settings: TerminalMatchSettings = {
        let settings = TerminalMatchSettings(defaults: iTermUserDefaults.userDefaults())
        settings.onChange = { _ in recolour() }
        let recolourIfOn: @Sendable (Notification) -> Void = { _ in
            MainActor.assumeIsolated { if settings.isOn { recolour() } }
        }
        NotificationCenter.default.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main,
                                               using: recolourIfOn)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                          object: nil, queue: .main, using: recolourIfOn)
        return settings
    }()

    /// Posted after every session has been recoloured: Settings › Appearance greys its Theme control.
    @objc static let didChangeNotification = NSNotification.Name("iTermShellforgeTerminalMatchDidChange")

    /// Whether iTerm2's theme reads as Minimal. Asked from `computedTabStyle`, on any thread, so it
    /// reads the saved value straight from defaults rather than the main-actor `settings`.
    @objc nonisolated static var overridesTheme: Bool {
        iTermUserDefaults.userDefaults().bool(forKey: TerminalMatchSettings.defaultsKey)
    }

    /// The profile `loadColorsFromProfile:` reads: `profile` itself while off; while on, a copy with
    /// each palette key, and its light and dark variants, set to Shellforge's colour — except the
    /// keys in `overridden`, which the session set for itself.
    @objc static func profile(forColors profile: [AnyHashable: Any], keeping overridden: Set<String>?) -> [AnyHashable: Any] {
        guard settings.isOn else { return profile }
        var result = profile
        for (role, color) in ShellforgeTerminalPalette.colors() {
            let value = nsColor(color).dictionaryValue
            let base = key(for: role)
            for key in [base, base + COLORS_LIGHT_MODE_SUFFIX, base + COLORS_DARK_MODE_SUFFIX] where overridden?.contains(key) != true {
                result[key] = value
            }
        }
        return result
    }

    /// Switches and saves at once, for host tests, which cannot import ShellforgeUI.
    static func setOn(_ on: Bool) { settings.set(on) }

    /// The palette's colour for an iTerm2 base colour key, for host tests.
    static func paletteColor(forKey key: String) -> NSColor? {
        ShellforgeTerminalPalette.colors().first { self.key(for: $0.key) == key }.map { nsColor($0.value) }
    }

    /// The profile key iTerm2 keeps `role` under.
    private static func key(for role: TerminalColorRole) -> String {
        switch role {
        case .background: KEY_BACKGROUND_COLOR
        case .foreground: KEY_FOREGROUND_COLOR
        case .bold: KEY_BOLD_COLOR
        case .cursor: KEY_CURSOR_COLOR
        case .cursorText: KEY_CURSOR_TEXT_COLOR
        case .selection: KEY_SELECTION_COLOR
        case .selectedText: KEY_SELECTED_TEXT_COLOR
        case .ansi(let index): "Ansi \(index) Color"
        }
    }

    private static func nsColor(_ color: SRGB) -> NSColor {
        NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
    }

    /// Every open session reloads its colours from its own profile, through the hook, and its Minimal
    /// appearance; then iTerm2 redraws its windows as it does when its theme setting changes.
    private static func recolour() {
        for session in iTermController.sharedInstance()?.allSessions() ?? [] {
            if let profile = session.profile { session.loadColors(fromProfile: profile) }
            session.themeDidChange()
        }
        (NSApp as? iTermApplication)?.updateAppearance()
        NotificationCenter.default.post(name: .refreshTerminal, object: nil)
        // The theme's other listeners — the status bar, Profiles › Colors, the effectiveTheme
        // variable — hear a theme change as this notification; the setting itself is not written.
        iTermPreferenceDidChangeNotification(key: kPreferenceKeyTabStyle,
                                             value: iTermPreferences.object(forKey: kPreferenceKeyTabStyle)).post()
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}
