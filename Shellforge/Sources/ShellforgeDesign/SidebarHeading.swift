// Ported from AiTerm (app/Sources/AiTermUI/SidebarHeading.swift), GPLv3, Laurens D'Hondt.
import SwiftUI

/// A heading in the sidebar's own voice — “Projects”, “Other Tabs” and a divider's name: macOS 26's
/// sidebar section header, sentence case, in secondary ink. The title is drawn as given.
///
/// Drawn in the sidebar, so it is drawn at the sidebar's scale: its one token is
/// `Typography.sectionHeader`, which scales by itself. It has no states; it is a label, never a control.
public struct SidebarHeading: View {
    private let title: String


    public init(_ title: String) { self.title = title }

    public var body: some View {
        Text(title).font(Typography.sectionHeader).foregroundStyle(Palette.muted)
    }
}
