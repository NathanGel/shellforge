import Combine
import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

/// Stands in for one iTerm2 window: a list of tabs, the selected one, and the calls made.
@MainActor final class FakeTerminalHost: TerminalHost {
    var tabs: [TabSnapshot] = []
    var selectedTabId: String?
    var onChange: (@MainActor () -> Void)?
    var opened: [(directory: String, taskId: UUID, projectId: UUID, title: String, command: String?, environment: [String: String],
                  beside: String?)] = []
    var onSplitRefused: (@MainActor @Sendable (String) -> Void)?
    /// iTerm2 refusing the split: a tmux tab, a window too small.
    var refusesSplit = false
    /// Ids are never reused, as iTerm2's are not, even after a tab closes.
    var nextTab = 0

    func select(tab id: String) {
        selectedTabId = id
        onChange?()
    }

    /// Other windows' tabs, for what is a task's last tab.
    var tabsElsewhere: [TabSnapshot] = []
    var closed: [String] = []
    /// iTerm2's running-job alert answered Cancel.
    var refusesClose = false
    func close(tab id: String) -> Bool {
        guard !refusesClose else { return false }
        closed.append(id)
        tabs.removeAll { $0.id == id }
        if selectedTabId == id { selectedTabId = nil }
        onChange?()
        return true
    }
    func paneCount(ofTask id: UUID) -> Int { (tabs + tabsElsewhere).filter { $0.taskId == id }.map(\.paneCount).reduce(0, +) }
    /// The tabs whose focused pane was closed, by their active session.
    var closedPanes: [String] = []
    func closePane(ofTab id: String) -> Bool {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return false }
        closedPanes.append(id)
        tabs[i].paneCount -= 1
        onChange?()
        return true
    }

    func openTab(in directory: String, taskId: UUID, projectId: UUID, title: String, command: String?, environment: [String: String],
                 beside: String?) {
        opened.append((directory, taskId, projectId, title, command, environment, beside))
        if beside != nil, refusesSplit { onSplitRefused?(title) }
        nextTab += 1
        let tab = TabSnapshot(id: "s\(nextTab)", tabId: nextTab, title: title, taskId: taskId, projectId: projectId)
        tabs.append(tab)
        selectedTabId = tab.id
        onChange?()
    }

    /// The tabs of no task opened: a tunnel answered in a tab.
    var openedPlain: [(directory: String, title: String, command: String)] = []

    func openTab(in directory: String, title: String, command: String) {
        openedPlain.append((directory, title, command))
    }

    /// The terminal tabs opened, and the terminals whose tabs were asked to close.
    var openedTerminals: [(directory: String, terminalId: UUID, projectId: UUID, title: String)] = []
    var closedTerminals: [UUID] = []

    func openTab(in directory: String, terminalId: UUID, projectId: UUID, title: String) {
        openedTerminals.append((directory, terminalId, projectId, title))
        nextTab += 1
        let tab = TabSnapshot(id: "s\(nextTab)", tabId: nextTab, title: title, taskId: nil, projectId: projectId, terminalId: terminalId)
        tabs.append(tab)
        selectedTabId = tab.id
        onChange?()
    }

    func closeTabs(ofTerminal id: UUID) -> Bool {
        closedTerminals.append(id)
        guard closesTabs else { return false }
        tabs.removeAll { $0.terminalId == id }
        onChange?()
        return true
    }

    /// The tasks whose tabs were asked to close, and whether they then did.
    var closedTasks: [UUID] = []
    var closesTabs = true

    func closeTabs(ofTask id: UUID) -> Bool {
        closedTasks.append(id)
        guard closesTabs else { return false }
        tabs.removeAll { $0.taskId == id }
        onChange?()
        return true
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

/// Stands in for the app's `DaemonLink`: the helper's status and what the daemon says, set by hand.
@MainActor final class FakeFeed: SessionFeed {
    @Published var status: HelperStatus = .connected
    @Published var store = SessionStore()
    var seen: [UUID] = []
    var statusPublisher: AnyPublisher<HelperStatus, Never> { $status.eraseToAnyPublisher() }
    var storePublisher: AnyPublisher<SessionStore, Never> { $store.eraseToAnyPublisher() }
    @Published var tunnelError: String?
    var tunnelErrorPublisher: AnyPublisher<String?, Never> { $tunnelError.eraseToAnyPublisher() }
    func markSeen(task: UUID) { seen.append(task) }
    var seenSessions: [[String]] = []
    func markSeen(sessions: [String]) { seenSessions.append(sessions) }
    var tunnelCalls: [String] = []
    func startTunnel(alias: String, keepRunning: Bool) { tunnelCalls.append("start \(alias)" + (keepRunning ? " (keep)" : "")) }
    func stopTunnel(alias: String) { tunnelCalls.append("stop \(alias)") }
    func holdTunnel(alias: String, port: Int, bind: String?) {
        tunnelCalls.append("hold \(alias) \(port)" + (bind.map { " at \($0)" } ?? ""))
    }

    /// The daemon saying, at once, each session's state and agent, each in a tab of its own.
    func sayAll(_ sessions: [(state: SessionState, session: String, task: UUID, agent: SessionAgent)]) {
        var next = SessionStore()
        next.apply(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true, sessions: sessions.enumerated().map { index, s in
            SessionInfo(sessionId: s.session, windowId: "w", tabIndex: index, taskId: s.task.uuidString.lowercased(), projectId: nil,
                        agent: s.agent, model: nil, state: s.state, title: "t", cwd: "/wt")
        }, usage: .empty)))
        store = next
    }

    /// The daemon saying `state` for one session of `task`.
    func say(_ state: SessionState, session: String, task: UUID) {
        var next = SessionStore()
        next.apply(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true, sessions: [
            SessionInfo(sessionId: session, windowId: "w", tabIndex: 0, taskId: task.uuidString.lowercased(), projectId: nil,
                        agent: .claude, model: nil, state: state, title: "claude", cwd: "/wt")
        ], usage: .empty)))
        store = next
    }
}

