import Combine
import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

/// `@Published` announces every assignment, equal or not, and every announcement redraws the
/// window's whole sidebar. The daemon's events and iTerm2's notifications arrive many times a
/// minute: one that changes nothing redraws nothing.
@MainActor @Suite struct RedrawTests {
    private func model() throws -> (SidebarModel, FakeTerminalHost, FakeFeed) {
        let folder = TestScratch.root.appendingPathComponent("shellforge-redraw-\(UUID().uuidString)")
        let document = WorkspaceDocument(store: WorkspaceStore(folder: folder))
        try document.update { $0.projects.append(Project(name: "api", path: "/api")) }
        let launcher = CommandLauncher(resolve: { ResolvedEnvironment(variables: ["PATH": "/usr/bin"], source: .loginShell("/bin/zsh")) })
        let host = FakeTerminalHost(), feed = FakeFeed()
        return (SidebarModel(host: host, document: document, launcher: launcher, feed: feed, jiraSettings: { nil }), host, feed)
    }

    private func redraws(of model: SidebarModel, during work: () -> Void) -> Int {
        var count = 0
        let subscription = model.objectWillChange.sink { count += 1 }
        work()
        subscription.cancel()
        return count
    }

    @Test func anEqualStoreRedrawsNothing() throws {
        let (model, _, feed) = try model()
        feed.sayAll([(state: .working, session: "s1", task: UUID(), agent: .claude)])
        let same = feed.store
        #expect(redraws(of: model) { feed.store = same } == 0)
    }

    @Test func anEqualRefreshRedrawsNothing() throws {
        let (model, host, _) = try model()
        host.onChange?()
        #expect(redraws(of: model) { host.onChange?() } == 0)
    }

    /// Clicking another tab of the same task in iTerm2's tab bar moves the highlight at once.
    @Test func switchingTabsOfOneTaskRedraws() throws {
        let (model, host, _) = try model()
        let project = try #require(model.tree.projects.first).project.id
        let task = UUID()
        host.tabs = [TabSnapshot(id: "s1", tabId: 1, title: "a", taskId: task, projectId: project),
                     TabSnapshot(id: "s2", tabId: 2, title: "b", taskId: task, projectId: project)]
        host.selectedTabId = "s1"
        host.onChange?()
        host.selectedTabId = "s2"
        #expect(redraws(of: model) { host.onChange?() } == 1)
    }

    /// A divider added, renamed or removed is drawn at once: the tree holds no dividers.
    @Test func aNewDividerRedraws() throws {
        let (model, _, _) = try model()
        #expect(redraws(of: model) { model.addDivider(name: "Work") } >= 1)
        #expect(model.rows.contains { if case .divider = $0 { true } else { false } })
    }

    /// Clicking the selected task, or Focus View showing it again, assigns nothing.
    @Test func reselectingATaskRedrawsNothing() throws {
        let (model, host, _) = try model()
        let project = try #require(model.tree.projects.first).project.id
        let task = TaskItem(projectId: project, title: "Fix", branch: "fix", worktreePath: "/api/.worktrees/fix", baseBranch: "main")
        try model.document.update { $0.tasks.append(task) }
        host.tabs = [TabSnapshot(id: "t1", tabId: 1, title: "a", taskId: task.id, projectId: project)]
        host.selectedTabId = "t1"
        host.onChange?()
        model.select(task: task.id)
        #expect(redraws(of: model) { model.select(task: task.id) } == 0)
        #expect(redraws(of: model) { model.show(task: task.id) } == 0)
    }
}
