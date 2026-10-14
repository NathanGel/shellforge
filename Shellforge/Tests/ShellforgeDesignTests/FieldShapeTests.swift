import AppKit
import SwiftUI
import Testing
@testable import ShellforgeDesign
import ShellforgeTestSupport

/// macOS 26's text fields: rounder, continuous corners; white in light, lighter than the sheet in dark.
@MainActor @Suite struct FieldShapeTests {
    @Test func aFieldHasTheGroupCorner() {
        #expect(FieldShape.cornerRadius == Radius.group)
    }

    @Test func aLightFieldIsWhite() {
        #expect(ColorProbe.hex(Palette.fieldFill, in: .aqua) == "#FFFFFF")
    }

    /// A dark field sits lighter than the sheet under it, as a native bezeled field does — never
    /// a dark well below it, which is what the system text background draws.
    @Test func aDarkFieldIsLighterThanItsSheet() throws {
        let host = NSHostingView(rootView: Palette.surface.overlay(Palette.fieldFill).frame(width: 20, height: 20))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame.size = host.fittingSize
        let field = try #require(Snapshot.bitmap(of: host)?.colorAt(x: 20, y: 20)?.usingColorSpace(.sRGB))
        let sheet = try #require(NSColor.windowBackgroundColor.resolved(in: .darkAqua))
        #expect(field.brightnessComponent > sheet.brightnessComponent + 0.03, "field \(field), sheet \(sheet)")
    }
}

private extension NSColor {
    func resolved(in name: NSAppearance.Name) -> NSColor? {
        var color: NSColor?
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance { color = usingColorSpace(.sRGB) }
        return color
    }
}
