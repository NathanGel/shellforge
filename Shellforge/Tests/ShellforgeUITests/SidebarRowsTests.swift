import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI

/// The sidebar's rows, as values: what the view draws, in order (AiTerm's `SidebarProjection`).
@MainActor @Suite struct SidebarRowsTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sf-rows-\(UUID().uuidString)")

    private func model(feed: FakeFeed? = nil, host: FakeTerminalHost = FakeTerminalHost()) throws -> (SidebarModel, GitRepoForUI) {
        let repo = try GitRepoForUI()
        return (SidebarModel(host: host, document: WorkspaceDocument(store: WorkspaceStore(folder: folder)), launcher: repo.launcher, feed: feed), repo)
    }

    private func selected(_ rows: [SidebarRow]) -> [String] {
        rows.compactMap {
            switch $0 {
            case .task(let node, true): "task \(node.task.title)"
            case .tab(let tab, true): "tab \(tab.title)"
            default: nil
            }
        }
    }

    private func titles(_ rows: [SidebarRow]) -> [String] {
        rows.map {
            switch $0 {
            case .empty: "empty"
            case .project(let node, _): "project \(node.project.name)"
            case .task(let node, _): "task \(node.task.title)"
            case .tab(let tab, _): "tab \(tab.title)"
            case .otherTabsHeading: "other tabs"
            }
        }
    }

    @Test func anEmptyWorkspaceShowsTheEmptyState() throws {
        let (model, _) = try model()
        #expect(titles(model.rows) == ["empty"])
    }

    @Test func aCollapsedProjectHidesItsTasks() async throws {
        let (model, repo) = try model()
        await model.addProject(folder: repo.path)
        await model.newTask(title: "Fix login", in: try #require(model.tree.projects.first).id)
        #expect(titles(model.rows) == ["project repo", "task Fix login"])
        model.toggleCollapsed(try #require(model.tree.projects.first).id)
        #expect(titles(model.rows) == ["project repo"])
    }

    /// A task with one tab is its tab: no tab row under it. With more, they are listed under the
    /// selected task, and the selection is the current tab's.
    @Test func theSelectedTasksTabsAreListedWhenItHasMoreThanOne() async throws {
        let host = FakeTerminalHost()
        let (model, repo) = try model(host: host)
        await model.addProject(folder: repo.path)
        let project = try #require(model.tree.projects.first).id
        await model.newTask(title: "Alpha", in: project)
        await model.newTask(title: "Beta", in: project)
        #expect(titles(model.rows) == ["project repo", "task Alpha", "task Beta"])
        let beta = try #require(model.selectedTaskId)
        host.openTab(in: repo.path, taskId: beta, projectId: project, title: "Beta 2", command: nil)
        #expect(titles(model.rows) == ["project repo", "task Alpha", "task Beta", "tab Beta", "tab Beta 2"])
    }

    /// One painter, one row: whatever is shown, exactly one row is selected.
    @Test func exactlyOneRowIsSelected() async throws {
        let host = FakeTerminalHost()
        let (model, repo) = try model(host: host)
        await model.addProject(folder: repo.path)
        let project = try #require(model.tree.projects.first).id
        await model.newTask(title: "Alpha", in: project)
        #expect(selected(model.rows) == ["task Alpha"])
        let alpha = try #require(model.selectedTaskId)
        host.openTab(in: repo.path, taskId: alpha, projectId: project, title: "Alpha 2", command: nil)
        #expect(selected(model.rows) == ["tab Alpha 2"])
        host.tabs.append(TabSnapshot(id: "s9", tabId: 9, title: "zsh", taskId: nil, projectId: nil))
        host.userSwitched(to: "s9")
        #expect(selected(model.rows) == ["tab zsh"])
        #expect(model.selectedTaskId == nil, "a tab of no task shows no task")
    }

    @Test func otherTabsShowEvenWithNoProject() {
        let host = FakeTerminalHost()
        host.tabs = [TabSnapshot(id: "s9", tabId: 9, title: "zsh", taskId: nil, projectId: nil)]
        let model = SidebarModel(host: host, document: WorkspaceDocument(store: WorkspaceStore(folder: folder)), launcher: CommandLauncher())
        #expect(titles(model.rows) == ["empty", "other tabs", "tab zsh"])
    }

    @Test func aNewTaskUnfoldsItsProject() async throws {
        let (model, repo) = try model()
        await model.addProject(folder: repo.path)
        let project = try #require(model.tree.projects.first).id
        model.toggleCollapsed(project)
        await model.newTask(title: "Fix login", in: project)
        #expect(titles(model.rows) == ["project repo", "task Fix login"])
    }

    /// AiTerm's task row shows the agents it was told of, none when there are none; only a tab — a
    /// terminal row in AiTerm — stands for its shell with `>_`.
    @Test func aTaskWithNoSessionShowsNoMarkAndATabItsShell() {
        #expect(TaskRowView.marks([]) == AvatarGroup(marks: [], overflow: 0))
        #expect(TabRowView.marks([]) == AvatarGroup(marks: [.shell], overflow: 0))
    }

    @Test func tabsOfNoTaskComeUnderOtherTabs() async throws {
        let host = FakeTerminalHost()
        host.tabs = [TabSnapshot(id: "s9", tabId: 9, title: "zsh", taskId: nil, projectId: nil)]
        let (model, repo) = try model(host: host)
        await model.addProject(folder: repo.path)
        #expect(titles(model.rows) == ["project repo", "other tabs", "tab zsh"])
    }

    @Test func avatarsShowOneAndCountTheRestBeyondTwo() {
        #expect(AvatarGroup.of([.claude, .codex]) == AvatarGroup(marks: [.claude, .codex], overflow: 0))
        #expect(AvatarGroup.of([.claude, .codex, .grok]) == AvatarGroup(marks: [.claude], overflow: 2))
        #expect(AvatarGroup.of([]) == AvatarGroup(marks: [], overflow: 0))
    }
}

/// A folded project still says what its tasks are doing: AiTerm's status count chips.
@Suite struct StatusCountTests {
    @Test func countsKeepAiTermsOrderAndLeaveOutEmptyStatuses() {
        #expect(StatusCount.of([.done, .needsInput, .done, .working]) ==
                [StatusCount(status: .working, count: 1), StatusCount(status: .needsInput, count: 1), StatusCount(status: .done, count: 2)])
        #expect(StatusCount.of([]).isEmpty)
    }

    @Test func theCountsReadAsASentence() {
        #expect(StatusCount.label([StatusCount(status: .needsInput, count: 1), StatusCount(status: .done, count: 2)]) == "1 needs input, 2 done")
        #expect(StatusCount.label([StatusCount(status: .needsInput, count: 3)]) == "3 need input")
    }
}
