// Ported from AiTerm (app/Sources/AiTermCore/Sidebar/SidebarModel.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// One segment of a footer row: `wk ◔ 84% Mon 21:00`. The ring beside the number is drawn from
/// `percent`, so there is no rendered bar to carry. `reset` is nil for a reading that never clears —
/// the context fill, which is emptied by compaction rather than by the clock, and the Mac's own
/// readings, which are now. `resetInFull` is the same time with its weekday spelt out, for `help`.
public struct UsageLine: Equatable, Sendable {
    /// What a segment measures: a conversation's context fill, one of a vendor's account windows, or
    /// one of the Mac's readings (`MachineReadings`). The footer prints `shortLabel`; the tooltip
    /// and VoiceOver say `name`.
    public enum Window: Equatable, Sendable {
        case context, weekly, fiveHour
        case cpu, ram, battery

        /// The glyphs before the ring: `ctx`, `wk`, `5h`, `cpu`, `ram`, `bat`.
        public var shortLabel: String {
            switch self {
            case .context: "ctx"
            case .weekly: "wk"
            case .fiveHour: "5h"
            case .cpu: "cpu"
            case .ram: "ram"
            case .battery: "bat"
            }
        }

        /// The window in words: "Context", "Weekly limit", "5-hour limit", "CPU", "Memory", "Battery".
        public var name: String {
            switch self {
            case .context: "Context"
            case .weekly: "Weekly limit"
            case .fiveHour: "5-hour limit"
            case .cpu: "CPU"
            case .ram: "Memory"
            case .battery: "Battery"
            }
        }
    }

    public var window: Window; public var percent: Int; public var reset: String?; public var warning: Bool
    public var resetInFull: String? = nil

    public init(window: Window, percent: Int, reset: String? = nil, warning: Bool, resetInFull: String? = nil) {
        self.window = window
        self.percent = percent
        self.reset = reset
        self.warning = warning
        self.resetInFull = resetInFull
    }

    /// The segment in words — its tooltip and its VoiceOver label: "Weekly limit, 61 % used, resets
    /// Friday 23:33", "Context 84 % full", or "CPU 87 % busy, slowed by heat". A Mac reading's
    /// amber names the warning macOS raised, since the number alone does not say why it is amber.
    public var help: String {
        switch window {
        case .context: return "\(window.name) \(percent) % full"
        case .weekly, .fiveHour:
            return "\(window.name), \(percent) % used" + ((resetInFull ?? reset).map { ", resets \($0)" } ?? "")
        case .cpu: return "\(window.name) \(percent) % busy" + (warning ? ", slowed by heat" : "")
        case .ram: return "\(window.name) \(percent) % used" + (warning ? ", under pressure" : "")
        case .battery:
            // AiTerm's "backpack mode turns off at …" returns with Backpack Mode (M1c-4).
            return "\(window.name) \(percent) %" + (warning ? ", running low" : "")
        }
    }
}
/// A vendor's single footer row: its ordered windows, or a note when there is nothing to draw.
/// `warning` marks a note that says the feed is broken rather than merely quiet — the footer draws
/// it amber — so the footer never has to recognise a note by its wording.
public struct UsageVendorRow: Equatable, Sendable {
    public var vendor: SessionAgent; public var lines: [UsageLine]; public var note: String?
    public var warning = false

    public init(vendor: SessionAgent, lines: [UsageLine], note: String?, warning: Bool = false) {
        self.vendor = vendor; self.lines = lines; self.note = note; self.warning = warning
    }
}
/// The footer's first row: what runs in the selected task's or terminal's active tab, its `ctx` line
/// and what its conversation has spent — each absent for a shell, and until the agent has reported it.
public struct UsageTaskRow: Equatable, Sendable {
    public var agent: SessionAgent; public var context: UsageLine?
    /// The active tab's own counts, its subagents and background workers included.
    public var tokens: TokenTally?
    public init(agent: SessionAgent, context: UsageLine?, tokens: TokenTally? = nil) {
        self.agent = agent; self.context = context; self.tokens = tokens
    }
}


/// AiTerm's footer rules (its `SidebarModel`'s usage half): the vendor rows, the selected row's
/// context and counts, and reset times as the status line prints them.
public enum UsageRows {
    public static let warningThreshold = 80
    public static let statusLineMissingNote = "Usage disconnected"

