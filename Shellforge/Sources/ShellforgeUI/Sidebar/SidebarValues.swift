// Ported from AiTerm (app/Sources/AiTermCore/Sidebar/SidebarModel.swift: AvatarGroup, BranchLabel),
// GPLv3, Laurens D'Hondt.
import ShellforgeCore

/// A row's agent marks: the first few, and how many more there are.
public struct AvatarGroup: Equatable, Sendable { public var marks: [SessionAgent]; public var overflow: Int }

/// A row's branch line (design canvas, "Branch awareness · 17 Sep"): the branch of the tab you are
/// looking at, how many *other* branches the same window has open, and whether that branch is not
/// the one the row is bound to. `detail` is the hover text; it is empty when there is nothing to
/// explain.
public struct BranchLabel: Equatable, Sendable {
    public var name: String, extra: Int, drifted: Bool, detail: String
    public init(name: String, extra: Int, drifted: Bool, detail: String) {
        self.name = name; self.extra = extra; self.drifted = drifted; self.detail = detail
    }
    public static let none = BranchLabel(name: "", extra: 0, drifted: false, detail: "")
}

extension AvatarGroup {
    /// AiTerm's most marks per row (`SidebarModel.avatarMax`).
    public static let max = 2

    /// A row's agents as its marks: all of them up to `max`, else one fewer and a `+n` for the rest
    /// (AiTerm's `SidebarModel.avatars(for:max:)`).
    public static func of(_ agents: [SessionAgent], max: Int = max) -> AvatarGroup {
        guard agents.count > max else { return AvatarGroup(marks: agents, overflow: 0) }
        return AvatarGroup(marks: Array(agents.prefix(max - 1)), overflow: agents.count - (max - 1))
    }
}

/// One line of the sidebar, in the order it is drawn — the values the view renders, as AiTerm's
/// `SidebarProjection` gives its `SidebarView`.
public enum SidebarRow: Equatable, Identifiable {
    case empty
    case project(ProjectNode, collapsed: Bool)
    case task(TaskNode, selected: Bool)
    case tab(TabSnapshot, selected: Bool)
    case tunnel(TunnelRowItem)
    case otherTabsHeading

    public var id: String {
        switch self {
        case .empty: "empty"
        case .project(let node, _): "project-\(node.id)"
        case .task(let node, _): "task-\(node.id)"
        case .tab(let tab, _): "tab-\(tab.id)"
        case .tunnel(let row): "tunnel-\(row.projectId)-\(row.alias)"
        case .otherTabsHeading: "other-tabs"
        }
    }
}

// Ported from AiTerm (app/Sources/AiTermCore/Sidebar/SidebarModel.swift: TaskStatus.label).
extension SessionState {
    /// The status as VoiceOver reads it on a row (the dot itself draws nothing for idle).
    var label: String {
        switch self {
        case .idle: "Idle"
        case .working: "Working"
        case .needsInput: "Needs input"
        case .done: "Done"
        }
    }
}

// Ported from AiTerm (app/Sources/AiTermCore/Sidebar/SidebarModel.swift: StatusCount, statusOrder,
// statusCounts, statusCountsLabel).
/// How many of a folded project's rows are in one status, for its count chips.
public struct StatusCount: Equatable, Sendable {
    public var status: SessionState, count: Int
    public init(status: SessionState, count: Int) { self.status = status; self.count = count }

    /// AiTerm's chip order.
    public static let order: [SessionState] = [.idle, .working, .needsInput, .done]

    /// Per-status counts, empty statuses left out: a project with nothing waiting on it draws no chip
    /// rather than a row of zeroes.
    public static func of(_ statuses: [SessionState]) -> [StatusCount] {
        order.compactMap { status in
            let n = statuses.filter { $0 == status }.count
            return n > 0 ? StatusCount(status: status, count: n) : nil
        }
    }

    /// The counts as a sentence, for the chips' tooltip and VoiceOver.
    public static func label(_ counts: [StatusCount]) -> String {
        counts.map { c in
            switch c.status {
            case .idle: "\(c.count) idle"
            case .working: "\(c.count) working"
            case .needsInput: c.count == 1 ? "1 needs input" : "\(c.count) need input"
            case .done: "\(c.count) done"
            }
        }.joined(separator: ", ")
    }
}
