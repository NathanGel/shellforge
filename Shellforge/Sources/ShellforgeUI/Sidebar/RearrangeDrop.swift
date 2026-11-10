import ShellforgeCore
import ShellforgeDesign
import SwiftUI
import UniformTypeIdentifiers

/// The row a drag in Rearrange mode is over, and whether over its lower half: the accent line is
/// drawn under the row then, over it otherwise.
public struct RearrangeDropTarget: Equatable, Sendable {
    public var item: RearrangeDraft.Item
    public var lowerHalf: Bool

    public init(item: RearrangeDraft.Item, lowerHalf: Bool) {
        self.item = item
        self.lowerHalf = lowerHalf
    }
}

/// Where a drop in Rearrange mode lands, read off the rows as drawn.
enum RearrangeDrop {
    /// What a dragged row is on the pasteboard: a type of Shellforge's own, offered to this process
    /// only, so a row let go over the terminal or Finder is no text to paste or clip.
    static let rowType = UTType(exportedAs: "io.github.nathangel.shellforge.sidebar-row", conformingTo: .data)

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

    /// The `before:` item for a drop on `item`: on its upper half, `item` itself; on its lower half,
    /// the next row of the same list, or nil at that list's end. An unfolded project with rows under
    /// it takes either half as before itself: the line is drawn at its header, so that is where the
    /// drop lands, not past rows the line does not reach.
    static func target(for item: RearrangeDraft.Item, lowerHalf: Bool, in rows: [SidebarRow]) -> RearrangeDraft.Item? {
        guard lowerHalf else { return item }
        let items = rows.compactMap(Self.item(of:))
        guard let index = items.firstIndex(of: item) else { return nil }
        let following = items[(index + 1)...]
        if case .entry(.project) = item, let next = following.first, !sameList(item, next) { return item }
        for next in following {
            // An entry's list runs past its project's own rows; an SSH row's or a child's ends with its run.
            if sameList(item, next) { return next }
            if case .entry = item { continue }
            return nil
        }
        return nil
    }

