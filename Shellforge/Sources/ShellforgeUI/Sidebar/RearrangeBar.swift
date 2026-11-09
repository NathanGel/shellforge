import ShellforgeDesign
import SwiftUI

/// The header's place while the sidebar is rearranged: what is going on, Cancel (Esc) and Done
/// (Return). With the window's buttons inside the sidebar it sits on their row, after them.
struct RearrangeBar: View {
    let cancel: () -> Void
    let done: () -> Void
    /// Set while the window's buttons sit inside the sidebar: the bar shares their row.
    var windowControls: SidebarWindowControls? = nil
    @Environment(\.interfaceScale) private var scale

    static let title = "Rearranging"
    static let cancelTitle = "Cancel"
    static let doneTitle = "Done"

    var body: some View {
        HStack(spacing: scale(Space.base)) {
            SidebarHeading(Self.title)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: scale(Space.tight))
            Button(Self.cancelTitle, action: cancel)
                .keyboardShortcut(.cancelAction)
            Button(Self.doneTitle, action: done)
                .keyboardShortcut(.defaultAction)
        }
        .controlSize(.small)
        .frame(height: scale(Size.menuRow))
        .modifier(HeaderPlacement(windowControls: windowControls, scale: scale))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.title)
    }
}
