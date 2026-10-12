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
    /// Called with a task's title when its tab opened but the pane beside it could not.
    var onSplitRefused: (@MainActor @Sendable (String) -> Void)? { get set }
    func select(tab id: String)
    /// Opens a tab in `directory`, running the login shell, tagged with the task and project, and
    /// selects it. `command` is typed into its shell once it starts: the task's agent. `environment`
    /// is set in that shell first: the project's running tunnels' ports.
    func openTab(in directory: String, taskId: UUID, projectId: UUID, title: String, command: String?, environment: [String: String],
                 beside: String?)
    /// Closes every tab tagged with the task, in every window — what removing it starts with. True
    /// once none is left open.
    func closeTabs(ofTask id: UUID) -> Bool
    /// Opens a tab of no task in `directory`, typing `command` into its shell, and selects it.
    func openTab(in directory: String, title: String, command: String)
}

extension TerminalHost {
    /// A task's tab with nothing beside its agent.
    func openTab(in directory: String, taskId: UUID, projectId: UUID, title: String, command: String?, environment: [String: String]) {
        openTab(in: directory, taskId: taskId, projectId: projectId, title: title, command: command, environment: environment, beside: nil)
    }
}

/// The draft's agent's CLI was not on the login shell's `PATH` when Create ran.
public struct AgentNotInstalled: Error, Equatable, LocalizedError {
    public let agent: String
    public var errorDescription: String? { "\(agent) isn’t installed. Install it in Settings › Agents." }
}

/// What the sidebar needs from the helper: its status, what the daemon says about the sessions,
/// and where to say a task was seen. `DaemonLink` is the app's; the tests use a fake.
@MainActor
public protocol SessionFeed: AnyObject {
    var statusPublisher: AnyPublisher<HelperStatus, Never> { get }
    var storePublisher: AnyPublisher<SessionStore, Never> { get }
    func markSeen(task: UUID)
    func startTunnel(alias: String, keepRunning: Bool)
    func stopTunnel(alias: String)
    func holdTunnel(alias: String, port: Int, bind: String?)
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
    /// Said while the login shell's environment could not be read and a fallback PATH is used (PRD E6).
    @Published public private(set) var environmentWarning: String?
    /// Where each project's code lives, for its row's mark; read from git off the main thread.
    @Published public private(set) var providers: [UUID: Provider] = [:]
    /// Each task row's removal: running, or why the last one stopped — in every window, from the
    /// board they share.
    public var removals: [UUID: RowRemoval] { removalBoard.removals }
    /// Where Remove asks its questions; the app hands in `ModalPrompter`, tests a script.
    public var prompter: Prompter = NullPrompter()
    /// After Settings' Reload: the app tells every window's sidebar, as the launcher is shared.
    public var onEnvironmentReloaded: (@MainActor () -> Void)?
    let removalBoard: RemovalBoard
    private var boardSubscription: AnyCancellable?
    /// How many projects' providers have been looked up, for the test that holds it to one each.
    private(set) var providerLookups = 0
    /// Projects whose provider is being looked up now.
    private var detecting: Set<UUID> = []

    let host: TerminalHost
    let document: WorkspaceDocument
    let launcher: CommandLauncher
    /// The agents New Task offers.
    public let agents: [AgentDefinition]
    /// An agent's model list, read off the main actor.
    private let catalogue: @Sendable (AgentDefinition) throws -> [AgentModel]
    /// Read the saved Jira, GitLab and GitHub connections: the Keychain and the defaults. Tests hand
    /// in their own.
    let jiraSettings: @Sendable () -> JiraConfig?
    let gitLabSettings: @Sendable () -> GitLabConfig?
    let gitHubSettings: @Sendable () -> GitHubConfig?
    private var subscription: AnyCancellable?
    let feed: SessionFeed?
    private var feedSubscriptions: [AnyCancellable] = []

