import Foundation

public struct TaskNode: Equatable, Sendable, Identifiable {
    public var task: TaskItem
    /// Its open tabs in window order; empty when none is open.
    public var tabs: [TabSnapshot]
    public var id: UUID { task.id }
}

public struct ProjectNode: Equatable, Sendable, Identifiable {
    public var project: Project
    public var tasks: [TaskNode]
    /// Its terminal rows, after its tasks, oldest first.
    public var terminals: [TerminalNode] = []
    public var id: UUID { project.id }
}

public struct TerminalNode: Equatable, Sendable, Identifiable {
    public var terminal: TerminalItem
    /// Its open tabs in window order; empty when none is open.
    public var tabs: [TabSnapshot]
    public var id: UUID { terminal.id }
}

/// What the sidebar draws: projects in saved order, each with its tasks oldest first and each
/// task's tabs in window order; tabs that belong to no known task come last, under "Other tabs".
public struct SidebarTree: Equatable, Sendable {
    public var projects: [ProjectNode]
    public var otherTabs: [TabSnapshot]

    public init(projects: [ProjectNode], otherTabs: [TabSnapshot]) {
        self.projects = projects
        self.otherTabs = otherTabs
    }

    public static func build(_ workspace: Workspace, tabs: [TabSnapshot]) -> SidebarTree {
        let ordered = tabs.sorted { $0.tabId < $1.tabId }
        let known = Set(workspace.tasks.map(\.id))
        let terminals = Set(workspace.terminals.map(\.id))
        let projects = workspace.projects.map { project in
            ProjectNode(project: project, tasks: workspace.tasks(in: project.id).map { task in
                TaskNode(task: task, tabs: ordered.filter { $0.taskId == task.id })
            }, terminals: workspace.terminals.filter { $0.projectId == project.id }.map { terminal in
                TerminalNode(terminal: terminal, tabs: ordered.filter { $0.terminalId == terminal.id })
            })
        }
        let other = ordered.filter { tab in
            if let terminal = tab.terminalId, terminals.contains(terminal) { return false }
            return tab.taskId.map { !known.contains($0) } ?? true
        }
        return SidebarTree(projects: projects, otherTabs: other)
    }

    /// The task whose tag `tab` carries, if it is one of the workspace's.
    public func task(owning tab: TabSnapshot) -> TaskItem? {
        projects.lazy.flatMap(\.tasks).first { $0.task.id == tab.taskId }?.task
    }
}
