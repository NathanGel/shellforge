import Foundation

/// What the daemon has said about the sessions, folded from its event stream: the bootstrap
/// snapshot, then each change. Events before the first snapshot are older than it and dropped —
/// the snapshot is the barrier (`DaemonClient.snapshot()`).
public struct SessionStore: Equatable, Sendable {
    public private(set) var sessions: [String: SessionInfo] = [:]
    public private(set) var usage: UsageSnapshot = .empty
    /// Every tunnel the daemon runs or ran, by alias.
    public private(set) var tunnels: [String: TunnelInfo] = [:]
    /// Whether the first snapshot has arrived; until it has, nothing is known.
    public private(set) var bootstrapped = false
    /// `sessions` by tab and by task, made once per update: every sidebar row asks, every redraw.
    private var index = Index()

    public init() {}

    /// Equal when what the daemon said is: the index follows from it.
    public static func == (lhs: SessionStore, rhs: SessionStore) -> Bool {
        lhs.bootstrapped == rhs.bootstrapped && lhs.sessions == rhs.sessions && lhs.usage == rhs.usage && lhs.tunnels == rhs.tunnels
    }

    public mutating func apply(_ event: DaemonEvent) {
        if case .snapshot(let snapshot) = event {
            sessions = Dictionary(snapshot.sessions.map { ($0.sessionId, $0) }, uniquingKeysWith: { _, last in last })
            usage = snapshot.usage
            tunnels = Dictionary((snapshot.tunnels ?? []).map { ($0.alias, $0) }, uniquingKeysWith: { _, last in last })
            bootstrapped = true
            index = Index(sessions)
            return
        }
        guard bootstrapped else { return }
        switch event {
        case .sessionOpened(let session), .sessionChanged(let session):
            sessions[session.sessionId] = session
            index = Index(sessions)
        case .sessionClosed(let id):
            sessions[id] = nil
            index = Index(sessions)
        case .usageChanged(let usage): self.usage = usage
        case .tunnelChanged(let tunnel): tunnels[tunnel.alias] = tunnel
        case .snapshot, .unknown: break
        }
    }

    /// The task's most urgent pane, in every tab one of its sessions is in: needs input, then
    /// working, then done, then idle. Only the pane that opened a tab carries the task's tag; a
    /// split beside it is the task's too.
    public func status(ofTask id: UUID) -> SessionState {
        TaskStatus.aggregate(sessions(ofTask: id).map(\.state))
    }

    /// The most urgent pane of the tab `sessionId` is in; idle for a session the daemon does not know.
    public func status(ofTab sessionId: String) -> SessionState {
        guard sessions[sessionId] != nil else { return .idle }
        return TaskStatus.aggregate(sessions(ofTab: sessionId).map(\.state))
    }

    /// The sessions in every tab one of `id`'s sessions is in — a tab's split panes are its task's.
    public func sessions(ofTask id: UUID) -> [SessionInfo] {
        index.byTask[id] ?? []
    }

    /// The sessions in the tab `sessionId` is in.
    public func sessions(ofTab sessionId: String) -> [SessionInfo] {
        guard let session = sessions[sessionId] else { return [] }
        return index.byTab[TabKey(session)] ?? []
    }

    /// A tab, as the daemon places its sessions: the window and the tab's index in it.
    private struct TabKey: Hashable, Sendable {
        let windowId: String, tabIndex: Int
        init(_ session: SessionInfo) { windowId = session.windowId; tabIndex = session.tabIndex }
    }

    /// Each tab's sessions, and each task's: those of every tab one of its sessions is in. Both
    /// in `sessions`' own order, as the scans they replace returned them.
    private struct Index: Sendable {
        var byTab: [TabKey: [SessionInfo]] = [:]
        var byTask: [UUID: [SessionInfo]] = [:]

        init() {}

        init(_ sessions: [String: SessionInfo]) {
            var tasksOfTab: [TabKey: [UUID]] = [:]
            for session in sessions.values {
                let tab = TabKey(session)
                byTab[tab, default: []].append(session)
                if let task = session.taskUUID, !(tasksOfTab[tab]?.contains(task) ?? false) { tasksOfTab[tab, default: []].append(task) }
            }
            for session in sessions.values {
                for task in tasksOfTab[TabKey(session)] ?? [] { byTask[task, default: []].append(session) }
            }
        }
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
