// Ported from AiTerm (app/Tests/AiTermUITests/ColorProbe.swift), GPLv3, Laurens D'Hondt.
import SwiftUI
import AppKit

/// Resolves a `Color` to plain values so a test can compare colours by their rendered result
/// rather than by identity. Every colour is resolved under a named appearance, `.darkAqua` unless a
/// test asks for another, so a test's outcome never depends on the machine's setting.
///
/// Test-only: this is not part of the design system's public surface, only a way for
/// `SurfaceTests` and `PaletteDistinctionTests` to ask "what colour does this actually resolve to."
///
/// `app/Sources/AiTermUI/IconSource.swift`'s `Icon.hexString(_:dark:)` resolves colours the same
/// way, for a tinted mark's SVG fill rather than for a test assertion. The two are kept separate
/// deliberately (test-only vs. production), but they duplicate this exact `.darkAqua`/sRGB dance —
/// if one changes, check the other.
@MainActor
enum ColorProbe {
    static func hex(_ color: Color, in name: NSAppearance.Name = .darkAqua) -> String {
        var hex = "#000000"
        let appearance = NSAppearance(named: name) ?? NSAppearance.currentDrawing()
        appearance.performAsCurrentDrawingAppearance {
            guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            hex = String(format: "#%02X%02X%02X",
                         Int((srgb.redComponent * 255).rounded()),
                         Int((srgb.greenComponent * 255).rounded()),
                         Int((srgb.blueComponent * 255).rounded()))
        }
        return hex
    }

    /// Alpha matters for the washes (`badge`, `row-hover`, `spinner-track`), which are drawn over
    /// another colour rather than replacing it.
    static func rgba(_ color: Color, in name: NSAppearance.Name = .darkAqua) -> String {
        var out = "rgba(0, 0, 0, 1)"
        let appearance = NSAppearance(named: name) ?? NSAppearance.currentDrawing()
        appearance.performAsCurrentDrawingAppearance {
            guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            out = String(format: "rgba(%d, %d, %d, %.3f)",
                         Int((srgb.redComponent * 255).rounded()),
                         Int((srgb.greenComponent * 255).rounded()),
                         Int((srgb.blueComponent * 255).rounded()),
                         srgb.alphaComponent)
        }
        return out
    }

    static func alpha(_ color: Color) -> Double {
        var a = 1.0
        let appearance = NSAppearance(named: .darkAqua) ?? NSAppearance.currentDrawing()
        appearance.performAsCurrentDrawingAppearance {
            a = Double(NSColor(color).usingColorSpace(.sRGB)?.alphaComponent ?? 1)
        }
        return a
    }
}