@MainActor @Suite struct SidebarModelTests {
    private let folder = TestScratch.root.appendingPathComponent("shellforge-model-\(UUID().uuidString)")

    /// AiTerm's setJiraProjects: a project is linked once, in order; an empty list unlinks; it is saved.
    @Test func linkingKeepsEachJiraProjectOnceAndAnEmptyListUnlinks() async throws {
        let repo = try GitRepoForUI()
        let document = WorkspaceDocument(store: WorkspaceStore(folder: folder))
        let sidebar = SidebarModel(host: FakeTerminalHost(), document: document, launcher: repo.launcher, jiraSettings: { nil })
        await sidebar.addProject(folder: repo.path)
        let id = try #require(document.workspace.projects.first?.id)
        let site = URL(string: "https://example.atlassian.net")!
        let shop = JiraProjectRef(id: "10001", key: "SHOP", name: "Storefront", siteURL: site)
        let pay = JiraProjectRef(id: "10002", key: "PAY", name: "Payments", siteURL: site)

        sidebar.setJiraProjects([shop, pay, shop], on: id)
        #expect(document.workspace.projects[0].jiraProjects == [shop, pay], "a project is linked once")
        #expect(try WorkspaceStore(folder: folder).load().workspace.projects[0].jiraProjects == [shop, pay])

        sidebar.setJiraProjects([], on: id)
        #expect(document.workspace.projects[0].jiraProjects.isEmpty)
        #expect(try WorkspaceStore(folder: folder).load().workspace.projects[0].jiraProjects.isEmpty)
    }

