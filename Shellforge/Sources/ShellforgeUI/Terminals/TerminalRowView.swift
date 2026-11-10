// Ported from AiTerm (app/Sources/AiTerm/Views/SidebarRows.swift: TerminalRowView), GPLv3, Laurens D'Hondt.
import ShellforgeCore
import ShellforgeDesign
import SwiftUI

/// A terminal row: the agents in its tabs, or its shell's `>_` when none is known; its name; its
/// status. Right-clicked: Rename…, Open in, Rearrange and Remove Terminal; VoiceOver offers Rename,
/// Rearrange and Remove Terminal, and none of them in Rearrange mode.
struct TerminalRowView: View {
    let node: TerminalNode
    let selected: Bool
    let agents: [SessionAgent]
    let status: SessionState
    /// The status is guessed from the terminal: its dot's tooltip says so.
    var guessed = false
    /// What each agent mark's tooltip calls its agent.
    var agentName: @MainActor (SessionAgent) -> String = { $0.rawValue }
    let activate: () -> Void
    var rename: () -> Void = {}
    var remove: () -> Void = {}
    var menuExtras: AnyView = AnyView(EmptyView())
    /// Rearrange mode, greyed while another window is in it.
    var canRearrange = true
    var rearrange: () -> Void = {}
    @Environment(\.interfaceScale) private var scale
    @Environment(\.isRearranging) private var isRearranging

    var body: some View {
        SelectableRow(selected: selected, activate: activate) {
            HStack(spacing: scale(Space.inset)) {
                AvatarGroupView(group: Self.marks(agents), name: agentName)
                RowTitle(node.terminal.name)
                Spacer(minLength: scale(Space.tight))
                StatusMark(status: status, size: SidebarRowLayout.trailingGlyph(scale), guessed: guessed)
                    .frame(width: SidebarRowLayout.trailingSlot(scale))
            }
        }
        .accessibilityLabel(node.terminal.name)
        .accessibilityValue(status.label)
        .modifier(NamedAccessibilityAction(name: "Rename", enabled: !isRearranging, action: rename))
        .modifier(RearrangeAccessibilityAction(canRearrange: canRearrange, action: rearrange))
        .modifier(NamedAccessibilityAction(name: "Remove Terminal", enabled: !isRearranging, action: remove))
        .rowContextMenu {
            Button("Rename…", action: rename)
            Divider()
            menuExtras
            Divider()
            RearrangeMenuItem(enabled: canRearrange, action: rearrange)
            Divider()
            Button("Remove Terminal", role: .destructive, action: remove)
        }
    }

    /// What VoiceOver offers outside Rearrange mode, as the context menu does.
    static let voiceOverActions = ["Rename", RearrangeMenuItem.title, "Remove Terminal"]

    /// The context menu's items, in order, apart from Open in's.
    static let menuTitles = ["Rename…", RearrangeMenuItem.title, "Remove Terminal"]

    /// AiTerm's: its agents, or `>_` when none is known.
    static func marks(_ agents: [SessionAgent]) -> AvatarGroup { AvatarGroup.of(agents.isEmpty ? [.shell] : agents) }
}
