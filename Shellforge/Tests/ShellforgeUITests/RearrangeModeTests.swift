import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

/// Rearrange mode in the sidebar: a draft held until Done, one window at a time, no commands meanwhile.
@MainActor @Suite struct RearrangeModeTests {
    @MainActor private struct Setup {
        let first: SidebarModel, second: SidebarModel, document: WorkspaceDocument, host: FakeTerminalHost, folder: URL
        let a: Project, task: TaskItem, terminal: TerminalItem
    }

    private func model(_ host: FakeTerminalHost, _ document: WorkspaceDocument) -> SidebarModel {
        let launcher = CommandLauncher(resolve: { ResolvedEnvironment(variables: ["PATH": "/usr/bin"], source: .loginShell("/bin/zsh")) })
        return SidebarModel(host: host, document: document, launcher: launcher, jiraSettings: { nil })
    }

    private func setup() throws -> Setup {
        let folder = TestScratch.root.appendingPathComponent("shellforge-rearrange-\(UUID().uuidString)")
        let document = WorkspaceDocument(store: WorkspaceStore(folder: folder))
        let a = Project(name: "api", path: "/api")
        let task = TaskItem(projectId: a.id, title: "Fix login", branch: "fix-login", worktreePath: "/api-worktrees/fix-login", baseBranch: "main")
        let terminal = TerminalItem(projectId: a.id, name: "Terminal")
        try document.update { w in
            w.projects.append(a); w.addTask(task); w.addTerminal(terminal)
        }
        let host = FakeTerminalHost()
        return Setup(first: model(host, document), second: model(FakeTerminalHost(), document), document: document, host: host, folder: folder,
                     a: a, task: task, terminal: terminal)
    }

    @Test func doneSavesTheDraft() throws {
        let s = try setup()
        let before = s.document.workspace.children(in: s.a.id)
        s.first.beginRearrange()
        #expect(s.first.isRearranging)
        #expect(s.first.moveInDraft(.child(project: s.a.id, .terminal(s.terminal.id)), before: .child(project: s.a.id, .task(s.task.id))))
        #expect(s.document.workspace.children(in: s.a.id) == before, "nothing is written before Done")
        s.first.finishRearrange()
        #expect(!s.first.isRearranging)
        #expect(s.document.workspace.children(in: s.a.id) == [.terminal(s.terminal.id), .task(s.task.id)])
        #expect(s.second.canRearrange)
    }

    @Test func cancelChangesNothing() throws {
        let s = try setup()
        let before = s.document.workspace
        s.first.beginRearrange()
        _ = s.first.moveInDraft(.child(project: s.a.id, .terminal(s.terminal.id)), before: .child(project: s.a.id, .task(s.task.id)))
        s.first.cancelRearrange()
        #expect(!s.first.isRearranging)
        #expect(s.document.workspace == before)
        #expect(s.second.canRearrange)
    }

    @Test func oneWindowAtATime() throws {
        let s = try setup()
        #expect(s.first.canRearrange && s.second.canRearrange)
        s.first.beginRearrange()
        #expect(!s.second.canRearrange)
        #expect(!s.first.canRearrange, "already rearranging")
        s.second.beginRearrange()
        #expect(!s.second.isRearranging)
        s.first.finishRearrange()
        #expect(s.second.canRearrange)
    }

    @Test func aClosedRearrangingWindowFreesTheLock() throws {
        let s = try setup()
        var closing: SidebarModel? = model(FakeTerminalHost(), s.document)
        closing?.beginRearrange()
        #expect(!s.second.canRearrange)
        closing = nil
        #expect(s.second.canRearrange)
    }

    @Test func commandsAreOffWhileRearranging() throws {
        let s = try setup()
        let commands: [SidebarCommand] = [.newTask, .newReview, .newTerminal, .addProject, .addDivider, .removeTask,
                                          .nextTask, .previousTask, .focusView, .listView]
        s.host.openTab(in: s.task.worktreePath, taskId: s.task.id, projectId: s.a.id, title: "claude", command: nil, environment: [:])
        s.first.select(task: s.task.id)
        let on = commands.filter { s.first.can($0) }
        s.first.beginRearrange()
        #expect(commands.allSatisfy { !s.first.can($0) })
        s.first.cancelRearrange()
        #expect(commands.filter { s.first.can($0) } == on)
        #expect(!on.isEmpty)
    }

    @Test func rowsWhileRearrangingHaveNoTabs() throws {
        let s = try setup()
        s.host.tabs = [TabSnapshot(id: "t1", tabId: 1, title: "a", taskId: s.task.id, projectId: s.a.id),
                       TabSnapshot(id: "t2", tabId: 2, title: "b", taskId: s.task.id, projectId: s.a.id),
                       TabSnapshot(id: "o1", tabId: 3, title: "zsh", taskId: nil, projectId: nil)]
        s.host.selectedTabId = "t1"
        s.host.onChange?()
        #expect(s.first.rows.contains { if case .tab = $0 { true } else { false } })
        s.first.beginRearrange()
        let ids = s.first.rows.map(\.id)
        #expect(ids == ["project-\(s.a.id)", "task-\(s.task.id)", "terminal-\(s.terminal.id)"])
    }

    @Test func rowsFollowTheDraftsOrder() throws {
        let s = try setup()
        s.first.beginRearrange()
        _ = s.first.moveInDraft(.child(project: s.a.id, .terminal(s.terminal.id)), before: .child(project: s.a.id, .task(s.task.id)))
        #expect(s.first.rows.map(\.id) == ["project-\(s.a.id)", "terminal-\(s.terminal.id)", "task-\(s.task.id)"])
    }

    /// A save that fails on Done keeps the mode (and the draft) open and says why; Cancel still leaves.
    @Test func aFailedSaveKeepsTheModeOpenAndSaysWhy() throws {
        let s = try setup()
        s.first.beginRearrange()
        _ = s.first.moveInDraft(.child(project: s.a.id, .terminal(s.terminal.id)), before: .child(project: s.a.id, .task(s.task.id)))
        // A file where the workspace folder was: the save cannot create it.
        try FileManager.default.removeItem(at: s.folder)
        try Data().write(to: s.folder)
        s.first.finishRearrange()
        #expect(s.first.isRearranging)
        #expect(s.first.lastError != nil)
        #expect(s.first.rearrange?.children[s.a.id] == [.terminal(s.terminal.id), .task(s.task.id)], "the draft is kept")
        #expect(!s.second.canRearrange, "the lock is kept")
        s.first.cancelRearrange()
        #expect(!s.first.isRearranging)
        #expect(s.second.canRearrange)
    }

    @Test func newHomeTabStaysEnabledWhileRearranging() throws {
        let s = try setup()
        s.first.beginRearrange()
        #expect(s.first.can(.newHomeTab))
    }

    @Test func aCollapsedProjectShowsOnlyItsHeaderWhileRearranging() throws {
        let s = try setup()
        try s.document.update { $0.projects[0].collapsed = true }
        s.first.beginRearrange()
        #expect(s.first.rows.map(\.id) == ["project-\(s.a.id)"])
    }
}
