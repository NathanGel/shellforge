//
//  iTermShellforgeThemes.swift
//  Shellforge
//
//  Settings › Core › Theme, for iTerm2's own code: the one place that applies the saved choice —
//  the theme Shellforge draws in, the appearance the app is held to, and, through the theme's
//  change notice, the matched terminal's colours. It follows the saved choice and the Mac.
//

import AppKit
import ShellforgeDesign
import ShellforgeUI

@objc(iTermShellforgeThemes)
@MainActor
final class iTermShellforgeThemes: NSObject {
    /// The app's one choice, in iTerm2's defaults domain so a `-suite` run keeps its own. A Save
    /// that changes it applies it at once.
    static let settings: ThemeSettings = {
        let settings = ThemeSettings(defaults: iTermUserDefaults.userDefaults())
        settings.onChange = { apply() }
        return settings
    }()

    /// Follows the app's appearance while Shellforge runs, so a Mac turning dark brings the dark
    /// slot's theme.
    private static var appearanceObservation: NSKeyValueObservation?
    /// Whether the theme was last applied for a dark appearance, so an appearance set again
    /// without a change between light and dark does nothing.
    private static var appliedDark: Bool?
    /// Set while `apply` runs: setting the app's appearance there changes its effective appearance,
    /// which must not apply it again.
    private static var applying = false
    /// Whether the app's appearance is the one a single theme holds it to.
    private static var holdsAppearance = false

    /// At launch: applies the saved choice, then follows the app's appearance.
    @objc static func start() {
        guard appearanceObservation == nil else { return }
        apply()
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { app, _ in
            MainActor.assumeIsolated { appearanceChanged(isDark: app.effectiveAppearance.it_isDark) }
        }
    }

    /// The appearance a single light or dark theme holds the app to, or nil when the Mac decides —
    /// following the Mac, or the adaptive Shellforge theme. `-[iTermApplication updateAppearance]`
    /// asks first, so iTerm2's own appearance changes keep it.
    @objc static var forcedAppearance: NSAppearance? {
        switch settings.choice.forcedAppearance() {
        case .dark: NSAppearance(named: .darkAqua)
        case .light: NSAppearance(named: .aqua)
        case .adaptive, nil: nil
        }
    }

    /// The app's appearance turned light or dark: the theme for it, when that is a change.
    static func appearanceChanged(isDark: Bool) {
        guard !applying, isDark != appliedDark else { return }
        apply(isDark: isDark)
    }

    /// Holds the app to the choice's appearance — or, when it held one, gives it back to iTerm2,
    /// which leaves it to the Mac under the Minimal theme — then sets the theme for the appearance that results:
    /// `isDark` when given, the app's otherwise. A changed theme posts `ThemeRuntime.didChange`,
    /// on which every themed view redraws and a matched terminal recolours.
    static func apply(isDark: Bool? = nil) {
        applying = true
        defer { applying = false }
        if let forced = forcedAppearance {
            if NSApp.appearance?.name != forced.name { NSApp.appearance = forced }
            holdsAppearance = true
        } else if holdsAppearance {
            // Only what the theme held is given back; an appearance flip leaves the app's alone.
            holdsAppearance = false
            if let app = NSApp as? iTermApplication { app.updateAppearance() } else { NSApp.appearance = nil }
        }
        let dark = isDark ?? NSApp.effectiveAppearance.it_isDark
        appliedDark = dark
        let theme = settings.choice.active(isDark: dark)
        DLog("Shellforge: theme \(theme.id) for a \(dark ? "dark" : "light") appearance")
        ThemeRuntime.set(theme)
    }

    // MARK: - For host tests, which cannot import ShellforgeUI

    /// Saves a choice and applies it at once.
    static func save(followsMac: Bool, light: String = "shellforge", dark: String = "shellforge", single: String = "shellforge") {
        settings.save(ThemeChoice(followsMac: followsMac, light: light, dark: dark, single: single))
    }

    /// The saved choice, as `save` takes it.
    static var savedChoice: (followsMac: Bool, light: String, dark: String, single: String) {
        let choice = settings.choice
        return (choice.followsMac, choice.light, choice.dark, choice.single)
    }

    /// The id of the theme Shellforge draws in.
    static var currentThemeID: String { ThemeRuntime.current.id }
}
