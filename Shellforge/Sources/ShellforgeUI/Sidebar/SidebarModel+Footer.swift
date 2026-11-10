import Foundation
import ShellforgeCore

/// The footer's rows: the selected task's or tab's context and spend, and the vendors' usage.
extension SidebarModel {
    /// The footer's first row: the selected task's, else the selected tab's when it belongs to no
    /// task (AiTerm's terminal row); nothing when neither — SYSTEM then holds the Mac alone.
    public var footerRow: UsageTaskRow? {
        if let id = selectedTaskId {
            let task = document.workspace.tasks.first { $0.id == id }
            let fallback = task?.agent.map(SessionAgent.init(agentId:)) ?? .shell
            return UsageRows.taskRow(sessions: sessions.sessions(ofTask: id), fallback: fallback,
                                     contexts: contexts.percents(forRow: .task(id)), preferring: host.selectedTabId)
        }
        guard let id = host.selectedTabId,
              let tab = (tree.otherTabs + terminalTabs).first(where: { $0.id == id }) else { return nil }
        return UsageRows.taskRow(sessions: sessions.sessions(ofTab: id), fallback: .shell,
                                 contexts: contexts.percents(forRow: .tab(tab.tabId)), preferring: id)
    }

    /// USAGE's rows for this minute: Claude's and Codex's windows, as AiTerm's footer works them out,
    /// leaving out a vendor with no data whose CLI is not installed (`installedAgents`).
    public func vendorRows(now: Date, calendar: Calendar, claudeStatusLineInstalled: Bool) -> [UsageVendorRow] {
        UsageRows.vendorRows(sessions.usage, now: now, calendar: calendar, claudeStatusLineInstalled: claudeStatusLineInstalled,
                             installed: installedAgents)
    }

    /// Finds which agents' CLIs are on the login shell's `PATH`, off the main actor (the first read of
    /// the environment runs a login shell), and publishes them as `installedAgents`. Claude Code also
    /// counts as in use when `~/.claude` exists: installed outside `PATH` (its own local install, say),
    /// its broken status line must still say “Usage disconnected”.
    public func refreshInstalledAgents() async {
        let (launcher, agents, home) = (self.launcher, self.agents, self.home)
        await publishInstalledAgents {
            await BackgroundWork.run {
                var found = Set(agents.filter { launcher.locate($0.command) != nil }.map { SessionAgent(agentId: $0.id) })
                if FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path) { found.insert(.claude) }
                return found
            }
        }
    }

    /// Publishes what `find` answers, unless a later look started meanwhile: overlapping refreshes
    /// (a reload of the agents and of the environment at once) publish the newest answer only.
    func publishInstalledAgents(_ find: () async -> Set<SessionAgent>) async {
        installedAgentsGeneration += 1
        let generation = installedAgentsGeneration
        let found = await find()
        guard generation == installedAgentsGeneration else { return }
        if found != installedAgents { installedAgents = found }
    }

    /// The agents of a task's tabs, as AiTerm's avatar group takes them: in tab order, a shell's too
    /// (its `>_` mark). `AvatarGroup.of` turns them into the marks a row draws.
    public func avatars(forTask id: UUID) -> [SessionAgent] { Self.agents(sessions.sessions(ofTask: id)) }
    public func avatars(forTab id: String) -> [SessionAgent] { Self.agents(sessions.sessions(ofTab: id)) }

    private static func agents(_ sessions: [SessionInfo]) -> [SessionAgent] {
        sessions.sorted { ($0.tabIndex, $0.sessionId) < ($1.tabIndex, $1.sessionId) }.map(\.agent)
    }
}
