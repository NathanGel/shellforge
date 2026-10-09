import Foundation

/// Where the drivers' bundled files are: `<resources>/hooks/`. Installing is refused from a
/// translocated bundle, whose path changes on every launch.
public struct HookResources: Sendable {
    public let folder: URL?
    public let installationAllowed: Bool
    public let unavailableReason: String?

    public init(folder: URL?, installationAllowed: Bool, unavailableReason: String?) {
        self.folder = folder
        self.installationAllowed = installationAllowed
        self.unavailableReason = unavailableReason
    }

    /// The app's own: the `hooks` folder its "Copy hooks" phase fills (as AiTerm's
    /// `HarnessResources.bundled`).
    public static func bundled(resourceURL: URL?) -> HookResources {
        guard let resourceURL else {
            return HookResources(folder: nil, installationAllowed: false, unavailableReason: "Shellforge’s bundled hooks are unavailable.")
        }
        let translocated = BundleLocation.isTranslocated(resourceURL.path)
        return HookResources(folder: resourceURL.appendingPathComponent("hooks"), installationAllowed: !translocated,
                             unavailableReason: translocated ? BundleLocation.translocationWarning : nil)
    }
}

public enum HookIntegrationError: Error, Equatable, LocalizedError {
    case unavailable(String)
    case unknownAgent(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): reason
        case .unknownAgent(let id): "Shellforge has no hooks for “\(id)”."
        }
    }
}

/// Each preset agent's hooks, probed and installed by its id: what the Agent hooks sheet shows and
/// what its buttons do. Every call reads or writes the user's files, so callers run it off the main
/// thread. Nothing here installs anything unasked.
public struct HookIntegrations: Sendable {
    /// The agents with hooks, in preset order.
    public let agents = ["claude", "codex", "grok", "pi"]
    private let drivers: [String: any HookDriver]
    private let unavailable: HookProbe
    private let home: URL
    /// The Claude status-line shim this copy installs, or its name when the bundle lacks it.
    private let claudeShim: String

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, port: Int = ShellforgePaths.hookPort,
                resources: HookResources) {
        unavailable = HookProbe(state: .resourceUnavailable, explanation: resources.unavailableReason ?? "The bundled hooks are unavailable.")
        self.home = home
        claudeShim = resources.folder?.appendingPathComponent("shellforge-claude-statusline.sh").path ?? "shellforge-claude-statusline.sh"
        var drivers: [String: any HookDriver] = [:]
        if resources.installationAllowed, let folder = resources.folder {
            func file(_ name: String) -> String? {
                let path = folder.appendingPathComponent(name).path
                return FileManager.default.fileExists(atPath: path) ? path : nil
            }
            if let shim = file("shellforge-claude-statusline.sh") { drivers["claude"] = ClaudeHooks(home: home, port: port, shimPath: shim) }
            drivers["codex"] = CodexHooks(home: home, port: port)
            if let shim = file("shellforge-grok-statusline.sh") { drivers["grok"] = GrokHooks(home: home, port: port, shimPath: shim) }
            if let path = file("pi-shellforge-status.ts"), let source = try? String(contentsOfFile: path, encoding: .utf8) {
                drivers["pi"] = PiHooks(home: home, port: port, source: source)
            }
        }
        self.drivers = drivers
    }

    /// Whether Claude Code's status line is a Shellforge shim that runs: the one feed of Claude's
    /// rate limits, so the footer says "Usage disconnected" when it is not (AiTerm's
    /// `statusLineIsInstalled`). Reads a file; call it off the main actor.
    public func claudeStatusLineIsInstalled() -> Bool {
        ClaudeSettings.statusLineIsInstalled(home: home, shimPath: claudeShim)
    }

    public func probe(_ agent: String) -> HookProbe {
        drivers[agent]?.probe() ?? unavailable
    }

    public func install(_ agent: String) throws {
        guard agents.contains(agent) else { throw HookIntegrationError.unknownAgent(agent) }
        guard let driver = drivers[agent] else { throw HookIntegrationError.unavailable(unavailable.explanation ?? "") }
        try driver.install()
    }
}
