import AppKit
import Testing
@testable import ShellforgeDesign

/// Shellforge's terminal colours: 23 keys from the sidebar's own macOS colours, each readable on
/// the sidebar's surface.
@Suite struct TerminalPaletteTests {
    private let dark = NSAppearance(named: .darkAqua)

    @Test func everyRoleHasAColour() {
        let colors = ShellforgeTerminalPalette.colors(in: dark)
        #expect(TerminalColorRole.all.count == 23)
        #expect(Set(colors.keys) == Set(TerminalColorRole.all))
    }

    @Test func theBackgroundIsAStepDarkerThanTheSidebar() throws {
        var surface = SRGB(red: 0, green: 0, blue: 0)
        try #require(dark).performAsCurrentDrawingAppearance {
            surface = SRGB(TerminalSource.surface, over: SRGB(red: 0, green: 0, blue: 0))
        }
        let background = try #require(ShellforgeTerminalPalette.colors(in: dark)[.background])
        #expect(background == surface.darkened(by: ShellforgeTerminalPalette.backgroundStep))
        #expect(background != surface, "the terminal reads apart from the sidebar")
        #expect(background.contrast(with: surface) < 1.2, "a step, not a different colour")
    }

    @Test func darkenedMixesInBlack() {
        let grey = SRGB(red: 0.5, green: 0.4, blue: 0.2)
        #expect(grey.darkened(by: 0.5) == SRGB(red: 0.25, green: 0.2, blue: 0.1))
        #expect(grey.darkened(by: 0) == grey)
    }

    @Test func theCursorTextIsTheBackground() {
        let colors = ShellforgeTerminalPalette.colors(in: dark)
        #expect(colors[.cursorText] == colors[.background])
    }

    @Test func everyTextColourIsReadableOnTheBackground() throws {
        let colors = ShellforgeTerminalPalette.colors(in: dark)
        let background = try #require(colors[.background])
        for role in TerminalColorRole.all where role.needsContrast {
            let color = try #require(colors[role])
            #expect(color.contrast(with: background) >= ShellforgeTerminalPalette.minimumContrast, "\(role)")
        }
    }

    @Test func blackAndBrightBlackAreExempt() {
        #expect(!TerminalColorRole.ansi(0).needsContrast)
        #expect(!TerminalColorRole.ansi(8).needsContrast)
        #expect(TerminalColorRole.ansi(1).needsContrast)
        #expect(TerminalColorRole.foreground.needsContrast)
    }

    @Test func aReadableColourIsLeftAlone() {
        let background = SRGB(red: 0.12, green: 0.12, blue: 0.12)
        let white = SRGB(red: 1, green: 1, blue: 1)
        #expect(ShellforgeTerminalPalette.readable(white, on: background) == white)
    }

    @Test func aDarkColourIsLightenedOnlyUntilItPasses() {
        let background = SRGB(red: 0.12, green: 0.12, blue: 0.12)
        let dim = SRGB(red: 0.25, green: 0.1, blue: 0.1)
        let readable = ShellforgeTerminalPalette.readable(dim, on: background)
        #expect(readable.contrast(with: background) >= ShellforgeTerminalPalette.minimumContrast)
        // One step back fails: it stopped at the first passing value, short of white.
        let stepBack = SRGB(red: (readable.red - 0.05) / 0.95, green: (readable.green - 0.05) / 0.95, blue: (readable.blue - 0.05) / 0.95)
        #expect(stepBack.contrast(with: background) < ShellforgeTerminalPalette.minimumContrast)
    }

    @Test func contrastIsTheWCAGRatio() {
        let black = SRGB(red: 0, green: 0, blue: 0), white = SRGB(red: 1, green: 1, blue: 1)
        #expect(abs(white.contrast(with: black) - 21) < 0.01)
        #expect(abs(black.contrast(with: black) - 1) < 0.0001)
    }

    private let light = NSAppearance(named: .aqua)

    @Test func theLightBackgroundIsAStepLighterThanTheLightSidebar() throws {
        var surface = SRGB(red: 0, green: 0, blue: 0)
        try #require(light).performAsCurrentDrawingAppearance {
            surface = SRGB(TerminalSource.surface, over: SRGB(red: 0, green: 0, blue: 0))
        }
        let background = try #require(ShellforgeTerminalPalette.colors(in: light)[.background])
        #expect(background == ShellforgeTerminalPalette.background(beside: surface))
        #expect(background != surface, "the terminal reads apart from the light sidebar")
    }

    /// Review fix: on macOS 26 the light sidebar is pure white, which lightening cannot move.
    @Test func aWhiteSidebarStillGetsAStep() {
        let white = SRGB(red: 1, green: 1, blue: 1)
        let background = ShellforgeTerminalPalette.background(beside: white)
        #expect(background != white)
        #expect(background.contrast(with: white) < 1.2, "a step, not a different colour")
    }

    @Test func aLightGreySidebarGetsALighterTerminal() {
        let grey = SRGB(red: 0.92, green: 0.92, blue: 0.92)
        #expect(ShellforgeTerminalPalette.background(beside: grey) == grey.lightened(by: ShellforgeTerminalPalette.backgroundStep))
    }

    @Test func everyTextColourIsReadableOnTheLightBackground() throws {
        let colors = ShellforgeTerminalPalette.colors(in: light)
        let background = try #require(colors[.background])
        for role in TerminalColorRole.all where role.needsContrast {
            let color = try #require(colors[role])
            #expect(color.contrast(with: background) >= ShellforgeTerminalPalette.minimumContrast, "\(role)")
        }
    }

    @Test func aLightColourIsDarkenedOnALightBackground() {
        let background = SRGB(red: 0.97, green: 0.97, blue: 0.97)
        let pale = SRGB(red: 0.9, green: 0.75, blue: 0.75)
        let readable = ShellforgeTerminalPalette.readable(pale, on: background)
        #expect(readable.contrast(with: background) >= ShellforgeTerminalPalette.minimumContrast)
        #expect(readable.red < pale.red, "darkened, not lightened")
    }
}
