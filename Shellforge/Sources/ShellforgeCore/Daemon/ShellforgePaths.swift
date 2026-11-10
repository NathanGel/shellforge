import Foundation

/// One support folder for the helper and the status-line shims: its socket, log, hook port and the
/// user's original status lines, and the port the helper listens for hooks on. The installed app's
/// is `~/Library/Application Support/Shellforge` with port 47831, apart from AiTerm's so both can run
/// on one Mac (`shellforged`'s `support_dir()` and `DEFAULT_HOOK_PORT`). A dev build run with
/// `-suite` has a folder of its own, and a port of its own, so its helper never adopts or fights
/// the installed app's.
public struct ShellforgeSupport: Sendable, Equatable {
    /// The installed app's hook port. Not 47821, AiTerm's.
    public static let defaultHookPort = 47831
    /// The variable the shims and `shellforge-status`/`shellforge-run` read the folder from, an
    /// absolute path, which every session a dev build starts inherits (`sessionEnvironment`). Unset,
    /// they read the default.
    public static let environmentVariable = "SHELLFORGE_SUPPORT"
    /// Where another folder's port is picked from: above the default and past AiTerm's 47821.
    static let derivedPorts = 47832..<48832

    public let folder: URL
    /// Whether `folder` is the installed app's, which keeps its port.
    public let isDefault: Bool

    /// `folder` as the helper's: the default when it is the installed app's folder under `home`
    /// (macOS folder names ignore case, so `shellforge` is that folder too).
    public init(folder: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.folder = folder
        isDefault = Self.comparable(folder) == Self.comparable(ShellforgePaths.supportDirectory(home: home))
    }

    /// The installed app's folder under `home`.
    public static func `default`(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> ShellforgeSupport {
        ShellforgeSupport(folder: ShellforgePaths.supportDirectory(home: home), home: home)
    }

    private static func comparable(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
    }

    /// 47831 for the installed app's folder; for any other, one picked from the folder's path, the
    /// same on every launch, so the shims' `hook-port` file and the helper agree without a lookup.
    public var hookPort: Int {
        guard !isDefault else { return Self.defaultHookPort }
        // FNV-1a: stable across launches, unlike `Hasher`.
        var hash: UInt32 = 2_166_136_261
        for byte in Self.comparable(folder).utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return Self.derivedPorts.lowerBound + Int(hash % UInt32(Self.derivedPorts.count))
    }

    public var socketPath: String { folder.appendingPathComponent("shellforged.sock").path }
    public var daemonLogURL: URL { folder.appendingPathComponent("shellforged.log") }
    /// The port the status-line shims post to (`ShimPort`); they read it with a shell builtin.
    public var hookPortURL: URL { folder.appendingPathComponent("hook-port") }
    /// The user's own Claude Code status line, which Shellforge's shim runs after posting.
    public var statusLineOriginalURL: URL { folder.appendingPathComponent("statusline-original.cmd") }
    /// The user's own Grok Build status line, which Shellforge's Grok shim runs after posting.
    public var grokStatusLineOriginalURL: URL { folder.appendingPathComponent("grok-statusline-original.cmd") }

    /// What every session a dev build starts carries, so an agent in it reports to that build's
    /// helper. The installed app's sessions carry nothing new: the default is the variable unset.
    public var sessionEnvironment: [String: String] { isDefault ? [:] : [Self.environmentVariable: folder.path] }
}

/// The running app's `ShellforgeSupport`: the default until the host configures its data folder at
/// launch, before the helper starts or a session opens.
public enum ShellforgePaths {
    private static let configured = Locked<ShellforgeSupport?>(nil)

    /// Sets the app's support folder; the host calls it once, at launch.
    public static func configure(_ support: ShellforgeSupport) {
        configured.withLock { $0 = support }
    }

    public static var current: ShellforgeSupport { configured.withLock { $0 } ?? .default() }

    public static var supportDirectory: URL { current.folder }

    /// The installed app's folder under `home`, for code that writes the user's files and tests that
    /// give it a scratch home.
    public static func supportDirectory(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/Shellforge", isDirectory: true)
    }

    public static func hookPortURL(home: URL) -> URL { ShellforgeSupport.default(home: home).hookPortURL }
    public static func statusLineOriginalURL(home: URL) -> URL { ShellforgeSupport.default(home: home).statusLineOriginalURL }
    public static func grokStatusLineOriginalURL(home: URL) -> URL { ShellforgeSupport.default(home: home).grokStatusLineOriginalURL }

    public static var socketPath: String { current.socketPath }
    public static var daemonLogURL: URL { current.daemonLogURL }
    public static var hookPort: Int { current.hookPort }
}
