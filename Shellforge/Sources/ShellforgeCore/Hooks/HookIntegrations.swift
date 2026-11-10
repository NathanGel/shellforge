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
    /// A development build's install, which leaves the installed app's hooks alone unless told to.
    case sharedWithInstalledApp

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): reason
        case .unknownAgent(let id): "Shellforge has no hooks for “\(id)”."
        case .sharedWithInstalledApp: HookIntegrations.sharedExplanation
        }
    }
}

/// Each preset agent's hooks, probed and installed by its id: what the Agent hooks sheet shows and
/// what its buttons do. Every call reads or writes the user's files, so callers run it off the main
/// thread. Nothing here installs anything unasked.
///
/// The agents' settings are global, and their lifecycle hooks name one port. A development build
/// (a support folder that is not the installed app's) probes the installed app's install, so the
/// sheet says what is really there, and installs only when told to (`install(_:forThisBuild:)`).
public struct HookIntegrations: Sendable {
    /// What a development build's sheet says, and what its plain install throws.
    public static let sharedExplanation = "Agent hooks are shared with the installed Shellforge. A development build leaves them alone; its status line and custom agents still report here."

    /// The agents with hooks, in preset order.
    public let agents = ["claude", "codex", "grok", "pi"]
    /// The installed app's: what is probed, and what a plain install writes.
    private let drivers: [String: any HookDriver]
    /// A development build's own port and folder, for an install made for this build anyway; nil
    /// for the installed app.
    private let buildDrivers: [String: any HookDriver]?
    private let unavailable: HookProbe
    private let home: URL
    /// The Claude status-line shim this copy installs, or its name when the bundle lacks it.
    private let claudeShim: String

    /// `support` is the app's folder, whose `hook-port` the shims read, and `port` the helper's, both
    /// the installed app's under `home` unless given: the app passes its own.
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, support: ShellforgeSupport? = nil, port: Int? = nil,
                resources: HookResources) {
        let support = support ?? .default(home: home)
        unavailable = HookProbe(state: .resourceUnavailable, explanation: resources.unavailableReason ?? "The bundled hooks are unavailable.")
        self.home = home
        claudeShim = resources.folder?.appendingPathComponent("shellforge-claude-statusline.sh").path ?? "shellforge-claude-statusline.sh"
        let own = Self.drivers(home: home, port: port ?? support.hookPort, support: support, resources: resources)
        if support.isDefault {
            drivers = own
            buildDrivers = nil
        } else {
            let installed = ShellforgeSupport.default(home: home)
            drivers = Self.drivers(home: home, port: installed.hookPort, support: installed, resources: resources)
            buildDrivers = own
        }
    }

    private static func drivers(home: URL, port: Int, support: ShellforgeSupport, resources: HookResources) -> [String: any HookDriver] {
        guard resources.installationAllowed, let folder = resources.folder else { return [:] }
        func file(_ name: String) -> String? {
            let path = folder.appendingPathComponent(name).path
            return FileManager.default.fileExists(atPath: path) ? path : nil
        }
        var drivers: [String: any HookDriver] = [:]
        if let shim = file("shellforge-claude-statusline.sh") { drivers["claude"] = ClaudeHooks(home: home, port: port, shimPath: shim, support: support) }
        drivers["codex"] = CodexHooks(home: home, port: port)
        if let shim = file("shellforge-grok-statusline.sh") { drivers["grok"] = GrokHooks(home: home, port: port, shimPath: shim, support: support) }
        if let path = file("pi-shellforge-status.ts"), let source = try? String(contentsOfFile: path, encoding: .utf8) {
            drivers["pi"] = PiHooks(home: home, port: port, source: source)
        }
        return drivers
    }

    /// Whether this is a development build's, whose installs are refused unless made for this build.
    public var isSharedWithInstalledApp: Bool { buildDrivers != nil }

    /// Whether Claude Code's status line is a Shellforge shim that runs: the one feed of Claude's
    /// rate limits, so the footer says "Usage disconnected" when it is not (AiTerm's
    /// `statusLineIsInstalled`). Reads a file; call it off the main actor.
    public func claudeStatusLineIsInstalled() -> Bool {
        ClaudeSettings.statusLineIsInstalled(home: home, shimPath: claudeShim)
    }

    public func probe(_ agent: String) -> HookProbe {
        drivers[agent]?.probe() ?? unavailable
    }

    /// Installs the installed app's hooks. A development build refuses (`sharedWithInstalledApp`)
    /// unless `forThisBuild`, which points them at its own port: the installed app then shows no
    /// working or done until it repairs them.
    public func install(_ agent: String, forThisBuild: Bool = false) throws {
        guard agents.contains(agent) else { throw HookIntegrationError.unknownAgent(agent) }
        if isSharedWithInstalledApp && !forThisBuild { throw HookIntegrationError.sharedWithInstalledApp }
        guard let driver = (forThisBuild ? buildDrivers : nil)?[agent] ?? drivers[agent] else {
            throw HookIntegrationError.unavailable(unavailable.explanation ?? "")
        }
        try driver.install()
    }
}
