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

    /// The task's most urgent tab: needs input, then working, then done, then idle.
    public func status(ofTask id: UUID) -> SessionState {
        TaskStatus.aggregate(sessions.values.filter { $0.taskUUID == id }.map(\.state))
    }

    /// The tab's own state; idle for a tab the daemon does not know.
    public func status(ofTab sessionId: String) -> SessionState {
        sessions[sessionId]?.state ?? .idle
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
