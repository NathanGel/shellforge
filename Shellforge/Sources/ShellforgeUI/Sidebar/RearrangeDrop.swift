import ShellforgeCore
import ShellforgeDesign
import SwiftUI

/// Where a move in Rearrange mode lands, read off the rows as drawn.
enum RearrangeDrop {
    /// The draft's item a row stands for; nil for a row that does not move (the empty state, a tab, a heading).
    static func item(of row: SidebarRow) -> RearrangeDraft.Item? {
        switch row {
        case .project(let node, _): .entry(.project(node.id))
        case .divider(let row): .entry(.divider(row.divider.id))
        case .tunnel(let row): .tunnel(project: row.projectId, alias: row.alias)
        case .task(let node, _): .child(project: node.task.projectId, .task(node.id))
        case .terminal(let node, _): .child(project: node.terminal.projectId, .terminal(node.id))
        case .empty, .tab, .otherTabsHeading: nil
        }
    }

    /// Whether two items are in the same list: entries among entries, a project's SSH rows among
    /// themselves, a project's tasks and terminals among themselves.
    static func sameList(_ a: RearrangeDraft.Item, _ b: RearrangeDraft.Item) -> Bool {
        switch (a, b) {
        case (.entry, .entry): true
        case (.tunnel(let p, _), .tunnel(let q, _)): p == q
        case (.child(let p, _), .child(let q, _)): p == q
        default: false
        }
    }

    /// What the List's move of the row at `source` to `destination` (SwiftUI's onMove index: the row
    /// it goes before, `rows.count` for the end) means for the draft: the item and the `before:` it
    /// lands at, or nil when it lands nowhere its list allows. A project or divider goes before the
    /// first project or divider at or after `destination`, so one dropped among a project's rows
    /// lands after that project. An SSH row, task or terminal lands only on a row of its own list or
    /// one past that list's last row (its end). The draft's own rules still decide the move.
    static func landing(moving source: Int, to destination: Int,
                        in rows: [SidebarRow]) -> (item: RearrangeDraft.Item, before: RearrangeDraft.Item?)? {
        guard rows.indices.contains(source), let item = item(of: rows[source]) else { return nil }
        let items = rows.map(Self.item(of:))
        let after = items.dropFirst(max(destination, 0))
        if case .entry = item {
            let before = after.lazy.compactMap { $0 }.first { if case .entry = $0 { true } else { false } }
            return (item, before)
        }
        if let target = after.first ?? nil, sameList(item, target) { return (item, target) }
        if let last = items.lastIndex(where: { $0.map { sameList(item, $0) } ?? false }), destination == last + 1 { return (item, nil) }
        return nil
    }
}

/// What VoiceOver offers on a row in Rearrange mode: one step up or down its own list, where it can go.
enum RearrangeRowActions {
    static let moveUp = "Move Up"
    static let moveDown = "Move Down"

    /// A project's fold, which still works in the mode.
    static func foldTitle(collapsed: Bool) -> String { collapsed ? "Unfold" : "Fold" }

    static func titles(for item: RearrangeDraft.Item, in draft: RearrangeDraft) -> [String] {
        (draft.canStep(item, up: true) ? [moveUp] : []) + (draft.canStep(item, up: false) ? [moveDown] : [])
    }
}

private struct IsRearrangingKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Set while the sidebar is in Rearrange mode: rows leave out their context menus and actions.
    var isRearranging: Bool {
        get { self[IsRearrangingKey.self] }
        set { self[IsRearrangingKey.self] = newValue }
    }
}

extension View {
    /// A row's context menu, left out in Rearrange mode.
    func rowContextMenu<Items: View>(@ViewBuilder _ items: () -> Items) -> some View {
        modifier(RowContextMenu(items: items()))
    }
}

private struct RowContextMenu<Items: View>: ViewModifier {
    let items: Items
    @Environment(\.isRearranging) private var isRearranging

    func body(content: Content) -> some View {
        if isRearranging { content } else { content.contextMenu { items } }
    }
}

/// The context menus' Rearrange, greyed while another window is rearranging.
struct RearrangeMenuItem: View {
    let enabled: Bool
    let action: () -> Void

    static let title = "Rearrange"

    /// Whether a row's VoiceOver actions offer Rearrange: as its menu does, outside the mode, and
    /// not while another window is rearranging (an action cannot be greyed, only left out).
    static func offeredToVoiceOver(canRearrange: Bool, isRearranging: Bool) -> Bool { canRearrange && !isRearranging }

    var body: some View { Button(Self.title, action: action).disabled(!enabled) }
}

/// Every arrangeable row's VoiceOver Rearrange action, the same on each.
struct RearrangeAccessibilityAction: ViewModifier {
    let canRearrange: Bool
    let action: () -> Void
    @Environment(\.isRearranging) private var isRearranging

    func body(content: Content) -> some View {
        content.modifier(NamedAccessibilityAction(
            name: RearrangeMenuItem.title,
            enabled: RearrangeMenuItem.offeredToVoiceOver(canRearrange: canRearrange, isRearranging: isRearranging),
            action: action))
    }
}

/// A project's fold in Rearrange mode: still live, and offered to VoiceOver.
struct RearrangeFold {
    let collapsed: Bool
    let toggle: () -> Void
}

/// A row in Rearrange mode: a handle mark before it, the row itself inert, and VoiceOver's one-step
/// moves. The List's own move drags it (`moveRows`), drawing the insertion line itself.
struct RearrangeRow<Content: View>: View {
    @ObservedObject var model: SidebarModel
    let item: RearrangeDraft.Item
    let label: String
    /// A project's fold: its row stays live for it (the row keeps its other controls quiet itself).
    var fold: RearrangeFold? = nil
    @ViewBuilder let content: () -> Content
    @Environment(\.interfaceScale) private var scale
    @Environment(\.surface) private var surface

    var body: some View {
        let actions = model.rearrange.map { RearrangeRowActions.titles(for: item, in: $0) } ?? []
        HStack(spacing: 0) {
            SymbolMark(symbol: "line.3.horizontal", size: scale(Size.avatar), tint: surface.secondaryInk)
                .padding(.leading, scale(Space.tight))
                .help("Drag to rearrange")
            content().allowsHitTesting(fold != nil)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityHint("Drag to rearrange")
        .modifier(NamedAccessibilityAction(name: RearrangeRowActions.moveUp, enabled: actions.contains(RearrangeRowActions.moveUp)) {
            model.stepInDraft(item, up: true)
        })
        .modifier(NamedAccessibilityAction(name: RearrangeRowActions.moveDown, enabled: actions.contains(RearrangeRowActions.moveDown)) {
            model.stepInDraft(item, up: false)
        })
        .modifier(NamedAccessibilityAction(name: RearrangeRowActions.foldTitle(collapsed: fold?.collapsed == true), enabled: fold != nil) {
            fold?.toggle()
        })
    }
}
