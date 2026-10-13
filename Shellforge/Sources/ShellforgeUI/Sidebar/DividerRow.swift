// Ported from AiTerm (app/Sources/AiTerm/Views/DividerRow.swift), GPLv3, Laurens D'Hondt.
import ShellforgeCore
import ShellforgeDesign
import SwiftUI

/// A named rule between two projects. A label, not a container: it holds nothing, selects nothing
/// and hovers to nothing — only its context menu responds. The name takes the `PROJECTS` header's
/// exact treatment, because that is what it is: a heading for the projects under it.
struct DividerRow: View {
    let row: DividerRowItem
    let rename: () -> Void
    let move: (_ up: Bool) -> Void
    let remove: () -> Void
    @Environment(\.interfaceScale) private var scale

    private var name: String { row.divider.name }

    var body: some View {
        HStack(spacing: scale(Space.base)) {
            Hairline()
            if !name.isEmpty {
                SidebarHeading(name)
                    .lineLimit(1).truncationMode(.tail).fixedSize(horizontal: true, vertical: false)
                Hairline()
            }
        }
        .frame(height: scale(Size.menuRow))
        .padding(.leading, scale(Space.base)).padding(.trailing, SidebarRowLayout.trailingInset(scale))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(name.isEmpty ? "Divider" : "\(name) divider")
        .contextMenu {
            Button("Rename…", action: rename)
            Divider()
            // Disabled at the edges rather than absent, exactly as a project's menu does it.
            Button("Move Up") { move(true) }.disabled(!row.canMoveUp)
            Button("Move Down") { move(false) }.disabled(!row.canMoveDown)
            Divider()
            // No confirmation: unlike removing a project this destroys nothing but the label.
            Button("Remove Divider", role: .destructive, action: remove)
        }
    }
}
