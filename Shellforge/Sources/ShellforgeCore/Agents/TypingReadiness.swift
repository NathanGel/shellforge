import Foundation

/// When a typed-in prompt can be typed: once the agent has printed something, the terminal has been
/// quiet for a while, and nothing has been printed for a moment; or at a ceiling after the agent
/// itself was first in the foreground. Quiet is judged as the helper judges sustained output
/// (`auto_status.py`): the whole `quiet` window and each half of it above `minOutputRate`, from at
/// least three samples; anything less is quiet. The caller must observe at least every 0.5 s, or the
/// samples cannot tell a burst from steady output. The decision is single-shot: after the first
/// `.type` or `.abandon`, every later call gives `.abandon`.
///
/// Only the agent is ever typed into. `shellforge-run` (`.runner`) can wait longer than the ceiling
/// for the helper's take, so its time counts toward nothing but `giveUp`; another program is never
/// typed into either. A shell in the foreground after the runner or the agent was seen means the
/// launch is over (the runner failed, or the agent exited) and abandons, so the prompt never runs as
/// a shell command.
public struct TypingReadiness: Sendable {
    /// Mirrors `MIN_OUTPUT_RATE` in `daemon/shellforged/auto_status.py` (a test pins them equal).
    /// Its tuning record, agent by agent, is the comment above it there; 0.9.0 keeps the starting value.
    public static let minOutputRate: Double = 64
    /// The window judged, the helper's `SUSTAIN_SECONDS`.
    public static let quiet: TimeInterval = 3
    /// How long nothing may have been printed, in addition to the window being quiet.
    public static let trailingSilence: TimeInterval = 1
    /// Counted from when the agent itself was first in the foreground.
    public static let ceiling: TimeInterval = 8
    /// Counted from the arm: longer than `run_agent.py`'s socket timeout, so a runner still waiting
    /// is never what gives up. Applies whenever the agent isn't in the foreground.
    public static let giveUp: TimeInterval = 30

    public enum Decision: Equatable, Sendable { case wait, type, abandon }

    private let armedAt: Date
    private var startedAt: Date?
    private var sawRunner = false
    private var baseline = 0
    private var lastGrowth: Date?
    private var done = false
    private var samples: [(t: Date, bytes: Int)] = []

    public init(armedAt: Date) { self.armedAt = armedAt }

    /// `foreground`: what the tab runs now (`AgentIdentity.foreground`).
    public mutating func observe(_ foreground: AgentIdentity.Foreground, outputBytes: Int, now: Date) -> Decision {
        if done { return .abandon }
        switch foreground {
        case .agent:
            break
        case .shell where startedAt != nil || sawRunner:
            return finish(.abandon)
        case .shell, .runner, .other:
            if foreground == .runner { sawRunner = true }
            return now.timeIntervalSince(armedAt) >= Self.giveUp ? finish(.abandon) : .wait
        }
        if startedAt == nil {
            // Output before the agent ran is the shell's, not the agent's.
            startedAt = now; baseline = outputBytes; samples = []; lastGrowth = nil
        }
        if let last = samples.last {
            if outputBytes < last.bytes { samples = []; baseline = outputBytes; lastGrowth = nil }
            else if outputBytes > last.bytes { lastGrowth = now }
        }
        if let last = samples.last, last.t >= now { samples.removeLast() }
        samples.append((now, outputBytes))
        // Keep the samples of the last `quiet` seconds and the newest one at least that old.
        while samples.count >= 2, samples[1].t <= now.addingTimeInterval(-Self.quiet) { samples.removeFirst() }

        if now.timeIntervalSince(startedAt!) >= Self.ceiling { return finish(.type) }
        guard outputBytes > baseline, let growth = lastGrowth, let first = samples.first,
              now.timeIntervalSince(first.t) >= Self.quiet,
              now.timeIntervalSince(growth) >= Self.trailingSilence else { return .wait }
        return Self.sustained(samples, now: now, bytes: outputBytes) ? .wait : finish(.type)
    }

    private mutating func finish(_ d: Decision) -> Decision { done = true; return d }

    private static func rate(_ a: (t: Date, bytes: Int), _ b: (t: Date, bytes: Int)) -> Double {
        let dt = b.t.timeIntervalSince(a.t)
        return dt > 0 ? Double(b.bytes - a.bytes) / dt : 0
    }

    private static func sustained(_ s: [(t: Date, bytes: Int)], now: Date, bytes: Int) -> Bool {
        let first = s[0], last = (t: now, bytes: bytes)
        guard rate(first, last) >= minOutputRate, s.count >= 3 else { return false }
        let mid = first.t.addingTimeInterval(now.timeIntervalSince(first.t) / 2)
        let middle = s.dropFirst().dropLast().min { abs($0.t.timeIntervalSince(mid)) < abs($1.t.timeIntervalSince(mid)) }!
        return rate(first, middle) >= minOutputRate && rate(middle, last) >= minOutputRate
    }
}
