// Ported from AiTerm (app/Sources/AiTermCore/Daemon/DaemonTypes.swift, SessionAgent and SessionState
// from Models.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// Which agent a session runs: one of the four built-ins, a plain shell, or an agent the user
/// defined, which the daemon names `custom:<id>`. A skewed daemon can send a raw value this app has
/// never heard of; decoding it to `.shell` keeps that one session from failing the whole
/// `DaemonSnapshot`.
public enum SessionAgent: Hashable, Codable, Sendable {
    case claude, codex, grok, pi, shell
    case custom(String)

    public static let builtIns: [SessionAgent] = [.claude, .codex, .grok, .pi]
    private static let customPrefix = "custom:"

    /// An id a custom agent may have, as the daemon's `AGENT_ID` and the agent file's name allow.
    static func isValidId(_ id: String) -> Bool {
        (1...64).contains(id.utf8.count) && id.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x5F || $0 == 0x2D
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "claude": self = .claude
        case "codex": self = .codex
        case "grok": self = .grok
        case "pi": self = .pi
        case "shell": self = .shell
        default:
            guard rawValue.hasPrefix(Self.customPrefix) else { return nil }
            let id = String(rawValue.dropFirst(Self.customPrefix.count))
            guard Self.isValidId(id) else { return nil }
            self = .custom(id)
        }
    }

    /// A built-in's case, or `.custom(id)` for any other id.
    public init(agentId: String) {
        self = Self.builtIns.first { $0.rawValue == agentId } ?? .custom(agentId)
    }

    public var rawValue: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .grok: "grok"
        case .pi: "pi"
        case .shell: "shell"
        case .custom(let id): Self.customPrefix + id
        }
    }

    /// The id of a custom agent; nil for a built-in and for a shell.
    public var customId: String? {
        if case .custom(let id) = self { id } else { nil }
    }

    public init(from decoder: Decoder) throws {
        self = SessionAgent(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .shell
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// What a session is doing. An unrecognized raw value decodes to `.idle` rather than failing the
/// session, and with it the snapshot, it came in.
public enum SessionState: String, Codable, Equatable, CaseIterable, Sendable {
    case idle, working, needsInput, done
    public init(from decoder: Decoder) throws {
        self = SessionState(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .idle
    }
}

public struct SessionInfo: Codable, Equatable, Identifiable, Sendable {
    public var sessionId: String, windowId: String, tabIndex: Int, taskId: String?, projectId: String?
    public var agent: SessionAgent, model: String?, reasoning: String? = nil, state: SessionState, title: String, cwd: String
    /// The directory the *agent* is in. `cwd` is the shell's and never follows
    /// a Claude that has entered a worktree; the daemon fills this in from the agent's own session
    /// file (Claude) or its hook posts (Codex). Absent for a plain shell.
    public var agentCwd: String? = nil
    /// True for the tab that was current in its window as of the daemon's last snapshot. The
    /// bundled daemon always says; one that does not is read as saying no.
    public var active = false
    /// This provider's last-known context fill within the task, 0-100. The daemon shares it across
    /// sibling tabs running the same provider so tab changes cannot erase it. An unassociated
    /// session may carry its own value, but the app only displays task context.
    public var contextPercent: Int? = nil
    /// What this tab's conversation has spent, its subagents and background workers included. The
    /// tab's own — the daemon never shares it across sibling tabs, as it does a context fill.
    public var tokens: TokenTally? = nil
    /// When the daemon last had an exact report of this tab's state from its agent's hooks, as seconds
    /// since 1970 on its clock; nil until the first one.
    public var reportedAt: Double? = nil
    /// Whether the daemon is still guessing this tab's state from its terminal output: a custom
    /// agent's tab that no hook has reported for yet.
    public var statusIsGuessed: Bool { agent.customId != nil && reportedAt == nil }
    public var id: String { sessionId }
    /// The task tag as the id it names. The app writes `uuidString`, but a tag read back from
    /// a session is a string, so it is compared as a UUID rather than by spelling.
    public var taskUUID: UUID? { taskId.flatMap(UUID.init(uuidString:)) }
    /// What this tab's branch must be resolved from.
    public var effectiveCwd: String { agentCwd ?? cwd }

    public init(sessionId: String, windowId: String, tabIndex: Int, taskId: String?, projectId: String?,
                agent: SessionAgent, model: String?, reasoning: String? = nil, state: SessionState, title: String, cwd: String,
                agentCwd: String? = nil, active: Bool = false, contextPercent: Int? = nil, tokens: TokenTally? = nil,
                reportedAt: Double? = nil) {
        self.sessionId = sessionId; self.windowId = windowId; self.tabIndex = tabIndex; self.taskId = taskId
        self.projectId = projectId; self.agent = agent; self.model = model; self.reasoning = reasoning
        self.state = state; self.title = title; self.cwd = cwd; self.agentCwd = agentCwd; self.active = active
        self.contextPercent = contextPercent; self.tokens = tokens; self.reportedAt = reportedAt
    }
}

extension SessionInfo {
    /// Written by hand for `active` alone, which an older daemon leaves out; every other field is
    /// read as the synthesised decoder would. In an extension, so the memberwise initialiser stays.
    /// `WireContractTests` reads the daemon's own sessions with it and compares each field with the
    /// daemon's JSON, so a field this misreads, or a key it reads under another name, shows there.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        windowId = try c.decode(String.self, forKey: .windowId)
        tabIndex = try c.decode(Int.self, forKey: .tabIndex)
        taskId = try c.decodeIfPresent(String.self, forKey: .taskId)
        projectId = try c.decodeIfPresent(String.self, forKey: .projectId)
        agent = try c.decode(SessionAgent.self, forKey: .agent)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        reasoning = try c.decodeIfPresent(String.self, forKey: .reasoning)
        state = try c.decode(SessionState.self, forKey: .state)
        title = try c.decode(String.self, forKey: .title)
        cwd = try c.decode(String.self, forKey: .cwd)
        agentCwd = try c.decodeIfPresent(String.self, forKey: .agentCwd)
        active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? false
        contextPercent = try c.decodeIfPresent(Int.self, forKey: .contextPercent)
        // Read leniently: a tally this app cannot read — a count too large for an `Int`, a daemon of
        // another shape — costs only these counts, not the session and the snapshot it came in.
        tokens = (try? c.decodeIfPresent(TokenTally.self, forKey: .tokens)) ?? nil
        reportedAt = try c.decodeIfPresent(Double.self, forKey: .reportedAt)
    }
}

/// What one conversation has spent so far, its subagents and background workers included (the
/// daemon's `TokenTally`). `input` counts cache reads and writes too; `cached` is that share — nil
/// when the harness cannot tell it apart — and `output` counts reasoning.
public struct TokenTally: Codable, Equatable, Sendable {
    public var input: Int, cached: Int?, output: Int
    public init(input: Int, cached: Int?, output: Int) { self.input = input; self.cached = cached; self.output = output }
}

public struct UsageWindow: Codable, Equatable, Sendable { public var usedPercent: Int; public var resetsAt: Int?
    public init(usedPercent: Int, resetsAt: Int?) { self.usedPercent = usedPercent; self.resetsAt = resetsAt } }
public struct Usage: Codable, Equatable, Sendable {
    public var fiveHour, sevenDay, spend: UsageWindow?; public var plan: String?
    /// When the vendor last reported, in epoch seconds.
    public var updatedAt: Int
}
public struct UsageSnapshot: Codable, Equatable, Sendable { public var claude, codex: Usage?
    public static let empty = UsageSnapshot(claude: nil, codex: nil) }

/// A request's failure: the daemon's error reply, or this client's own (`Code`). `message` is
/// written for the protocol, or by Python — "no such window or session: w3", an exception's text —
/// so it is what the log and a developer read (`description`); the person reads `userMessage`.
public struct DaemonError: Error, Equatable, LocalizedError, CustomStringConvertible {
    public let code: Code, message: String
    public var errorDescription: String? { userMessage }
    public var description: String { message }

    /// The failure as a banner's reason says it, by its code — never the helper's own message, which
    /// is written for the protocol or by Python. A code only a newer helper knows reads as the
    /// helper's problem, as `internal` does.
    public var userMessage: String {
        switch code {
        case .notFound: "That tab is already gone."
        case .timeout: "Shellforge’s helper didn’t answer in time; it may still finish."
        case .disconnected, .connect, .socket, .write, .connectionUsed: "Shellforge’s helper isn’t connected."
        case .unknownMethod, .incompatible: "Shellforge’s helper is from another version."
        case .badParams, .protocol: "Shellforge’s helper couldn’t read the request."
        default: "Shellforge’s helper ran into a problem."
        }
    }

    public var isNotFound: Bool { code == .notFound }
    /// Either code a stale or mismatched helper answers with, as opposed to the helper being
    /// unreachable — `DaemonConnection` reports these as `.helperMismatch`, not a retryable outage.
    public var isMismatch: Bool { code == .incompatible || code == .unknownMethod }
}

public struct DaemonSnapshot: Decodable, Equatable, Sendable {
    public let protocolVersion: Int
    public let connected: Bool
    public let sessions: [SessionInfo]
    public let usage: UsageSnapshot
    /// The daemon's supervisor still reports these from its iTerm2 days: in app mode the version is
    /// "Shellforge" and the other two are null. Read, so the snapshot's fields match the daemon's.
    public var itermVersion: String? = nil
    public var itermAuthError: String? = nil
    public var itermCookieRequest: Int? = nil
    /// Every tunnel the daemon runs or ran; none from a helper older than tunnels.
    public var tunnels: [TunnelInfo]? = nil

    public init(protocolVersion: Int, connected: Bool, sessions: [SessionInfo], usage: UsageSnapshot) {
        self.protocolVersion = protocolVersion; self.connected = connected; self.sessions = sessions; self.usage = usage
    }
}

/// One of the app's tabs, as `sessions.update` takes it (`shellforged/app_sessions.py`). Every key
/// is written, a missing value as null: the daemon reads each by name.
public struct SessionReport: Codable, Equatable, Sendable {
    public var sessionId: String, windowId: String, tabIndex: Int
    public var commandLine: String?, jobPid: Int?
    public var title: String, cwd: String, active: Bool
    public var taskId: String?, projectId: String?
    /// The id of the custom agent the tab runs, and the terminal signals read for it: bytes of
    /// output so far, and the bell count.
    public var agentId: String?, outputBytes: Int?, attention: Int?

    /// Takes the ids as UUIDs so they are spelled one way: the daemon matches them as strings, and
    /// the sidebar's session tags are lowercase (`DaemonClient.wireId`).
    public init(sessionId: String, windowId: String, tabIndex: Int, commandLine: String?, jobPid: Int?, title: String,
                cwd: String, active: Bool, task: UUID?, project: UUID?,
                agentId: String? = nil, outputBytes: Int? = nil, attention: Int? = nil) {
        self.sessionId = sessionId; self.windowId = windowId; self.tabIndex = tabIndex; self.commandLine = commandLine
        self.jobPid = jobPid; self.title = title; self.cwd = cwd; self.active = active
        self.taskId = task.map(DaemonClient.wireId); self.projectId = project.map(DaemonClient.wireId)
        self.agentId = agentId; self.outputBytes = outputBytes; self.attention = attention
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(windowId, forKey: .windowId)
        try c.encode(tabIndex, forKey: .tabIndex)
        try c.encode(commandLine, forKey: .commandLine)
        try c.encode(jobPid, forKey: .jobPid)
        try c.encode(title, forKey: .title)
        try c.encode(cwd, forKey: .cwd)
        try c.encode(active, forKey: .active)
        try c.encode(taskId, forKey: .taskId)
        try c.encode(projectId, forKey: .projectId)
        try c.encode(agentId, forKey: .agentId)
        try c.encode(outputBytes, forKey: .outputBytes)
        try c.encode(attention, forKey: .attention)
    }
}

/// What the daemon says, in the order it said it. `.snapshot` is the bootstrap barrier: events
/// before it are older than the snapshot. Events Shellforge does not read arrive as `.unknown`.
public enum DaemonEvent: Equatable, Sendable {
    case snapshot(DaemonSnapshot)
    case sessionOpened(SessionInfo), sessionClosed(String), sessionChanged(SessionInfo)
    case usageChanged(UsageSnapshot), tunnelChanged(TunnelInfo), unknown(String)
}

/// Where an SSH tunnel stands, as the daemon's supervisor says (`shellforged/tunnels.py`).
public enum TunnelState: String, Codable, Equatable, Sendable {
    /// Not running: never started, or stopped.
    case stopped
    /// ssh is starting, or restarting after a drop.
    case connecting
    /// ssh has held its forwards for a moment.
    case up
    /// ssh ended before it was up; `error` says why, and it is not restarted.
    case failed
}

/// One tunnel, as `tunnel.changed` and the snapshot carry it.
public struct TunnelInfo: Codable, Equatable, Sendable {
    public var alias: String
    public var state: TunnelState
    /// ssh's last line, for a failure or a drop.
    public var error: String?
    /// When it came to this state, in the daemon's clock's seconds.
    public var since: Double
    /// ssh's traffic since it started, as `nettop` counts it; nil until sampled, or from an older daemon.
    public var bytesIn: Int?
    public var bytesOut: Int?
    /// Who holds its ports when not the supervisor: a terminal tab the user answers ssh in.
    public var heldBy: TunnelHolder?
    /// It failed because ssh needed an answer: a host key, a passphrase, a code.
    public var needsInput: Bool?

    public init(alias: String, state: TunnelState, error: String?, since: Double, bytesIn: Int? = nil, bytesOut: Int? = nil,
                heldBy: TunnelHolder? = nil, needsInput: Bool? = nil) {
        self.alias = alias; self.state = state; self.error = error; self.since = since
        self.bytesIn = bytesIn; self.bytesOut = bytesOut; self.heldBy = heldBy; self.needsInput = needsInput
    }
}

/// Who holds a tunnel's ports other than the supervisor.
public enum TunnelHolder: String, Codable, Equatable, Sendable {
    case tab
}

/// What routes a line from the daemon: a reply's `id` and `error`, or an event's name. The rest of
/// the line is decoded from the same bytes, once, into the type its route names (`Reply`,
/// `EventPayload`), with no untyped tree in between.
struct Header: Decodable { var id: Int?, event: String?, error: DaemonErrorBody? }
struct DaemonErrorBody: Decodable { var code: DaemonError.Code, message: String }
/// A reply's `result`, as the request's own type.
struct Reply<Value: Decodable>: Decodable { var result: Value }
/// An event's `payload`, as the type its name says.
struct EventPayload<Value: Decodable>: Decodable { var payload: Value }

extension SessionReport {
    /// The session variables a report is read from: iTerm2's names, as shellforged's own iTerm2
    /// bridge reads them (`iterm_bridge.VARIABLES`).
    public enum Variable {
        public static let commandLine = "commandLine"
        public static let jobPid = "jobPid"
        public static let title = "autoName"
        public static let path = "path"
    }

    private static func taskTag(_ value: (String) -> Any?) -> UUID? {
        (value(ShellforgeTags.task) as? String).flatMap(UUID.init(uuidString:))
    }

    /// One session's report from its placement and a lookup of its variables (`Variable`, and the
    /// task and project tags). A job pid of 0 or less is no job; a tag that is not a UUID is no tag.
    public static func reading(sessionId: String, windowId: String, tabIndex: Int, active: Bool,
                               value: (String) -> Any?) -> SessionReport {
        let pid = (value(Variable.jobPid) as? NSNumber)?.intValue
        return SessionReport(sessionId: sessionId, windowId: windowId, tabIndex: tabIndex,
                             commandLine: value(Variable.commandLine) as? String,
                             jobPid: pid.flatMap { $0 > 0 ? $0 : nil },
                             title: value(Variable.title) as? String ?? "",
                             cwd: value(Variable.path) as? String ?? "",
                             active: active,
                             task: taskTag(value),
                             project: (value(ShellforgeTags.project) as? String).flatMap(UUID.init(uuidString:)))
    }

    /// As `reading`, and for a tab that runs a custom agent (`AgentIdentity.customAgent`) the agent's
    /// id and the terminal signals read for it. A built-in agent's tab carries none: its own hooks report.
    public static func reading(sessionId: String, windowId: String, tabIndex: Int, active: Bool,
                               value: (String) -> Any?, taskAgent: (UUID) -> String?, agents: [AgentDefinition],
                               signals: (String) -> TerminalSignals?) -> SessionReport {
        var report = reading(sessionId: sessionId, windowId: windowId, tabIndex: tabIndex, active: active, value: value)
        guard let id = AgentIdentity.customAgent(taskAgent: taskTag(value).flatMap(taskAgent), commandLine: report.commandLine, agents: agents)
        else { return report }
        report.agentId = id
        let s = signals(sessionId)
        report.outputBytes = s?.outputBytes ?? 0
        report.attention = s?.attention ?? 0
        return report
    }
}
