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
        #expect(titles(model.rows) == ["project repo", "task Fix login", "tab Fix login"])
        model.toggleCollapsed(try #require(model.tree.projects.first).id)
        #expect(titles(model.rows) == ["project repo"])
    }

    @Test func theSelectedTaskShowsItsTabsAndOthersDoNot() async throws {
        let (model, repo) = try model()
        await model.addProject(folder: repo.path)
        let project = try #require(model.tree.projects.first).id
        await model.newTask(title: "Alpha", in: project)
        await model.newTask(title: "Beta", in: project)
        #expect(titles(model.rows) == ["project repo", "task Alpha", "task Beta", "tab Beta"])
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
