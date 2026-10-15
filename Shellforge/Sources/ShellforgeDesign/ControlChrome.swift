// Ported from AiTerm (app/Sources/AiTermUI/ControlChrome.swift), GPLv3, Laurens D'Hondt.
import SwiftUI

// The house chrome every control in the app is dressed in: the focus ring, the field box, the
// group box, a dropdown row's highlight, and the one elevation anything hanging off a field is given.

/// The focus ring's own stroke width and outset — belongs to `focusRing` alone, and to nothing
/// `Metrics` names: at 3 pt the ring used to bleed a point *inside* the control it sits outside, so
/// the stroke and the outset have to stay equal, not merely both "small."
private let focusRingWidth: CGFloat = 2

public extension View {
    /// The house focus ring, drawn *outside* the control's own edge. One modifier, so a control that
    /// gains keyboard focus does not have to reinvent it — it used to exist only inside
    /// `fieldChrome`, which left focus invisible on everything that is not a text field.
    ///
    /// 2 pt at 35 %, not the 3 pt at 55 % it started as: on a field that halo is a hint, but the
    /// same ring around a full-width `SegmentedControl` is a second border competing with the one the
    /// track already draws. The 2 pt stroke and the 2 pt outset also finally agree — at 3 pt the
    /// ring bled a point *inside* the control it is documented as sitting outside.
    func focusRing(_ focused: Bool, cornerRadius: CGFloat = Radius.control) -> some View {
        overlay(RoundedRectangle(cornerRadius: cornerRadius)
            .strokeBorder(focused ? Palette.focusRing : .clear, lineWidth: focusRingWidth)
            .padding(-focusRingWidth))
    }

    /// The one panel anything that hangs off a field is drawn in: the `menu` fill, the hairline and
    /// one elevation. The ticket list and the completion popup used to be 4 px apart in y and 2 px
    /// apart in blur, for no reason anyone could name — and both sat on the sheet's own `surface`,
    /// so over a field or a line of text they read as having no background at all.
    func menuChrome() -> some View {
        background(RoundedRectangle(cornerRadius: Radius.panel).fill(Palette.menu))
            .overlay(RoundedRectangle(cornerRadius: Radius.panel).strokeBorder(Palette.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 16, y: 6)
    }

    /// The box a group of controls is drawn in: the surface fill inside the one hairline, at the
    /// group radius — a `SettingsGroup`, a segmented track.
    func groupChrome() -> some View {
        background(RoundedRectangle(cornerRadius: Radius.group).fill(Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: Radius.group).strokeBorder(Palette.border, lineWidth: 1))
    }

    /// A dropdown row's highlight — the accent behind the row the keyboard or the pointer is on,
    /// dimmed while the pointer holds it down — and the ground that row now declares, so a badge or
    /// an icon inside it inks for the accent by itself. The ticket, merge request and branch pickers
    /// and the prompt's completion popup all draw their rows in it.
    func menuRowHighlight(_ on: Bool, pressed: Bool = false) -> some View {
        background(RoundedRectangle(cornerRadius: Radius.chip)
            .fill(pressed ? Palette.accentPressed : (on ? Palette.accent : .clear)))
            .surface(on || pressed ? .accent : .sheet)
    }

    /// A single-line text input's chrome: the field's own padding, `Size.control` tall, full
    /// width, in the field box.
    func fieldChrome(focused: Bool = false) -> some View {
        padding(.horizontal, Space.inset)
            .frame(height: Size.control)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fieldBox(focused: focused)
    }

    /// The filled, inset-stroked box every text input sits in, and its focus ring — without
    /// `fieldChrome`'s padding and height, for a field that sizes and insets itself: the prompt
    /// editor.
    func fieldBox(focused: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: FieldShape.cornerRadius, style: .continuous)
        return background(shape.fill(Palette.fieldFill))
            .overlay(shape.strokeBorder(Palette.border, lineWidth: 1))
            .focusRing(focused, cornerRadius: FieldShape.cornerRadius)
    }
}

/// The shape of a text field: macOS 26's, rounder than a control.
public enum FieldShape {
    public static let cornerRadius = Radius.group
}
