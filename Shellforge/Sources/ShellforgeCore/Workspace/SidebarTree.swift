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
    public var id: UUID { project.id }
}

/// What the sidebar draws: projects in saved order, each with its tasks oldest first and each
/// task's tabs in window order; tabs that belong to no known task come last, under "Other tabs".
public struct SidebarTree: Equatable, Sendable {
    public var projects: [ProjectNode]
    public var otherTabs: [TabSnapshot]

    public static func build(_ workspace: Workspace, tabs: [TabSnapshot]) -> SidebarTree {
        let ordered = tabs.sorted { $0.tabId < $1.tabId }
        let known = Set(workspace.tasks.map(\.id))
        let projects = workspace.projects.map { project in
            ProjectNode(project: project, tasks: workspace.tasks(in: project.id).map { task in
                TaskNode(task: task, tabs: ordered.filter { $0.taskId == task.id })
            })
        }
        let other = ordered.filter { $0.taskId.map { !known.contains($0) } ?? true }
        return SidebarTree(projects: projects, otherTabs: other)
    }

    /// The task whose tag `tab` carries, if it is one of the workspace's.
    public func task(owning tab: TabSnapshot) -> TaskItem? {
        projects.lazy.flatMap(\.tasks).first { $0.task.id == tab.taskId }?.task
    }
}
