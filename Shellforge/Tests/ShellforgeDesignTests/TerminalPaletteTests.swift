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

    @Test func theBackgroundIsTheSidebarsSurface() throws {
        var surface = SRGB(red: 0, green: 0, blue: 0)
        try #require(dark).performAsCurrentDrawingAppearance {
            surface = SRGB(TerminalSource.surface, over: SRGB(red: 0, green: 0, blue: 0))
        }
        #expect(ShellforgeTerminalPalette.colors(in: dark)[.background] == surface)
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
}
