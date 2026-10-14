// Ported from AiTerm (app/Sources/AiTermUI/IconSource.swift), GPLv3, Laurens D'Hondt.
import SwiftUI
import AppKit

/// One way to name any mark AiTerm draws, so a component that shows an icon does not care which
/// kind it is. `Icon` and `Badge` both take one of these.
public enum IconSource: Sendable, Equatable {
    /// An SF Symbol, by name.
    case symbol(String)
    /// A single-colour vendor mark, in its brand colour unless tinted. Adding a vendor is one
    /// `Brand`, usable everywhere.
    case brand(Brand)
    /// A full-colour SVG document, drawn as it is: it has no one colour a tint could replace, so a
    /// tint reaches only `fallback` — what is drawn instead if the document will not decode.
    indirect case artwork(svg: String, fallback: IconSource)
}

public extension IconSource {
    /// GitLab's four-colour tanuki, drawn for a light ground; the single-colour mark if it will not
    /// decode.
    static let gitlabTanuki = IconSource.artwork(svg: Logos.gitlabFourColourSVG, fallback: .brand(Palette.gitlab))
    /// Pi's white badge, drawn for `VendorMark`'s black disc.
    static let piBadge = IconSource.artwork(svg: Logos.piBadgeSVG, fallback: .symbol("square.grid.2x2.fill"))
}

/// Draws an `IconSource` at a size, optionally overriding its ink. A brand or an artwork fills a
/// `size` × `size` box; a symbol keeps its glyph's own width at that point size, which is what the
/// Settings check chips are measured by.
///
/// A brand keeps its vendor colour unless `tint` overrides it — which is what a selected row does,
/// where a brand colour on the accent would read as a mistake. A symbol with no tint takes the ink
/// of the surface it sits on, so it turns white on the accent by itself.
public struct Icon: View {
    private let source: IconSource
    private let size: CGFloat
    private let tint: Color?
    @Environment(\.surface) private var surface
    @Environment(\.colorScheme) private var colorScheme

    public init(_ source: IconSource, size: CGFloat, tint: Color? = nil) {
        self.source = source
        self.size = size
        self.tint = tint
    }

    public var body: some View {
        switch source {
        case let .symbol(name):
            Image(systemName: name)
                .font(.system(size: size))
                .foregroundStyle(tint ?? surface.ink)
        case let .brand(brand):
            LogoGlyph(brand: brand, fill: Self.fill(for: brand, tint: tint, dark: colorScheme == .dark), size: size)
        case let .artwork(svg, fallback):
            if let image = Logos.image(svg: svg) {
                Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
                    .accessibilityHidden(true)
            } else {
                Icon(fallback, size: size, tint: tint)
            }
        }
    }

    /// `LogoGlyph` builds an SVG document, so it needs the fill as text rather than a `Color`.
    ///
    /// Resolved in the appearance the icon draws in, light or dark, which `Icon` reads from its
    /// colour scheme.
    ///
    /// `ColorProbe` (the design tests) resolves colours the same way, for tests rather than for an
    /// SVG fill. The two are kept separate deliberately (production vs. test-only), but they
    /// duplicate this appearance/sRGB dance — if one changes, check the other.
    ///
    /// Remembered per colour and appearance: a body asks again each time it runs, and the resolve
    /// costs an appearance switch and a string format, for the handful of tints there are.
    /// A brand mark's SVG fill: the tint when there is one, else the text colour for a brand that
    /// follows the appearance (GitHub), else the brand's own colour.
    @MainActor
    static func fill(for brand: Brand, tint: Color?, dark: Bool) -> String {
        if let tint { return hexString(tint, dark: dark) }
        return brand.followsAppearance ? hexString(brand.color, dark: dark) : brand.hex
    }

    @MainActor
    static func hexString(_ color: Color, dark: Bool) -> String {
        let key = HexKey(color: color, dark: dark)
        if let known = hexes[key] { return known }
        var hex = "#000000"
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
        appearance.performAsCurrentDrawingAppearance {
            guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            hex = String(format: "#%02X%02X%02X",
                         Int((srgb.redComponent * 255).rounded()),
                         Int((srgb.greenComponent * 255).rounded()),
                         Int((srgb.blueComponent * 255).rounded()))
        }
        hexes[key] = hex
        return hex
    }

    private struct HexKey: Hashable {
        let color: Color
        let dark: Bool
    }

    @MainActor private static var hexes: [HexKey: String] = [:]
}
