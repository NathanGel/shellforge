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
    /// Its tasks and terminals in the order they are drawn (`Workspace.children(in:)`).
    public var children: [ProjectChild] = []
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
    /// Tabs a panel opened whose owner exists, in window order; the panels list them.
    public var panelTabs: [TabSnapshot]

    public init(projects: [ProjectNode], otherTabs: [TabSnapshot], panelTabs: [TabSnapshot] = []) {
        self.projects = projects
        self.otherTabs = otherTabs
        self.panelTabs = panelTabs
    }

    /// `isOwned` says whether a panel tag’s owner (host, project, task) still exists; a tab whose
    /// owner is gone lists under other tabs, so it stays reachable.
    public static func build(_ workspace: Workspace, tabs: [TabSnapshot], isOwned: (PanelTab) -> Bool = { _ in true }) -> SidebarTree {
        let ordered = tabs.sorted { $0.tabId < $1.tabId }
        let known = Set(workspace.tasks.map(\.id))
        // Only a terminal whose project is drawn has a row; another's tabs are other tabs.
        let projectIds = Set(workspace.projects.map(\.id))
        let terminals = Set(workspace.terminals.filter { projectIds.contains($0.projectId) }.map(\.id))
        let projects = workspace.projects.map { project in
            ProjectNode(project: project, tasks: workspace.tasks(in: project.id).map { task in
                TaskNode(task: task, tabs: ordered.filter { $0.taskId == task.id })
            }, terminals: workspace.terminals.filter { $0.projectId == project.id }.map { terminal in
                // One owner per tab: a pane of a task moved in makes the tab the task's.
                TerminalNode(terminal: terminal, tabs: ordered.filter { tab in
                    tab.terminalId == terminal.id && !(tab.taskId.map(known.contains) ?? false)
                })
            }, children: workspace.children(in: project.id))
        }
        // A task or terminal tag wins over a panel tag: `unclaimed` is what neither owns.
        let unclaimed = ordered.filter { tab in
            if let terminal = tab.terminalId, terminals.contains(terminal) { return false }
            return tab.taskId.map { !known.contains($0) } ?? true
        }
        var panelTabs: [TabSnapshot] = []
        var other: [TabSnapshot] = []
        for tab in unclaimed {
            if let panel = tab.panel, isOwned(panel) { panelTabs.append(tab) } else { other.append(tab) }
        }
        return SidebarTree(projects: projects, otherTabs: other, panelTabs: panelTabs)
    }

    /// Whether the two trees draw the same: equal but for the titles of tabs no row draws. A task's
    /// tabs are drawn under it only while it is `selectedTask`; a terminal's never are (its row
    /// shows the terminal's name). Other and panel tabs always are. Claude's spinner retitles its
    /// tab several times a second, and a retitle that no row shows must not redraw the sidebar.
    public func drawsTheSame(as other: SidebarTree, selectedTask: UUID?) -> Bool {
        self.undrawnTitlesCleared(selectedTask) == other.undrawnTitlesCleared(selectedTask)
    }

    private func undrawnTitlesCleared(_ selectedTask: UUID?) -> SidebarTree {
        var copy = self
        for p in copy.projects.indices {
            for t in copy.projects[p].tasks.indices where copy.projects[p].tasks[t].id != selectedTask {
                for i in copy.projects[p].tasks[t].tabs.indices { copy.projects[p].tasks[t].tabs[i].title = "" }
            }
            for t in copy.projects[p].terminals.indices {
                for i in copy.projects[p].terminals[t].tabs.indices { copy.projects[p].terminals[t].tabs[i].title = "" }
            }
        }
        return copy
    }

    /// The task whose tag `tab` carries, if it is one of the workspace's.
    public func task(owning tab: TabSnapshot) -> TaskItem? {
        projects.lazy.flatMap(\.tasks).first { $0.task.id == tab.taskId }?.task
    }
}
