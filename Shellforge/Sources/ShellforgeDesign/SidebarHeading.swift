// Ported from AiTerm (app/Sources/AiTermUI/SidebarHeading.swift), GPLv3, Laurens D'Hondt.
import SwiftUI

/// A heading in the sidebar's own voice — `PROJECTS` and a divider's name: the micro face,
/// uppercase, tracked out, in secondary ink.
///
/// Drawn in the sidebar, so it is drawn at the sidebar's scale: its one token is
/// `Typography.micro`, which scales by itself. It has no states; it is a label, never a control.
public struct SidebarHeading: View {
    private let title: String

    /// The tracking an uppercase run needs at this size to read as a word rather than a row of
    /// capitals. An optical correction, not a size: it is not tokenised and does not scale.
    private static let tracking: CGFloat = 0.45

    public init(_ title: String) { self.title = title }

    public var body: some View {
        Text(title).font(Typography.micro).kerning(Self.tracking).textCase(.uppercase).foregroundStyle(Palette.muted)
    }
}
