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
    private var cached: ResolvedEnvironment?

    /// `resolve` reads the environment; the default asks the user's login shell.
    public init(resolve: @escaping @Sendable () -> ResolvedEnvironment = CommandLauncher.loginShell) {
        self.resolve = resolve
    }

    /// The user's `$SHELL`, or zsh, macOS's default, asked with what this process inherited.
    public static let loginShell: @Sendable () -> ResolvedEnvironment = {
        let inherited = ProcessInfo.processInfo.environment
        return LoginEnvironment.resolve(shell: inherited["SHELL"] ?? "/bin/zsh", inherited: inherited)
    }

    /// The environment children get, read now if it has not been yet.
    public var environment: ResolvedEnvironment {
        lock.withLock {
            if let cached { return cached }
            let fresh = resolve()
            cached = fresh
            return fresh
        }
    }

    /// Reads the environment again, for Settings' Reload or after an rc file changed.
    @discardableResult
    public func reload() -> ResolvedEnvironment {
        let fresh = resolve()
        lock.withLock { cached = fresh }
        return fresh
    }

    /// The executable `command` runs: itself when it is a path, else the first executable file of
    /// that name on the environment's `PATH`. `Process` searches no `PATH`, so a bare name never
    /// reaches it.
    public func locate(_ command: String) -> String? {
        Self.locate(command, in: environment.variables["PATH"] ?? "")
    }

    static func locate(_ command: String, in path: String) -> String? {
        if command.contains("/") { return isExecutableFile(command) ? command : nil }
        return path.split(separator: ":").lazy
            .map { "\($0)/\(command)" }
            .first(where: isExecutableFile)
    }

    /// Runs `command` with the login environment, `extra` set over it, and waits for it to finish.
    public func run(_ command: String, _ arguments: [String], directory: String? = nil,
                    extra: [String: String] = [:], timeout: TimeInterval = 120) throws -> ChildOutput {
        var current = environment
        var executable = Self.locate(command, in: current.variables["PATH"] ?? "")
        if executable == nil {
            current = reload()
            executable = Self.locate(command, in: current.variables["PATH"] ?? "")
        }
        guard let executable else {
            throw CommandNotFound(name: command, searchedPath: current.variables["PATH"] ?? "", source: current.source)
        }
        return try ChildProcess.run(executable, arguments, environment: current.variables.merging(extra) { $1 },
                                    directory: directory, timeout: timeout)
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
        return "\(name) was not found. Searched PATH: \(searchedPath) (from \(origin))."
    }
}
