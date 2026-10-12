import Foundation
import Testing
@testable import ShellforgeCore

@Suite struct SessionStoreTests {
    private func session(_ id: String, task: UUID?, _ state: SessionState) -> SessionInfo {
        SessionInfo(sessionId: id, windowId: "pty-1", tabIndex: 0, taskId: task?.uuidString, projectId: nil,
                    agent: .claude, model: nil, state: state, title: id, cwd: "/r")
    }

    private func pane(_ id: String, tab: Int, task: UUID?, _ state: SessionState) -> SessionInfo {
        SessionInfo(sessionId: id, windowId: "pty-1", tabIndex: tab, taskId: task?.uuidString.lowercased(), projectId: nil,
                    agent: .codex, model: nil, state: state, title: id, cwd: "/r")
    }

    /// A tab is all its panes: an agent waiting in a split beside the selected one shows on the tab,
    /// and on the task the tab belongs to, though only the pane that opened the tab carries the tag.
    @Test func aTabAndItsTaskShowEveryPaneOfTheTab() {
        let task = UUID()
        var store = SessionStore()
        store.apply(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true, sessions: [
            pane("a", tab: 0, task: task, .idle), pane("b", tab: 0, task: nil, .needsInput), pane("c", tab: 1, task: nil, .working),
        ], usage: .empty)))
        #expect(store.status(ofTab: "a") == .needsInput)
        #expect(store.status(ofTab: "b") == .needsInput)
        #expect(store.status(ofTask: task) == .needsInput)
        #expect(store.status(ofTab: "c") == .working)       // another tab's pane is not this tab's
    }

    @Test func eventsBeforeTheSnapshotAreIgnored() {
        var store = SessionStore()
        store.apply(.sessionOpened(session("a", task: nil, .working)))
        store.apply(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true, sessions: [], usage: .empty)))
        #expect(store.sessions.isEmpty && store.bootstrapped)
    }

    @Test func openedChangedAndClosedKeepTheSessionsCurrent() {
        var store = SessionStore()
        store.apply(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true, sessions: [session("a", task: nil, .idle)], usage: .empty)))
        store.apply(.sessionChanged(session("a", task: nil, .working)))
        store.apply(.sessionOpened(session("b", task: nil, .idle)))
        store.apply(.sessionClosed("a"))
        #expect(store.sessions.keys.sorted() == ["b"])
    }

    /// Each tunnel's state, from the snapshot and then from every change the daemon broadcasts.
    @Test func tunnelEventsKeepTheirStateCurrent() {
        var store = SessionStore()
        var snapshot = DaemonSnapshot(protocolVersion: 1, connected: true, sessions: [], usage: .empty)
        snapshot.tunnels = [TunnelInfo(alias: "db", state: .up, error: nil, since: 1)]
        store.apply(.snapshot(snapshot))
        #expect(store.tunnels["db"]?.state == .up)
        store.apply(.tunnelChanged(TunnelInfo(alias: "db", state: .failed, error: "bind: Address already in use", since: 2)))
        store.apply(.tunnelChanged(TunnelInfo(alias: "cache", state: .connecting, error: nil, since: 3)))
        #expect(store.tunnels["db"] == TunnelInfo(alias: "db", state: .failed, error: "bind: Address already in use", since: 2))
        #expect(store.tunnels.keys.sorted() == ["cache", "db"])
    }

    @Test func aTaskShowsItsMostUrgentTab() {
        let task = UUID()
        var store = SessionStore()
        store.apply(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true, sessions: [
            pane("a", tab: 0, task: task, .done), pane("b", tab: 1, task: task, .needsInput), pane("c", tab: 2, task: nil, .working)],
            usage: .empty)))
        #expect(store.status(ofTask: task) == .needsInput)
        #expect(store.status(ofTab: "c") == .working)
        #expect(store.status(ofTask: UUID()) == .idle)
    }

    @Test(arguments: [([SessionState.idle, .done], SessionState.done), ([.done, .working], .working),
                      ([.working, .needsInput, .done], .needsInput), ([], .idle)])
    func urgencyOrder(states: [SessionState], expected: SessionState) {
        #expect(TaskStatus.aggregate(states) == expected)
    }
}
