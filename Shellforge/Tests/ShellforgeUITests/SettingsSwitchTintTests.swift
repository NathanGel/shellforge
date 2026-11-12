import AppKit
import SwiftUI
import Testing
@testable import ShellforgeDesign
@testable import ShellforgeTestSupport
@testable import ShellforgeUI

/// A Settings switch that is on fills with the theme's accent, not the Mac's.
@MainActor @Suite struct SettingsSwitchTintTests {
    /// Dracula with its accent replaced, so two runs differ only in the accent.
    private func dracula(accent: SRGB) throws -> Theme {
        let base = ThemeCatalog.theme(id: "dracula")
        var colors = try #require(base.colors)
        colors.accent = accent
        return Theme(id: "dracula-test", name: "Dracula test", appearance: .dark, colors: colors, terminal: base.terminal)
    }

    /// The hue, in degrees, of the most saturated pixel a switch that is on draws under `theme`.
    /// AppKit shades the track, so its colour is not the accent's exactly; its hue is.
    private func trackHue(under theme: Theme) throws -> Double {
        try ThemeRuntime.$override.withValue(theme) {
            let host = NSHostingView(rootView: SettingsSwitch(title: "Example", isOn: .constant(true)).padding(4))
            host.appearance = NSAppearance(named: .darkAqua)
            host.frame = NSRect(x: 0, y: 0, width: 60, height: 30)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(Snapshot.bitmap(of: host))
            var best: (saturation: CGFloat, hue: CGFloat) = (0, 0)
            for x in 0..<bitmap.pixelsWide {
                for y in 0..<bitmap.pixelsHigh {
                    guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), pixel.alphaComponent > 0.9 else { continue }
                    if pixel.saturationComponent > best.saturation { best = (pixel.saturationComponent, pixel.hueComponent) }
                }
            }
            #expect(best.saturation > 0.2, "the track is coloured")
            return Double(best.hue) * 360
        }
    }

    private func hue(of color: SRGB) -> Double {
        Double(NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1).hueComponent) * 360
    }

    /// Two accents far apart on the colour wheel, so at most one could be the Mac's own.
    @Test func anOnSwitchTakesTheThemesAccent() throws {
        for accent in [SRGB(red: 0.74, green: 0.58, blue: 0.98), SRGB(red: 0.2, green: 0.75, blue: 0.2)] {
            let drawn = try trackHue(under: dracula(accent: accent))
            let wanted = hue(of: accent)
            let apart = min(abs(drawn - wanted), 360 - abs(drawn - wanted))
            #expect(apart < 20, "drawn hue \(drawn)°, the accent's \(wanted)°")
        }
    }
}
