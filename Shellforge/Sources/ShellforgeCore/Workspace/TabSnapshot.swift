import Foundation

/// The iTerm2 user variables that tie a session to its task. Every tab carries its own: in one
/// shared window, nothing can be inherited from the window as AiTerm did.
public enum ShellforgeTags {
    public static let task = "user.shellforge_task"
    public static let project = "user.shellforge_project"
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

    public init(id: String, tabId: Int, title: String, taskId: UUID?, projectId: UUID?) {
        self.id = id
        self.tabId = tabId
        self.title = title
        self.taskId = taskId
        self.projectId = projectId
    }
}