    @Test func withoutJiraTheProjectListSaysHow() async throws {
        let repo = try GitRepoForUI()
        let sidebar = SidebarModel(host: FakeTerminalHost(), document: WorkspaceDocument(store: WorkspaceStore(folder: folder)),
                                   launcher: repo.launcher, jiraSettings: { nil })
        await #expect { _ = try await sidebar.loadJiraProjects() } throws: {
            ($0 as? ActionUnavailable)?.message == "Connect Jira in Settings to choose a Jira project."
        }
    }

    private func model(_ host: FakeTerminalHost, repo: GitRepoForUI, document: WorkspaceDocument? = nil) -> SidebarModel {
        SidebarModel(host: host, document: document ?? WorkspaceDocument(store: WorkspaceStore(folder: folder)), launcher: repo.launcher, jiraSettings: { nil })
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
    /// The first read, init's, has no git on PATH: `addProject`'s git misses, and its re-read is the
    /// second read recorded, not one init made for it.
    @Test func gitRunsOffTheMainThread() async throws {
        let repo = try GitRepoForUI()
        let calls = MainThreadRecorder()
        let launcher = CommandLauncher {
            calls.record(Thread.isMainThread)
            if calls.values.count == 1 { return ResolvedEnvironment(variables: ["PATH": "/nowhere"], source: .loginShell("/bin/zsh")) }
            return repo.launcher.environment
        }
        let sidebar = SidebarModel(host: FakeTerminalHost(), document: WorkspaceDocument(store: WorkspaceStore(folder: folder)), launcher: launcher, jiraSettings: { nil })
        #expect(await eventually { calls.values.count == 1 }, "init's read has finished")
        await sidebar.addProject(folder: repo.path)
        #expect(calls.values == [false, false])
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

    @Test func aTaskShowsItsMostUrgentTabAndATabItsOwn() async throws {
        let repo = try GitRepoForUI()
        let host = FakeTerminalHost(), feed = FakeFeed()
        let sidebar = SidebarModel(host: host, document: WorkspaceDocument(store: WorkspaceStore(folder: folder)), launcher: repo.launcher, feed: feed, jiraSettings: { nil })
        await sidebar.addProject(folder: repo.path)
        await sidebar.newTask(title: "Fix login", in: try #require(sidebar.tree.projects.first).id)
        let task = try #require(sidebar.selectedTaskId), tab = try #require(host.tabs.first).id
        feed.say(.needsInput, session: tab, task: task)
        #expect(sidebar.status(ofTask: task) == .needsInput)
        #expect(sidebar.status(ofTab: tab) == .needsInput)
    }

    @Test func openingADoneTaskMarksItSeenAndOpeningAnotherDoesNot() async throws {
        let repo = try GitRepoForUI()
        let host = FakeTerminalHost(), feed = FakeFeed()
        let sidebar = SidebarModel(host: host, document: WorkspaceDocument(store: WorkspaceStore(folder: folder)), launcher: repo.launcher, feed: feed, jiraSettings: { nil })
        await sidebar.addProject(folder: repo.path)
        let project = try #require(sidebar.tree.projects.first).id
        await sidebar.newTask(title: "One", in: project)
        let one = try #require(sidebar.selectedTaskId), oneTab = try #require(host.tabs.last).id
        await sidebar.newTask(title: "Two", in: project)
        let two = try #require(sidebar.selectedTaskId)
        feed.say(.done, session: oneTab, task: one)
        #expect(feed.seen.isEmpty)            // done while Two is shown: not seen yet
        sidebar.select(task: two)
        #expect(feed.seen.isEmpty)            // Two is not done
        sidebar.select(task: one)
        #expect(feed.seen == [one])
    }

    @Test func switchingToADoneTasksTabInITerm2MarksItSeen() async throws {
        let repo = try GitRepoForUI()
        let host = FakeTerminalHost(), feed = FakeFeed()
        let sidebar = SidebarModel(host: host, document: WorkspaceDocument(store: WorkspaceStore(folder: folder)), launcher: repo.launcher, feed: feed, jiraSettings: { nil })
        await sidebar.addProject(folder: repo.path)
        let project = try #require(sidebar.tree.projects.first).id
        await sidebar.newTask(title: "One", in: project)
        let one = try #require(sidebar.selectedTaskId), oneTab = try #require(host.tabs.last).id
        await sidebar.newTask(title: "Two", in: project)
        feed.say(.done, session: oneTab, task: one)
        host.userSwitched(to: oneTab)
        #expect(feed.seen == [one])
    }

    @Test func openingTheDoneTabOfTheShownTaskMarksItSeen() async throws {
        let repo = try GitRepoForUI()
        let host = FakeTerminalHost(), feed = FakeFeed()
        let sidebar = SidebarModel(host: host, document: WorkspaceDocument(store: WorkspaceStore(folder: folder)), launcher: repo.launcher, feed: feed, jiraSettings: { nil })
        await sidebar.addProject(folder: repo.path)
        let project = try #require(sidebar.tree.projects.first).id
        await sidebar.newTask(title: "One", in: project)
        let one = try #require(sidebar.selectedTaskId), first = try #require(host.tabs.last).id
        host.openTab(in: repo.path, taskId: one, projectId: project, title: "second", command: nil, environment: [:])
        let second = try #require(host.tabs.last).id
        host.userSwitched(to: first)
        feed.say(.done, session: second, task: one)
        #expect(feed.seen.isEmpty)            // the task is shown, but not the tab that finished
        host.userSwitched(to: second)
        #expect(feed.seen == [one])
    }

    @Test func theHelpersProblemIsShownAndClearedWhenItConnects() async throws {
        let repo = try GitRepoForUI()
        let feed = FakeFeed()
        let sidebar = SidebarModel(host: FakeTerminalHost(), document: WorkspaceDocument(store: WorkspaceStore(folder: folder)), launcher: repo.launcher, feed: feed, jiraSettings: { nil })
        feed.status = .pythonMissing
        #expect(sidebar.helper == .pythonMissing)
        feed.status = .connected
        #expect(sidebar.helper == .connected)
    }

    @Test func avatarsShowEveryTabsAgentInTabOrder() async throws {
        let repo = try GitRepoForUI()
        let host = FakeTerminalHost(), feed = FakeFeed()
        let sidebar = SidebarModel(host: host, document: WorkspaceDocument(store: WorkspaceStore(folder: folder)), launcher: repo.launcher, feed: feed, jiraSettings: { nil })
        await sidebar.addProject(folder: repo.path)
        await sidebar.newTask(title: "One", in: try #require(sidebar.tree.projects.first).id)
        let task = try #require(sidebar.selectedTaskId)
        feed.sayAll([(.idle, "a", task, .shell), (.working, "b", task, .claude), (.needsInput, "c", task, .codex)])
        #expect(sidebar.avatars(forTask: task) == [.shell, .claude, .codex])   // AiTerm's: in tab order, a shell's ">_" too
        #expect(sidebar.avatars(forTab: "b") == [.claude])
    }

    @Test func avatarsCountEveryAgentTab() async throws {
        let repo = try GitRepoForUI()
        let host = FakeTerminalHost(), feed = FakeFeed()
        let sidebar = SidebarModel(host: host, document: WorkspaceDocument(store: WorkspaceStore(folder: folder)), launcher: repo.launcher, feed: feed, jiraSettings: { nil })
        await sidebar.addProject(folder: repo.path)
        await sidebar.newTask(title: "One", in: try #require(sidebar.tree.projects.first).id)
        let task = try #require(sidebar.selectedTaskId)
        feed.sayAll([(.working, "a", task, .claude), (.working, "b", task, .codex), (.idle, "c", task, .grok)])
        #expect(sidebar.avatars(forTask: task).count == 3)
    }

    @Test func aProjectRemembersItIsCollapsed() async throws {
        let repo = try GitRepoForUI()
        let sidebar = SidebarModel(host: FakeTerminalHost(), document: WorkspaceDocument(store: WorkspaceStore(folder: folder)), launcher: repo.launcher, jiraSettings: { nil })
        await sidebar.addProject(folder: repo.path)
        let id = try #require(sidebar.tree.projects.first).id
        sidebar.toggleCollapsed(id)
        #expect(try WorkspaceStore(folder: folder).load().workspace.projects.first?.collapsed == true)
        sidebar.toggleCollapsed(id)
        #expect(try WorkspaceStore(folder: folder).load().workspace.projects.first?.collapsed == false)
    }

    @Test func aGitHubProjectShowsGitHubsMark() async throws {
        let repo = try GitRepoForUI()
        _ = try repo.launcher.run("/usr/bin/git", ["-C", repo.path, "remote", "add", "origin", "git@github.com:a/b.git"])
        let sidebar = SidebarModel(host: FakeTerminalHost(), document: WorkspaceDocument(store: WorkspaceStore(folder: folder)), launcher: repo.launcher, jiraSettings: { nil })
        await sidebar.addProject(folder: repo.path)
        let id = try #require(sidebar.tree.projects.first).id
        #expect(await eventually { sidebar.providers[id] == .github })
    }

    /// iTerm2 restoring its windows refreshes the sidebar many times before git answers: one lookup per
    /// project, not one per refresh.
    @Test func aProjectsProviderIsLookedUpOnceHoweverOftenTheSidebarRefreshes() async throws {
        let repo = try GitRepoForUI()
        let host = FakeTerminalHost()
        let sidebar = SidebarModel(host: host, document: WorkspaceDocument(store: WorkspaceStore(folder: folder)), launcher: repo.launcher, jiraSettings: { nil })
        await sidebar.addProject(folder: repo.path)
        for _ in 0..<5 { host.onChange?() }
        let id = try #require(sidebar.tree.projects.first).id
        #expect(await eventually { sidebar.providers[id] != nil })
        #expect(sidebar.providerLookups == 1)
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

    /// `installed` are agent CLIs the launcher finds: `exit 0` scripts in a bin of the repository's
    /// own, ahead of git's folder, so what this Mac has installed never decides a test.
    init(installed: [String] = ["claude"]) throws {
        let root = TestScratch.root.appendingPathComponent("shellforge-uirepo-\(UUID().uuidString)").path
        path = "\(root)/repo"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: "\(root)/bin", withIntermediateDirectories: true)
        for name in installed {
            try "#!/bin/sh\nexit 0\n".write(toFile: "\(root)/bin/\(name)", atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: "\(root)/bin/\(name)")
        }
        let env = ["PATH": "\(root)/bin:/usr/bin:/bin", "HOME": root, "GIT_CONFIG_NOSYSTEM": "1",
                   "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"]
        launcher = CommandLauncher { ResolvedEnvironment(variables: env, source: .loginShell("/bin/sh")) }
        for args in [["init", "-q", "-b", "main"], ["commit", "-q", "--allow-empty", "-m", "first"]] {
            let out = try launcher.run("git", ["-C", path] + args)
            guard out.status == 0 else { throw GitFailure(command: "git", message: out.stderr) }
        }
    }
}

extension SidebarModel {
    /// A task as the New Task sheet would create it, for the tests that only need one to exist:
    /// Claude Code on `opus`, named `title`, from `main`.
    func newTask(title: String, in projectId: UUID) async {
        var draft = TaskDraft(baseBranch: "main", agentId: "claude", model: "opus", reasoning: nil)
        draft.setTitle(title)
        try? await newTask(draft: draft, in: projectId)
    }
}

@MainActor @Suite struct NewTaskWiringTests {
    private let folder = TestScratch.root.appendingPathComponent("shellforge-wiring-\(UUID().uuidString)")

    private func modelWithProject(installed: [String] = ["claude"]) async throws -> (SidebarModel, FakeTerminalHost, WorkspaceDocument, UUID) {
        let repo = try GitRepoForUI(installed: installed)
        let host = FakeTerminalHost()
        let document = WorkspaceDocument(store: WorkspaceStore(folder: folder))
        let model = SidebarModel(host: host, document: document, launcher: repo.launcher, catalogue: { _ in [] }, jiraSettings: { nil })
        await model.addProject(folder: repo.path)
        return (model, host, document, try #require(document.workspace.projects.first).id)
    }

    @Test func aNewTaskOpensItsTabRunningTheAgent() async throws {
        let (model, host, document, project) = try await modelWithProject()
        var draft = TaskDraft(baseBranch: "main", agentId: "claude", model: "opus", reasoning: "high")
        draft.setTitle("Login")
        draft.promptText = "fix it"
        try await model.newTask(draft: draft, in: project)
        let opened = try #require(host.opened.last)
        #expect(opened.directory.hasSuffix("/.worktrees/login"))
        #expect(opened.command == "claude --model opus --effort high 'fix it'")
        #expect(document.workspace.lastAgentByProject[project] == "claude")
        #expect(document.workspace.lastModelByAgent["claude"] == "opus")
    }

    @Test func theNextSheetOpensWithTheLastAgentWhileItIsInstalled() async throws {
        let (model, _, document, project) = try await modelWithProject(installed: ["claude", "codex"])
        try document.update { $0.lastAgentByProject[project] = "codex" }
        let sheet = try #require(model.makeNewTaskModel(for: project))
        #expect(sheet.availableAgents == ["claude", "codex"])
        #expect(sheet.draft.agentId == "codex")
        try document.update { $0.lastAgentByProject[project] = "pi" }
        #expect(model.makeNewTaskModel(for: project)?.draft.agentId == "claude", "an uninstalled last agent gives way to the first installed")
    }

    @Test func aFailedCreateLeavesNoTaskAndThrows() async throws {
        let (model, host, document, project) = try await modelWithProject()
        var draft = TaskDraft(baseBranch: "no-such-branch", agentId: "claude", model: "opus", reasoning: nil)
        draft.setTitle("Login")
        await #expect(throws: GitFailure.self) { try await model.newTask(draft: draft, in: project) }
        #expect(document.workspace.tasks.isEmpty && host.opened.isEmpty)
    }

    /// An agent removed while the sheet was up is caught before anything is made.
    @Test func anAgentGoneSinceTheSheetOpenedCreatesNothing() async throws {
        let (model, host, document, project) = try await modelWithProject(installed: [])
        var draft = TaskDraft(baseBranch: "main", agentId: "claude", model: "opus", reasoning: nil)
        draft.setTitle("Login")
        await #expect(throws: AgentNotInstalled(agent: "Claude Code")) { try await model.newTask(draft: draft, in: project) }
        #expect(document.workspace.tasks.isEmpty && host.opened.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: try #require(document.workspace.projects.first).path + "/.worktrees"))
    }

    /// A task reopened from the sidebar, its tab long closed, is a shell: the agent ran once.
    @Test func reopeningATaskStartsNoAgent() async throws {
        let (model, host, _, project) = try await modelWithProject()
        await model.newTask(title: "Login", in: project)
        let task = try #require(model.tree.projects.first?.tasks.first).id
        host.close(try #require(host.tabs.first).id)
        model.select(task: task)
        #expect(host.opened.count == 2 && host.opened.last?.command == nil)
    }
}
