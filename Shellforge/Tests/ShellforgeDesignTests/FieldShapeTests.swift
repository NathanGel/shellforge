import AppKit
import SwiftUI
import Testing
@testable import ShellforgeDesign

/// macOS 26's text fields: rounder, continuous corners on the system text background.
@MainActor @Suite struct FieldShapeTests {
    @Test func aFieldHasTheGroupCorner() {
        #expect(FieldShape.cornerRadius == Radius.group)
    }

    @Test func theFieldFillIsTheSystemTextBackground() {
        #expect(ColorProbe.hex(Palette.fieldFill, in: .aqua) != ColorProbe.hex(Palette.fieldFill, in: .darkAqua))
        #expect(ColorProbe.hex(Palette.fieldFill, in: .aqua) == "#FFFFFF")
    }
}
