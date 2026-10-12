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
    /// The Jira projects whose tickets belong to this one, in the order they were linked. Empty:
    /// New Task searches every Jira project.
    public var jiraProjects: [JiraProjectRef]
    /// The SSH tunnels this project runs (`~/.ssh/config` hosts), in the order they were added.
    public var tunnels: [TunnelDefinition] = []
    /// The `~/.ssh/config` host New Task can open in a pane beside the agent; nil for none.
    public var sshHost: String?

    public init(id: UUID = UUID(), name: String, path: String, addedAt: Date = Date(), collapsed: Bool = false,
                jiraProjects: [JiraProjectRef] = []) {
        self.id = id
        self.name = name
        self.path = path
        self.addedAt = addedAt
        self.collapsed = collapsed
        self.jiraProjects = jiraProjects
    }

    private enum CodingKeys: String, CodingKey { case id, name, path, addedAt, collapsed, jiraProjects, tunnels, sshHost }

    /// A workspace saved before projects could fold loads them unfolded, and one saved before they
    /// could link Jira projects links none.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), name: try c.decode(String.self, forKey: .name),
                  path: try c.decode(String.self, forKey: .path), addedAt: try c.decode(Date.self, forKey: .addedAt),
                  collapsed: try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false,
                  jiraProjects: try c.decodeIfPresent([JiraProjectRef].self, forKey: .jiraProjects) ?? [])
        // A workspace saved before tunnels has none.
        tunnels = try c.decodeIfPresent([TunnelDefinition].self, forKey: .tunnels) ?? []
        sshHost = try c.decodeIfPresent(String.self, forKey: .sshHost)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(path, forKey: .path)
        try c.encode(addedAt, forKey: .addedAt)
        try c.encode(collapsed, forKey: .collapsed)
        try c.encode(jiraProjects, forKey: .jiraProjects)
        try c.encode(tunnels, forKey: .tunnels)
        try c.encodeIfPresent(sshHost, forKey: .sshHost)
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
    /// The merge request a review was made from.
    public var mr: MergeRequestRef?
    /// Assigning one replaces what the file had: the new value is what is saved from then on.
    public var kind: TaskKind { didSet { savedKind = kind.rawValue } }
    public var createdAt: Date
    /// `kind` as the file has it, written back as it was: none for a task saved without one, and a
    /// raw value a newer build saved, which this build reads as `.task`.
    private var savedKind: String?

    /// A `.task` is made with no `kind` to save, as every task has been: only a review is stamped.
    public init(id: UUID = UUID(), projectId: UUID, title: String, branch: String, worktreePath: String,
                baseBranch: String, agent: String? = nil, model: String? = nil, reasoning: String? = nil,
                jira: JiraRef? = nil, kind: TaskKind = .task, mr: MergeRequestRef? = nil, createdAt: Date = Date()) {
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
        self.kind = kind
        self.mr = mr
        self.createdAt = createdAt
        savedKind = kind == .task ? nil : kind.rawValue
    }

    /// "Task" or "Review": what the row's menu and its alerts call it.
    public var kindName: String { kind.displayName }

    private enum CodingKeys: String, CodingKey {
        case id, projectId, title, branch, worktreePath, baseBranch, agent, model, reasoning, jira, kind, mr, createdAt
    }

    /// Written by hand, as AiTerm's is, so a `kind` this build has no case for is kept rather than
    /// failing the whole workspace load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        projectId = try c.decode(UUID.self, forKey: .projectId)
        title = try c.decode(String.self, forKey: .title)
        branch = try c.decode(String.self, forKey: .branch)
        worktreePath = try c.decode(String.self, forKey: .worktreePath)
        baseBranch = try c.decode(String.self, forKey: .baseBranch)
        agent = try c.decodeIfPresent(String.self, forKey: .agent)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        reasoning = try c.decodeIfPresent(String.self, forKey: .reasoning)
        jira = try c.decodeIfPresent(JiraRef.self, forKey: .jira)
        savedKind = try c.decodeIfPresent(String.self, forKey: .kind)
        kind = savedKind.flatMap(TaskKind.init(rawValue:)) ?? .task
        mr = try c.decodeIfPresent(MergeRequestRef.self, forKey: .mr)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(projectId, forKey: .projectId)
        try c.encode(title, forKey: .title)
        try c.encode(branch, forKey: .branch)
        try c.encode(worktreePath, forKey: .worktreePath)
        try c.encode(baseBranch, forKey: .baseBranch)
        try c.encodeIfPresent(agent, forKey: .agent)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(reasoning, forKey: .reasoning)
        try c.encodeIfPresent(jira, forKey: .jira)
        try c.encodeIfPresent(savedKind, forKey: .kind)
        try c.encodeIfPresent(mr, forKey: .mr)
        try c.encode(createdAt, forKey: .createdAt)
    }
}

/// Which of the two branch-shaped flows made a task; only `== .review` is ever tested. A task saved
/// without one — every task is — reads as `.task`, and so does a raw value this build does not know;
/// `TaskItem` keeps what the file had for the resave. AiTerm's `TaskKind`.
public enum TaskKind: String, Codable, Equatable, Sendable {
    case task, review
    public init(from decoder: Decoder) throws {
        self = TaskKind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .task
    }

    /// The kind as copy names it — "Remove Review…" — capitalised, as a menu item has it.
    public var displayName: String { self == .review ? "Review" : "Task" }
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
    /// Whether New Task last opened each project's SSH pane: the box opens as it was left.
    public var lastOpenSSHByProject: [UUID: Bool] = [:]

    public init(projects: [Project] = [], tasks: [TaskItem] = []) {
        self.projects = projects
        self.tasks = tasks
    }

    private enum CodingKeys: String, CodingKey { case version, projects, tasks, lastAgentByProject, lastModelByAgent, lastOpenSSHByProject }

    /// A file written before the remembered choices existed reads them as empty; one without its
    /// projects or tasks is not a workspace and fails, rather than reading as an empty one to be saved over.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        projects = try c.decode([Project].self, forKey: .projects)
        tasks = try c.decode([TaskItem].self, forKey: .tasks)
        lastAgentByProject = try c.decodeIfPresent([UUID: String].self, forKey: .lastAgentByProject) ?? [:]
        lastModelByAgent = try c.decodeIfPresent([String: String].self, forKey: .lastModelByAgent) ?? [:]
        lastOpenSSHByProject = try c.decodeIfPresent([UUID: Bool].self, forKey: .lastOpenSSHByProject) ?? [:]
    }

    /// What the next New Task in this project opens with: this agent, and this model for it.
    public mutating func remember(_ draft: some AgentDraft, projectId: UUID) {
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
