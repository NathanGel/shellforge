// Ported from AiTerm (app/Tests/AiTermCoreTests/SessionContextsTests.swift), GPLv3, Laurens D'Hondt.
import Foundation
import Testing
@testable import ShellforgeCore

/// The context fill each row keeps per agent (`SessionContexts`), as the tabs report it. AiTerm
/// resolved a session's row through its `AppState`; here the caller hands in the resolver — a
/// task by its tag while the workspace has it, a tab outside any task by the sidebar's own tab.
@Suite struct SessionContextsTests {
    func tab(_ id: String, window: String, task: UUID? = nil, agent: SessionAgent, active: Bool, context: Int?) -> SessionInfo {
        var s = SessionInfo(sessionId: id, windowId: window, tabIndex: 0, taskId: task?.uuidString, projectId: nil,
                            agent: agent, model: nil, state: .idle, title: id, cwd: "/repo")
        s.active = active; s.contextPercent = context
        return s
    }

    /// The workspace's tasks, and which window each sidebar tab outside a task stands for.
    func resolver(tasks: Set<UUID>, tabs: [String: Int] = [:]) -> (SessionInfo) -> FooterRow? {
        { session in
            if let task = session.taskUUID { return tasks.contains(task) ? .task(task) : nil }
            guard session.taskId == nil else { return nil }
            return tabs[session.windowId].map(FooterRow.tab)
        }
    }

    /// A snapshot seeds each agent from its active tab; a tab change keeps the row's value until a
    /// tab reports, even one re-reporting an old value; missing telemetry never erases one; and a
    /// row that leaves the workspace takes its values with it.
    @Test func aTasksContextFollowsWhatItsTabsReport() {
        let task = UUID()
        let row = resolver(tasks: [task])
        let first = tab("a", window: "w1", task: task, agent: .claude, active: true, context: 42)
        let second = tab("b", window: "w1", task: task, agent: .claude, active: false, context: 18)
        let codex = tab("c", window: "w1", task: task, agent: .codex, active: false, context: 64)
        var contexts = SessionContexts()
        contexts.seed(from: [first, second, codex], row: row)
        #expect(contexts.percents(forRow: .task(task)) == [.claude: 42, .codex: 64])

        var firstInactive = first; firstInactive.active = false
        var secondActive = second; secondActive.active = true
        contexts.remember(firstInactive, replacing: first, row: row)
        contexts.remember(secondActive, replacing: second, row: row)
        #expect(contexts.percents(forRow: .task(task)) == [.claude: 42, .codex: 64], "a tab change is not telemetry")

        var propagated = firstInactive; propagated.contextPercent = 18
        contexts.remember(propagated, replacing: firstInactive, row: row)
        #expect(contexts.percents(forRow: .task(task)) == [.claude: 18, .codex: 64], "a tab re-reporting an old value still replaces it")

        var reported = secondActive; reported.contextPercent = 27
        contexts.remember(reported, replacing: secondActive, row: row)
        var silent = reported; silent.contextPercent = nil
        contexts.remember(silent, replacing: reported, row: row)
        #expect(contexts.percents(forRow: .task(task)) == [.claude: 27, .codex: 64], "missing telemetry never erases a value")

        contexts.seed(from: [first, second, codex], row: row)
        #expect(contexts.percents(forRow: .task(task)) == [.claude: 27, .codex: 64], "a snapshot only fills what is unknown")

        contexts.prune(keeping: [])
        #expect(contexts.percents(forRow: .task(task)).isEmpty)
        #expect(contexts == SessionContexts())
    }

    /// With no active tab for an agent, its fullest tab seeds the row.
    @Test func withNoActiveTabTheFullestSeeds() {
        let task = UUID()
        var contexts = SessionContexts()
        contexts.seed(from: [tab("a", window: "w1", task: task, agent: .claude, active: false, context: 12),
                             tab("b", window: "w1", task: task, agent: .claude, active: false, context: 30)],
                      row: resolver(tasks: [task]))
        #expect(contexts.percents(forRow: .task(task)) == [.claude: 30])
    }

    /// A tab outside any task is its own row (AiTerm's terminal, matched on its window); a tab tagged
    /// with a task the workspace does not have counts for no row.
    @Test func aTabsContextIsMatchedThroughItsResolver() {
        let row = resolver(tasks: [], tabs: ["w2": 2, "w3": 3])
        var contexts = SessionContexts()
        let shell = tab("t", window: "w2", agent: .shell, active: true, context: nil)
        contexts.seed(from: [shell], row: row)
        #expect(contexts == SessionContexts())

        var claude = shell; claude.agent = .claude
        contexts.remember(claude, replacing: shell, row: row)
        #expect(contexts == SessionContexts(), "the agent has not reported yet")
        var reporting = claude; reporting.contextPercent = 12
        contexts.remember(reporting, replacing: claude, row: row)
        #expect(contexts.percents(forRow: .tab(2)) == [.claude: 12])
        #expect(contexts.percents(forRow: .tab(3)).isEmpty, "another tab is not this one")

        let before = contexts
        contexts.remember(tab("x", window: "w2", task: UUID(), agent: .claude, active: true, context: 90), replacing: nil, row: row)
        #expect(contexts == before, "a tab tagged with a task the workspace lacks is not the tab's")
    }
}
