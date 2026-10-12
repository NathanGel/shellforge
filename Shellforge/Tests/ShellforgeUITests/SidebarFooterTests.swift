import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI

@MainActor @Suite struct SidebarFooterTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shellforge-footer-\(UUID().uuidString)")

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

    @Test func aMissingStatusLineSaysUsageIsDisconnected() async throws {
        let (model, _, _, _, _) = try await sidebar()
        let rows = model.vendorRows(now: Date(), calendar: .current, claudeStatusLineInstalled: false)
        #expect(rows.map(\.vendor) == [.claude, .codex])
        #expect(rows[0].note == UsageRows.statusLineMissingNote && rows[0].warning)
        #expect(rows[1].note == "No usage data yet" && !rows[1].warning)
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
