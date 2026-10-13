// Ported from AiTerm (app/Sources/AiTerm/Views/SidebarRows.swift: TerminalRowView), GPLv3, Laurens D'Hondt.
import ShellforgeCore
import ShellforgeDesign
import SwiftUI

/// A terminal row: the agents in its tabs, or its shell's `>_` when none is known; its name; its
/// status. Right-clicked: Rename… and Remove Terminal.
struct TerminalRowView: View {
    let node: TerminalNode
    let selected: Bool
    let agents: [SessionAgent]
    let status: SessionState
    let activate: () -> Void
    var rename: () -> Void = {}
    var remove: () -> Void = {}
    var menuExtras: AnyView = AnyView(EmptyView())
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        SelectableRow(selected: selected, activate: activate) {
            HStack(spacing: scale(Space.inset)) {
                AvatarGroupView(group: Self.marks(agents))
                RowTitle(node.terminal.name)
                Spacer(minLength: scale(Space.tight))
                StatusMark(status: status, size: SidebarRowLayout.trailingGlyph(scale))
                    .frame(width: SidebarRowLayout.trailingSlot(scale))
            }
        }
        .accessibilityLabel(node.terminal.name)
        .accessibilityValue(status.label)
        .contextMenu {
            Button("Rename…", action: rename)
            menuExtras
            Divider()
            Button("Remove Terminal", role: .destructive, action: remove)
        }
    }

    /// AiTerm's: its agents, or `>_` when none is known.
    static func marks(_ agents: [SessionAgent]) -> AvatarGroup { AvatarGroup.of(agents.isEmpty ? [.shell] : agents) }
}