    /// The `before:` item for dropping `dragged` on `item`, or nil (outer) when the draft refuses it:
    /// a drop lands only in the dragged row's own list.
    static func landing(of dragged: RearrangeDraft.Item, on item: RearrangeDraft.Item, lowerHalf: Bool,
                        in rows: [SidebarRow], draft: RearrangeDraft) -> RearrangeDraft.Item?? {
        guard sameList(dragged, item) else { return nil }
        let before = target(for: item, lowerHalf: lowerHalf, in: rows)
        var trial = draft
        return trial.move(dragged, before: before) ? .some(before) : nil
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

/// A row in Rearrange mode: a drag handle before it, the row itself inert, dragged and dropped onto,
/// with an accent line where a drop would land and VoiceOver's one-step moves.
struct RearrangeRow<Content: View>: View {
    @ObservedObject var model: SidebarModel
    let item: RearrangeDraft.Item
    let id: String
    let label: String
    /// A project's fold: its row stays live for it (the row keeps its other controls quiet itself).
    var fold: RearrangeFold? = nil
    @ViewBuilder let content: () -> Content
    @State private var height: CGFloat = 0
    @Environment(\.interfaceScale) private var scale
    @Environment(\.surface) private var surface

    /// The line's thickness, in points.
    private static var lineWidth: CGFloat { 2 }

    var body: some View {
        let line = model.dropTarget.flatMap { $0.item == item ? $0.lowerHalf : nil }
        let actions = model.rearrange.map { RearrangeRowActions.titles(for: item, in: $0) } ?? []
        HStack(spacing: 0) {
            SymbolMark(symbol: "line.3.horizontal", size: scale(Size.avatar), tint: surface.secondaryInk)
                .padding(.leading, scale(Space.tight))
                .help("Drag to rearrange")
            content().allowsHitTesting(fold != nil)
        }
        .contentShape(Rectangle())
        .background { GeometryReader { proxy in Color.clear.onAppear { height = proxy.size.height }.onChange(of: proxy.size.height) { height = $0 } } }
        .overlay(alignment: line == true ? .bottom : .top) {
            if line != nil { Rectangle().fill(Palette.accent).frame(height: Self.lineWidth).allowsHitTesting(false) }
        }
        .onDrag { [weak model, item, id] in
            let session = model?.startDragging(item) ?? 0
            return RearrangeDragProvider(payload: id) { [weak model] in
                Task { @MainActor in model?.dragEnded(session) }
            }
        }
        .onDrop(of: [RearrangeDrop.rowType], delegate: RearrangeRowDrop(model: model, item: item, height: height))
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

/// A drop over one row: where it would land, and the move.
private struct RearrangeRowDrop: DropDelegate {
    let model: SidebarModel
    let item: RearrangeDraft.Item
    let height: CGFloat

    private func lowerHalf(_ info: DropInfo) -> Bool { info.location.y > height / 2 }

    /// What moves is read from the payload at the drop, never from what this sidebar thinks is dragged.
    func validateDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated { model.isRearranging } && info.hasItemsConforming(to: [RearrangeDrop.rowType])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let accepted = MainActor.assumeIsolated { model.hover(over: item, lowerHalf: lowerHalf(info)) }
        return DropProposal(operation: accepted ? .move : .forbidden)
    }

    func dropExited(info: DropInfo) {
        MainActor.assumeIsolated { if model.dropTarget?.item == item { model.dropTarget = nil } }
    }

    func performDrop(info: DropInfo) -> Bool {
        let model = model, item = item, lowerHalf = lowerHalf(info)
        guard let provider = info.itemProviders(for: [RearrangeDrop.rowType]).first else {
            MainActor.assumeIsolated { model.endDrag() }
            return false
        }
        MainActor.assumeIsolated { model.dropTarget = nil }
        RearrangeDragProvider.loadPayload(from: provider) { payload in
            Task { @MainActor in
                if let payload { model.drop(payload: payload, on: item, lowerHalf: lowerHalf) } else { model.endDrag() }
            }
        }
        return true
    }
}

/// A dragged row's id, under `RearrangeDrop.rowType` only, for this process only. AppKit holds it
/// for as long as the drag session lasts; letting go of it, dropped or abandoned, tells the sidebar
/// the drag is over.
final class RearrangeDragProvider: NSItemProvider, @unchecked Sendable {
    private let ended: @Sendable () -> Void

    init(payload: String, ended: @escaping @Sendable () -> Void) {
        self.ended = ended
        super.init()
        let data = Data(payload.utf8)
        registerDataRepresentation(forTypeIdentifier: RearrangeDrop.rowType.identifier, visibility: .ownProcess) { completion in
            completion(data, nil)
            return nil
        }
    }

    /// The row id a drop carries, or nil when it carries none.
    static func loadPayload(from provider: NSItemProvider, then handle: @escaping @Sendable (String?) -> Void) {
        _ = provider.loadDataRepresentation(forTypeIdentifier: RearrangeDrop.rowType.identifier) { data, _ in
            handle(data.flatMap { String(data: $0, encoding: .utf8) })
        }
    }

    deinit { ended() }
}

/// A drop anywhere else in the list: nothing moves. Leaving the list ends the drag, so a project
/// dropped outside the sidebar unfolds again; passing onto a row inside it does not.
private struct RearrangeListDrop: DropDelegate {
    let model: SidebarModel
    let size: CGSize

    func validateDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated { model.isRearranging } && info.hasItemsConforming(to: [RearrangeDrop.rowType])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        MainActor.assumeIsolated { model.dropTarget = nil }
        return DropProposal(operation: .forbidden)
    }

    func dropExited(info: DropInfo) {
        let inside = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1).contains(info.location)
        MainActor.assumeIsolated { if !inside { model.endDrag() } }
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated { model.endDrag() }
        return false
    }
}

extension View {
    /// The list's own drop target in Rearrange mode, under the rows' (RearrangeListDrop). Always
    /// there, so the list keeps its identity (and its scroll) as the mode comes and goes; it
    /// accepts nothing outside the mode.
    func rearrangeListDrop(_ model: SidebarModel) -> some View {
        modifier(RearrangeListDropArea(model: model))
    }
}

private struct RearrangeListDropArea: ViewModifier {
    let model: SidebarModel
    @State private var size: CGSize = .zero

    func body(content: Content) -> some View {
        content
            .background { GeometryReader { proxy in Color.clear.onAppear { size = proxy.size }.onChange(of: proxy.size) { size = $0 } } }
            .onDrop(of: [RearrangeDrop.rowType], delegate: RearrangeListDrop(model: model, size: size))
    }
}
