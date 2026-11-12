//
//  iTermShellforgeTabLook.swift
//  Shellforge
//
//  VS Code’s tab look, for iTerm2’s own code: the Minimal tab style whatever iTerm2 theme is
//  saved, a 2-pt accent edge along the top of the active tab, and the tab strip in the theme’s
//  colours. `PSMMinimalTabStyle` asks here as it draws; a nil colour means Minimal’s own, which it
//  reads from the terminal’s background — the Shellforge theme without Match Terminal.
//

import AppKit
import ShellforgeDesign
import SwiftUI

@objc(iTermShellforgeTabLook)
final class iTermShellforgeTabLook: NSObject {
    /// Whether iTerm2’s theme reads as Minimal, whatever is saved: always. App-wide, not per
    /// window: `computedTabStyle` is one setting for every window, and every terminal window carries
    /// the sidebar. Asked from `computedTabStyle` on any thread.
    @objc static var overridesTheme: Bool { true }

    /// How deep the active tab’s accent edge is, in points.
    @objc static let edgeWidth: CGFloat = 2

    /// The active tab’s edge: the theme’s accent — the system accent under Shellforge.
    @MainActor @objc static var activeEdgeColor: NSColor { resolved(Palette.accent) }

    /// The strip behind the tabs, which Minimal also reads its ink and lines from: the theme’s
    /// sidebar colour — Shellforge’s own while Match Terminal is on.
    @MainActor @objc static var stripColor: NSColor? { coloursTheStrip ? resolved(Palette.chrome) : nil }

    /// The active tab: the theme’s background, as VS Code’s active tab is the editor’s.
    @MainActor @objc static var activeTabColor: NSColor? { coloursTheStrip ? resolved(Palette.surface) : nil }

    /// The other tabs: the strip’s colour under a theme. Nil under Shellforge, whose background and
    /// sidebar are one colour, so Minimal steps them off the strip as it always has.
    @MainActor @objc static var inactiveTabColor: NSColor? {
        ThemeRuntime.current.colors != nil ? resolved(Palette.chrome) : nil
    }

    /// Whether the strip takes Shellforge’s colours rather than Minimal’s: under any theme but
    /// Shellforge, and under Shellforge while Match Terminal lays its colours over the terminal.
    @MainActor private static var coloursTheStrip: Bool {
        ThemeRuntime.current.colors != nil || iTermShellforgeTerminalMatch.isOn
    }

    /// `color` as a fixed sRGB colour in the app’s appearance, which the matched terminal is
    /// coloured in: Minimal does arithmetic on the components, which a dynamic colour has not got.
    @MainActor private static func resolved(_ color: Color) -> NSColor {
        let dynamic = NSColor(color)
        var result = dynamic
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            result = dynamic.usingColorSpace(.sRGB) ?? dynamic
        }
        return result
    }

    /// Follows `ThemeRuntime.didChange`, once made by `start`.
    @MainActor private static var themeObserver: NSObjectProtocol?

    /// At launch: every tab strip redraws when the theme changes.
    @MainActor @objc static func start() {
        guard themeObserver == nil else { return }
        // Posted on the main thread, so no queue.
        themeObserver = NotificationCenter.default.addObserver(forName: ThemeRuntime.didChange, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { themeDidChange() }
        }
    }

    /// As Match Terminal’s recolour does, which already does this while it is on: each window takes
    /// its tab style again and redraws, and iTerm2’s other theme listeners hear a theme change. The
    /// setting itself is not written.
    @MainActor private static func themeDidChange() {
        guard !iTermShellforgeTerminalMatch.isOn else { return }
        DLog("Shellforge: theme changed; redrawing the tab strips")
        NotificationCenter.default.post(name: .refreshTerminal, object: nil)
        iTermPreferenceDidChangeNotification(key: kPreferenceKeyTabStyle,
                                             value: iTermPreferences.object(forKey: kPreferenceKeyTabStyle)).post()
    }
}
