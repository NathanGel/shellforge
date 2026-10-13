import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

/// AiTerm's Dock badge: how many task and terminal rows wait on you — needing input, or done and
/// unseen — once for the app, however many windows show them.
@MainActor @Suite struct DockBadgeTests {
    @Test func zeroIsNoBadge() {
        #expect(DockBadge.label(count: 0) == nil)
        #expect(DockBadge.label(count: 3) == "3")
    }

    /// Two windows over one workspace and one helper; a task waiting, and a terminal waiting in one
    /// window's tab.
    private func twoWindows() throws -> (SidebarModel, SidebarModel, FakeFeed, FakeTerminalHost, UUID, UUID) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shellforge-dock-\(UUID().uuidString)")
        let document = WorkspaceDocument(store: WorkspaceStore(folder: folder))
        let project = Project(name: "api", path: "/api")
        let task = TaskItem(projectId: project.id, title: "Login", branch: "feat/login", worktreePath: "/wt", baseBranch: "main")
        try document.update { $0.projects.append(project); $0.tasks.append(task) }
        let launcher = CommandLauncher(resolve: { ResolvedEnvironment(variables: ["PATH": "/usr/bin"], source: .loginShell("/bin/zsh")) })
        let feed = FakeFeed()
        let host = FakeTerminalHost()
        let first = SidebarModel(host: host, document: document, launcher: launcher, feed: feed, jiraSettings: { nil })
        let second = SidebarModel(host: FakeTerminalHost(), document: document, launcher: launcher, feed: feed, jiraSettings: { nil })
        first.newTerminal(name: "logs", in: project.id)
        return (first, second, feed, host, task.id, try #require(document.workspace.terminals.first).id)
    }

    @Test func theBadgeCountsOnceForTheApp() throws {
        let (first, second, feed, _, task, _) = try twoWindows()
        feed.sayAll([(.needsInput, "task-session", task, .claude)])
        #expect(DockBadge.count(across: [first, second]) == 1, "one task, two windows: one")
    }

    @Test func waitingTerminalsCount() throws {
        let (first, second, feed, host, task, terminal) = try twoWindows()
        let tab = try #require(host.tabs.first { $0.terminalId == terminal })
        // The daemon says the terminal's tab is done; the task needs input.
        var store = SessionStore()
        var snapshot = DaemonSnapshot(protocolVersion: 1, connected: true, sessions: [
            SessionInfo(sessionId: tab.id, windowId: "w", tabIndex: 0, taskId: nil, projectId: nil, agent: .claude, model: nil,
                        state: .done, title: "logs", cwd: "/api"),
            SessionInfo(sessionId: "task-session", windowId: "w", tabIndex: 1, taskId: task.uuidString.lowercased(), projectId: nil, agent: .claude,
                        model: nil, state: .needsInput, title: "t", cwd: "/wt"),
        ], usage: .empty)
        snapshot.tunnels = []
        store.apply(.snapshot(snapshot))
        feed.store = store
        #expect(DockBadge.count(across: [first, second]) == 2)
    }
}
