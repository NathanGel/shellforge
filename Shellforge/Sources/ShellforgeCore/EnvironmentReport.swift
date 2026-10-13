import Foundation

/// The environment Shellforge starts things in, as Settings › Core shows it: the login shell it was
/// read from — or why a fallback was used — when, the PATH's folders, and where the tools a task
/// relies on were found. Built from the environment as read: no re-read per missing tool, which
/// would run a login shell for each.
public struct EnvironmentReport: Equatable, Sendable {
    public struct Tool: Equatable, Sendable {
        public let name: String
        /// Where it was found on PATH, as found — a symlink is not followed; nil when it was not.
        public let path: String?
    }

    public let shell: String?
    public let fallbackReason: String?
    public let readAt: Date?
    public let path: [String]
    public let tools: [Tool]

    /// The tools every task can need, before the agents' own commands.
    public static let baseTools = ["git", "uv", "python3", "node", "ssh"]

    public static func make(launcher: CommandLauncher, agents: [AgentDefinition]) -> EnvironmentReport {
        let (environment, readAt) = launcher.snapshot
        let searched = environment.variables["PATH"] ?? ""
        var commands = baseTools
        for agent in agents where !commands.contains(agent.command) { commands.append(agent.command) }
        let shell: String?, reason: String?
        switch environment.source {
        case .loginShell(let name): (shell, reason) = (name, nil)
        case .fallback(let why): (shell, reason) = (nil, why)
        }
        // An agent given by its full path is named by its file, as a tab would show it.
        return EnvironmentReport(shell: shell, fallbackReason: reason, readAt: readAt,
                                 path: searched.split(separator: ":").map(String.init),
                                 tools: commands.map { Tool(name: ($0 as NSString).lastPathComponent,
                                                            path: CommandLauncher.locate($0, in: searched)) })
    }
}
