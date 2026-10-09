// Ported from AiTerm (app/Sources/AiTermUI/FormField.swift), GPLv3, Laurens D'Hondt.
import SwiftUI

/// A label above its control, at the system's spacing. The label draws over the control, as
/// AiTerm's `FrontToBackStack` orders them; that stack needs macOS 15 (`Group(subviews:)`), so the
/// order is given here by `zIndex`, for these two children.
public struct FormField<Content: View>: View {
    let label: String
    let content: Content

    public init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            Text(label).font(Typography.label).foregroundStyle(Palette.muted).zIndex(1)
            content
        }
    }
}

/// Subordinate copy under a control: what a field means, why an option is unavailable, what went
/// wrong. It inks itself by `tone` — a caller's `.foregroundStyle` outside it would lose to the ink
/// set inside, which is how three warnings once drew grey.
public struct HelpText: View {
    /// What the copy is saying.
    public enum Tone: Equatable, Sendable {
        /// Explanation: the default, in secondary ink.
        case secondary
        /// Something needs attention — a failed search, a missing CLI — in the warning semantic.
        case warning
    }

    let text: String
    let tone: Tone

    public init(_ text: String, tone: Tone = .secondary) {
        self.text = text
        self.tone = tone
    }

    public var body: some View {
        Text(text).font(Typography.help).foregroundStyle(tone == .warning ? Palette.amber : Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}
