// Ported from AiTerm (app/Tests/AiTermUITests/ControlChromeTests.swift), GPLv3, Laurens D'Hondt.
import AppKit
import SwiftUI
import Testing
@testable import ShellforgeDesign

@MainActor
struct ControlChromeTests {
    /// A highlighted dropdown row is drawn on the accent, so it declares the accent: a badge or an
    /// icon inside it then inks white without the row passing a flag down.
    @Test func aHighlightedMenuRowDeclaresTheAccent() {
        #expect(Self.surface(inside: { $0.menuRowHighlight(true) }) == .accent)
        #expect(Self.surface(inside: { $0.menuRowHighlight(false, pressed: true) }) == .accent)
        #expect(Self.surface(inside: { $0.menuRowHighlight(false) }) == .sheet)
    }

    private static func surface(inside wrap: (EnvironmentReader) -> some View) -> Surface? {
        let log = EnvironmentLog()
        let host = NSHostingView(rootView: wrap(EnvironmentReader(log: log)).surface(.sidebar))
        host.frame = NSRect(x: 0, y: 0, width: 40, height: 20)
        host.layoutSubtreeIfNeeded()
        return log.surface[0]
    }
}
