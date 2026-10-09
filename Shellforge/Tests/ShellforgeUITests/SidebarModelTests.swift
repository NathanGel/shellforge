import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI

/// Stands in for one iTerm2 window: a list of tabs, the selected one, and the calls made.
@MainActor final class FakeTerminalHost: TerminalHost {
    var tabs: [TabSnapshot] = []
    var selectedTabId: String?
    var onChange: (@MainActor () -> Void)?
    var opened: [(directory: String, taskId: UUID, projectId: UUID, title: String)] = []
    /// Ids are never reused, as iTerm2's are not, even after a tab closes.
    private var nextTab = 0

    func select(tab id: String) {
        selectedTabId = id
        onChange?()
    }

    func openTab(in directory: String, taskId: UUID, projectId: UUID, title: String) {
        opened.append((directory, taskId, projectId, title))
        nextTab += 1
        let tab = TabSnapshot(id: "s\(nextTab)", tabId: nextTab, title: title, taskId: taskId, projectId: projectId)
        tabs.append(tab)
        selectedTabId = tab.id
        onChange?()
    }

    /// iTerm2 switching tabs on its own, as Cmd-Shift-] does.
    func userSwitched(to id: String) {
        selectedTabId = id
        onChange?()
    }

    func close(_ id: String) {
        tabs.removeAll { $0.id == id }
        selectedTabId = tabs.first?.id
        onChange?()
    }
}

@MainActor @Suite struct SidebarModelTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shellforge-model-\(UUID().uuidString)")

    private func model(_ host: FakeTerminalHost, repo: GitRepoForUI) -> SidebarModel {
        SidebarModel(host: host, store: WorkspaceStore(folder: folder), launcher: repo.launcher)
    }

    @Test func addingAProjectListsItAndSavesIt() throws {
        let repo = try GitRepoForUI()
        let host = FakeTerminalHost()
        let sidebar = model(host, repo: repo)
        sidebar.addProject(folder: repo.path)
        #expect(sidebar.tree.projects.map(\.project.name) == ["repo"])
        #expect(try WorkspaceStore(folder: folder).load().workspace.projects.count == 1)
    }

    @Test func aNewTaskGetsAWorktreeAndATabTaggedWithIt() throws {
        let repo = try GitRepoForUI()
        let host = FakeTerminalHost()
        let sidebar = model(host, repo: repo)
        sidebar.addProject(folder: repo.path)
        let project = try #require(sidebar.tree.projects.first).project
        sidebar.newTask(title: "Fix login", in: project.id)
        let task = try #require(sidebar.tree.projects.first?.tasks.first).task
        #expect(host.opened.map(\.directory) == [task.worktreePath])
        #expect(host.opened.first?.taskId == task.id)
        #expect(sidebar.selectedTaskId == task.id)
        #expect(sidebar.tree.projects[0].tasks[0].tabs.count == 1)
    }

    @Test func selectingATaskSelectsItsFirstTab() throws {
        let (sidebar, host, first, _) = try twoTasks()
        sidebar.select(task: first)
        #expect(host.selectedTabId == sidebar.tree.projects[0].tasks.first { $0.id == first }?.tabs.first?.id)
        #expect(sidebar.selectedTaskId == first)
    }

    @Test func whenITerm2SwitchesTabsTheSidebarFollows() throws {
        let (sidebar, host, first, second) = try twoTasks()
        sidebar.select(task: first)
        let otherTab = try #require(sidebar.tree.projects[0].tasks.first { $0.id == second }?.tabs.first)
        host.userSwitched(to: otherTab.id)
        #expect(sidebar.selectedTaskId == second)
    }

    @Test func aTaskWhoseLastTabClosedStaysAndReopensOnSelect() throws {
        let (sidebar, host, first, _) = try twoTasks()
        let tab = try #require(sidebar.tree.projects[0].tasks.first { $0.id == first }?.tabs.first)
        host.close(tab.id)
        #expect(sidebar.tree.projects[0].tasks.first { $0.id == first }?.tabs == [])
        sidebar.select(task: first)
        #expect(host.opened.last?.taskId == first)
        #expect(sidebar.selectedTaskId == first)
    }

    @Test func aFailureIsShownNotThrown() throws {
        let repo = try GitRepoForUI()
        let sidebar = model(FakeTerminalHost(), repo: repo)
        sidebar.addProject(folder: "/")
        #expect(sidebar.lastError?.contains("not a git repository") == true)
        #expect(sidebar.tree.projects.isEmpty)
    }

    private func twoTasks() throws -> (SidebarModel, FakeTerminalHost, UUID, UUID) {
        let repo = try GitRepoForUI()
        let host = FakeTerminalHost()
        let sidebar = model(host, repo: repo)
        sidebar.addProject(folder: repo.path)
        let project = try #require(sidebar.tree.projects.first).project
        sidebar.newTask(title: "One", in: project.id)
        sidebar.newTask(title: "Two", in: project.id)
        let ids = sidebar.tree.projects[0].tasks.map(\.id)
        return (sidebar, host, ids[0], ids[1])
    }
}

/// `GitRepoFixture` lives in the Core tests, which this target cannot import; a copy for UI tests.
struct GitRepoForUI {
    let path: String
    let launcher: CommandLauncher

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shellforge-uirepo-\(UUID().uuidString)").path
        path = "\(root)/repo"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let env = ["PATH": "/usr/bin:/bin", "HOME": root, "GIT_CONFIG_NOSYSTEM": "1",
                   "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"]
        launcher = CommandLauncher { ResolvedEnvironment(variables: env, source: .loginShell("/bin/sh")) }
        for args in [["init", "-q", "-b", "main"], ["commit", "-q", "--allow-empty", "-m", "first"]] {
            let out = try launcher.run("git", ["-C", path] + args)
            guard out.status == 0 else { throw GitFailure(command: "git", message: out.stderr) }
        }
    }
}
