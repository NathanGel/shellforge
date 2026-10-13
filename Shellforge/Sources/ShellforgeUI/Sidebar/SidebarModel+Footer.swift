import Foundation
import ShellforgeCore

/// The footer's rows: the selected task's or tab's context and spend, and the vendors' usage.
extension SidebarModel {
    /// The footer's first row: the selected task's, else the selected tab's when it belongs to no
    /// task (AiTerm's terminal row); nothing when neither — SYSTEM then holds the Mac alone.
    public var footerRow: UsageTaskRow? {
        if let id = selectedTaskId {
            let task = document.workspace.tasks.first { $0.id == id }
            let fallback = task?.agent.flatMap(SessionAgent.init(rawValue:)) ?? .shell
            return UsageRows.taskRow(sessions: sessions.sessions(ofTask: id), fallback: fallback,
                                     contexts: contexts.percents(forRow: .task(id)), preferring: host.selectedTabId)
        }
        guard let id = host.selectedTabId,
              let tab = (tree.otherTabs + terminalTabs).first(where: { $0.id == id }) else { return nil }
        return UsageRows.taskRow(sessions: sessions.sessions(ofTab: id), fallback: .shell,
                                 contexts: contexts.percents(forRow: .tab(tab.tabId)), preferring: id)
    }

    /// USAGE's rows for this minute: Claude's and Codex's windows, as AiTerm's footer works them out.
    public func vendorRows(now: Date, calendar: Calendar, claudeStatusLineInstalled: Bool) -> [UsageVendorRow] {
        UsageRows.vendorRows(sessions.usage, now: now, calendar: calendar, claudeStatusLineInstalled: claudeStatusLineInstalled)
    }

    /// The agents of a task's tabs, as AiTerm's avatar group takes them: in tab order, a shell's too
    /// (its `>_` mark). `AvatarGroup.of` turns them into the marks a row draws.
    public func avatars(forTask id: UUID) -> [SessionAgent] { Self.agents(sessions.sessions(ofTask: id)) }
    public func avatars(forTab id: String) -> [SessionAgent] { Self.agents(sessions.sessions(ofTab: id)) }

    private static func agents(_ sessions: [SessionInfo]) -> [SessionAgent] {
        sessions.sorted { ($0.tabIndex, $0.sessionId) < ($1.tabIndex, $1.sessionId) }.map(\.agent)
    }
}
