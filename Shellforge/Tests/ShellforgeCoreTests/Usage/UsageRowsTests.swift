// Ported from AiTerm (app/Tests/AiTermCoreTests/SidebarModelTests.swift), GPLv3, Laurens D'Hondt.
import Foundation
import Testing
@testable import ShellforgeCore

/// AiTerm's footer cases from its `SidebarModelTests`, their assertions as AiTerm wrote them. Its
/// `usageTaskRow` and `usageTerminalRow` filtered the sessions and took the counts as a map; here
/// the two helpers below do that and call `UsageRows.taskRow`, which takes one row's own sessions.
@Suite struct UsageRowsTests {
    func session(_ id: String, task: String?, agent: SessionAgent, state: SessionState, tab: Int, window: String = "w1", project: String? = nil,
                 cwd: String = "", agentCwd: String? = nil, active: Bool = false, context: Int? = nil) -> SessionInfo {
        var s = SessionInfo(sessionId: id, windowId: window, tabIndex: tab, taskId: task, projectId: project, agent: agent, model: nil,
                            state: state, title: "", cwd: cwd)
        s.agentCwd = agentCwd; s.active = active; s.contextPercent = context
        return s
    }

    /// AiTerm's `usageTaskRow`: the task's own sessions, each carrying its counts from `tokens`.
    func usageTaskRow(taskId: UUID, agent: SessionAgent, sessions: [SessionInfo], contexts: [SessionAgent: Int],
                      tokens: [String: TokenTally] = [:]) -> UsageTaskRow {
        let own = sessions.filter { $0.taskUUID == taskId }.map { s -> SessionInfo in var s = s; s.tokens = tokens[s.sessionId]; return s }
        return UsageRows.taskRow(sessions: own, fallback: agent, contexts: contexts)
    }

    /// AiTerm's `usageTerminalRow`: a window's sessions, and a shell when it has none.
    func usageTerminalRow(windowId: String?, sessions: [SessionInfo], contexts: [SessionAgent: Int]) -> UsageTaskRow {
        let own = windowId.map { wid in sessions.filter { $0.windowId == wid } } ?? []
        return UsageRows.taskRow(sessions: own, fallback: .shell, contexts: contexts)
    }

