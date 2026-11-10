import Foundation
import Testing
@testable import ShellforgeTestSupport
@testable import ShellforgeCore
@testable import ShellforgeUI

@MainActor @Suite struct SidebarFooterTests {
    private let folder = TestScratch.root.appendingPathComponent("shellforge-footer-\(UUID().uuidString)")

    /// A sidebar with one project and two tasks, one tab each, and a tab of no task.
    private func sidebar() async throws -> (SidebarModel, FakeTerminalHost, FakeFeed, alpha: UUID, beta: UUID) {
        let repo = try GitRepoForUI()
        let host = FakeTerminalHost(), feed = FakeFeed()
        let model = SidebarModel(host: host, document: WorkspaceDocument(store: WorkspaceStore(folder: folder)),
                                 launcher: repo.launcher, feed: feed, jiraSettings: { nil })
        await model.addProject(folder: repo.path)
        let project = try #require(model.tree.projects.first).id
        await model.newTask(title: "Alpha", in: project)
        await model.newTask(title: "Beta", in: project)
        let tasks = try #require(model.tree.projects.first).tasks.map(\.id)
        return (model, host, feed, tasks[0], tasks[1])
    }

    private func session(_ id: String, task: UUID?, agent: SessionAgent, context: Int?, tokens: TokenTally? = nil,
                         window: String = "w", tab: Int = 0) -> SessionInfo {
        var s = SessionInfo(sessionId: id, windowId: window, tabIndex: tab, taskId: task?.uuidString.lowercased(), projectId: nil,
                            agent: agent, model: nil, state: .idle, title: "t", cwd: "/wt")
        s.active = true; s.contextPercent = context; s.tokens = tokens
        return s
    }

