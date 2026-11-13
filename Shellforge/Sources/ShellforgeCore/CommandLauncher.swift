import Foundation

/// How Shellforge starts every command — git and the hooks git runs, agent CLIs, `ssh` tunnels,
/// scripts — so each one sees the environment the user's own terminal would, and none comes back
/// "not found" when it works in a tab.
///
/// The environment is read once, on first use, and kept: a login shell costs the better part of a
/// second. A command that is not on its `PATH` reads it again once, for a tool installed since.
public final class CommandLauncher: @unchecked Sendable {
    private let resolve: @Sendable () -> ResolvedEnvironment
    private let lock = NSLock()
    /// Held across the first read only, so two first uses run one login shell between them.
    private let resolving = NSLock()
    private var cached: ResolvedEnvironment?
    private let clock: @Sendable () -> Date
    private var read: Date?
    /// Counts the reloads begun, so an older one finishing last never replaces a newer one's read.
    private var started = 0, published = 0
    private var reloaded: (@Sendable () -> Void)?

    /// `resolve` reads the environment; the default asks the user's login shell. `clock` stamps
    /// each read, for Settings › Core.
    public init(resolve: @escaping @Sendable () -> ResolvedEnvironment = CommandLauncher.loginShell,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.resolve = resolve
        self.clock = clock
    }

    /// When the environment was last read; nil before the first use.
    public var readAt: Date? { lock.withLock { read } }

    /// Told, on the thread that ran the command, when a command not on `PATH` made it read the
    /// environment again: the app redraws what it shows of the environment.
    public var onReload: (@Sendable () -> Void)? {
        get { lock.withLock { reloaded } }
        set { lock.withLock { reloaded = newValue } }
    }

    /// The environment and when it was read, from the same read: a reload landing between two
    /// separate reads would pair one read's `PATH` with another's time.
    ///
    /// The login shell runs under `resolving`, not `lock`: callers wait for one first read rather than
    /// each starting their own, while `environmentIfRead` still answers at once meanwhile.
    public var snapshot: (environment: ResolvedEnvironment, readAt: Date?) {
        if let hit = cachedSnapshot { return hit }
        return resolving.withLock {
            if let hit = cachedSnapshot { return hit }
            let fresh = resolve()
            let now = clock()
            return lock.withLock {
                // A reload published while this read ran: its read is as new.
                if let cached { return (cached, read) }
                cached = fresh
                read = now
                return (fresh, now)
            }
        }
    }

    private var cachedSnapshot: (environment: ResolvedEnvironment, readAt: Date?)? {
        lock.withLock { cached.map { ($0, read) } }
    }

    /// The environment if it has been read, else nil — never waiting for the login shell, so the
    /// main thread can ask while the first read is still running elsewhere.
    public var environmentIfRead: ResolvedEnvironment? { lock.withLock { cached } }

    /// The user's `$SHELL`, or zsh, macOS's default, asked with what this process inherited.
    public static let loginShell: @Sendable () -> ResolvedEnvironment = {
        let inherited = ProcessInfo.processInfo.environment
        return LoginEnvironment.resolve(shell: inherited["SHELL"] ?? "/bin/zsh", inherited: inherited)
    }

    /// The environment children get, read now if it has not been yet.
    public var environment: ResolvedEnvironment { snapshot.environment }

    /// Reads the environment again, for Settings' Reload or after an rc file changed.
    @discardableResult
    public func reload() -> ResolvedEnvironment {
        let generation = lock.withLock { started += 1; return started }
        let fresh = resolve()
        let now = clock()
        return lock.withLock {
            // A reload begun after this one has published already: its read is the newer.
            guard generation > published else { return cached ?? fresh }
            published = generation
            cached = fresh
            read = now
            return fresh
        }
    }

    /// The executable `command` runs: itself when it is a path, else the first executable file of
    /// that name on the environment's `PATH`. `Process` searches no `PATH`, so a bare name never
    /// reaches it.
    public func locate(_ command: String) -> String? {
        Self.locate(command, in: environment.variables["PATH"] ?? "")
    }

    /// Whether `command` is installed, by the environment as read so far: nil while it has not been
    /// read, so a caller on the main thread never waits for the login shell.
    public func isInstalledIfKnown(_ command: String) -> Bool? {
        environmentIfRead.map { Self.locate(command, in: $0.variables["PATH"] ?? "") != nil }
    }

    static func locate(_ command: String, in path: String) -> String? {
        if command.contains("/") { return isExecutableFile(command) ? command : nil }
        return path.split(separator: ":").lazy
            .map { "\($0)/\(command)" }
            .first(where: isExecutableFile)
    }

    /// Runs `command` with the login environment, `extra` set over it, and waits for it to finish.
    public func run(_ command: String, _ arguments: [String], directory: String? = nil,
                    extra: [String: String] = [:], timeout: TimeInterval = 120,
                    cancellation: CreationCancellation? = nil) throws -> ChildOutput {
        var current = environment
        var executable = Self.locate(command, in: current.variables["PATH"] ?? "")
        if executable == nil {
            current = reload()
            onReload?()
            executable = Self.locate(command, in: current.variables["PATH"] ?? "")
        }
        guard let executable else {
            throw CommandNotFound(name: command, searchedPath: current.variables["PATH"] ?? "", source: current.source)
        }
        return try ChildProcess.run(executable, arguments, environment: current.variables.merging(extra) { $1 },
                                    directory: directory, timeout: timeout, cancellation: cancellation)
    }

    /// An executable regular file: `isExecutableFile` alone is also true of a folder.
    static func isExecutableFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }
}

/// A command that is on no folder of the `PATH`, even after reading the environment again. It
/// names what was searched, so "not found" is never a bare exit 127.
public struct CommandNotFound: Error, CustomStringConvertible, Sendable {
    public let name: String
    public let searchedPath: String
    public let source: ResolvedEnvironment.Source

    public var description: String {
        let origin: String
        switch source {
        case .loginShell(let shell): origin = "the environment of your login shell, \(shell)"
        case .fallback(let reason): origin = "a fallback environment, because \(reason)"
        }
        return "\(name) was not found. Searched PATH: \(searchedPath) (from \(origin)). Settings › Core shows the environment Shellforge uses."
    }
}
