import Foundation

/// The iTerm2 user variables that tie a session to its task. Every tab carries its own: in one
/// shared window, nothing can be inherited from the window as AiTerm did.
public enum ShellforgeTags {
    public static let task = "user.shellforge_task"
    public static let project = "user.shellforge_project"
    /// A terminal's tab: a plain shell in its project's folder, under a row of its own.
    public static let terminal = "user.shellforge_terminal"
}

/// One live tab, as the sidebar needs it. Built by the terminal host from iTerm2's sessions.
public struct TabSnapshot: Equatable, Sendable, Identifiable {
    /// The tab's active session's guid.
    public var id: String
    /// iTerm2's unique tab id; also the tab's order in the window.
    public var tabId: Int
    public var title: String
    public var taskId: UUID?
    public var projectId: UUID?
    /// The terminal row it is a tab of; nil for a task's tab or one of no row.
    public var terminalId: UUID?

    public init(id: String, tabId: Int, title: String, taskId: UUID?, projectId: UUID?, terminalId: UUID? = nil) {
        self.id = id
        self.tabId = tabId
        self.title = title
        self.taskId = taskId
        self.projectId = projectId
        self.terminalId = terminalId
    }
}

extension TabSnapshot {
    /// A tab's task and project, from its panes' tags with the focused pane first: the first pane
    /// that names a task gives it (and the first that names a project gives that). Only the pane that
    /// opened a task's tab is tagged, so a split focused beside it keeps the tab in its task.
    public static func tags(ofPanes panes: [(task: String?, project: String?)]) -> (task: UUID?, project: UUID?) {
        (panes.lazy.compactMap { $0.task.flatMap(UUID.init(uuidString:)) }.first,
         panes.lazy.compactMap { $0.project.flatMap(UUID.init(uuidString:)) }.first)
    }

    /// A tab's terminal, from its panes' tags: the first pane that names one.
    public static func terminal(ofPanes panes: [String?]) -> UUID? {
        panes.lazy.compactMap { $0.flatMap(UUID.init(uuidString:)) }.first
    }
}
