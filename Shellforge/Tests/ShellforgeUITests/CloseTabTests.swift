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
        let folder = TestScratch.root.appendingPathComponent("shellforge-close-\(UUID().uuidString)")
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
        #expect(requests(model) { model.closeTab("t1") } == [.closeLastTab(task: task, tab: "t1")])
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
        #expect(requests(model) { model.closeCurrentTab(ofTask: task) } == [.closeLastTab(task: task, tab: "t1")], "one left: its last")
    }

    /// Focusing another pane of the current tab changes the session iTerm2 names it by, with no
    /// refresh: the task row still closes that tab, found by its tab id, not its first.
    @Test func theTaskRowFindsTheCurrentTabAfterAPaneChange() throws {
        let (model, host, project, task) = try model()
        host.tabs = [TabSnapshot(id: "t1", tabId: 1, title: "a", taskId: task, projectId: project),
                     TabSnapshot(id: "t2", tabId: 2, title: "b", taskId: task, projectId: project)]
        host.selectedTabId = "t2"
        host.onChange?()
        host.tabs[1] = TabSnapshot(id: "t2-pane", tabId: 2, title: "b", taskId: task, projectId: project)
        host.selectedTabId = "t2-pane"
        model.closeCurrentTab(ofTask: task)
        #expect(host.closed == ["t2-pane"], "tab 2, by the name the window has for it now")
    }

    // -- M4f: panes --

    private func split(_ id: String, _ tabId: Int, task: UUID?, project: UUID?, panes: Int) -> TabSnapshot {
        var tab = TabSnapshot(id: id, tabId: tabId, title: "t", taskId: task, projectId: project)
        tab.paneCount = panes
        return tab
    }

    /// The agent and a ⌘D pane beside it: one tab, two panes. Close Pane closes the focused pane.
    @Test func aSplitTaskTabClosesItsFocusedPane() throws {
        let (model, host, project, task) = try model()
        host.tabs = [split("t1", 1, task: task, project: project, panes: 2)]
        host.onChange?()
        #expect(requests(model) { model.closeTab("t1") }.isEmpty, "the task keeps a pane: nothing to remove")
        #expect(host.closedPanes == ["t1"] && host.closed.isEmpty)
    }

    @Test func aTaskWithTwoPanesClosesAPaneWithoutAsking() throws {
        let (model, host, project, task) = try model()
        host.tabs = [split("t1", 1, task: task, project: project, panes: 2)]
        host.onChange?()
        #expect(requests(model) { model.closeCurrentTab(ofTask: task) }.isEmpty)
        #expect(host.closedPanes == ["t1"])
    }

    @Test func aTasksLastPaneAsks() throws {
        let (model, host, project, task) = try model()
        host.tabs = [split("t1", 1, task: task, project: project, panes: 2)]
        host.onChange?()
        model.closeTab("t1")
        #expect(requests(model) { model.closeTab("t1") } == [.closeLastTab(task: task, tab: "t1")], "one pane left: its last")
    }

    @Test func aSplitOtherTabClosesAPane() throws {
        let (model, host, _, _) = try model()
        host.tabs = [split("o1", 1, task: nil, project: nil, panes: 2)]
        host.onChange?()
        model.closeTab("o1")
        #expect(host.closedPanes == ["o1"] && host.closed.isEmpty)
    }

    @Test func theMenuSaysPaneOnASplitTab() throws {
        let (model, host, project, task) = try model()
        host.tabs = [split("t1", 1, task: task, project: project, panes: 2)]
        host.onChange?()
        #expect(model.closeTitle(ofTab: "t1") == "Close Pane" && model.closeTitle(ofTask: task) == "Close Pane")
        model.closeTab("t1")
        #expect(model.closeTitle(ofTab: "t1") == "Close Tab")
    }

    /// Another task's tab is in front: the task row brings its own tab forward before closing a
    /// pane of it, so the pane closed is one the user sees.
    @Test func theTaskRowShowsItsTabBeforeClosingAPane() throws {
        let (model, host, project, task) = try model()
        let other = UUID()
        host.tabs = [split("t1", 1, task: task, project: project, panes: 2),
                     TabSnapshot(id: "b1", tabId: 2, title: "b", taskId: other, projectId: project)]
        host.selectedTabId = "b1"
        host.onChange?()
        model.closeCurrentTab(ofTask: task)
        #expect(host.selectedTabId == "t1")
        #expect(host.closedPanes == ["t1"])
    }

    /// Focusing the other pane of a split tab renames the tab's session with no refresh: Close Pane
    /// from the row still finds the tab, by its tab id, and closes a pane, not the whole tab.
    @Test func closePaneFindsTheTabAfterTheFocusMoved() throws {
        let (model, host, _, _) = try model()
        host.tabs = [split("o1", 1, task: nil, project: nil, panes: 2)]
        host.onChange?()
        host.tabs[0].id = "o1-other-pane"
        model.closeTab("o1")
        #expect(host.closedPanes == ["o1-other-pane"] && host.closed.isEmpty)
    }

    /// One tab, two panes: this task's and another's. Closing this task's only pane asks Remove,
    /// and the removal will close the pane, not the tab the other task shares.
    @Test func aTasksLastPaneInASharedTabAsks() throws {
        let (model, host, project, task) = try model()
        host.tabs = [split("t1", 1, task: task, project: project, panes: 2)]
        host.taggedPanes = [task: 1]
        host.onChange?()
        #expect(requests(model) { model.closeTab("t1") } == [.closeLastTab(task: task, tab: "t1", paneOnly: true)])
        #expect(host.closedPanes.isEmpty)
    }
}
