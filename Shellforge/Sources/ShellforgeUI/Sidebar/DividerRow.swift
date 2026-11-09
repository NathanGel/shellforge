// Ported from AiTerm (app/Sources/AiTerm/Views/DividerRow.swift), GPLv3, Laurens D'Hondt.
import ShellforgeCore
import ShellforgeDesign
import SwiftUI

/// A named rule between two projects. A label, not a container: it holds nothing, selects nothing
/// and hovers to nothing — only its context menu responds. The name takes the `PROJECTS` header's
/// exact treatment, because that is what it is: a heading for the projects under it. It moves in
/// Rearrange mode, which its menu opens.
struct DividerRow: View {
    let row: DividerRowItem
    let rename: () -> Void
    var canRearrange = true
    var rearrange: () -> Void = {}
    let remove: () -> Void
    @Environment(\.interfaceScale) private var scale
    @Environment(\.isRearranging) private var isRearranging

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
        // Rearrange mode offers its own moves instead (RearrangeRow).
        .modifier(NamedAccessibilityAction(name: "Rename", enabled: !isRearranging, action: rename))
        .modifier(NamedAccessibilityAction(name: RearrangeMenuItem.title, enabled: !isRearranging && canRearrange, action: rearrange))
        .modifier(NamedAccessibilityAction(name: "Remove Divider", enabled: !isRearranging, action: remove))
        .rowContextMenu {
            Button("Rename…", action: rename)
            Divider()
            RearrangeMenuItem(enabled: canRearrange, action: rearrange)
            Divider()
            // No confirmation: unlike removing a project this destroys nothing but the label.
            Button("Remove Divider", role: .destructive, action: remove)
        }
    }

    /// What VoiceOver offers outside Rearrange mode, as the context menu does: its items that can act now.
    static func voiceOverActions(_ row: DividerRowItem, canRearrange: Bool = true) -> [String] {
        ["Rename"] + (canRearrange ? [RearrangeMenuItem.title] : []) + ["Remove Divider"]
    }

    /// The context menu's items, in order.
    static let menuTitles = ["Rename…", RearrangeMenuItem.title, "Remove Divider"]
}

/// A named accessibility action that is there only while `enabled`: unlike a menu item, an action
/// cannot be greyed, only left out.
struct NamedAccessibilityAction: ViewModifier {
    let name: String
    let enabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if enabled { content.accessibilityAction(named: Text(name), action) } else { content }
    }
}
