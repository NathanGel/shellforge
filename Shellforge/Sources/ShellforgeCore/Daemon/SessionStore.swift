import Foundation

/// What the daemon has said about the sessions, folded from its event stream: the bootstrap
/// snapshot, then each change. Events before the first snapshot are older than it and dropped —
/// the snapshot is the barrier (`DaemonClient.snapshot()`).
public struct SessionStore: Equatable, Sendable {
    public private(set) var sessions: [String: SessionInfo] = [:]
    public private(set) var usage: UsageSnapshot = .empty
    /// Whether the first snapshot has arrived; until it has, nothing is known.
    public private(set) var bootstrapped = false

    public init() {}

    public mutating func apply(_ event: DaemonEvent) {
        if case .snapshot(let snapshot) = event {
            sessions = Dictionary(snapshot.sessions.map { ($0.sessionId, $0) }, uniquingKeysWith: { _, last in last })
            usage = snapshot.usage
            bootstrapped = true
            return
        }
        guard bootstrapped else { return }
        switch event {
        case .sessionOpened(let session), .sessionChanged(let session): sessions[session.sessionId] = session
        case .sessionClosed(let id): sessions[id] = nil
        case .usageChanged(let usage): self.usage = usage
        case .snapshot, .unknown: break
        }
    }

    /// The task's most urgent pane, in every tab one of its sessions is in: needs input, then
    /// working, then done, then idle. Only the pane that opened a tab carries the task's tag; a
    /// split beside it is the task's too.
    public func status(ofTask id: UUID) -> SessionState {
        let tabs = Set(sessions.values.filter { $0.taskUUID == id }.map(TabKey.init))
        return TaskStatus.aggregate(sessions.values.filter { tabs.contains(TabKey($0)) }.map(\.state))
    }

    /// The most urgent pane of the tab `sessionId` is in; idle for a session the daemon does not know.
    public func status(ofTab sessionId: String) -> SessionState {
        guard let session = sessions[sessionId] else { return .idle }
        let tab = TabKey(session)
        return TaskStatus.aggregate(sessions.values.filter { TabKey($0) == tab }.map(\.state))
    }

    /// A tab, as the daemon places its sessions: the window and the tab's index in it.
    private struct TabKey: Hashable {
        let windowId: String, tabIndex: Int
        init(_ session: SessionInfo) { windowId = session.windowId; tabIndex = session.tabIndex }
    }
}

public enum TaskStatus {
    /// A row with several tabs shows the most urgent of them: an input request must stay visible.
    public static func aggregate(_ states: [SessionState]) -> SessionState {
        if states.contains(.needsInput) { return .needsInput }
        if states.contains(.working) { return .working }
        if states.contains(.done) { return .done }
        return .idle
    }
}
