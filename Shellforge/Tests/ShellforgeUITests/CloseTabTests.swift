import Combine
import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

/// Closing a tab from the sidebar: an Other tab or one of several closes; a task's last tab asks to
/// remove the task instead, through Remove Task's own confirmation, and closes nothing yet.
@MainActor @Suite struct CloseTabTests {
    private func model() throws -> (SidebarModel, FakeTerminalHost, UUID, UUID) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shellforge-close-\(UUID().uuidString)")
        let document = WorkspaceDocument(store: WorkspaceStore(folder: folder))
        let project = Project(name: "api", path: "/api")
        let task = TaskItem(projectId: project.id, title: "Fix", branch: "fix", worktreePath: "/api/.worktrees/fix", baseBranch: "main")
        try document.update { $0.projects.append(project); $0.tasks.append(task) }
        let launcher = CommandLauncher(resolve: { ResolvedEnvironment(variables: ["PATH": "/usr/bin"], source: .loginShell("/bin/zsh")) })
        let host = FakeTerminalHost()
        return (SidebarModel(host: host, document: document, launcher: launcher, jiraSettings: { nil }), host, project.id, task.id)
    }

    private func requests(_ model: SidebarModel, during work: () -> Void) -> [SidebarSheetRequest] {
        var seen: [SidebarSheetRequest] = []
        let subscription = model.sheetRequests.sink { seen.append($0) }
        work()
        subscription.cancel()
        return seen
    }

    @Test func anOtherTabCloses() throws {
        let (model, host, _, _) = try model()
        host.tabs = [TabSnapshot(id: "o1", tabId: 1, title: "zsh", taskId: nil, projectId: nil)]
        host.onChange?()
        model.closeTab("o1")
        #expect(host.closed == ["o1"])
        #expect(model.tree.otherTabs.isEmpty)
    }

    @Test func aTaskTabWithAnotherCloses() throws {
        let (model, host, project, task) = try model()
        host.tabs = [TabSnapshot(id: "t1", tabId: 1, title: "a", taskId: task, projectId: project),
                     TabSnapshot(id: "t2", tabId: 2, title: "b", taskId: task, projectId: project)]
        host.onChange?()
        #expect(requests(model) { model.closeTab("t2") }.isEmpty)
        #expect(host.closed == ["t2"])
    }

    @Test func theLastTabAsksToRemoveTheTask() throws {
        let (model, host, project, task) = try model()
        host.tabs = [TabSnapshot(id: "t1", tabId: 1, title: "a", taskId: task, projectId: project)]
        host.onChange?()
        #expect(requests(model) { model.closeTab("t1") } == [.removeTask(task)])
        #expect(host.closed.isEmpty, "the confirmation decides; a cancel leaves the tab open")
    }

    @Test func aTaskTabWithAnotherElsewhereJustCloses() throws {
        let (model, host, project, task) = try model()
        host.tabs = [TabSnapshot(id: "t1", tabId: 1, title: "a", taskId: task, projectId: project)]
        host.tabsElsewhere = [TabSnapshot(id: "w2", tabId: 9, title: "a", taskId: task, projectId: project)]
        host.onChange?()
        #expect(requests(model) { model.closeTab("t1") }.isEmpty)
        #expect(host.closed == ["t1"])
    }

    @Test func theTaskRowClosesItsCurrentTab() throws {
        let (model, host, project, task) = try model()
        host.tabs = [TabSnapshot(id: "t1", tabId: 1, title: "a", taskId: task, projectId: project),
                     TabSnapshot(id: "t2", tabId: 2, title: "b", taskId: task, projectId: project)]
        host.selectedTabId = "t2"
        host.onChange?()
        model.closeCurrentTab(ofTask: task)
        #expect(host.closed == ["t2"])
        host.selectedTabId = nil
        host.onChange?()
        #expect(requests(model) { model.closeCurrentTab(ofTask: task) } == [.removeTask(task)], "one left: its last")
    }
}