    @Test func resetTimesFormatCorrectlyFromManyThreadsAtOnce() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/Brussels")!
        let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 17, hour: 9, minute: 55))!
        let calendar = cal
        let cases = (0..<48).map { hour -> (Int, String) in
            let date = cal.date(byAdding: .hour, value: hour, to: now)!
            let day = (9 + hour) / 24, time = String(format: "%02d:55", (9 + hour) % 24)
            let expected = day == 0 ? time : ["Fri", "Sat"][day - 1] + " " + time
            return (Int(date.timeIntervalSince1970), expected)
        }
        let wrong = Locked(0)
        DispatchQueue.concurrentPerform(iterations: 400) { i in
            let (resetsAt, expected) = cases[i % cases.count]
            if UsageRows.fmtReset(resetsAt, now: now, calendar: calendar) != expected { wrong.withLock { $0 += 1 } }
        }
        #expect(wrong.withLock { $0 } == 0)
    }

    @Test func testUsageVendorRowsPutFiveHourFirstWhenAvailable() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/Brussels")!
        let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 17, hour: 9, minute: 55))!
        let today1640 = Int(cal.date(from: DateComponents(year: 2026, month: 9, day: 17, hour: 16, minute: 40))!.timeIntervalSince1970)
        let monday2100 = Int(cal.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: 21, minute: 0))!.timeIntervalSince1970)
        let wednesday1628 = Int(cal.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 16, minute: 28))!.timeIntervalSince1970)
        let snap = UsageSnapshot(
            claude: Usage(fiveHour: UsageWindow(usedPercent: 23, resetsAt: today1640), sevenDay: UsageWindow(usedPercent: 84, resetsAt: monday2100), spend: nil, plan: nil, updatedAt: Int(now.timeIntervalSince1970)),
            codex: Usage(fiveHour: nil, sevenDay: UsageWindow(usedPercent: 23, resetsAt: wednesday1628), spend: nil, plan: "self_serve_business_prolite", updatedAt: Int(now.timeIntervalSince1970)))
        let rows = UsageRows.vendorRows(snap, now: now, calendar: cal)
        #expect(rows == [
            UsageVendorRow(vendor: .claude, lines: [UsageLine(window: .weekly, percent: 84, reset: "Mon 21:00", warning: true, resetInFull: "Monday 21:00"),
                                                    UsageLine(window: .fiveHour, percent: 23, reset: "16:40", warning: false, resetInFull: "16:40")], note: nil),
            UsageVendorRow(vendor: .codex, lines: [UsageLine(window: .weekly, percent: 23, reset: "Wed 16:28", warning: false, resetInFull: "Wednesday 16:28")], note: nil),
        ])
        // Each segment's tooltip and VoiceOver label say it in words.
        #expect(rows[0].lines.map(\.help) == ["Weekly limit, 84 % used, resets Monday 21:00", "5-hour limit, 23 % used, resets 16:40"])
        let none = UsageRows.vendorRows(UsageSnapshot(claude: nil, codex: Usage(fiveHour: nil, sevenDay: nil, spend: nil, plan: nil, updatedAt: Int(now.timeIntervalSince1970))), now: now, calendar: cal)
        #expect(none[0] == UsageVendorRow(vendor: .claude, lines: [], note: "No usage data yet"))
        #expect(none[1] == UsageVendorRow(vendor: .codex, lines: [], note: "No usage data reported"))
        let noReset = UsageRows.vendorRows(UsageSnapshot(claude: Usage(fiveHour: UsageWindow(usedPercent: 5, resetsAt: nil), sevenDay: nil, spend: nil, plan: nil, updatedAt: Int(now.timeIntervalSince1970)), codex: nil), now: now, calendar: cal)
        #expect(noReset[0].lines == [UsageLine(window: .fiveHour, percent: 5, reset: nil, warning: false)])
        #expect(noReset[0].lines[0].help == "5-hour limit, 5 % used")
    }

    /// "No usage data yet" is the honest answer while the first status line tick is awaited, but it is a
    /// lie once AiTerm's shim is no longer Claude Code's status line: no tick is coming, ever. The
    /// footer has to tell those two apart, or a broken feed looks like a slow one forever.
    @Test func testTheClaudeRowSaysWhenTheStatusLineIsNotInstalled() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let cal = Calendar(identifier: .gregorian)
        let empty = UsageSnapshot(claude: nil, codex: nil)
        let claude = { (rows: [UsageVendorRow]) in rows.first { $0.vendor == .claude }! }
        #expect(claude(UsageRows.vendorRows(empty, now: now, calendar: cal)).note == "No usage data yet")
        #expect(claude(UsageRows.vendorRows(empty, now: now, calendar: cal, claudeStatusLineInstalled: false)).note == "Usage disconnected")
        let codex = UsageRows.vendorRows(empty, now: now, calendar: cal, claudeStatusLineInstalled: false).first { $0.vendor == .codex }!
        #expect(codex.note == "No usage data yet", "Codex's rate limits come from its own rollout file; the status line is not its feed")
        // Only the broken feed is a warning; the footer reads the flag, not the wording.
        #expect(claude(UsageRows.vendorRows(empty, now: now, calendar: cal, claudeStatusLineInstalled: false)).warning)
        #expect(!claude(UsageRows.vendorRows(empty, now: now, calendar: cal)).warning)
        #expect(!codex.warning)
    }

    /// A window whose reset time has passed has cleared: whatever it last reported, that limit is at
    /// zero now. Drawing the old percentage next to a reset time in the past would be a stale
    /// number wearing a live one's clothes, so the window is dropped instead.
    @Test func testAWindowPastItsResetIsDroppedNotRedrawn() {
        let now = Date(timeIntervalSince1970: 1_700_000_000), cal = Calendar(identifier: .gregorian)
        let epoch = Int(now.timeIntervalSince1970)
        let snap = UsageSnapshot(
            claude: Usage(fiveHour: UsageWindow(usedPercent: 91, resetsAt: epoch - 1),
                          sevenDay: UsageWindow(usedPercent: 40, resetsAt: epoch + 3600), spend: nil, plan: nil, updatedAt: epoch),
            codex: Usage(fiveHour: nil, sevenDay: UsageWindow(usedPercent: 28, resetsAt: epoch - 86_400), spend: nil, plan: nil, updatedAt: epoch))
        let rows = UsageRows.vendorRows(snap, now: now, calendar: cal)
        #expect(rows[0].lines.map(\.window) == [.weekly])
        #expect(rows[1] == UsageVendorRow(vendor: .codex, lines: [], note: "No usage data reported"))
        // A window with no reset time at all never expires.
        let open = UsageSnapshot(claude: Usage(fiveHour: UsageWindow(usedPercent: 5, resetsAt: nil), sevenDay: nil, spend: nil, plan: nil, updatedAt: epoch), codex: nil)
        #expect(UsageRows.vendorRows(open, now: now, calendar: cal)[0].lines.map(\.window) == [.fiveHour])
    }

    /// Both feeds only move while their agent runs, so a quiet vendor is idle, not broken. Its last
    /// numbers are still its numbers: a day-old report yields the same lines as a fresh one.
    @Test func testASilentVendorsWindowsAreDrawnLikeFreshOnes() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/Brussels")!
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let epoch = Int(now.timeIntervalSince1970)
        let usage = { (age: Int) in
            UsageSnapshot(claude: nil, codex: Usage(fiveHour: nil, sevenDay: UsageWindow(usedPercent: 28, resetsAt: epoch + 86_400),
                                                     spend: nil, plan: nil, updatedAt: epoch - age))
        }
        let rows = { (age: Int) in UsageRows.vendorRows(usage(age), now: now, calendar: cal)[1].lines }
        #expect(rows(86_400) == rows(0))
        #expect(rows(0) == [UsageLine(window: .weekly, percent: 28, reset: "Wed 23:13", warning: false, resetInFull: "Wednesday 23:13")])
    }

    // MARK: - context

    /// The counts are the active tab's own, never another tab's: two Claude tabs are two conversations.
    @Test func theCountsAreTheActiveTabsOwn() {
        let id = UUID()
        let sessions = [tab(id, .claude, 0), tab(id, .claude, 1, active: true)]
        let counts = ["s0": TokenTally(input: 9, cached: 0, output: 9), "s1": TokenTally(input: 936_018, cached: 935_988, output: 5_625)]
        let row = usageTaskRow(taskId: id, agent: .claude, sessions: sessions, contexts: [.claude: 42], tokens: counts)
        #expect(row.tokens == counts["s1"])
    }

    /// A shell tab, or a task whose window is closed, has no conversation and no counts.
    @Test func aShellTabHasNoCounts() {
        let id = UUID()
        let counts = ["s0": TokenTally(input: 9, cached: 0, output: 9), "s1": TokenTally(input: 1, cached: 0, output: 1)]
        #expect(usageTaskRow(taskId: id, agent: .claude, sessions: [tab(id, .claude, 0), tab(id, .shell, 1, active: true)],
                                          contexts: [:], tokens: counts).tokens == nil)
        #expect(usageTaskRow(taskId: UUID(), agent: .claude, sessions: [], contexts: [:], tokens: counts).tokens == nil)
    }

    /// A tally of nothing in and nothing out — PI reports one from a session's start — is no counts
    /// at all, never `in 0 · out 0`; a tally with either side spent still shows.
    @Test func aTallyOfNothingInAndNothingOutHasNoCounts() {
        let id = UUID()
        let row = { (tally: TokenTally) in
            usageTaskRow(taskId: id, agent: .pi, sessions: [self.tab(id, .pi, 0, active: true)],
                                      contexts: [:], tokens: ["s0": tally]).tokens
        }
        #expect(row(TokenTally(input: 0, cached: 0, output: 0)) == nil)
        #expect(row(TokenTally(input: 0, cached: nil, output: 0)) == nil)
        #expect(row(TokenTally(input: 0, cached: 0, output: 3)) == TokenTally(input: 0, cached: 0, output: 3))
        #expect(row(TokenTally(input: 12, cached: nil, output: 0)) == TokenTally(input: 12, cached: nil, output: 0))
    }

    /// The footer's first row is the selected task's active tab: that tab's agent mark and its
    /// provider's context fill. Other providers' fills in the same task are not drawn.
    @Test func testTheTaskRowFollowsTheActiveTab() {
        let id = UUID()
        let sessions = [tab(id, .claude, 0), tab(id, .codex, 1, active: true), tab(UUID(), .pi, 0, active: true)]
        let task = usageTaskRow(taskId: id, agent: .claude, sessions: sessions,
                                             contexts: [.claude: 42, .codex: 18, .pi: 7])
        #expect(task == UsageTaskRow(agent: .codex,
                                     context: UsageLine(window: .context, percent: 18, reset: nil, warning: false)))
    }

    /// The row is the active tab, whatever runs in it: a shell tab shows the shell with no fill,
    /// even while another tab of the task has reported one.
    @Test func testAnActiveShellTabShowsTheShellWithoutContext() {
        let id = UUID()
        let task = usageTaskRow(taskId: id, agent: .claude,
                                             sessions: [tab(id, .claude, 0), tab(id, .shell, 1, active: true)],
                                             contexts: [.claude: 42])
        #expect(task == UsageTaskRow(agent: .shell, context: nil))
    }

    /// A task whose window is closed has no tab to follow; it shows its own agent's last fill.
    @Test func testATaskWithoutTabsShowsItsOwnAgent() {
        let task = usageTaskRow(taskId: UUID(), agent: .pi, sessions: [tab(UUID(), .codex, 0, active: true)],
                                             contexts: [.pi: 12, .codex: 30])
        #expect(task == UsageTaskRow(agent: .pi, context: UsageLine(window: .context, percent: 12, reset: nil, warning: false)))
    }

    /// A provider that has not reported yet keeps its mark and draws no fill.
    @Test func testAnAgentWithoutContextHasNoFill() {
        let id = UUID()
        let task = usageTaskRow(taskId: id, agent: .claude, sessions: [tab(id, .codex, 0, active: true)],
                                             contexts: [.claude: 42])
        #expect(task == UsageTaskRow(agent: .codex, context: nil))
    }

    /// A selected terminal is a row like a task, its tabs matched by window since they carry no
    /// task tag. A shell shows the shell mark with no fill; starting Claude in that tab turns the
    /// same row into Claude's mark and its fill.
    @Test func testATerminalRowFollowsItsActiveTab() {
        let shell = [session("s0", task: nil, agent: .shell, state: .idle, tab: 0, window: "w2", active: true),
                     session("s1", task: nil, agent: .codex, state: .idle, tab: 0, window: "w3", active: true)]
        #expect(usageTerminalRow(windowId: "w2", sessions: shell, contexts: [.codex: 18])
                == UsageTaskRow(agent: .shell, context: nil))
        var claude = shell
        claude[0].agent = .claude
        #expect(usageTerminalRow(windowId: "w2", sessions: claude, contexts: [.claude: 42, .codex: 18])
                == UsageTaskRow(agent: .claude, context: UsageLine(window: .context, percent: 42, reset: nil, warning: false)))
    }

    /// A terminal whose window is closed has no tab and no agent of its own: it is a shell.
    @Test func testATerminalWithoutTabsIsAShell() {
        #expect(usageTerminalRow(windowId: nil, sessions: [], contexts: [.claude: 42])
                == UsageTaskRow(agent: .shell, context: nil))
    }

    /// The daemon may not have said which tab is current yet; the first tab stands in for it.
    @Test func testWithoutAnActiveTabTheFirstTabLeads() {
        let tabs = [session("s0", task: nil, agent: .codex, state: .idle, tab: 1, window: "w2"),
                    session("s1", task: nil, agent: .claude, state: .idle, tab: 0, window: "w2")]
        #expect(usageTerminalRow(windowId: "w2", sessions: tabs, contexts: [:])
                == UsageTaskRow(agent: .claude, context: nil))
    }

    /// Context crosses the same 80% line as a rate-limit window, so it turns amber with them.
    @Test func testContextWarnsAtTheSameThresholdAsAWindow() {
        let line = { (pct: Int) in usageTaskRow(taskId: UUID(), agent: .claude, sessions: [], contexts: [.claude: pct]).context }
        #expect(line(79) == UsageLine(window: .context, percent: 79, reset: nil, warning: false))
        #expect(line(80) == UsageLine(window: .context, percent: 80, reset: nil, warning: true))
        #expect(line(84)?.help == "Context 84 % full")
    }

    /// PI has no account-quota source, so it never gets a vendor row: its context lives on the task.
    @Test func testVendorRowsAreClaudeAndCodexOnly() {
        let now = Date(timeIntervalSince1970: 1_700_000_000), cal = Calendar(identifier: .gregorian)
        #expect(UsageRows.vendorRows(.empty, now: now, calendar: cal).map(\.vendor) == [.claude, .codex])
    }

    /// Grok Build has no account-quota source either, so it follows PI: no vendor row, only ctx.
    @Test func grokGetsAContextRowAndNoVendorRow() {
        let rows = UsageRows.vendorRows(.empty, now: Date(), calendar: .current)
        #expect(rows.map(\.vendor) == [.claude, .codex])
        let task = UUID()
        let tab = session("g", task: task.uuidString, agent: .grok, state: .working, tab: 0, active: true)
        let row = usageTaskRow(taskId: task, agent: .grok, sessions: [tab], contexts: [.grok: 37])
        #expect(row.agent == .grok && row.context?.percent == 37)
    }

    private func tab(_ task: UUID, _ agent: SessionAgent, _ index: Int, active: Bool = false) -> SessionInfo {
        session("s\(index)", task: task.uuidString, agent: agent, state: .idle, tab: index, active: active)
    }

    /// iTerm2's focused pane in the selected tab is the truth, ahead of the daemon's `active` flag:
    /// that flag arrives a round trip late, and every window has one, so a task's tabs in two
    /// windows have two active panes.
    @Test func theHostsFocusedPaneLeadsOverADaemonActiveFlag() {
        let id = UUID()
        let elsewhere = session("a", task: id.uuidString, agent: .codex, state: .idle, tab: 0, window: "w9", active: true)
        let here = session("b", task: id.uuidString, agent: .claude, state: .idle, tab: 0, window: "w1", active: true)
        let row = UsageRows.taskRow(sessions: [elsewhere, here], fallback: .claude, contexts: [.claude: 50, .codex: 10], preferring: "b")
        #expect(row.agent == .claude && row.context?.percent == 50)
        #expect(UsageRows.taskRow(sessions: [elsewhere, here], fallback: .claude, contexts: [:], preferring: "gone").agent == .codex,
                "a focused pane the daemon has not seen leaves the active flag to decide")
    }
}
