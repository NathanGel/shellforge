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
                  beside: String?, launch: AgentLaunch?)] = []
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
    /// A task's tagged panes when a tab mixes two tasks' panes, which the snapshots cannot show.
    var taggedPanes: [UUID: Int] = [:]
    func paneCount(ofTask id: UUID) -> Int {
        taggedPanes[id] ?? (tabs + tabsElsewhere).filter { $0.taskId == id }.map(\.paneCount).reduce(0, +)
    }
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
                 beside: String?, launch: AgentLaunch?) {
        opened.append((directory, taskId, projectId, title, command, environment, beside, launch))
        if beside != nil, refusesSplit { onSplitRefused?(title) }
        nextTab += 1
        let tab = TabSnapshot(id: "s\(nextTab)", tabId: nextTab, title: title, taskId: taskId, projectId: projectId)
        tabs.append(tab)
        selectedTabId = tab.id
        onChange?()
    }

    /// The untagged tabs opened in a folder by the header's New Tab in Home Folder.
    var plainOpened: [String] = []

    func openPlainTab(in directory: String) {
        plainOpened.append(directory)
    }

    /// The tabs of no task opened: a tunnel answered in a tab. Fires `onChange` synchronously; the
    /// real host fires it from the launch's async completion.
    var openedPlain: [(directory: String, title: String, command: String, panel: PanelTab?)] = []

    func openTab(in directory: String, title: String, command: String, panel: PanelTab?) {
        openedPlain.append((directory, title, command, panel))
        nextTab += 1
        let tab = TabSnapshot(id: "s\(nextTab)", tabId: nextTab, title: title, taskId: nil, projectId: nil, panel: panel)
        tabs.append(tab)
        selectedTabId = tab.id
        onChange?()
    }

    /// The file tabs a panel opened, by what they run: listed in `openedPlain` too, by its `line`.
    var openedFiles: [FileCommand] = []

    func openTab(in directory: String, title: String, running: FileCommand, panel: PanelTab) {
        openedFiles.append(running)
        openTab(in: directory, title: title, command: running.line, panel: panel)
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
    let tunnelOutcomes = PassthroughSubject<TunnelOutcome, Never>()
    var tunnelOutcomePublisher: AnyPublisher<TunnelOutcome, Never> { tunnelOutcomes.eraseToAnyPublisher() }
    @Published var launchError: String?
    var launchErrorPublisher: AnyPublisher<String?, Never> { $launchError.eraseToAnyPublisher() }
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

    /// A launch the helper couldn't be armed for is the sidebar's error; the next one armed clears
    /// it, and only it: an error said since by something else stays.
    @Test func aLaunchThatCouldNotBeArmedIsTheSidebarsError() throws {
        let repo = try GitRepoForUI()
        let feed = FakeFeed()
        let sidebar = SidebarModel(host: FakeTerminalHost(), document: WorkspaceDocument(store: WorkspaceStore(folder: folder)),
                                   launcher: repo.launcher, feed: feed, jiraSettings: { nil })
        feed.launchError = "Couldn’t start gemini: Shellforge’s helper isn’t connected."
        #expect(sidebar.lastError == "Couldn’t start gemini: Shellforge’s helper isn’t connected.")
        feed.launchError = nil
        #expect(sidebar.lastError == nil)
        feed.launchError = "Couldn’t start gemini: Shellforge’s helper isn’t connected."
        sidebar.lastError = "The project was removed."
        feed.launchError = nil
        #expect(sidebar.lastError == "The project was removed.")
    }

    /// With the app's own link and no helper: the arm's failure is said in a sentence that holds no
    /// secret.
    @Test func anArmFailureIsSaidWithoutTheSecret() throws {
        let repo = try GitRepoForUI()
        let link = DaemonLink(daemonDir: nil, findPython: { nil }, reports: { [] })
        let sidebar = SidebarModel(host: FakeTerminalHost(), document: WorkspaceDocument(store: WorkspaceStore(folder: folder)),
                                   launcher: repo.launcher, feed: link, jiraSettings: { nil })
        link.armLaunch(session: "S", agentId: "gemini", environment: ["GEMINI_API_KEY": "placeholder-secret-value"])
        #expect(sidebar.lastError == "Couldn’t start gemini: Shellforge’s helper isn’t connected.")
        #expect(sidebar.lastError?.contains("placeholder-secret-value") == false)
        // A window opened later doesn't say an old launch's failure.
        let later = SidebarModel(host: FakeTerminalHost(), document: WorkspaceDocument(store: WorkspaceStore(folder: folder)),
                                 launcher: repo.launcher, feed: link, jiraSettings: { nil })
        #expect(later.lastError == nil)
    }

    /// A typed-in prompt that never went because its agent ended first is said, briefly.
    @Test func aTypedPromptAbandonedByItsAgentIsSaid() throws {
        let repo = try GitRepoForUI()
        let sidebar = SidebarModel(host: FakeTerminalHost(), document: WorkspaceDocument(store: WorkspaceStore(folder: folder)),
                                   launcher: repo.launcher, agents: AgentPresets.all + [AgentDefinition(id: "aider", name: "Aider", command: "aider")],
                                   jiraSettings: { nil })
        sidebar.typedPromptAbandoned(agentId: "aider", title: "Fix login")
        #expect(sidebar.notice == "Aider exited before its first prompt could be typed in Fix login.")
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

    /// A task with one tab done and another still working: shown, its done tab is seen.
    @Test func aShownTaskMarksItsDoneTabsSeenWhileAnotherWorks() async throws {
        let repo = try GitRepoForUI()
        let host = FakeTerminalHost(), feed = FakeFeed()
        let sidebar = SidebarModel(host: host, document: WorkspaceDocument(store: WorkspaceStore(folder: folder)), launcher: repo.launcher, feed: feed, jiraSettings: { nil })
        await sidebar.addProject(folder: repo.path)
        let project = try #require(sidebar.tree.projects.first).id
        await sidebar.newTask(title: "One", in: project)
        let one = try #require(sidebar.selectedTaskId)
        await sidebar.newTask(title: "Two", in: project)
        feed.sayAll([(state: .done, session: "d1", task: one, agent: .claude), (state: .working, session: "w1", task: one, agent: .codex)])
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

    /// A window opened later reads no git for a project another window has read: the answer is
    /// the app's, and stands until the repository's config changes.
    @Test func aSecondWindowReusesTheFirstWindowsProvider() async throws {
        let repo = try GitRepoForUI()
        _ = try repo.launcher.run("/usr/bin/git", ["-C", repo.path, "remote", "add", "origin", "git@github.com:a/b.git"])
        let document = WorkspaceDocument(store: WorkspaceStore(folder: folder))
        let first = SidebarModel(host: FakeTerminalHost(), document: document, launcher: repo.launcher, jiraSettings: { nil })
        await first.addProject(folder: repo.path)
        let id = try #require(first.tree.projects.first).id
        #expect(await eventually { first.providers[id] == .github })
        let facts = first.repositoryFacts, reads = facts.readCount
        let second = SidebarModel(host: FakeTerminalHost(), document: document, launcher: repo.launcher, jiraSettings: { nil })
        #expect(await eventually { second.providers[id] == .github })
        #expect(second.repositoryFacts === facts)
        #expect(facts.readCount == reads, "the second window ran no git")
        // A changed remote is read again.
        _ = try repo.launcher.run("/usr/bin/git", ["-C", repo.path, "remote", "set-url", "origin", "git@gitlab.com:a/b.git"])
        #expect(facts.facts(of: repo.path).provider == .gitlab)
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

    private func modelWithProject(installed: [String] = ["claude"], agents: [AgentDefinition] = AgentPresets.all,
                                  secrets: any SecretStore & Sendable = MemorySecretStore(),
                                  tools: AgentTools = .none) async throws -> (SidebarModel, FakeTerminalHost, WorkspaceDocument, UUID) {
        let repo = try GitRepoForUI(installed: installed)
        let host = FakeTerminalHost()
        let document = WorkspaceDocument(store: WorkspaceStore(folder: folder))
        let model = SidebarModel(host: host, document: document, launcher: repo.launcher, agents: agents, catalogue: { _ in [] },
                                 jiraSettings: { nil }, secrets: secrets, tools: tools)
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

    /// Cancel pressed after git made the review's worktree, while its command is still being put
    /// together, saves nothing and takes the worktree back: the sheet said it was cancelled.
    @Test func aReviewCancelledAfterItsWorktreeSavesNothing() async throws {
        let (model, host, document, project) = try await modelWithProject()
        let repo = try #require(document.workspace.projects.first).path
        _ = try model.launcher.run("git", ["-C", repo, "branch", "feature"])
        // A git that holds at the command's one call — the prompt written beside it — until let go.
        let root = (repo as NSString).deletingLastPathComponent
        try """
        #!/bin/sh
        case "$*" in *review-feature*--git-common-dir*) touch "\(root)/held"; while [ ! -f "\(root)/go" ]; do sleep 0.02; done;; esac
        exec /usr/bin/git "$@"
        """.write(toFile: "\(root)/bin/git", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: "\(root)/bin/git")
        var draft = ReviewDraft(mr: nil, agentId: "claude", model: "opus", reasoning: nil)
        draft.setTitle("Review feature")
        draft.setBranch("feature")
        draft.promptText = "look\tclosely"   // a tab: written to a file, not typed
        let cancellation = CreationCancellation()
        let creating = Task { @MainActor in
            try await CreationContext.$cancellation.withValue(cancellation) { try await model.newReview(draft: draft, in: project) }
        }
        #expect(await eventually { FileManager.default.fileExists(atPath: "\(root)/held") })
        cancellation.cancel()
        FileManager.default.createFile(atPath: "\(root)/go", contents: nil)
        await #expect(throws: CreationCancelled.self) { try await creating.value }
        #expect(document.workspace.tasks.isEmpty && host.opened.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: "\(repo)/.worktrees/review-feature"))
    }

    private func projectFolderDraft(_ title: String) -> TaskDraft {
        var draft = TaskDraft(baseBranch: "main", agentId: "claude", model: "opus", reasoning: nil)
        draft.setTitle(title)
        draft.choose(.projectFolder)
        return draft
    }

    @Test func newTaskInProjectFolderOpensThere() async throws {
        let (model, host, document, project) = try await modelWithProject()
        let folder = try #require(document.workspace.projects.first).path
        try await model.newTask(draft: projectFolderDraft("Home"), in: project)
        let task = try #require(document.workspace.tasks.first)
        #expect(task.worktreePath == folder && task.branch == "main")
        #expect(host.opened.last?.directory == folder && host.opened.last?.command == "claude --model opus")
        #expect(!FileManager.default.fileExists(atPath: folder + "/.worktrees"))
        #expect(try model.launcher.run("git", ["-C", folder, "worktree", "list"]).stdout.split(separator: "\n").count == 1)
    }

    // -- Project folder on another branch -------------------------------------------------

    @discardableResult
    private func git(_ model: SidebarModel, _ folder: String, _ args: String...) throws -> String {
        let out = try model.launcher.run("git", ["-C", folder] + args)
        guard out.status == 0 else { throw GitFailure(command: "git " + args.joined(separator: " "), message: out.stderr) }
        return out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func projectFolderDraft(_ title: String, branch: String) -> TaskDraft {
        var draft = projectFolderDraft(title)
        draft.folderBranch = branch
        return draft
    }

    @Test func projectFolderSwitchesToAnExistingBranchWithoutAsking() async throws {
        let (model, _, document, project) = try await modelWithProject()
        let folder = try #require(document.workspace.projects.first).path
        try git(model, folder, "branch", "feat/a")
        let prompter = ScriptedPrompter([])
        model.prompter = prompter
        try await model.newTask(draft: projectFolderDraft("Home", branch: "feat/a"), in: project)
        #expect(try #require(document.workspace.tasks.first).branch == "feat/a")
        #expect(try git(model, folder, "symbolic-ref", "--short", "HEAD") == "feat/a")
        #expect(prompter.asked.isEmpty)
    }

    @Test func projectFolderOffersToCreateAMissingBranch() async throws {
        let (model, _, document, project) = try await modelWithProject()
        let folder = try #require(document.workspace.projects.first).path
        let prompter = ScriptedPrompter([AlertAnswer(button: 0)])
        model.prompter = prompter
        try await model.newTask(draft: projectFolderDraft("Home", branch: "feat/new"), in: project)
        #expect(prompter.asked.first?.message == "“feat/new” doesn’t exist yet.")
        #expect(prompter.asked.first?.buttons == ["Create Branch", "Cancel"])
        #expect(try #require(document.workspace.tasks.first).branch == "feat/new")
        #expect(try git(model, folder, "symbolic-ref", "--short", "HEAD") == "feat/new")
    }

    @Test func cancellingTheCreateLeavesTheFolderAlone() async throws {
        let (model, host, document, project) = try await modelWithProject()
        let folder = try #require(document.workspace.projects.first).path
        model.prompter = ScriptedPrompter([AlertAnswer(button: 1)])
        await #expect(throws: CreationDeclined.self) {
            try await model.newTask(draft: projectFolderDraft("Home", branch: "feat/new"), in: project)
        }
        #expect(document.workspace.tasks.isEmpty && host.opened.isEmpty)
        #expect(try git(model, folder, "symbolic-ref", "--short", "HEAD") == "main")
    }

    @Test func clashingChangesOfferAStash() async throws {
        let (model, _, document, project) = try await modelWithProject()
        let folder = try #require(document.workspace.projects.first).path
        try git(model, folder, "switch", "-q", "-c", "feat/a")
        try "theirs".write(toFile: folder + "/file.txt", atomically: true, encoding: .utf8)
        try git(model, folder, "add", "file.txt")
        try git(model, folder, "commit", "-q", "-m", "theirs")
        try git(model, folder, "switch", "-q", "main")
        try "mine".write(toFile: folder + "/file.txt", atomically: true, encoding: .utf8)
        let prompter = ScriptedPrompter([AlertAnswer(button: 0)])
        model.prompter = prompter
        try await model.newTask(draft: projectFolderDraft("Fix", branch: "feat/a"), in: project)
        #expect(prompter.asked.first?.buttons == ["Stash and Switch", "Cancel"])
        #expect(try git(model, folder, "symbolic-ref", "--short", "HEAD") == "feat/a")
        #expect(try git(model, folder, "stash", "list").contains("Shellforge: before “Fix”"))
        #expect(document.workspace.tasks.count == 1)
    }

    @Test func aBranchInAnotherWorktreeOffersThatWorktree() async throws {
        let (model, host, document, project) = try await modelWithProject()
        let folder = try #require(document.workspace.projects.first).path
        let other = folder + "-other"
        try git(model, folder, "worktree", "add", "-q", "-b", "feat/b", other)
        let prompter = ScriptedPrompter([AlertAnswer(button: 0)])
        model.prompter = prompter
        try await model.newTask(draft: projectFolderDraft("Home", branch: "feat/b"), in: project)
        #expect(prompter.asked.first?.buttons == ["Use That Worktree", "Cancel"])
        let task = try #require(document.workspace.tasks.first)
        #expect(ExistingWorktrees.resolved(task.worktreePath) == ExistingWorktrees.resolved(other) && task.branch == "feat/b")
        #expect(host.opened.last.map { ExistingWorktrees.resolved($0.directory) } == ExistingWorktrees.resolved(other))
        #expect(try git(model, folder, "symbolic-ref", "--short", "HEAD") == "main")
    }

    @Test func switchingUnderAnotherRunningTaskAsksFirst() async throws {
        let (model, host, document, project) = try await modelWithProject()
        let folder = try #require(document.workspace.projects.first).path
        try git(model, folder, "branch", "feat/a")
        try await model.newTask(draft: projectFolderDraft("Running"), in: project)
        let running = try #require(document.workspace.tasks.first)
        host.tabs.append(TabSnapshot(id: "t1", tabId: 1, title: "Running", taskId: running.id, projectId: project))
        host.onChange?()
        let prompter = ScriptedPrompter([AlertAnswer(button: 1)])
        model.prompter = prompter
        await #expect(throws: CreationDeclined.self) {
            try await model.newTask(draft: projectFolderDraft("Second", branch: "feat/a"), in: project)
        }
        #expect(prompter.asked.first?.message == "“Running” is also working in this folder.")
        #expect(try git(model, folder, "symbolic-ref", "--short", "HEAD") == "main")
    }

    /// Cancelled after the task was made, nothing is saved and the project's own folder and its
    /// checked-out branch are untouched: undo's `branch -D` is not path-guarded.
    @Test func cancelledProjectFolderCreateLeavesFolder() async throws {
        let (model, host, document, project) = try await modelWithProject()
        let folder = try #require(document.workspace.projects.first).path
        try "keep".write(toFile: folder + "/file.txt", atomically: true, encoding: .utf8)
        let cancellation = CreationCancellation()
        cancellation.cancel()
        let draft = projectFolderDraft("Home")
        await #expect(throws: CreationCancelled.self) {
            try await CreationContext.$cancellation.withValue(cancellation) { try await model.newTask(draft: draft, in: project) }
        }
        #expect(document.workspace.tasks.isEmpty && host.opened.isEmpty)
        #expect(FileManager.default.fileExists(atPath: folder + "/file.txt") && FileManager.default.fileExists(atPath: folder + "/.git"))
        #expect(try model.launcher.run("git", ["-C", folder, "rev-parse", "--verify", "--quiet", "refs/heads/main"]).status == 0,
                "the checked-out branch is still there")
    }

    private let runner = URL(fileURLWithPath: "/Applications/Shell Forge.app/Contents/Resources/hooks/shellforge-run")
    private var tools: AgentTools { AgentTools(statusCommand: nil, runner: runner, readyMade: nil, translocated: false) }

    private func gemini(prompt: AgentDefinition.PromptDelivery = .argument, secrets: [String: String] = ["GEMINI_API_KEY": "agent.gemini.GEMINI_API_KEY"]) -> AgentDefinition {
        AgentDefinition(id: "gemini", name: "Gemini CLI", command: "gemini", arguments: prompt == .argument ? [["-i", "{prompt}"]] : [],
                        prompt: prompt, secrets: secrets)
    }

    private func geminiDraft(_ title: String, prompt: String = "fix it") -> TaskDraft {
        var draft = TaskDraft(baseBranch: "main", agentId: "gemini", model: "", reasoning: nil)
        draft.setTitle(title)
        draft.promptText = prompt
        return draft
    }

    /// The secret goes to the host as the launch's environment, for the helper to arm; the typed
    /// command is the quoted runner's, and never holds the value.
    @Test func newTaskWithSecretsArmsTheLaunch() async throws {
        let store = MemorySecretStore()
        store.set(AgentSecrets.key(agent: "gemini", variable: "GEMINI_API_KEY"), "placeholder-secret-value")
        let (model, host, _, project) = try await modelWithProject(installed: ["claude", "gemini"], agents: AgentPresets.all + [gemini()],
                                                                   secrets: store, tools: tools)
        try await model.newTask(draft: geminiDraft("Login"), in: project)
        let opened = try #require(host.opened.last)
        let launch = try #require(opened.launch)
        #expect(launch.agentId == "gemini")
        #expect(launch.environment["GEMINI_API_KEY"] == "placeholder-secret-value")
        let command = try #require(opened.command)
        #expect(command == launch.command, "the command typed is the launch's, as made")
        #expect(command.hasPrefix(AgentCommand.shellQuote(runner.path) + " gemini -- "))
        #expect(!command.contains("placeholder-secret-value"))
    }

    /// A typed-in prompt rides with the launch, for the host to paste once the agent is up; the
    /// command starts the agent bare.
    @Test func typedPromptGoesToTheHostNotTheCommand() async throws {
        let (model, host, _, project) = try await modelWithProject(installed: ["claude", "gemini"],
                                                                   agents: AgentPresets.all + [gemini(prompt: .typed, secrets: [:])], tools: tools)
        try await model.newTask(draft: geminiDraft("Login", prompt: "fix the login page"), in: project)
        let opened = try #require(host.opened.last)
        #expect(opened.launch?.typedPrompt == "fix the login page")
        #expect(opened.command == AgentCommand.shellQuote(runner.path) + " gemini -- 'gemini'")
        #expect(opened.command?.contains("login page") == false)
    }

    /// A secret the Keychain doesn't hold refuses the create in a sentence naming the variable, and
    /// nothing is saved or opened.
    @Test func missingSecretRefusesWithItsSentence() async throws {
        let (model, host, document, project) = try await modelWithProject(installed: ["claude", "gemini"], agents: AgentPresets.all + [gemini()],
                                                                          tools: tools)
        await #expect(throws: AgentSecrets.Missing(agent: "Gemini CLI", variable: "GEMINI_API_KEY")) {
            try await model.newTask(draft: geminiDraft("Login"), in: project)
        }
        #expect(AgentSecrets.Missing(agent: "Gemini CLI", variable: "GEMINI_API_KEY").localizedDescription
                == "Gemini CLI’s secret GEMINI_API_KEY isn’t in the Keychain. Set it again in Settings › Agents.")
        #expect(document.workspace.tasks.isEmpty && host.opened.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: try #require(document.workspace.projects.first).path + "/.worktrees/login"))
    }

    /// Settings › Agents' changes reach the next New Task: an agent added since is offered and starts.
    @Test func reloadAgentsReachesNewTask() async throws {
        let (model, host, _, project) = try await modelWithProject(installed: ["claude", "gemini"], tools: tools)
        #expect(model.makeNewTaskModel(for: project)?.agents.map(\.id) == AgentPresets.all.map(\.id))
        model.reloadAgents(AgentPresets.all + [gemini(secrets: [:])], readyMade: [])
        #expect(model.agents.map(\.id).last == "gemini")
        #expect(model.makeNewTaskModel(for: project)?.availableAgents.contains("gemini") == true)
        try await model.newTask(draft: geminiDraft("Login"), in: project)
        #expect(host.opened.last?.launch?.agentId == "gemini")
    }

    /// The four built-ins start exactly as before, with nothing to arm.
    @Test func aBuiltInsLaunchIsItsPlainCommand() async throws {
        let (model, host, _, project) = try await modelWithProject(tools: tools)
        var draft = TaskDraft(baseBranch: "main", agentId: "claude", model: "opus", reasoning: "high")
        draft.setTitle("Login")
        draft.promptText = "fix it"
        try await model.newTask(draft: draft, in: project)
        let opened = try #require(host.opened.last)
        #expect(opened.command == "claude --model opus --effort high 'fix it'")
        #expect(opened.launch?.environment.isEmpty == true && opened.launch?.typedPrompt == nil)
        #expect(opened.launch?.needsArming == false, "a built-in's tab arms nothing")
    }

    /// A custom agent's launch is armed.
    @Test func aCustomLaunchIsArmed() async throws {
        let (model, host, _, project) = try await modelWithProject(installed: ["claude", "gemini"],
                                                                   agents: AgentPresets.all + [gemini(secrets: [:])], tools: tools)
        try await model.newTask(draft: geminiDraft("Login"), in: project)
        #expect(host.opened.last?.launch?.needsArming == true)
    }

    /// With no `shellforge-run` handed in, New Task refuses a custom agent in words rather than
    /// typing a line that can't work, and nothing is saved.
    @Test func aCustomLaunchWithNoRunnerIsRefused() async throws {
        let (model, host, document, project) = try await modelWithProject(installed: ["claude", "gemini"],
                                                                          agents: AgentPresets.all + [gemini(secrets: [:])])
        await #expect(throws: AgentLaunch.RunnerMissing()) { try await model.newTask(draft: geminiDraft("Login"), in: project) }
        #expect(document.workspace.tasks.isEmpty && host.opened.isEmpty)
    }

    @Test func twoProjectFolderTasksAllowed() async throws {
        let (model, _, document, project) = try await modelWithProject()
        try await model.newTask(draft: projectFolderDraft("One"), in: project)
        try await model.newTask(draft: projectFolderDraft("Two"), in: project)
        #expect(document.workspace.tasks.count == 2)
    }
}
