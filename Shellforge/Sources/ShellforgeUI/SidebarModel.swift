import Combine
import Foundation
import ShellforgeCore

/// One terminal window, as the sidebar sees it. iTerm2 implements it in-process
/// (`iTermShellforgeHost`); the tests use a fake.
@MainActor
public protocol TerminalHost: AnyObject {
    var tabs: [TabSnapshot] { get }
    var selectedTabId: String? { get }
    /// Called whenever a tab opens, closes, is renamed or is selected — by the sidebar or by iTerm2.
    var onChange: (@MainActor () -> Void)? { get set }
    func select(tab id: String)
    /// Opens a tab in `directory`, running the login shell, tagged with the task and project, and
    /// selects it. `command` is typed into its shell once it starts: the task's agent.
    func openTab(in directory: String, taskId: UUID, projectId: UUID, title: String, command: String?)
}

/// What the sidebar needs from the helper: its status, what the daemon says about the sessions,
/// and where to say a task was seen. `DaemonLink` is the app's; the tests use a fake.
@MainActor
public protocol SessionFeed: AnyObject {
    var statusPublisher: AnyPublisher<HelperStatus, Never> { get }
    var storePublisher: AnyPublisher<SessionStore, Never> { get }
    func markSeen(task: UUID)
}

/// The sidebar's state for one window: the shared workspace, this window's tabs, and which task is
/// shown. git work — a checkout and the repository's hooks — runs off the main thread; its result is
/// applied back on it.
@MainActor
public final class SidebarModel: ObservableObject {
    @Published public private(set) var tree = SidebarTree(projects: [], otherTabs: [])
    @Published public private(set) var selectedTaskId: UUID?
    /// The last action's failure, in words the user can act on; cleared by the next success.
    @Published public var lastError: String?
    /// What is being done right now, such as "Creating Fix login…"; nil when idle.
    @Published public private(set) var working: String?
    /// What the daemon says about the sessions: every dot is read from it.
    @Published public private(set) var sessions = SessionStore()
    /// How far the chain to the helper reaches; the sidebar says it while it is a problem.
    @Published public private(set) var helper: HelperStatus = .starting
    /// Where each project's code lives, for its row's mark; read from git off the main thread.
    @Published public private(set) var providers: [UUID: Provider] = [:]
    /// How many projects' providers have been looked up, for the test that holds it to one each.
    private(set) var providerLookups = 0
    /// Projects whose provider is being looked up now.
    private var detecting: Set<UUID> = []

    private let host: TerminalHost
    private let document: WorkspaceDocument
    private let launcher: CommandLauncher
    /// The agents New Task offers.
    public let agents: [AgentDefinition]
    /// An agent's model list, read off the main actor.
    private let catalogue: @Sendable (AgentDefinition) throws -> [AgentModel]
    private var subscription: AnyCancellable?
    private let feed: SessionFeed?
    private var feedSubscriptions: [AnyCancellable] = []
    /// The tab selected at the last refresh: moving to another is opening it.
    private var lastSelectedTab: String?

    public init(host: TerminalHost, document: WorkspaceDocument, launcher: CommandLauncher, feed: SessionFeed? = nil,
                agents: [AgentDefinition] = AgentPresets.all,
                catalogue: @escaping @Sendable (AgentDefinition) throws -> [AgentModel] = { _ in [] }) {
        self.host = host
        self.document = document
        self.launcher = launcher
        self.agents = agents
        self.catalogue = catalogue
        self.feed = feed
        lastError = document.loadProblem
        host.onChange = { [weak self] in self?.refresh() }
        // @Published announces before it stores, so the new value is passed along.
        subscription = document.$workspace.dropFirst().sink { [weak self] workspace in
            MainActor.assumeIsolated { self?.refresh(workspace) }
        }
        if let feed {
            feedSubscriptions = [
                feed.storePublisher.sink { [weak self] store in MainActor.assumeIsolated { self?.sessions = store } },
                feed.statusPublisher.sink { [weak self] status in MainActor.assumeIsolated { self?.helper = status } },
            ]
        }
        refresh()
    }

