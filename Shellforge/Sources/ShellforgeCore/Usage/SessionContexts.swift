// Ported from AiTerm (app/Sources/AiTermCore/Sidebar/SessionContexts.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// The context fill each sidebar row last reported, per provider. Context is shown per row — a task
/// or a terminal — not per tab: each provider's last value is kept while tabs switch, or while a
/// snapshot has nothing new to say. Nothing here is saved.
/// A sidebar row the footer can show: a task, or a tab outside any task (AiTerm's terminal), by
/// its `TabSnapshot.tabId` — iTerm2's own number for the tab, which stays while another of its
/// panes is focused (the tab's `id` is its focused pane's).
public enum FooterRow: Hashable, Sendable {
    case task(UUID), tab(Int)
}

public struct SessionContexts: Equatable, Sendable {
    private var byRow: [FooterRow: [SessionAgent: Int]] = [:]
    /// The agents that report a context fill: every preset, never the shell.
    private static let agents: [SessionAgent] = [.claude, .codex, .grok, .pi]

    public init() {}

    public func percents(forRow id: FooterRow) -> [SessionAgent: Int] { byRow[id] ?? [:] }

    public mutating func prune(keeping live: Set<FooterRow>) {
        guard byRow.keys.contains(where: { !live.contains($0) }) else { return }
        byRow = byRow.filter { live.contains($0.key) }
    }

    public mutating func seed(from sessions: [SessionInfo], row: (SessionInfo) -> FooterRow?) {
        let reportingByRow = Dictionary(grouping: sessions.filter { $0.contextPercent != nil }, by: row)
        for case let (rowId?, reporting) in reportingByRow {
            for agent in Self.agents where byRow[rowId]?[agent] == nil {
                let own = reporting.filter { $0.agent == agent }
                let session = own.first(where: \.active)
                    ?? own.max { ($0.contextPercent ?? 0) < ($1.contextPercent ?? 0) }
                if let context = session?.contextPercent { set(context, row: rowId, agent: agent) }
            }
        }
    }

    public mutating func remember(_ session: SessionInfo, replacing old: SessionInfo?, row: (SessionInfo) -> FooterRow?) {
        guard let context = session.contextPercent,
              old?.contextPercent != context || old?.taskId != session.taskId
                  || old?.windowId != session.windowId || old?.agent != session.agent,
              session.agent != .shell,
              let rowId = row(session) else { return }
        set(context, row: rowId, agent: session.agent)
    }

    private mutating func set(_ context: Int, row: FooterRow, agent: SessionAgent) {
        guard byRow[row]?[agent] != context else { return }
        byRow[row, default: [:]][agent] = context
    }
}
