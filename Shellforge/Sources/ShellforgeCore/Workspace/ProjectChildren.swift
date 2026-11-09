import Foundation

/// One row under a project: a task or a terminal.
public enum ProjectChild: Hashable, Sendable {
    case task(UUID)
    case terminal(UUID)

    public var id: UUID {
        switch self {
        case .task(let id), .terminal(let id): id
        }
    }
}

extension Workspace {
    /// The project's tasks and terminals in the order the sidebar draws them. A project never
    /// arranged lists its tasks oldest first, then its terminals oldest first. Otherwise `childOrder`
    /// leads, skipping ids that are gone, and anything it does not name follows, oldest first.
    public func children(in projectId: UUID) -> [ProjectChild] {
        let tasks = tasks(in: projectId)
        let terminals = self.terminals.filter { $0.projectId == projectId }.sorted { $0.createdAt < $1.createdAt }
        let defaults = tasks.map { ProjectChild.task($0.id) } + terminals.map { ProjectChild.terminal($0.id) }
        guard let order = projects.first(where: { $0.id == projectId })?.childOrder else { return defaults }
        let existing = Dictionary(defaults.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<UUID>()
        let listed = order.compactMap { id in existing[id].flatMap { seen.insert(id).inserted ? $0 : nil } }
        let others = (tasks.map { ($0.createdAt, ProjectChild.task($0.id)) } + terminals.map { ($0.createdAt, ProjectChild.terminal($0.id)) })
            .filter { !seen.contains($0.1.id) }
            .sorted { $0.0 < $1.0 }
            .map(\.1)
        return listed + others
    }

    /// Adds `task` at the bottom of its project, freezing an unarranged project's order first so
    /// the new row does not slide in among the others by date.
    public mutating func addTask(_ task: TaskItem) {
        freezeOrder(of: task.projectId)
        tasks.append(task)
        appendToOrder(task.id, in: task.projectId)
    }

    /// Adds `terminal` at the bottom of its project, as `addTask` does.
    public mutating func addTerminal(_ terminal: TerminalItem) {
        freezeOrder(of: terminal.projectId)
        terminals.append(terminal)
        appendToOrder(terminal.id, in: terminal.projectId)
    }

    private mutating func freezeOrder(of projectId: UUID) {
        guard let i = projects.firstIndex(where: { $0.id == projectId }), projects[i].childOrder == nil else { return }
        projects[i].childOrder = children(in: projectId).map(\.id)
    }

    private mutating func appendToOrder(_ id: UUID, in projectId: UUID) {
        guard let i = projects.firstIndex(where: { $0.id == projectId }) else { return }
        projects[i].childOrder?.append(id)
    }
}