    public func addProject(folder: String) async {
        let (launcher, snapshot) = (self.launcher, document.workspace)
        working = "Adding \(URL(fileURLWithPath: folder).lastPathComponent)…"
        defer { working = nil }
        let found = await Task.detached { try ProjectFolders.project(at: folder, in: snapshot, launcher: launcher) }.result
        attempt {
            let project = try found.get()
            try document.update { workspace in
                // Another window may have added it while git was running.
                guard !workspace.projects.contains(where: { $0.path == project.path }) else {
                    throw ProjectFolders.Refusal.alreadyAdded(project.path)
                }
                workspace.projects.append(project)
            }
        }
    }

    /// The New Task sheet for `projectId`: the agent last started there while its CLI is installed,
    /// else the first installed one; its last model; and the project's branches, read when shown.
    public func makeNewTaskModel(for projectId: UUID) -> NewTaskModel? {
        guard let project = document.workspace.projects.first(where: { $0.id == projectId }), !agents.isEmpty else { return nil }
        let launcher = self.launcher
        let available = Set(agents.filter { launcher.locate($0.command) != nil }.map(\.id))
        let last = document.workspace.lastAgentByProject[projectId]
        let agentId = last.flatMap { available.contains($0) ? $0 : nil }
            ?? agents.first { available.contains($0.id) }?.id ?? agents[0].id
        let draft = TaskDraft(baseBranch: Repository.fallbackDefaultBranch, agentId: agentId, model: "", reasoning: nil)
        let path = project.path
        return NewTaskModel(project: project, agents: agents, available: available, draft: draft,
                            rememberedModels: document.workspace.lastModelByAgent, catalogue: catalogue,
                            branches: { Repository.branches(of: path, launcher: launcher) },
                            submit: { [weak self] draft in try await self?.newTask(draft: draft, in: projectId) })
    }

    /// AiTerm's create: the worktree on the draft's branch, the agent's command (its first prompt
    /// written beside it when too long or too strange to type), then the task saved and its tab
    /// opened running the agent. Throws, with nothing saved, so the sheet keeps its draft and says why.
    public func newTask(draft: TaskDraft, in projectId: UUID) async throws {
        guard let project = document.workspace.projects.first(where: { $0.id == projectId }),
              let agent = agents.first(where: { $0.id == draft.agentId }) else { return }
        let launcher = self.launcher
        let made = try await BackgroundWork.run { () throws -> (TaskItem, String) in
            let task = try TaskWorktrees.create(draft: draft, in: project, launcher: launcher)
            let command = try AgentCommand.build(agent: agent, model: draft.model, reasoning: draft.reasoning,
                                                 prompt: AgentCommand.composePrompt(userText: draft.promptText),
                                                 worktreePath: task.worktreePath, launcher: launcher)
            return (task, command)
        }
        try document.update { workspace in
            workspace.tasks.append(made.0)
            workspace.remember(draft, projectId: projectId)
            // A task made in a folded project is shown: the project unfolds for it.
            if let i = workspace.projects.firstIndex(where: { $0.id == projectId }) { workspace.projects[i].collapsed = false }
        }
        selectedTaskId = made.0.id
        host.openTab(in: made.0.worktreePath, taskId: made.0.id, projectId: projectId, title: made.0.title, command: made.1)
    }

    /// Shows the task: its first open tab, or a new one in its worktree when none is open.
    public func select(task id: UUID) {
        guard let node = tree.projects.lazy.flatMap(\.tasks).first(where: { $0.id == id }) else { return }
        guard let tab = node.tabs.first else {
            selectedTaskId = id
            // A shell, as AiTerm's New Terminal: the agent ran once, in the task's first tab.
            host.openTab(in: node.task.worktreePath, taskId: id, projectId: node.task.projectId, title: node.task.title, command: nil)
            return
        }
        if tab.id == host.selectedTabId {
            // Nothing will move: picking the task is the only sign it was looked at.
            shown(id, explicit: true)
        } else {
            // Selecting the tab refreshes, and the refresh sees it opened.
            selectedTaskId = id
            host.select(tab: tab.id)
        }
    }

    public func select(tab id: String) {
        host.select(tab: id)
    }

    private func refresh(_ workspace: Workspace? = nil) {
        tree = SidebarTree.build(workspace ?? document.workspace, tabs: host.tabs)
        detectProviders(tree.projects.map(\.project))
        // Follow iTerm2: whatever tab is selected decides the task shown.
        let opened = host.selectedTabId != lastSelectedTab
        lastSelectedTab = host.selectedTabId
        if let selected = host.tabs.first(where: { $0.id == host.selectedTabId }) {
            if let task = tree.task(owning: selected) {
                shown(task.id, explicit: opened)
            } else {
                // A tab of no task is shown: no task is.
                selectedTaskId = nil
            }
        }
    }