    private func say(_ feed: FakeFeed, _ sessions: [SessionInfo], usage: UsageSnapshot = .empty) {
        var store = SessionStore()
        store.apply(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true, sessions: sessions, usage: usage)))
        feed.store = store
    }

    @Test func theFooterFollowsTheSelection() async throws {
        let (model, host, feed, alpha, beta) = try await sidebar()
        host.tabs.append(TabSnapshot(id: "s9", tabId: 9, title: "zsh", taskId: nil, projectId: nil))
        say(feed, [session("a", task: alpha, agent: .claude, context: 84, tokens: TokenTally(input: 936_000, cached: nil, output: 5_600)),
                   session("b", task: beta, agent: .codex, context: 12, tab: 1),
                   session("s9", task: nil, agent: .shell, context: nil, window: "w2")])
        model.select(task: alpha)
        #expect(model.footerRow?.agent == .claude && model.footerRow?.context?.percent == 84 && model.footerRow?.context?.warning == true)
        #expect(model.footerRow?.tokens?.input == 936_000)
        model.select(task: beta)
        #expect(model.footerRow?.agent == .codex && model.footerRow?.context?.percent == 12 && model.footerRow?.tokens == nil)
        host.userSwitched(to: "s9")
        #expect(model.footerRow == UsageTaskRow(agent: .shell, context: nil, tokens: nil))
    }

    /// No task and no tab: SYSTEM holds the Mac alone. (A task stays selected in Shellforge while
    /// its tab is gone — `aClosedTasksContextStays` — so "nothing selected" is a sidebar with neither.)
    @Test func nothingSelectedShowsTheMacAlone() async throws {
        let model = SidebarModel(host: FakeTerminalHost(), document: WorkspaceDocument(store: WorkspaceStore(folder: folder)),
                                 launcher: try GitRepoForUI().launcher, feed: FakeFeed(), jiraSettings: { nil })
        #expect(model.footerRow == nil)
    }

    @Test func aCustomAgentsTaskKeepsItsAgentRow() async throws {
        let (model, _, feed, alpha, _) = try await sidebar()
        try model.document.update { workspace in
            if let i = workspace.tasks.firstIndex(where: { $0.id == alpha }) { workspace.tasks[i].agent = "gemini" }
        }
        say(feed, [])
        model.select(task: alpha)
        #expect(model.footerRow?.agent == .custom("gemini"), "a custom task's own agent stands in for its closed tab")
    }

    @Test func aClosedTasksContextStays() async throws {
        let (model, _, feed, alpha, _) = try await sidebar()
        say(feed, [session("a", task: alpha, agent: .claude, context: 40)])
        say(feed, [])
        model.select(task: alpha)
        #expect(model.footerRow?.agent == .claude, "the task's own agent stands in for its closed tab")
        #expect(model.footerRow?.context?.percent == 40, "its last fill stays")
    }

    @Test func anAgentThatReportedNothingHasNoFillAndNoCounts() async throws {
        let (model, _, feed, alpha, _) = try await sidebar()
        say(feed, [session("a", task: alpha, agent: .pi, context: nil, tokens: TokenTally(input: 0, cached: nil, output: 0))])
        model.select(task: alpha)
        #expect(model.footerRow == UsageTaskRow(agent: .pi, context: nil, tokens: nil))
    }

    /// A home folder of the test's own, with `~/.claude` in it when `claude` is true.
    private func home(claude: Bool) throws -> URL {
        let home = TestScratch.root.appendingPathComponent("footer-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: claude ? home.appendingPathComponent(".claude") : home, withIntermediateDirectories: true)
        return home
    }

    private func model(installed: [String], home: URL) throws -> SidebarModel {
        SidebarModel(host: FakeTerminalHost(), document: WorkspaceDocument(store: WorkspaceStore(folder: folder)),
                     launcher: try GitRepoForUI(installed: installed).launcher, feed: FakeFeed(), jiraSettings: { nil }, home: home)
    }

    @Test func aMissingStatusLineSaysUsageIsDisconnected() async throws {
        let model = try model(installed: ["claude", "codex"], home: try home(claude: false))
        await model.refreshInstalledAgents()
        let rows = model.vendorRows(now: Date(), calendar: .current, claudeStatusLineInstalled: false)
        #expect(rows.map(\.vendor) == [.claude, .codex])
        #expect(rows[0].note == UsageRows.statusLineMissingNote && rows[0].warning)
        #expect(rows[1].note == "No usage data yet" && !rows[1].warning)
    }

    /// The footer leaves out a vendor you don’t use: the model finds which agents’ CLIs are on PATH,
    /// off the main actor, and only those wait for usage data.
    @Test func theModelFindsTheInstalledAgents() async throws {
        let model = try model(installed: ["codex"], home: try home(claude: false))
        await model.refreshInstalledAgents()
        #expect(model.installedAgents == [.codex])
        #expect(model.vendorRows(now: Date(), calendar: .current, claudeStatusLineInstalled: true).map(\.vendor) == [.codex])
    }

    /// Claude Code installed off `PATH` still has its `~/.claude`: it counts as in use, so a broken
    /// status line still says “Usage disconnected” rather than the row going missing.
    @Test func claudesHomeFolderCountsAsInUse() async throws {
        let model = try model(installed: [], home: try home(claude: true))
        await model.refreshInstalledAgents()
        #expect(model.installedAgents == [.claude])
        let rows = model.vendorRows(now: Date(), calendar: .current, claudeStatusLineInstalled: false)
        #expect(rows == [UsageVendorRow(vendor: .claude, lines: [], note: UsageRows.statusLineMissingNote, warning: true)])
        let without = try self.model(installed: [], home: try home(claude: false))
        await without.refreshInstalledAgents()
        #expect(without.vendorRows(now: Date(), calendar: .current, claudeStatusLineInstalled: false).isEmpty)
    }

    /// Two looks overlap and the older finishes last: its answer is dropped, so the newer one stands.
    /// The older look is held open by a stream the test finishes once the newer one has published.
    @Test func anOlderLookFinishingLastIsDropped() async throws {
        let model = try model(installed: [], home: try home(claude: false))
        // The model's own first look, at init, is done before the two the test starts.
        await model.environmentRead?.value
        let (started, startedSignal) = AsyncStream<Void>.makeStream()
        let (gate, open) = AsyncStream<Void>.makeStream()
        let older = Task { @MainActor in
            await model.publishInstalledAgents {
                startedSignal.yield()
                for await _ in gate {}
                return [.claude]
            }
        }
        for await _ in started { break }
        await model.publishInstalledAgents { [.codex] }
        #expect(model.installedAgents == [.codex])
        open.finish()
        await older.value
        #expect(model.installedAgents == [.codex], "the older look's answer replaced the newer one's")
        // On its own, a look publishes as before.
        await model.publishInstalledAgents { [.claude] }
        #expect(model.installedAgents == [.claude])
    }

    @Test func theFooterRedrawsOnTheMinute() async throws {
        let (model, _, feed, _, _) = try await sidebar()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let window = UsageWindow(usedPercent: 50, resetsAt: Int(now.timeIntervalSince1970) + 30)
        say(feed, [], usage: UsageSnapshot(claude: Usage(fiveHour: window, sevenDay: nil, spend: nil, plan: nil, updatedAt: 0), codex: nil))
        #expect(model.vendorRows(now: now, calendar: .current, claudeStatusLineInstalled: true)[0].lines.map(\.window) == [.fiveHour])
        #expect(model.vendorRows(now: now.addingTimeInterval(60), calendar: .current, claudeStatusLineInstalled: true)[0].note
                == "No usage data reported", "a window past its reset is dropped at the next minute")
    }

    /// A pane split off a task's tab carries no task tag of its own (only the pane that opened the
    /// tab does); its agent's fill is still the task's, as every pane of AiTerm's task window was.
    @Test func aSplitPanesAgentShowsItsContext() async throws {
        let (model, host, feed, alpha, _) = try await sidebar()
        let tab = try #require(host.tabs.first { $0.taskId == alpha })
        var opener = session(tab.id, task: alpha, agent: .shell, context: nil)
        opener.active = false
        let split = session("p2", task: nil, agent: .codex, context: 30)
        say(feed, [opener, split])
        // The user focuses the split: iTerm2's tab now names it, and still carries the task's tag.
        let index = try #require(host.tabs.firstIndex { $0.id == tab.id })
        host.tabs[index] = TabSnapshot(id: "p2", tabId: tab.tabId, title: "codex", taskId: alpha, projectId: tab.projectId)
        host.userSwitched(to: "p2")
        #expect(model.selectedTaskId == alpha)
        #expect(model.footerRow?.agent == .codex)
        #expect(model.footerRow?.context?.percent == 30)
    }

    /// A pane that appears and reports in one update is placed by that update, not one later.
    @Test func aNewPaneReportsOnItsFirstUpdate() async throws {
        let (model, host, feed, _, _) = try await sidebar()
        host.tabs.append(TabSnapshot(id: "s9", tabId: 9, title: "zsh", taskId: nil, projectId: nil))
        host.onChange?()
        var shell = session("s9", task: nil, agent: .shell, context: nil, window: "w2")
        shell.active = false
        say(feed, [shell, session("p9", task: nil, agent: .claude, context: 20, window: "w2")])
        host.tabs[host.tabs.count - 1] = TabSnapshot(id: "p9", tabId: 9, title: "claude", taskId: nil, projectId: nil)
        host.userSwitched(to: "p9")
        #expect(model.footerRow?.agent == .claude && model.footerRow?.context?.percent == 20)
    }

    /// Focusing another pane of a tab outside any task changes the tab's id (its focused pane) but
    /// not the tab: its last fill stays.
    @Test func aTabKeepsItsFillWhenAnotherPaneIsFocused() async throws {
        let (model, host, feed, _, _) = try await sidebar()
        host.tabs.append(TabSnapshot(id: "s9", tabId: 9, title: "zsh", taskId: nil, projectId: nil))
        host.onChange?()
        var shell = session("s9", task: nil, agent: .shell, context: nil, window: "w2")
        shell.active = false
        say(feed, [shell, session("p9", task: nil, agent: .claude, context: 20, window: "w2")])
        host.tabs[host.tabs.count - 1] = TabSnapshot(id: "p9", tabId: 9, title: "claude", taskId: nil, projectId: nil)
        host.userSwitched(to: "p9")
        #expect(model.footerRow?.agent == .claude && model.footerRow?.context?.percent == 20)
    }
}
