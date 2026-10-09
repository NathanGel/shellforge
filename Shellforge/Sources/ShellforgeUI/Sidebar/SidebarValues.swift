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
    case otherTabsHeading

    public var id: String {
        switch self {
        case .empty: "empty"
        case .project(let node, _): "project-\(node.id)"
        case .task(let node, _): "task-\(node.id)"
        case .tab(let tab, _): "tab-\(tab.id)"
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