    /// The agents of a task's tabs, as AiTerm's avatar group takes them: in tab order, a shell's too
    /// (its `>_` mark). `AvatarGroup.of` turns them into the marks a row draws.
    public func avatars(forTask id: UUID) -> [SessionAgent] { Self.agents(sessions.sessions(ofTask: id)) }
    public func avatars(forTab id: String) -> [SessionAgent] { Self.agents(sessions.sessions(ofTab: id)) }

    private static func agents(_ sessions: [SessionInfo]) -> [SessionAgent] {
        sessions.sorted { ($0.tabIndex, $0.sessionId) < ($1.tabIndex, $1.sessionId) }.map(\.agent)
    }

    /// What the sidebar draws, in order: each project, and unless it is folded its tasks — the selected
    /// task's tabs under it when it has more than one; then the tabs of no task. With no project, the
    /// empty state comes first. Exactly one row is selected: the current tab when it is listed, else
    /// the task it belongs to (AiTerm's one painter, one row).
    public var rows: [SidebarRow] {
        var rows: [SidebarRow] = tree.projects.isEmpty ? [.empty] : []
        let current = host.selectedTabId
        for node in tree.projects {
            rows.append(.project(node, collapsed: node.project.collapsed))
            guard !node.project.collapsed else { continue }
            for task in node.tasks {
                let listsTabs = task.id == selectedTaskId && task.tabs.count > 1
                let ownsCurrent = task.tabs.contains { $0.id == current }
                rows.append(.task(task, selected: task.id == selectedTaskId && !(listsTabs && ownsCurrent)))
                if listsTabs { rows += task.tabs.map { .tab($0, selected: $0.id == current) } }
            }
        }
        if !tree.otherTabs.isEmpty {
            rows.append(.otherTabsHeading)
            rows += tree.otherTabs.map { .tab($0, selected: selectedTaskId == nil && $0.id == current) }
        }
        return rows
    }

    /// Folds or unfolds a project, as AiTerm's chevron does; kept with the workspace.
    public func toggleCollapsed(_ project: UUID) {
        attempt {
            try document.update { workspace in
                if let i = workspace.projects.firstIndex(where: { $0.id == project }) { workspace.projects[i].collapsed.toggle() }
            }
        }
    }

    /// Reads each project's provider it does not know yet, off the main thread.
    /// `projects` is the tree's: `@Published` announces before it stores, so the document's own copy is
    /// the one before the change when a refresh asks.
    private func detectProviders(_ projects: [Project]) {
        // Not one already known or being looked up: iTerm2 refreshes the sidebar many times while
        // it restores its windows, long before git answers.
        let unknown = projects.filter { providers[$0.id] == nil && !detecting.contains($0.id) }
        guard !unknown.isEmpty else { return }
        providerLookups += unknown.count
        detecting.formUnion(unknown.map(\.id))
        let launcher = self.launcher
        Task {
            let found = await BackgroundWork.run {
                unknown.map { ($0.id, ProviderDetector.provider(ofRepositoryAt: $0.path, launcher: launcher)) }
            }
            // One publication for the batch, not one redraw per project.
            var next = providers
            for (id, provider) in found { next[id] = provider }
            providers = next
            detecting.subtract(found.map(\.0))
        }
    }

    public func status(ofTask id: UUID) -> SessionState { sessions.status(ofTask: id) }
    public func status(ofTab id: String) -> SessionState { sessions.status(ofTab: id) }

    /// The task the user is now looking at. A done one has been seen — when the user picked it or
    /// opened one of its tabs (`explicit`), or the selection moved to it; not on every refresh while
    /// it stays selected.
    private func shown(_ id: UUID, explicit: Bool) {
        let changed = selectedTaskId != id
        selectedTaskId = id
        if explicit || changed, sessions.status(ofTask: id) == .done { feed?.markSeen(task: id) }
    }

    private func attempt(_ action: () throws -> Void) {
        do {
            try action()
            lastError = nil
        } catch let refusal as ProjectFolders.Refusal {
            switch refusal {
            case .notARepository(let reason): lastError = reason
            case .alreadyAdded(let path): lastError = "\(path) is already in the sidebar."
            }
        } catch {
            lastError = String(describing: error)
        }
    }
}
