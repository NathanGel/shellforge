// Ported from AiTerm (app/Sources/AiTermUI/Kbd.swift), GPLv3, Laurens D'Hondt.
import SwiftUI

/// Keycaps for a shortcut: restated on a primary button's label, or listed in Settings.
///
/// Pass the glyphs macOS menus use: `⌘`, `↩` (U+21A9, not U+23CE — which reads heavier at this
/// size), `⎋`, `⇧`. The caps ink for the ground they sit on, read from `@Environment(\.surface)`:
/// on the accent — a primary button's label declares `.surface(.accent)` — `Palette.onAccent` on
/// the keycap washes, which only hold against the accent; anywhere else the surface's ink on its
/// badge wash, edged in the hairline, as the Keyboard settings list has them.
public struct Kbd: View {
    /// The glyphs, in the order they are drawn.
    private let keys: [String]
    @Environment(\.surface) private var surface

    /// The gap between two caps. Narrower than `Space.tight`: the caps are a single token read as
    /// one shortcut, not two controls beside each other.
    private static let capGap: CGFloat = 3

    public init(_ keys: String...) { self.init(keys) }
    public init(_ keys: [String]) { self.keys = keys }

    public var body: some View {
        HStack(spacing: Self.capGap) {
            ForEach(Array(keys.enumerated()), id: \.offset) { cap($0.element) }
        }
        // A restatement of a key equivalent, not a control: read out, it would turn every press of
        // the button into "Create Task command return".
        .accessibilityHidden(true)
    }

    static func ink(_ surface: Surface) -> Color { surface.ink }
    static func fill(_ surface: Surface) -> Color { surface.isOnAccent ? Palette.keycapFill : surface.badgeWash }
    static func stroke(_ surface: Surface) -> Color { surface.isOnAccent ? Palette.keycapStroke : Palette.border }

    private func cap(_ glyph: String) -> some View {
        Text(glyph)
            .font(Typography.mono)
            .foregroundStyle(Self.ink(surface))
            .frame(minWidth: Size.chip)
            .frame(height: Size.chip)
            .background(RoundedRectangle(cornerRadius: Radius.chip).fill(Self.fill(surface)))
            .overlay(RoundedRectangle(cornerRadius: Radius.chip).strokeBorder(Self.stroke(surface), lineWidth: 1))
    }
}
