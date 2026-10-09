// Ported from AiTerm (app/Tests/AiTermUITests/HelpTextTests.swift), GPLv3, Laurens D'Hondt.
import AppKit
import SwiftUI
import Testing
@testable import ShellforgeDesign

@MainActor
struct HelpTextTests {
    /// A warning has to reach the screen amber. `HelpText` inks its own text, so a caller's
    /// `.foregroundStyle(Palette.amber)` outside it lost to the `Palette.muted` inside and three
    /// sheets drew their warnings grey.
    @Test func aWarningIsDrawnAmber() throws {
        let ink = try #require(brightestPixel(of: HelpText("Jira could not be reached", tone: .warning)))
        #expect(ink.redComponent > ink.blueComponent + 0.3, "a warning drew \(ink), not amber")
    }

    @Test func secondaryCopyIsDrawnGrey() throws {
        let ink = try #require(brightestPixel(of: HelpText("Select a ticket to fill in the name")))
        #expect(abs(ink.redComponent - ink.blueComponent) < 0.05, "help copy drew \(ink), not grey")
    }
}
