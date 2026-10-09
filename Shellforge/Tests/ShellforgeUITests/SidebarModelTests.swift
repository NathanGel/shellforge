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

    private func model(_ host: FakeTerminalHost, repo: GitRepoForUI, document: WorkspaceDocument? = nil) -> SidebarModel {
        SidebarModel(host: host, document: document ?? WorkspaceDocument(store: WorkspaceStore(folder: folder)), launcher: repo.launcher)
    }

    @Test func addingAProjectListsItAndSavesIt() async throws {
        let repo = try GitRepoForUI()
        let host = FakeTerminalHost()
        let sidebar = model(host, repo: repo)
        await sidebar.addProject(folder: repo.path)
        #expect(sidebar.tree.projects.map(\.project.name) == ["repo"])
        #expect(try WorkspaceStore(folder: folder).load().workspace.projects.count == 1)
    }

    @Test func aNewTaskGetsAWorktreeAndATabTaggedWithIt() async throws {
        let repo = try GitRepoForUI()
        let host = FakeTerminalHost()
        let sidebar = model(host, repo: repo)
        await sidebar.addProject(folder: repo.path)
        let project = try #require(sidebar.tree.projects.first).project
        await sidebar.newTask(title: "Fix login", in: project.id)
        let task = try #require(sidebar.tree.projects.first?.tasks.first).task
        #expect(host.opened.map(\.directory) == [task.worktreePath])
        #expect(host.opened.first?.taskId == task.id)
        #expect(sidebar.selectedTaskId == task.id)
        #expect(sidebar.tree.projects[0].tasks[0].tabs.count == 1)
    }

    @Test func selectingATaskSelectsItsFirstTab() async throws {
        let (sidebar, host, first, _) = try await twoTasks()
        sidebar.select(task: first)
        #expect(host.selectedTabId == sidebar.tree.projects[0].tasks.first { $0.id == first }?.tabs.first?.id)
        #expect(sidebar.selectedTaskId == first)
    }

    @Test func whenITerm2SwitchesTabsTheSidebarFollows() async throws {
        let (sidebar, host, first, second) = try await twoTasks()
        sidebar.select(task: first)
        let otherTab = try #require(sidebar.tree.projects[0].tasks.first { $0.id == second }?.tabs.first)
        host.userSwitched(to: otherTab.id)
        #expect(sidebar.selectedTaskId == second)
    }

    @Test func aTaskWhoseLastTabClosedStaysAndReopensOnSelect() async throws {
        let (sidebar, host, first, _) = try await twoTasks()
        let tab = try #require(sidebar.tree.projects[0].tasks.first { $0.id == first }?.tabs.first)
        host.close(tab.id)
        #expect(sidebar.tree.projects[0].tasks.first { $0.id == first }?.tabs == [])
        sidebar.select(task: first)
        #expect(host.opened.last?.taskId == first)
        #expect(sidebar.selectedTaskId == first)
    }

    @Test func aFailureIsShownNotThrown() async throws {
        let repo = try GitRepoForUI()
        let sidebar = model(FakeTerminalHost(), repo: repo)
        await sidebar.addProject(folder: "/")
        #expect(sidebar.lastError?.contains("not a git repository") == true)
        #expect(sidebar.tree.projects.isEmpty)
    }

    /// Every window's sidebar shares one workspace: what one window adds, the other shows, and
    /// neither save drops the other's change.
    @Test func twoWindowsShareOneWorkspace() async throws {
        let (repoA, repoB) = (try GitRepoForUI(), try GitRepoForUI())
        let document = WorkspaceDocument(store: WorkspaceStore(folder: folder))
        let windowA = model(FakeTerminalHost(), repo: repoA, document: document)
        let windowB = model(FakeTerminalHost(), repo: repoB, document: document)
        await windowA.addProject(folder: repoA.path)
        #expect(windowB.tree.projects.count == 1)
        await windowB.addProject(folder: repoB.path)
        #expect(windowA.tree.projects.count == 2)
        #expect(try WorkspaceStore(folder: folder).load().workspace.projects.count == 2)
    }

    /// git runs a checkout and the repository's hooks; on the main thread it would freeze every window.
    @Test func gitRunsOffTheMainThread() async throws {
        let repo = try GitRepoForUI()
        let calls = MainThreadRecorder()
        let launcher = CommandLauncher {
            calls.record(Thread.isMainThread)
            return repo.launcher.environment
        }
        let sidebar = SidebarModel(host: FakeTerminalHost(), document: WorkspaceDocument(store: WorkspaceStore(folder: folder)), launcher: launcher)
        await sidebar.addProject(folder: repo.path)
        #expect(calls.values == [false])
        #expect(sidebar.tree.projects.count == 1)
    }

    /// A workspace that could not be loaded must not be saved over: the damaged file is the user's data.
    @Test func afterAFailedLoadNothingIsSaved() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("workspace.json")
        try "{ damaged".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        let repo = try GitRepoForUI()
        let sidebar = model(FakeTerminalHost(), repo: repo)
        #expect(sidebar.lastError != nil)
        await sidebar.addProject(folder: repo.path)
        #expect(sidebar.tree.projects.isEmpty)
        #expect(try String(contentsOf: file, encoding: .utf8) == "{ damaged")
    }

    private func twoTasks() async throws -> (SidebarModel, FakeTerminalHost, UUID, UUID) {
        let repo = try GitRepoForUI()
        let host = FakeTerminalHost()
        let sidebar = model(host, repo: repo)
        await sidebar.addProject(folder: repo.path)
        let project = try #require(sidebar.tree.projects.first).project
        await sidebar.newTask(title: "One", in: project.id)
        await sidebar.newTask(title: "Two", in: project.id)
        let ids = sidebar.tree.projects[0].tasks.map(\.id)
        return (sidebar, host, ids[0], ids[1])
    }
}

/// Which threads a closure ran on, from any thread.
final class MainThreadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Bool] = []
    func record(_ isMain: Bool) { lock.withLock { recorded.append(isMain) } }
    var values: [Bool] { lock.withLock { recorded } }
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
