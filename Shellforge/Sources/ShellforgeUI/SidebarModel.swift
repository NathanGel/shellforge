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
    /// Opens a tab in `directory`, running the login shell, tagged with the task and project, and selects it.
    func openTab(in directory: String, taskId: UUID, projectId: UUID, title: String)
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

    private let host: TerminalHost
    private let document: WorkspaceDocument
    private let launcher: CommandLauncher
    private var subscription: AnyCancellable?
    private let feed: SessionFeed?
    private var feedSubscriptions: [AnyCancellable] = []
    /// The tab selected at the last refresh: moving to another is opening it.
    private var lastSelectedTab: String?

    public init(host: TerminalHost, document: WorkspaceDocument, launcher: CommandLauncher, feed: SessionFeed? = nil) {
        self.host = host
        self.document = document
        self.launcher = launcher
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

    public func newTask(title: String, in projectId: UUID) async {
        guard let project = document.workspace.projects.first(where: { $0.id == projectId }) else { return }
        let launcher = self.launcher
        working = "Creating \(title)…"
        defer { working = nil }
        let made = await Task.detached { try TaskWorktrees.create(title: title, in: project, base: nil, launcher: launcher) }.result
        attempt {
            let task = try made.get()
            try document.update { $0.tasks.append(task) }
            selectedTaskId = task.id
            host.openTab(in: task.worktreePath, taskId: task.id, projectId: project.id, title: task.title)
        }
    }

    /// Shows the task: its first open tab, or a new one in its worktree when none is open.
    public func select(task id: UUID) {
        guard let node = tree.projects.lazy.flatMap(\.tasks).first(where: { $0.id == id }) else { return }
        guard let tab = node.tabs.first else {
            selectedTaskId = id
            host.openTab(in: node.task.worktreePath, taskId: id, projectId: node.task.projectId, title: node.task.title)
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
        // Follow iTerm2: whatever tab is selected decides the task shown.
        let opened = host.selectedTabId != lastSelectedTab
        lastSelectedTab = host.selectedTabId
        if let selected = host.tabs.first(where: { $0.id == host.selectedTabId }), let task = tree.task(owning: selected) {
            shown(task.id, explicit: opened)
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
