import ShellforgeCore
import ShellforgeDesign
import SwiftUI

/// The Metrics panel: the footer that used to sit under Sessions, in full — the selected row's
/// context and spend, the Mac's readings and its mode (a click toggles Backpack Mode, a right-click
/// offers Mac Settings…), and each vendor's windows with their reset times — scrolling when the
/// sidebar is short. `titled` false when the title is pinned above the panel instead.
struct MetricsPanel: View {
    let titled: Bool
    let footer: SidebarFooterHost
    @Environment(\.interfaceScale) private var scale

    /// The panel's `ViewMark`.
    static let markName = "MetricsPanel"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if titled {
                SidebarHeading(ActivityPanel.metrics.title)
                    .frame(height: scale(Size.menuRow))
                    .background(ViewMark(name: SidebarHeader.markName))
                    .padding(.horizontal, SidebarRowLayout.listInset + scale(Space.base))
            }
            ScrollView(.vertical) { footer }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ViewMark(name: Self.markName))
    }
}
