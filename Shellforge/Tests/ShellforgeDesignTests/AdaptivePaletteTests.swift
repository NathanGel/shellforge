import AppKit
import SwiftUI
import Testing
@testable import ShellforgeDesign

/// The colours that only worked on AiTerm's dark sidebar now read in light too; their dark values
/// are what they always were.
@MainActor @Suite struct AdaptivePaletteTests {
    @Test(arguments: ["rowHover", "badgeHovered", "codeBackground", "rowHoverSolid"])
    func theColourDiffersInLightAndDark(name: String) {
        let color = Self.colors[name] ?? .clear
        #expect(ColorProbe.rgba(color, in: .aqua) != ColorProbe.rgba(color, in: .darkAqua), "\(name)")
    }

    private static let colors: [String: Color] = [
        "rowHover": Palette.rowHover, "badgeHovered": Palette.badgeHovered,
        "codeBackground": Palette.codeBackground, "rowHoverSolid": Palette.rowHoverSolid,
    ]

    @Test func darkIsUnchanged() {
        #expect(ColorProbe.hex(Palette.codeBackground) == "#141519")
        #expect(ColorProbe.rgba(Palette.rowHover) == "rgba(255, 255, 255, 0.060)")
        #expect(ColorProbe.rgba(Palette.badgeHovered) == "rgba(255, 255, 255, 0.140)")
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func aHoveredRowIsNotTheSidebar(appearance: NSAppearance.Name) {
        #expect(ColorProbe.hex(Palette.rowHoverSolid, in: appearance) != ColorProbe.hex(Palette.sidebar, in: appearance))
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func theCodeBlockStandsOffTheSheet(appearance: NSAppearance.Name) {
        #expect(ColorProbe.hex(Palette.codeBackground, in: appearance) != ColorProbe.hex(Palette.surface, in: appearance))
    }

    @Test func aSelectedRowIsWhiteOnTheAccentInLight() {
        #expect(ColorProbe.hex(Surface.accent.ink, in: .aqua) == "#FFFFFF")
    }

    @Test func aTintIsResolvedPerAppearance() {
        let dark = Icon.hexString(Palette.text, dark: true)
        let light = Icon.hexString(Palette.text, dark: false)
        #expect(dark != light)
        #expect(Icon.hexString(Palette.text, dark: true) == dark, "remembered per appearance")
    }

    /// Review fix: GitHub's white mark vanished on a light sheet. Its brand follows the appearance.
    @Test func theGitHubMarkFollowsTheAppearance() {
        #expect(ColorProbe.hex(Palette.github.color, in: .aqua) != "#FFFFFF")
        #expect(Icon.fill(for: Palette.github, tint: nil, dark: false) == Icon.hexString(Palette.text, dark: false))
        #expect(Icon.fill(for: Palette.github, tint: nil, dark: true) == Icon.hexString(Palette.text, dark: true))
    }

    @Test func otherBrandsKeepTheirColour() {
        #expect(Icon.fill(for: Palette.gitlab, tint: nil, dark: false) == Palette.gitlab.hex)
        #expect(Icon.fill(for: Palette.gitlab, tint: Palette.text, dark: false) == Icon.hexString(Palette.text, dark: false))
    }
}
