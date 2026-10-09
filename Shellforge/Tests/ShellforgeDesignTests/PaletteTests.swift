// Ported from AiTerm (app/Tests/AiTermUITests/PaletteTests.swift), GPLv3, Laurens D'Hondt.
import AppKit
import SwiftUI
import Testing
import ShellforgeDesign

@MainActor
struct PaletteTests {
    @Test(arguments: [NSAppearance.Name.darkAqua, .accessibilityHighContrastDarkAqua])
    func secondarySelectionsAreNeutralGray(appearanceName: NSAppearance.Name) throws {
        let appearance = try #require(NSAppearance(named: appearanceName))
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(Palette.controlActive).usingColorSpace(.sRGB)
        }
        let color = try #require(resolved)

        #expect(abs(color.redComponent - color.greenComponent) < 0.02)
        #expect(abs(color.greenComponent - color.blueComponent) < 0.02)
    }

    /// `badge` is written as 8 %, but of `.primary`, which carries the label ink's own alpha: what it
    /// draws is 8 % of that ink. This pins what the wash is, so no one "corrects" the literal and
    /// silently brightens every badge.
    @Test func theBadgeWashIsEightPercentOfTheLabelInk() {
        #expect(abs(ColorProbe.alpha(Palette.badge) - 0.08 * ColorProbe.alpha(Palette.text)) < 0.002)
    }
}
