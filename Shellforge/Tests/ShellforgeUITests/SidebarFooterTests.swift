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
                                 launcher: repo.launcher, feed: feed)
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
                                 launcher: try GitRepoForUI().launcher, feed: FakeFeed())
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
}
