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

/// The sidebar's state for one window: the saved workspace, the window's tabs, and which task is
/// shown. Every change to the workspace is saved at once.
@MainActor
public final class SidebarModel: ObservableObject {
    @Published public private(set) var tree = SidebarTree(projects: [], otherTabs: [])
    @Published public private(set) var selectedTaskId: UUID?
    /// The last action's failure, in words the user can act on; cleared by the next success.
    @Published public var lastError: String?

    private let host: TerminalHost
    private let store: WorkspaceStore
    private let launcher: CommandLauncher
    private var workspace: Workspace

    public init(host: TerminalHost, store: WorkspaceStore, launcher: CommandLauncher) {
        self.host = host
        self.store = store
        self.launcher = launcher
        let loaded = try? store.load()
        workspace = loaded?.workspace ?? Workspace()
        if let kept = loaded?.recoveredFrom {
            lastError = "Your workspace file was damaged; it was kept as \(kept) and the last good copy loaded."
        }
        host.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    public func addProject(folder: String) {
        attempt {
            workspace.projects.append(try ProjectFolders.project(at: folder, in: workspace, launcher: launcher))
            try store.save(workspace)
        }
        refresh()
    }

    public func newTask(title: String, in projectId: UUID) {
        guard let project = workspace.projects.first(where: { $0.id == projectId }) else { return }
        attempt {
            let task = try TaskWorktrees.create(title: title, in: project, base: nil, launcher: launcher)
            workspace.tasks.append(task)
            try store.save(workspace)
            selectedTaskId = task.id
            host.openTab(in: task.worktreePath, taskId: task.id, projectId: project.id, title: task.title)
        }
        refresh()
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

    private func refresh() {
        tree = SidebarTree.build(workspace, tabs: host.tabs)
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
