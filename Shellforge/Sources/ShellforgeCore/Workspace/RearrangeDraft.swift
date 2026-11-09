import Foundation

/// The sidebar's order while it is being rearranged: the top level, each project's SSH rows and each
/// project's tasks and terminals, moved only within their own list. Nothing is written until `apply`.
public struct RearrangeDraft: Equatable, Sendable {
    /// The projects and dividers, as drawn.
    public private(set) var entries: [SidebarEntry]
    /// Each project's SSH rows, by alias.
    public private(set) var tunnels: [UUID: [String]]
    /// Each project's tasks and terminals.
    public private(set) var children: [UUID: [ProjectChild]]

    public init(_ workspace: Workspace) {
        entries = SidebarLayout.entries(projects: workspace.projects, dividers: workspace.dividers)
        tunnels = Dictionary(workspace.projects.map { ($0.id, $0.tunnels.map(\.alias)) }, uniquingKeysWith: { first, _ in first })
        children = Dictionary(workspace.projects.map { ($0.id, workspace.children(in: $0.id)) }, uniquingKeysWith: { first, _ in first })
    }

    /// One movable row.
    public enum Item: Hashable, Sendable {
        case entry(SidebarEntry)
        case tunnel(project: UUID, alias: String)
        case child(project: UUID, ProjectChild)
    }

    /// Moves `item` to just before `before` (nil = end of its own list). False, nothing changed, when the rules refuse it.
    /// An item moves only among its own kind in its own list: an entry among entries, an SSH row among
    /// its project's SSH rows, a task or terminal among its project's tasks and terminals. So nothing
    /// leaves its project, and no task or terminal goes above the SSH rows.
    @discardableResult
    public mutating func move(_ item: Item, before: Item?) -> Bool {
        switch (item, before) {
        case (.entry(let e), nil):
            Self.commit(Self.moving(e, before: nil, in: entries), to: &entries)
        case (.entry(let e), .entry(let target)?):
            Self.commit(Self.moving(e, before: target, in: entries), to: &entries)
        case (.tunnel(let p, let alias), nil):
            Self.commit(Self.moving(alias, before: nil, in: tunnels[p]), to: &tunnels[p])
        case (.tunnel(let p, let alias), .tunnel(let q, let target)?) where p == q:
            Self.commit(Self.moving(alias, before: target, in: tunnels[p]), to: &tunnels[p])
        case (.child(let p, let child), nil):
            Self.commit(Self.moving(child, before: nil, in: children[p]), to: &children[p])
        case (.child(let p, let child), .child(let q, let target)?) where p == q:
            Self.commit(Self.moving(child, before: target, in: children[p]), to: &children[p])
        default:
            false
        }
    }

    /// One step, for VoiceOver; false at an edge.
    @discardableResult
    public mutating func step(_ item: Item, up: Bool) -> Bool {
        switch item {
        case .entry(let e): Self.commit(Self.stepping(e, up: up, in: entries), to: &entries)
        case .tunnel(let p, let alias): Self.commit(Self.stepping(alias, up: up, in: tunnels[p]), to: &tunnels[p])
        case .child(let p, let child): Self.commit(Self.stepping(child, up: up, in: children[p]), to: &children[p])
        }
    }

    public func canStep(_ item: Item, up: Bool) -> Bool {
        switch item {
        case .entry(let e): Self.stepping(e, up: up, in: entries) != nil
        case .tunnel(let p, let alias): Self.stepping(alias, up: up, in: tunnels[p]) != nil
        case .child(let p, let child): Self.stepping(child, up: up, in: children[p]) != nil
        }
    }

    /// Writes the draft into `workspace`: anything added since `init` goes to the bottom of its list, anything gone is dropped.
    public func apply(to workspace: inout Workspace) {
        for i in workspace.projects.indices {
            let id = workspace.projects[i].id
            if let order = children[id] {
                workspace.projects[i].childOrder = order.map(\.id)
                // Settle it against what is there now: gone ids out, new ones in at the bottom.
                workspace.projects[i].childOrder = workspace.children(in: id).map(\.id)
            }
            if let aliases = tunnels[id] {
                // By the draft's order; aliases it does not know (added since) after, as they are now.
                let rank = Dictionary(aliases.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
                let key = { (t: (offset: Int, element: TunnelDefinition)) in (rank[t.element.alias] ?? Int.max, t.offset) }
                workspace.projects[i].tunnels = workspace.projects[i].tunnels.enumerated()
                    .sorted { key($0) < key($1) }
                    .map(\.element)
            }
        }
        let present = SidebarLayout.entries(projects: workspace.projects, dividers: workspace.dividers)
        // Counted rather than a set, so an id a hand-edited workspace repeats is kept as often as it is there.
        var remaining = Dictionary(present.map { ($0, 1) }, uniquingKeysWith: +)
        var order: [SidebarEntry] = []
        for entry in entries + present where remaining[entry, default: 0] > 0 {
            remaining[entry, default: 0] -= 1
            order.append(entry)
        }
        SidebarLayout.apply(order, projects: &workspace.projects, dividers: &workspace.dividers)
    }

    /// `list` with `item` just before `target` (nil = at the end), or nil when either is not in it.
    private static func moving<T: Equatable>(_ item: T, before target: T?, in list: [T]?) -> [T]? {
        guard var all = list, let from = all.firstIndex(of: item) else { return nil }
        guard let target else {
            all.remove(at: from)
            all.append(item)
            return all
        }
        guard all.contains(target) else { return nil }
        if target == item { return all }
        all.remove(at: from)
        guard let to = all.firstIndex(of: target) else { return nil }
        all.insert(item, at: to)
        return all
    }

    /// `list` with `item` swapped with its neighbour, or nil at an edge or when it is not in it.
    private static func stepping<T: Equatable>(_ item: T, up: Bool, in list: [T]?) -> [T]? {
        guard var all = list, let index = all.firstIndex(of: item) else { return nil }
        let other = up ? index - 1 : index + 1
        guard all.indices.contains(other) else { return nil }
        all.swapAt(index, other)
        return all
    }

    private static func commit<T>(_ new: [T]?, to list: inout [T]) -> Bool {
        guard let new else { return false }
        list = new
        return true
    }

    private static func commit<T>(_ new: [T]?, to list: inout [T]?) -> Bool {
        guard let new else { return false }
        list = new
        return true
    }
}