    /// `claudeStatusLineInstalled` is the difference between "the first status line tick has not
    /// arrived yet" and "no tick will ever arrive". Claude Code hands `rate_limits` to the status
    /// line command and to nothing else, so when AiTerm's shim is no longer that command the Claude
    /// row is permanently empty, and saying "No usage data yet" would keep promising data that is not
    /// coming. Codex is unaffected: the daemon reads its rate limits from Codex's own rollout file.
    ///
    /// A window whose `resetsAt` has passed has cleared — whatever percentage it last reported,
    /// that limit is at zero now — so it is dropped rather than drawn. A vendor that has merely
    /// gone quiet keeps its last numbers, drawn like any other: both feeds only move while their
    /// agent runs, so silence is idleness, and the reset clock already says how old a window is.
    ///
    /// `wk` leads every row, then `5h`: Codex often reports only its weekly window, and a shared
    /// first column keeps the two rows aligned.
    ///
    /// Context is not here: it belongs to the selected row and is drawn on ``usageTaskRow``. PI and
    /// Grok Build have no account-quota source AiTerm can read (see the Grok spec's usage spike),
    /// so neither gets a vendor row; both show `ctx` on the task row.
    public static func vendorRows(_ snap: UsageSnapshot, now: Date, calendar: Calendar,
                                       claudeStatusLineInstalled: Bool = true) -> [UsageVendorRow] {
        [(SessionAgent.claude, snap.claude), (.codex, snap.codex)].map { vendor, usage in
            guard let usage else {
                let broken = vendor == .claude && !claudeStatusLineInstalled
                return UsageVendorRow(vendor: vendor, lines: [], note: broken ? statusLineMissingNote : "No usage data yet", warning: broken)
            }
            let epoch = Int(now.timeIntervalSince1970)
            let windows = [(UsageLine.Window.weekly, usage.sevenDay), (.fiveHour, usage.fiveHour)].compactMap { kind, window -> UsageLine? in
                guard let window, (window.resetsAt ?? .max) > epoch else { return nil }
                return UsageLine(window: kind, percent: window.usedPercent,
                                 reset: window.resetsAt.map { fmtReset($0, now: now, calendar: calendar) },
                                 warning: window.usedPercent >= warningThreshold,
                                 resetInFull: window.resetsAt.map { fmtReset($0, now: now, calendar: calendar, inFull: true) })
            }
            return UsageVendorRow(vendor: vendor, lines: windows, note: windows.isEmpty ? "No usage data reported" : nil)
        }
    }

    /// The footer's first row for the sessions of one row — a task's, or one tab's: whatever runs in
    /// its active tab, that agent's last-known fill from `contexts`, and that tab's own counts. Until
    /// the daemon has said which tab is current, the first tab stands in for it; with no session at
    /// all, `fallback` (a task's own agent, or a shell). AiTerm's `usageTaskRow` and
    /// `usageTerminalRow` chose the sessions themselves; here the caller hands in the row's own.
    ///
    /// `preferring` is iTerm2's focused pane in the selected tab, which leads when the row has it:
    /// the daemon's `active` flag arrives a round trip late, and every window has one.
    public static func taskRow(sessions own: [SessionInfo], fallback: SessionAgent, contexts: [SessionAgent: Int],
                               preferring focused: String? = nil) -> UsageTaskRow {
        let tab = own.first { $0.sessionId == focused } ?? own.first(where: \.active) ?? own.min { $0.tabIndex < $1.tabIndex }
        let agent = tab?.agent ?? fallback
        let fill = agent == .shell ? nil : contexts[agent]
        return UsageTaskRow(agent: agent, context: fill.map {
            UsageLine(window: .context, percent: $0, reset: nil, warning: $0 >= warningThreshold)
        }, tokens: agent == .shell ? nil : tab?.tokens.flatMap {
            // Nothing in and nothing out (PI's tally from a session's start) is no counts yet, never
            // `in 0 · out 0`. Dropped here, not by the daemon: a PI /new's zeros still replace an old tally.
            $0.input == 0 && $0.output == 0 ? nil : $0
        })
    }

    /// The statusline's `fmt_reset`: 24-hour local time, with a weekday prefix only across a date
    /// boundary — abbreviated, or `inFull` for the words a tooltip and VoiceOver read.
    public static func fmtReset(_ resetsAt: Int, now: Date, calendar: Calendar, inFull: Bool = false) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(resetsAt))
        let format = calendar.isDate(date, inSameDayAs: now) ? "HH:mm" : inFull ? "EEEE HH:mm" : "EEE HH:mm"
        return formatReset(date, as: format, calendar: calendar)
    }

    /// Building a `DateFormatter` cost more than the rest of the footer together, and the footer is
    /// drawn on every sidebar render — so one per format and time zone is kept.
    private static let resetFormatters = Locked<[String: DateFormatter]>([:])

    /// A kept formatter is used inside the lock and never handed out of it: a `DateFormatter` is
    /// mutable, non-`Sendable` state, and two renders on different threads would share it.
    private static func formatReset(_ date: Date, as format: String, calendar: Calendar) -> String {
        let key = "\(calendar.identifier)|\(calendar.timeZone.identifier)|\(format)"
        return resetFormatters.withLock { cache in
            if let cached = cache[key] { return cached.string(from: date) }
            let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone; f.locale = Locale(identifier: "en_GB")
            f.dateFormat = format
            cache[key] = f
            return f.string(from: date)
        }
    }
}
