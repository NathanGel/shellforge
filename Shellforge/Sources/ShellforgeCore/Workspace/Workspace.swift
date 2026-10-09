import Foundation

/// A git repository the sidebar lists, with its tasks under it.
public struct Project: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// The repository's top-level folder.
    public var path: String
    public var addedAt: Date
    /// Whether the sidebar shows only its header, as AiTerm's project rows fold.
    public var collapsed: Bool

    public init(id: UUID = UUID(), name: String, path: String, addedAt: Date = Date(), collapsed: Bool = false) {
        self.id = id
        self.name = name
        self.path = path
        self.addedAt = addedAt
        self.collapsed = collapsed
    }

    private enum CodingKeys: String, CodingKey { case id, name, path, addedAt, collapsed }

    /// A workspace saved before projects could fold loads them unfolded.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), name: try c.decode(String.self, forKey: .name),
                  path: try c.decode(String.self, forKey: .path), addedAt: try c.decode(Date.self, forKey: .addedAt),
                  collapsed: try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false)
    }
}

/// A piece of work in its own git worktree and branch. Its tabs are found live by their
/// `user.shellforge_task` tag, never stored here.
public struct TaskItem: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var projectId: UUID
    public var title: String
    public var branch: String
    public var worktreePath: String
    /// The branch the task's branch was made from.
    public var baseBranch: String
    public var createdAt: Date

    public init(id: UUID = UUID(), projectId: UUID, title: String, branch: String, worktreePath: String,
                baseBranch: String, createdAt: Date = Date()) {
        self.id = id
        self.projectId = projectId
        self.title = title
        self.branch = branch
        self.worktreePath = worktreePath
        self.baseBranch = baseBranch
        self.createdAt = createdAt
    }
}

/// Everything the sidebar saves: projects in sidebar order, and their tasks.
public struct Workspace: Codable, Equatable, Sendable {
    /// Bumped when the file's shape changes in a way old code cannot read.
    public var version: Int = 1
    public var projects: [Project] = []
    public var tasks: [TaskItem] = []

    public init(projects: [Project] = [], tasks: [TaskItem] = []) {
        self.projects = projects
        self.tasks = tasks
    }

    /// The project's tasks, oldest first.
    public func tasks(in projectId: UUID) -> [TaskItem] {
        tasks.filter { $0.projectId == projectId }.sorted { $0.createdAt < $1.createdAt }
    }
}

extension JSONEncoder {
    static var workspace: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var workspace: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