    // -- tunnels (SidebarModel+Tunnels.swift) --
    let sshConfig: SSHConfigSource
    /// The config's hosts by alias, as last read; nil until a project with tunnels asks for them.
    @Published public internal(set) var sshHosts: [String: SSHHost]?
    var readingSSH = false
    /// The `.onLaunch` tunnels asked of the helper now connected; emptied when it goes.
    var launchRequested: Set<String> = []
    /// The tab selected at the last refresh: moving to another is opening it.
    private var lastSelectedTab: String?

    public init(host: TerminalHost, document: WorkspaceDocument, launcher: CommandLauncher, feed: SessionFeed? = nil,
                agents: [AgentDefinition] = AgentPresets.all,
                catalogue: @escaping @Sendable (AgentDefinition) throws -> [AgentModel] = { _ in [] },
                jiraSettings: @escaping @Sendable () -> JiraConfig? = { JiraSettings.load() },
                gitLabSettings: @escaping @Sendable () -> GitLabConfig? = { GitLabSettings.load() },
                gitHubSettings: @escaping @Sendable () -> GitHubConfig? = { GitHubSettings.load() },
                sshConfig: SSHConfigSource = .none) {
        self.host = host
        self.sshConfig = sshConfig
        self.jiraSettings = jiraSettings
        self.gitLabSettings = gitLabSettings
        self.gitHubSettings = gitHubSettings
        removalBoard = RemovalBoard.shared(for: document)
        self.document = document
        self.launcher = launcher
        self.agents = agents
        self.catalogue = catalogue
        self.feed = feed
        lastError = document.loadProblem
        host.onChange = { [weak self] in self?.refresh() }
        host.onSplitRefused = { [weak self] title in self?.lastError = "The ssh pane couldn’t open beside \(title)." }
        // @Published announces before it stores, so the new value is passed along.
        subscription = document.$workspace.dropFirst().sink { [weak self] workspace in
            MainActor.assumeIsolated { self?.refresh(workspace) }
        }
        // A removal in any window redraws this one's rows.
        boardSubscription = removalBoard.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        }
        if let feed {
            feedSubscriptions = [
                feed.storePublisher.sink { [weak self] store in MainActor.assumeIsolated { self?.take(store) } },
                feed.statusPublisher.sink { [weak self] status in
                    MainActor.assumeIsolated {
                        self?.helper = status
                        self?.autoStartOnLaunch()
                    }
                },
            ]
        }
        refresh()
        // The first read runs a login shell: off the main actor, and said if it fell back.
        environmentChanged()
    }

    /// Reads the environment as the launcher now has it — reading it first if it has not been — and
    /// says whether it is a fallback. The app calls it after a Reload or a changed rc file.
    public func environmentChanged() {
        let launcher = self.launcher
        Task {
            let source = await BackgroundWork.run { launcher.environment.source }
            environmentWarning = Self.warning(source)
        }
    }

    static func warning(_ source: ResolvedEnvironment.Source) -> String? {
        guard case .fallback(let reason) = source else { return nil }
        return "Your login shell’s environment couldn’t be read (\(reason)); Shellforge is using a fallback PATH. Settings › Core shows it."
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

    /// The New Task sheet for `projectId`, the SSH config read first when the project names a host:
    /// the pane it offers is the config's now, not the last refresh's.
    public func prepareNewTask(for projectId: UUID) async -> NewTaskModel? {
        // The sheet looks for each agent's CLI on PATH: read the environment here first, off the
        // main actor, so a New Task opened right after launch runs no login shell on it.
        let launcher = self.launcher
        _ = await BackgroundWork.run { launcher.environment }
        if project(projectId)?.sshHost != nil { _ = await loadSSHHosts() }
        return makeNewTaskModel(for: projectId)
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
        var draft = TaskDraft(baseBranch: Repository.fallbackDefaultBranch, agentId: agentId, model: "", reasoning: nil)
        draft.paneHost = paneHost(of: project)
        draft.openSSH = draft.paneHost != nil && document.workspace.lastOpenSSHByProject[projectId] ?? true
        let path = project.path
        return NewTaskModel(project: project, agents: agents, available: available, draft: draft,
                            rememberedModels: document.workspace.lastModelByAgent, catalogue: catalogue,
                            branches: { Repository.branches(of: path, launcher: launcher) },
                            submit: { [weak self] draft in try await self?.newTask(draft: draft, in: projectId) },
                            // Read once, as the sheet opens: a Keychain read is too slow for every keystroke.
                            searchIssues: NewTaskModel.jiraSearcher(for: project, jira: jiraSettings()),
                            sshHost: paneHost(of: project),
                            home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// AiTerm's create: the worktree on the draft's branch, the agent's command (its first prompt
    /// written beside it when too long or too strange to type), then the task saved and its tab
    /// opened running the agent. Throws, with nothing saved, so the sheet keeps its draft and says why.
    public func newTask(draft: TaskDraft, in projectId: UUID) async throws {
        guard let project = document.workspace.projects.first(where: { $0.id == projectId }),
              let agent = agents.first(where: { $0.id == draft.agentId }) else { return }
        let launcher = self.launcher
        let made = try await BackgroundWork.run { () throws -> (TaskItem, String) in
            // Looked for again here: the sheet read what was installed when it opened, and a tab
            // whose first line is "command not found" is worse than a refusal.
            guard launcher.locate(agent.command) != nil else { throw AgentNotInstalled(agent: agent.name) }
            let task = try TaskWorktrees.create(draft: draft, in: project, launcher: launcher)
            let command = try AgentCommand.build(agent: agent, model: draft.model, reasoning: draft.reasoning,
                                                 prompt: AgentCommand.composePrompt(userText: draft.promptText, ticket: draft.ticket,
                                                                                    appendTicket: draft.appendTicket),
                                                 worktreePath: task.worktreePath, launcher: launcher)
            return (task, command)
        }
        try document.update { workspace in
            workspace.tasks.append(made.0)
            workspace.remember(draft, projectId: projectId)
            // Only a box the sheet showed is a choice to remember.
            if draft.paneHost != nil { workspace.lastOpenSSHByProject[projectId] = draft.openSSH }
            // A task made in a folded project is shown: the project unfolds for it.
            if let i = workspace.projects.firstIndex(where: { $0.id == projectId }) { workspace.projects[i].collapsed = false }
        }
        selectedTaskId = made.0.id
        // The pane the sheet offered, never one the config grew since it opened.
        let beside = draft.openSSH ? draft.paneHost.map(SSHConfig.paneCommand(alias:)) : nil
        host.openTab(in: made.0.worktreePath, taskId: made.0.id, projectId: projectId, title: made.0.title, command: made.1,
                     environment: openingTaskTab(in: projectId), beside: beside)
    }

    // -- New Review ----------------------------------------------------------------------

    /// The New Review sheet for `projectId`: the agent and model New Task would open with, the
    /// project's branches, and the search of its open merge requests — on GitLab or GitHub, as its
    /// remote says, with the connection as it stands now. The remote and the connections are read
    /// off the main actor: a git call and Keychain reads.
    public func makeReviewModel(for projectId: UUID) async -> ReviewCreationModel? {
        guard let project = document.workspace.projects.first(where: { $0.id == projectId }), !agents.isEmpty else { return nil }
        let launcher = self.launcher, path = project.path
        let readGitLab = gitLabSettings, readGitHub = gitHubSettings
        let read = await BackgroundWork.run { () -> (RemoteInfo, GitLabConfig?, GitHubConfig?) in
            let url = try? launcher.run("git", ["-C", path, "remote", "get-url", "origin"])
            let remote = ProviderDetector.detect(remoteUrl: url?.status == 0 ? url?.stdout : nil, repoPath: path)
            return (remote, readGitLab(), readGitHub())
        }
        let available = Set(agents.filter { launcher.locate($0.command) != nil }.map(\.id))
        let last = document.workspace.lastAgentByProject[projectId]
        let agentId = last.flatMap { available.contains($0) ? $0 : nil } ?? agents.first { available.contains($0.id) }?.id ?? agents[0].id
        return ReviewCreationModel(project: project, agents: agents, available: available,
                                   draft: ReviewDraft(mr: nil, agentId: agentId, model: "", reasoning: nil),
                                   rememberedModels: document.workspace.lastModelByAgent, catalogue: catalogue,
                                   branches: { Repository.branches(of: path, launcher: launcher) },
                                   codeHost: MergeRequestSearch.host(for: read.0),
                                   searchMergeRequests: ReviewCreationModel.searcher(gitLab: read.1, gitHub: read.2, remote: read.0),
                                   submit: { [weak self] draft in try await self?.newReview(draft: draft, in: projectId) },
                                   home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// AiTerm's review create: the merge request's branch in a worktree of its own, the agent's
    /// command with the typed prompt, then the review saved and its tab opened running the agent.
    public func newReview(draft: ReviewDraft, in projectId: UUID) async throws {
        guard let project = document.workspace.projects.first(where: { $0.id == projectId }),
              let agent = agents.first(where: { $0.id == draft.agentId }) else { return }
        let launcher = self.launcher
        let made = try await BackgroundWork.run { () throws -> (TaskItem, String) in
            guard launcher.locate(agent.command) != nil else { throw AgentNotInstalled(agent: agent.name) }
            let review = try ReviewWorktrees.create(draft: draft, in: project, launcher: launcher)
            let command = try AgentCommand.build(agent: agent, model: draft.model, reasoning: draft.reasoning,
                                                 prompt: draft.promptText.isEmpty ? nil : draft.promptText,
                                                 worktreePath: review.worktreePath, launcher: launcher)
            return (review, command)
        }
        try document.update { workspace in
            workspace.tasks.append(made.0)
            workspace.remember(draft, projectId: projectId)
            if let i = workspace.projects.firstIndex(where: { $0.id == projectId }) { workspace.projects[i].collapsed = false }
        }
        selectedTaskId = made.0.id
        host.openTab(in: made.0.worktreePath, taskId: made.0.id, projectId: projectId, title: made.0.title, command: made.1,
                     environment: openingTaskTab(in: projectId))
    }

    /// Shows the task: its first open tab, or a new one in its worktree when none is open.
    public func select(task id: UUID) {
        guard let node = tree.projects.lazy.flatMap(\.tasks).first(where: { $0.id == id }) else { return }
        guard let tab = node.tabs.first else {
            selectedTaskId = id
            // A shell, as AiTerm's New Terminal: the agent ran once, in the task's first tab.
            host.openTab(in: node.task.worktreePath, taskId: id, projectId: node.task.projectId, title: node.task.title, command: nil,
                         environment: openingTaskTab(in: node.task.projectId))
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
        refreshSSHHosts(tree.projects.map(\.project))
        contexts.prune(keeping: Set(tree.projects.flatMap(\.tasks).map { FooterRow.task($0.id) } + tree.otherTabs.map { FooterRow.tab($0.tabId) }))
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

    // -- the footer -----------------------------------------------------------------

    /// Each task's and other tab's last context fill per agent, as AiTerm's `LiveSessions` keeps it:
    /// a tab change or a closed tab leaves the row's fill as it was.
    public private(set) var contexts = SessionContexts()

    /// What the daemon says now: every session's fill remembered against its row first, then
    /// published.
    private func take(_ store: SessionStore) {
        let old = sessions.sessions
        let row = footerRowResolver(store)
        for session in store.sessions.values { contexts.remember(session, replacing: old[session.sessionId], row: row) }
        // A snapshot only fills what is not known yet, so seeding on every update is safe.
        contexts.seed(from: Array(store.sessions.values), row: row)
        sessions = store
        autoStartOnLaunch()
    }

    /// A session's footer row, read against `store` — the update being taken, so a pane that appears
    /// and reports at once is placed at once: its task while the workspace has it; else the sidebar
    /// tab it is a pane of — the tab's task when the tab opened one (a split carries no tag of its
    /// own), or the tab itself when it is outside any task. One map per update, so each lookup is
    /// a dictionary read.
    private func footerRowResolver(_ store: SessionStore) -> (SessionInfo) -> FooterRow? {
        let tasks = Set(document.workspace.tasks.map(\.id))
        let others = Set(tree.otherTabs.map(\.tabId))
        var byPane: [String: FooterRow] = [:]
        for tab in host.tabs {
            let row: FooterRow? = tab.taskId.flatMap { tasks.contains($0) ? FooterRow.task($0) : nil }
                ?? (others.contains(tab.tabId) ? .tab(tab.tabId) : nil)
            guard let row else { continue }
            byPane[tab.id] = row
            for pane in store.sessions(ofTab: tab.id) { byPane[pane.sessionId] = row }
        }
        return { session in
            if let task = session.taskUUID, tasks.contains(task) { return .task(task) }
            return byPane[session.sessionId]
        }
    }

    /// The footer's first row: the selected task's, else the selected tab's when it belongs to no
    /// task (AiTerm's terminal row); nothing when neither — SYSTEM then holds the Mac alone.
    public var footerRow: UsageTaskRow? {
        if let id = selectedTaskId {
            let task = document.workspace.tasks.first { $0.id == id }
            let fallback = task?.agent.flatMap(SessionAgent.init(rawValue:)) ?? .shell
            return UsageRows.taskRow(sessions: sessions.sessions(ofTask: id), fallback: fallback,
                                     contexts: contexts.percents(forRow: .task(id)), preferring: host.selectedTabId)
        }
        guard let id = host.selectedTabId, let tab = tree.otherTabs.first(where: { $0.id == id }) else { return nil }
        return UsageRows.taskRow(sessions: sessions.sessions(ofTab: id), fallback: .shell,
                                 contexts: contexts.percents(forRow: .tab(tab.tabId)), preferring: id)
    }

    /// USAGE's rows for this minute: Claude's and Codex's windows, as AiTerm's footer works them out.
    public func vendorRows(now: Date, calendar: Calendar, claudeStatusLineInstalled: Bool) -> [UsageVendorRow] {
        UsageRows.vendorRows(sessions.usage, now: now, calendar: calendar, claudeStatusLineInstalled: claudeStatusLineInstalled)
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
            rows += tunnelRows(of: node.project).map(SidebarRow.tunnel)
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

    // -- Jira projects ----------------------------------------------------------------

    /// The project as the workspace holds it now.
    public func project(_ id: UUID) -> Project? { document.workspace.projects.first { $0.id == id } }

    /// Every Jira project the account can see, for a project's Jira Projects sheet. The connection
    /// is read off the main actor: the Keychain is slow.
    public func loadJiraProjects() async throws -> [JiraProjectRef] {
        let read = jiraSettings
        guard let config = await BackgroundWork.run(read) else {
            throw ActionUnavailable("Connect Jira in Settings to choose a Jira project.")
        }
        return try await JiraClient(config: config).projects()
    }

    /// Replaces the project's linked Jira projects with `jiraProjects`, each once, in their order.
    /// An empty list unlinks them all: New Task then searches every Jira project.
    public func setJiraProjects(_ jiraProjects: [JiraProjectRef], on projectId: UUID) {
        let linked = jiraProjects.linkedOnce
        guard let current = document.workspace.projects.first(where: { $0.id == projectId }),
              current.jiraProjects != linked else { return }
        attempt {
            try document.update { workspace in
                if let i = workspace.projects.firstIndex(where: { $0.id == projectId }) { workspace.projects[i].jiraProjects = linked }
            }
        }
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
