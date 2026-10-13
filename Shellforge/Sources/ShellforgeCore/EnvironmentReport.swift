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

/// The files the login shell reads its environment from, watched by their modification dates, so
/// a tool installed and put on PATH is found without a relaunch:
/// - zsh: `.zshenv`, `.zprofile`, `.zshrc`, in `$ZDOTDIR` or the home folder;
/// - bash: `.bash_profile`, `.bash_login`, `.profile`, `.bashrc`;
/// - fish: `~/.config/fish/config.fish`;
/// - any other: `.profile`;
/// - and, for every shell, `/etc/paths` and `/etc/paths.d`, where installers add their folders.
///
/// A file created or deleted counts as a change; a linked file is judged by its target. The shell
/// and `ZDOTDIR` are read at each check, from the environment Shellforge uses.
public struct RCFiles: Sendable {
    private let home: URL, etc: URL
    private let environment: @Sendable () -> [String: String]
    private var last: [String: Date]?

    public init(home: URL, etc: URL = URL(fileURLWithPath: "/etc"), environment: @escaping @Sendable () -> [String: String]) {
        self.home = home
        self.etc = etc
        self.environment = environment
    }

    /// The files `shell` reads at login, then the system's PATH files.
    public static func watched(home: URL, etc: URL, shell: String, zdotdir: String?) -> [URL] {
        let own: [URL]
        switch (shell as NSString).lastPathComponent {
        case "zsh":
            let folder = zdotdir.map { URL(fileURLWithPath: $0) } ?? home
            own = [".zshenv", ".zprofile", ".zshrc"].map { folder.appendingPathComponent($0) }
        case "bash":
            own = [".bash_profile", ".bash_login", ".profile", ".bashrc"].map { home.appendingPathComponent($0) }
        case "fish":
            own = [home.appendingPathComponent(".config/fish/config.fish")]
        default:
            own = [home.appendingPathComponent(".profile")]
        }
        return own + [etc.appendingPathComponent("paths"), etc.appendingPathComponent("paths.d")]
    }

    /// Whether any of them changed since the last call; the first call only looks.
    public mutating func changed() -> Bool {
        let variables = environment()
        let files = Self.watched(home: home, etc: etc, shell: variables["SHELL"] ?? "/bin/zsh", zdotdir: variables["ZDOTDIR"])
        var now: [String: Date] = [:]
        for file in files {
            // Through a link to its target: a dotfile manager's ~/.zshrc is a link, and the edit is there.
            let target = file.resolvingSymlinksInPath().path
            if let date = (try? FileManager.default.attributesOfItem(atPath: target))?[.modificationDate] as? Date {
                now[file.path] = date
            }
        }
        defer { last = now }
        guard let last else { return false }
        return now != last
    }
}
