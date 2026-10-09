// Ported from AiTerm (app/Tests/AiTermUITests/KbdTests.swift), GPLv3, Laurens D'Hondt.
import AppKit
import SwiftUI
import Testing
@testable import ShellforgeDesign

@MainActor
@Suite(.serialized) struct KbdTests {
    @Test func moreKeysDrawAWiderControl() {
        let one = NSHostingView(rootView: Kbd("⌘"))
        let two = NSHostingView(rootView: Kbd("⌘", "↩"))
        for host in [one, two] as [NSView] {
            host.frame = NSRect(x: 0, y: 0, width: 200, height: 40)
        }
        let windows = [one, two].map { window(hosting: $0) }
        defer { windows.forEach { $0.orderOut(nil) } }
        settle(one)
        settle(two)

        // Proves the variadic actually reaches `body`: two keys draw two caps, one key draws one,
        // so the two-key control must measure wider than the one-key control.
        #expect(two.fittingSize.width > one.fittingSize.width)
    }

    @Test func theCapsAreActuallyDrawn() throws {
        let kbd = NSHostingView(rootView: Kbd("⌘"))
        let blank = NSHostingView(rootView: Color.clear)
        for host in [kbd, blank] as [NSView] {
            host.frame = NSRect(x: 0, y: 0, width: 40, height: 24)
        }
        let windows = [kbd, blank].map { window(hosting: $0) }
        defer { windows.forEach { $0.orderOut(nil) } }
        settle(kbd)
        settle(blank)

        // Catches a `cap(_:)` broken to the point of drawing nothing: a rendered `Kbd` must differ
        // from an empty view of the same size, proving non-uniform pixel output was produced.
        #expect(try pixels(in: kbd) != pixels(in: blank))
    }

    /// Off the accent the caps take the surface's badge wash, the hairline and its ink; on it, the
    /// keycap washes and white. Each token is checked, so neither ground borrows the other's.
    @Test func theCapsInkForTheSurfaceTheySitOn() {
        #expect(Kbd.ink(.sheet) == Palette.text)
        #expect(Kbd.fill(.sheet) == Palette.badge)
        #expect(Kbd.stroke(.sheet) == Palette.border)
        #expect(Kbd.ink(.accent) == Palette.onAccent)
        #expect(Kbd.fill(.accent) == Palette.keycapFill)
        #expect(Kbd.stroke(.accent) == Palette.keycapStroke)
    }

    @Test func theAccentIsDrawnDifferently() throws {
        let accent = NSHostingView(rootView: Kbd("⌘").surface(.accent))
        let quiet = NSHostingView(rootView: Kbd("⌘"))
        for host in [accent, quiet] as [NSView] {
            host.frame = NSRect(x: 0, y: 0, width: 40, height: 24)
        }
        let windows = [accent, quiet].map { window(hosting: $0) }
        defer { windows.forEach { $0.orderOut(nil) } }
        settle(accent)
        settle(quiet)

        #expect(try pixels(in: quiet) != pixels(in: accent))
    }
}
