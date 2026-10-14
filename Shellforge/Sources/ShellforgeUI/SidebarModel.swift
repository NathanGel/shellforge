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
    /// Opens a terminal row's tab: a plain shell in `directory`, tagged with the terminal and its
    /// project, and selects it.
    func openTab(in directory: String, terminalId: UUID, projectId: UUID, title: String)
    /// Closes every tab of the terminal, in every window. True once none is left open.
    func closeTabs(ofTerminal id: UUID) -> Bool
    /// Closes the tab holding session `id`, as iTerm2's Close Tab does: a running job asks first.
    /// True once it closed.
    @discardableResult func close(tab id: String) -> Bool
    /// How many panes tagged with the task every window holds.
    func paneCount(ofTask id: UUID) -> Int
    /// Closes the pane of session `id` — the tab's focused pane when the row was drawn — as iTerm2's
    /// Close does: a running job asks first. True once it closed.
    @discardableResult func closePane(ofTab id: String) -> Bool
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
/// and where to say a task or a terminal was seen. `DaemonLink` is the app's; the tests use a fake.
@MainActor
public protocol SessionFeed: AnyObject {
    var statusPublisher: AnyPublisher<HelperStatus, Never> { get }
    var storePublisher: AnyPublisher<SessionStore, Never> { get }
    /// Each tunnel call's outcome, once, as it happens: a refusal is said as the sidebar's error,
    /// and the same tunnel's next success clears it.
    var tunnelOutcomePublisher: AnyPublisher<TunnelOutcome, Never> { get }
    func markSeen(task: UUID)
    /// A terminal's tabs, by their sessions: they carry no task.
    func markSeen(sessions: [String])
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
    /// What `rows` draws beyond the tree — the current tab's highlight and the dividers — as of the
    /// last refresh: published so a change to either redraws, as the tree's does.
    @Published private(set) var drawnTabId: String?
    @Published private(set) var drawnDividers: [SidebarDivider] = []
    @Published public internal(set) var selectedTaskId: UUID?
    /// The terminal row shown, when the selected tab is a terminal's (Terminals/).
    @Published public internal(set) var selectedTerminalId: UUID?
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
    /// Keyboard commands that need one of the sidebar's sheets (SidebarCommands.swift).
    public let sheetRequests = PassthroughSubject<SidebarSheetRequest, Never>()
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
    let catalogue: @Sendable (AgentDefinition) throws -> [AgentModel]
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
    var launchRequested: Set<String> {
        get { LaunchStarts.shared(for: document).requested }
        set { LaunchStarts.shared(for: document).requested = newValue }
    }
    /// The tunnel error the banner shows, by its tunnel: that tunnel's next success clears it.
    private var shownTunnelError: (alias: String, message: String)?
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
                feed.tunnelOutcomePublisher.sink { [weak self] outcome in
                    MainActor.assumeIsolated { self?.take(outcome) }
                },
                feed.statusPublisher.sink { [weak self] status in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        // Emptied when a connection ends, not whenever this window has yet to hear
                        // of one: a window opened later must not undo what another asked.
                        if self.helper == .connected, status != .connected { self.launchRequested = [] }
                        self.helper = status
                        self.autoStartOnLaunch()
                    }
                },
            ]
        }
        refresh()
        // The first read runs a login shell: off the main actor, and said if it fell back.
        environmentChanged()
    }

    /// A tunnel's refusal shown as the error; its next success clears it, and only it — an error
    /// set since by something else stays.
    private func take(_ outcome: TunnelOutcome) {
        if let error = outcome.error {
            lastError = error
            shownTunnelError = (outcome.alias, error)
        } else if let shown = shownTunnelError, shown.alias == outcome.alias {
            if lastError == shown.message { lastError = nil }
            shownTunnelError = nil
        }
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
        // Held for Remove Project from the start of git's work until the task is saved.
        let made = try await whileCreating(in: projectId) { () async throws -> (TaskItem, String) in
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
            return made
        }
        selectedTaskId = made.0.id
        selectedTerminalId = nil
        // The pane the sheet offered, never one the config grew since it opened.
        let beside = draft.openSSH ? draft.paneHost.map(SSHConfig.paneCommand(alias:)) : nil
        host.openTab(in: made.0.worktreePath, taskId: made.0.id, projectId: projectId, title: made.0.title, command: made.1,
                     environment: openingTaskTab(in: projectId), beside: beside)
    }

    /// Shows the task: its first open tab, or a new one in its worktree when none is open.
    public func select(task id: UUID) {
        guard let node = tree.projects.lazy.flatMap(\.tasks).first(where: { $0.id == id }) else { return }
        // Assigned only when it changes: an equal assignment still redraws the whole sidebar.
        if selectedTerminalId != nil { selectedTerminalId = nil }
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

    /// The keyboard's way to a task (Next, Previous, Focus View): its tab in this window when it has
    /// one, else only the selection. Unlike a click it opens nothing: stepping through tasks must not
    /// leave a shell behind for each, nor a second tab for one whose tab is in another window.
    public func show(task id: UUID) {
        guard let node = tree.projects.lazy.flatMap(\.tasks).first(where: { $0.id == id }) else { return }
        if selectedTaskId != id { selectedTaskId = id }
        if selectedTerminalId != nil { selectedTerminalId = nil }
        if let tab = node.tabs.first, tab.id != host.selectedTabId { host.select(tab: tab.id) }
    }

    public func select(tab id: String) {
        host.select(tab: id)
    }

    private func refresh(_ workspace: Workspace? = nil) {
        // Assigned only when it differs: `@Published` announces every assignment, and every
        // announcement redraws the whole sidebar.
        let current = workspace ?? document.workspace
        let built = SidebarTree.build(current, tabs: host.tabs)
        if built != tree { tree = built }
        if host.selectedTabId != drawnTabId { drawnTabId = host.selectedTabId }
        if current.dividers != drawnDividers { drawnDividers = current.dividers }
        refreshSSHHosts(tree.projects.map(\.project))
        contexts.prune(keeping: Set(tree.projects.flatMap(\.tasks).map { FooterRow.task($0.id) }
                                    + (tree.otherTabs + terminalTabs).map { FooterRow.tab($0.tabId) }))
        detectProviders(tree.projects.map(\.project))
        // Follow iTerm2: whatever tab is selected decides the task shown.
        let opened = host.selectedTabId != lastSelectedTab
        lastSelectedTab = host.selectedTabId
        if let selected = host.tabs.first(where: { $0.id == host.selectedTabId }) {
            if let task = tree.task(owning: selected) {
                if selectedTerminalId != nil { selectedTerminalId = nil }
                shown(task.id, explicit: opened)
            } else {
                // A tab of no task is shown: no task is — a terminal's, perhaps.
                if selectedTaskId != nil { selectedTaskId = nil }
                if let id = selected.terminalId, document.workspace.terminals.contains(where: { $0.id == id }) {
                    shown(terminal: id, explicit: opened)
                } else if selectedTerminalId != nil {
                    selectedTerminalId = nil
                }
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
        // The same store again (a resend, an event that changed nothing here): nothing to redraw.
        guard store != sessions else { return }
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
        // Terminal tabs keep the footer row they had as other tabs: the tab's own.
        let others = Set(tree.otherTabs.map(\.tabId) + terminalTabs.map(\.tabId))
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

    /// What the sidebar draws, in order: each project, and unless it is folded its tasks — the selected
    /// task's tabs under it when it has more than one; then the tabs of no task. With no project, the
    /// empty state comes first. Exactly one row is selected: the current tab when it is listed, else
    /// the task it belongs to (AiTerm's one painter, one row).
    public var rows: [SidebarRow] {
        var rows: [SidebarRow] = tree.projects.isEmpty ? [.empty] : []
        let current = host.selectedTabId
        let workspace = document.workspace
        // A hand-edited workspace may repeat a project: the first is drawn, never a crash.
        let nodes = Dictionary(tree.projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let dividers = Dictionary(workspace.dividers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // With no project the empty state stands alone; a rule under it would divide nothing.
        let entries = tree.projects.isEmpty ? [] : SidebarLayout.entries(projects: tree.projects.map(\.project), dividers: workspace.dividers)
        for (index, entry) in entries.enumerated() {
            guard case .project(let id) = entry, let node = nodes[id] else {
                // Its ends from its place in the one layout drawn, not a layout rebuilt per divider.
                if case .divider(let id) = entry, let divider = dividers[id] {
                    rows.append(.divider(DividerRowItem(divider: divider, canMoveUp: index > 0, canMoveDown: index < entries.count - 1)))
                }
                continue
            }
            rows.append(.project(node, collapsed: node.project.collapsed))
            guard !node.project.collapsed else { continue }
            rows += tunnelRows(of: node.project).map(SidebarRow.tunnel)
            for task in node.tasks {
                let listsTabs = task.id == selectedTaskId && task.tabs.count > 1
                let ownsCurrent = task.tabs.contains { $0.id == current }
                rows.append(.task(task, selected: task.id == selectedTaskId && !(listsTabs && ownsCurrent)))
                if listsTabs { rows += task.tabs.map { .tab($0, selected: $0.id == current) } }
            }
            rows += node.terminals.map { .terminal($0, selected: $0.id == selectedTerminalId) }
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

    /// Every terminal row's tabs in this window.
    var terminalTabs: [TabSnapshot] { tree.projects.flatMap(\.terminals).flatMap(\.tabs) }

    /// A terminal row is the one selected: no task is (Terminals/).
    func selectTerminalRow(_ id: UUID?) {
        if selectedTerminalId != id { selectedTerminalId = id }
        if id != nil, selectedTaskId != nil { selectedTaskId = nil }
    }

    /// The task the user is now looking at. A done one has been seen — when the user picked it or
    /// opened one of its tabs (`explicit`), or the selection moved to it; not on every refresh while
    /// it stays selected.
    private func shown(_ id: UUID, explicit: Bool) {
        let changed = selectedTaskId != id
        if changed { selectedTaskId = id }
        // Any done tab, even beside one still working: the daemon marks only the done ones seen.
        if explicit || changed, sessions.sessions(ofTask: id).contains(where: { $0.state == .done }) { feed?.markSeen(task: id) }
    }

    func attempt(_ action: () throws -> Void) {
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
