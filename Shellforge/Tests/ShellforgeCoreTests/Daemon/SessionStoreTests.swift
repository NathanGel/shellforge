import Foundation
import Testing
@testable import ShellforgeCore

@Suite struct SessionStoreTests {
    private func session(_ id: String, task: UUID?, _ state: SessionState) -> SessionInfo {
        SessionInfo(sessionId: id, windowId: "pty-1", tabIndex: 0, taskId: task?.uuidString, projectId: nil,
                    agent: .claude, model: nil, state: state, title: id, cwd: "/r")
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

    @Test func aTaskShowsItsMostUrgentTab() {
        let task = UUID()
        var store = SessionStore()
        store.apply(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true, sessions: [
            session("a", task: task, .done), session("b", task: task, .needsInput), session("c", task: nil, .working)],
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
