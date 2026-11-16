import Foundation
import ShellforgeCore

/// The Sessions panel's filter: text, matched case-insensitively against a task's title, ticket key
/// and branch, a terminal's name, or a project's name; and a status. Off when both are empty. Held
/// by the window's model, not saved.
public struct RowFilter: Equatable, Sendable {
    public var text = ""
    public var status: SessionState? = nil

    public init(text: String = "", status: SessionState? = nil) {
        self.text = text; self.status = status
    }

    private var query: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var isActive: Bool { !query.isEmpty || status != nil }

    func matches(_ fields: String?...) -> Bool {
        let query = self.query
        guard !query.isEmpty else { return true }
        return fields.contains { $0?.localizedCaseInsensitiveContains(query) == true }
    }

    func matches(status state: SessionState) -> Bool { status == nil || status == state }

    /// The children of `node` the filter keeps, in their order, or nil when the project isn't shown
    /// at all. A project whose name matches the text shows every child that passes the status, and
    /// shows even with none when there is no status to pass.
    func children(of node: ProjectNode, status: (ProjectChild) -> SessionState) -> [ProjectChild]? {
        let projectMatches = !query.isEmpty && matches(node.project.name)
        let tasks = Dictionary(node.tasks.map { ($0.id, $0.task) }, uniquingKeysWith: { first, _ in first })
        let terminals = Dictionary(node.terminals.map { ($0.id, $0.terminal) }, uniquingKeysWith: { first, _ in first })
        let kept = node.children.filter { child in
            guard matches(status: status(child)) else { return false }
            if projectMatches { return true }
            switch child {
            case .task(let id): return tasks[id].map { matches($0.title, $0.jira?.key, $0.branch) } ?? false
            case .terminal(let id): return terminals[id].map { matches($0.name) } ?? false
            }
        }
        if kept.isEmpty && !(projectMatches && self.status == nil) { return nil }
        return kept
    }
}
