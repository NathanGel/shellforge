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
        let environment = launcher.environment
        let searched = environment.variables["PATH"] ?? ""
        var names = baseTools
        for agent in agents where !names.contains(agent.command) { names.append(agent.command) }
        let shell: String?, reason: String?
        switch environment.source {
        case .loginShell(let name): (shell, reason) = (name, nil)
        case .fallback(let why): (shell, reason) = (nil, why)
        }
        return EnvironmentReport(shell: shell, fallbackReason: reason, readAt: launcher.readAt,
                                 path: searched.split(separator: ":").map(String.init),
                                 tools: names.map { Tool(name: $0, path: CommandLauncher.locate($0, in: searched)) })
    }
}

/// The rc files a login shell reads — `~/.zshenv`, `~/.zprofile`, `~/.zshrc` — watched by their
/// modification dates, so a tool installed and put on PATH is found without a relaunch. A file
/// created or deleted counts as a change; a linked file is judged by its target.
public struct RCFiles: Sendable {
    public static let names = [".zshenv", ".zprofile", ".zshrc"]
    private let files: [URL]
    private var last: [Date?]?

    public init(home: URL) {
        files = Self.names.map { home.appendingPathComponent($0) }
    }

    /// Whether any of them changed since the last call; the first call only looks.
    public mutating func changed() -> Bool {
        // Through a link to its target: a dotfile manager's ~/.zshrc is a link, and the edit is there.
        let now = files.map { (try? FileManager.default.attributesOfItem(atPath: $0.resolvingSymlinksInPath().path))?[.modificationDate] as? Date }
        defer { last = now }
        guard let last else { return false }
        return now != last
    }
}
