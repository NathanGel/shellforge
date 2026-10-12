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
    /// The agent the task's first tab started (`AgentDefinition.id`), with its model and reasoning
    /// level; nil for a task made before New Task picked one.
    public var agent: String?
    public var model: String?
    public var reasoning: String?
    /// The Jira ticket the task was made from.
    public var jira: JiraRef?
    public var createdAt: Date

    public init(id: UUID = UUID(), projectId: UUID, title: String, branch: String, worktreePath: String,
                baseBranch: String, agent: String? = nil, model: String? = nil, reasoning: String? = nil,
                jira: JiraRef? = nil, createdAt: Date = Date()) {
        self.jira = jira
        self.id = id
        self.projectId = projectId
        self.title = title
        self.branch = branch
        self.worktreePath = worktreePath
        self.baseBranch = baseBranch
        self.agent = agent
        self.model = model
        self.reasoning = reasoning
        self.createdAt = createdAt
    }
}

/// Everything the sidebar saves: projects in sidebar order, and their tasks.
public struct Workspace: Codable, Equatable, Sendable {
    /// Bumped when the file's shape changes in a way old code cannot read.
    public var version: Int = 1
    public var projects: [Project] = []
    public var tasks: [TaskItem] = []
    /// What the next New Task opens with: the agent last started in each project, and the model
    /// last used with each agent (AiTerm's `AppState.lastAgentByProject` and `lastModelByAgent`).
    public var lastAgentByProject: [UUID: String] = [:]
    public var lastModelByAgent: [String: String] = [:]

    public init(projects: [Project] = [], tasks: [TaskItem] = []) {
        self.projects = projects
        self.tasks = tasks
    }

    private enum CodingKeys: String, CodingKey { case version, projects, tasks, lastAgentByProject, lastModelByAgent }

    /// A file written before the remembered choices existed reads them as empty; one without its
    /// projects or tasks is not a workspace and fails, rather than reading as an empty one to be saved over.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        projects = try c.decode([Project].self, forKey: .projects)
        tasks = try c.decode([TaskItem].self, forKey: .tasks)
        lastAgentByProject = try c.decodeIfPresent([UUID: String].self, forKey: .lastAgentByProject) ?? [:]
        lastModelByAgent = try c.decodeIfPresent([String: String].self, forKey: .lastModelByAgent) ?? [:]
    }

    /// What the next New Task in this project opens with: this agent, and this model for it.
    public mutating func remember(_ draft: TaskDraft, projectId: UUID) {
        lastAgentByProject[projectId] = draft.agentId
        lastModelByAgent[draft.agentId] = draft.model
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

// Ported from AiTerm (app/Sources/AiTermCore/Models.swift `JiraRef`), GPLv3, Laurens D'Hondt.
/// The Jira ticket a task was made from: its key, summary and page.
public struct JiraRef: Codable, Equatable, Sendable {
    public var key: String, summary: String, url: String
    public init(key: String, summary: String, url: String) { self.key = key; self.summary = summary; self.url = url }
}
