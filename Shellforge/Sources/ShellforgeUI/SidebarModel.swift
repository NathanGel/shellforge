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

    private let host: TerminalHost
    private let document: WorkspaceDocument
    private let launcher: CommandLauncher
    private var subscription: AnyCancellable?

    public init(host: TerminalHost, document: WorkspaceDocument, launcher: CommandLauncher) {
        self.host = host
        self.document = document
        self.launcher = launcher
        lastError = document.loadProblem
        host.onChange = { [weak self] in self?.refresh() }
        // @Published announces before it stores, so the new value is passed along.
        subscription = document.$workspace.dropFirst().sink { [weak self] workspace in
            MainActor.assumeIsolated { self?.refresh(workspace) }
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
        selectedTaskId = id
        if let tab = node.tabs.first {
            host.select(tab: tab.id)
        } else {
            host.openTab(in: node.task.worktreePath, taskId: id, projectId: node.task.projectId, title: node.task.title)
        }
    }

    public func select(tab id: String) {
        host.select(tab: id)
    }

    private func refresh(_ workspace: Workspace? = nil) {
        tree = SidebarTree.build(workspace ?? document.workspace, tabs: host.tabs)
        // Follow iTerm2: whatever tab is selected decides the task shown.
        if let selected = host.tabs.first(where: { $0.id == host.selectedTabId }), let task = tree.task(owning: selected) {
            selectedTaskId = task.id
        }
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
