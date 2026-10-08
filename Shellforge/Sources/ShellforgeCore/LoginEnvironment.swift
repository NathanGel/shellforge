import Foundation

/// The environment the user's own terminal would have. An app opened from the Dock or Finder gets
/// launchd's minimal one — `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, no Homebrew, no `~/.local/bin`,
/// none of what `~/.zprofile` and `~/.zshrc` set — so every child Shellforge starts must be given
/// this one instead, or a git hook calling `uv` fails with "command not found".
public enum LoginEnvironment {
    /// Printed by the login shell right before `env -0`, so whatever an rc file prints first is skipped.
    static let marker = "__SHELLFORGE_ENV__"

    /// The variables in a login shell's answer: everything after the marker, as `env -0` prints it,
    /// one `NAME=value` per NUL. `nil` when the marker never came, which means the shell never got
    /// as far as printing its environment.
    static func parse(_ output: String) -> [String: String]? {
        guard let start = output.range(of: marker)?.upperBound else { return nil }
        var environment: [String: String] = [:]
        for entry in output[start...].split(separator: "\0", omittingEmptySubsequences: true) {
            guard let equals = entry.firstIndex(of: "="), equals != entry.startIndex else { continue }
            environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        return environment
    }

    /// Asks `shell` for its environment as a login, interactive shell — the one that reads
    /// `~/.zprofile` and `~/.zshrc` — and gives up after `timeout` seconds, since an rc file that
    /// waits for input must not stall the app. When the shell cannot answer, falls back to
    /// `inherited` with the usual tool folders added to its `PATH`, and says why.
    public static func resolve(shell: String, inherited: [String: String],
                               timeout: TimeInterval = 15) -> ResolvedEnvironment {
        let command = "printf '%s' \(marker); /usr/bin/env -0"
        let reason: String
        do {
            let output = try ChildProcess.run(shell, ["-l", "-i", "-c", command], environment: inherited, timeout: timeout)
            if output.timedOut {
                reason = "\(shell) did not answer within \(Int(timeout.rounded(.up))) s"
            } else if output.status != 0 {
                reason = "\(shell) exited with status \(output.status)"
            } else if let variables = parse(output.stdout) {
                return ResolvedEnvironment(variables: forChildren(variables), source: .loginShell(shell))
            } else {
                reason = "\(shell) printed no environment"
            }
        } catch {
            reason = "\(shell) could not be started: \(error.localizedDescription)"
        }
        return ResolvedEnvironment(variables: fallback(inherited), source: .fallback(reason))
    }

    /// `inherited`, its `PATH` followed by the folders tools are usually installed in, each once.
    static func fallback(_ inherited: [String: String]) -> [String: String] {
        let home = inherited["HOME"] ?? NSHomeDirectory()
        let usual = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.cargo/bin"]
        var seen = Set<String>()
        let path = ((inherited["PATH"] ?? "").split(separator: ":").map(String.init) + usual)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        var variables = forChildren(inherited)
        variables["PATH"] = path.joined(separator: ":")
        return variables
    }

    /// `environment` as children should inherit it: all of it — `SSH_AUTH_SOCK` for a 1Password or
    /// Secretive agent, a version manager's variables, proxies — except what belonged to the shell
    /// that printed it or to the app that launched us. A child that saw `__CFBundleIdentifier` or
    /// `XPC_*` would check in with LaunchServices as Shellforge itself.
    public static func forChildren(_ environment: [String: String]) -> [String: String] {
        environment.filter { key, _ in !isSessionKey(key) }
    }

    private static let sessionKeys: Set<String> = ["SHLVL", "PWD", "OLDPWD", "_", "TERM_SESSION_ID", "__CFBundleIdentifier"]
    private static let sessionPrefixes = ["ITERM_", "XPC_", "__XPC_"]

    private static func isSessionKey(_ key: String) -> Bool {
        sessionKeys.contains(key) || sessionPrefixes.contains { key.hasPrefix($0) }
    }
}

/// The environment children get, and where it came from — for Settings to show and for an error to
/// name.
public struct ResolvedEnvironment: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        /// Read from this login shell.
        case loginShell(String)
        /// The login shell could not answer, for this reason; the variables are a best guess.
        case fallback(String)
    }

    public let variables: [String: String]
    public let source: Source
}
