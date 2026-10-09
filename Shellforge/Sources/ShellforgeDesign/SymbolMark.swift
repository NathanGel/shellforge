// Ported from AiTerm (app/Sources/AiTermUI/SymbolMark.swift), GPLv3, Laurens D'Hondt.
import SwiftUI

/// A round mark for something that is not a vendor: an SF Symbol on a neutral
/// `Palette.controlActive` disc (`.quiet` style, in `IntegrationMark`'s family), or `Palette.markInk`
/// on `Palette.markPaper` (`.paper` style, the vendor discs' recipe). The Mac card in Settings › Integrations
/// draws it at `Size.control`; the sidebar footer's Mac readings row draws it at `Size.vendorMark`. `size` is
/// points on screen: the caller scales the token it passes.
public struct SymbolMark: View {
    let symbol: String
    let size: CGFloat
    let tint: Color

    /// The disc's recipe. `.quiet` is `IntegrationMark`'s family for things AiTerm does itself, on
    /// `Palette.controlActive`; `.paper` is the vendor discs': `Palette.markInk` on `Palette.markPaper`,
    /// so a mark beside Claude's and Codex's in a column reads as one of them.
    public enum Style: Sendable { case quiet, paper }

    let style: Style

    /// The glyph's optical size inside the disc. A symbol's ink box is not a logo's, so `LogoFit`
    /// does not apply, and no `Size` step fits.
    private static let glyphRatio: CGFloat = 0.5

    public init(symbol: String, size: CGFloat, tint: Color = Palette.text, style: Style = .quiet) {
        self.symbol = symbol
        self.size = size
        self.tint = tint
        self.style = style
    }

    public var body: some View {
        ZStack {
            Circle().fill(style == .paper ? Palette.markPaper : Palette.controlActive)
            Icon(.symbol(symbol), size: size * Self.glyphRatio, tint: style == .paper ? Palette.markInk : tint)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
