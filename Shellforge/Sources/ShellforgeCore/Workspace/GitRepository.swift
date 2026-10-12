// Ported from AiTerm (app/Sources/AiTermCore/Git/Repository.swift and Repository+Worktrees.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// How a `GitRepository` runs git: the login shell's, through `CommandLauncher`, in the app; a
/// stand-in that times out or records, in the tests that need one — AiTerm's `GitRunning`.
public protocol GitCommands: Sendable {
    /// `git -C directory args`. `remote` marks a call that talks to origin: it may not prompt for
    /// credentials, and gets a shorter deadline. `timeout`, when given, is the call's own deadline.
    func git(_ args: [String], in directory: String, remote: Bool, timeout: TimeInterval?) throws -> ChildOutput
}

/// git as the login shell finds it.
public struct LauncherGit: GitCommands {
    let launcher: CommandLauncher
    public init(launcher: CommandLauncher) { self.launcher = launcher }

    public func git(_ args: [String], in directory: String, remote: Bool, timeout: TimeInterval?) throws -> ChildOutput {
        try launcher.run("git", ["-C", directory] + args, extra: remote ? ["GIT_TERMINAL_PROMPT": "0"] : [:],
                         timeout: timeout ?? (remote ? 30 : 60))
    }
}

/// git outlived its deadline: no answer, which is never taken for a "no".
public struct GitTimedOut: Error, Equatable, LocalizedError {
    public let command: String
    public var errorDescription: String? { "git timed out running \(command)." }
}

/// A repository's refs, origin and worktrees, as AiTerm's `Repository` reads them for reviews. Every
/// call blocks: callers run it off the main actor.
public struct GitRepository: Sendable {
    public let path: String
    let commands: any GitCommands

    public init(_ path: String, launcher: CommandLauncher) { self.init(path, git: LauncherGit(launcher: launcher)) }
    public init(_ path: String, git: any GitCommands) { self.path = path; self.commands = git }

    // -- running git ---------------------------------------------------------------------

    /// git's output, trimmed; a refusal throws `GitFailure` with git's words, a timeout `GitTimedOut`.
    @discardableResult
    func run(_ args: [String], in directory: String? = nil, remote: Bool = false, timeout: TimeInterval? = nil) throws -> String {
        guard let out = try ask(args, in: directory, remote: remote, timeout: timeout, none: []) else { return "" }
        return out
    }

    /// `run`, with `none`'s exit codes answered as nil: git's way of saying "there is none".
    func ask(_ args: [String], in directory: String? = nil, remote: Bool = false, timeout: TimeInterval? = nil,
             none: Set<Int32>) throws -> String? {
        let out = try commands.git(args, in: directory ?? path, remote: remote, timeout: timeout)
        let command = "git " + args.joined(separator: " ")
        if out.timedOut { throw GitTimedOut(command: command) }
        if none.contains(out.status) { return nil }
        guard out.status == 0 else { throw GitFailure(command: command, message: out.stderr) }
        return out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    func runRemote(_ args: [String]) throws -> String { try run(args, remote: true) }

    /// git's reason for a failure, in one line: its stderr's first line, or the error's own words.
    static func reason(of error: Error) -> String {
        let text = (error as? GitFailure)?.message ?? (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return text.split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? text
    }

    // -- refs and origin -----------------------------------------------------------------

    /// The commit `ref` names; nil when there is none or git could not be asked.
    func sha(_ ref: String) -> String? { (try? commit(ref)) ?? nil }

    /// The commit `ref` names, nil when git says there is none; thrown when git could not be asked.
    func commit(_ ref: String) throws -> String? {
        try ask(["rev-parse", "--verify", "--quiet", ref + "^{commit}"], none: [1])
    }

    /// Whether `ancestor` is in `commit`'s history. git's "no" is exit 1; anything else is thrown,
    /// so it is never taken for a no.
    func isAncestor(_ ancestor: String, of commit: String) throws -> Bool {
        try ask(["merge-base", "--is-ancestor", ancestor, commit], none: [1]) != nil
    }

    /// How many commits `to` has that `from` lacks; nil when git could not count them.
    func count(_ from: String, _ to: String) -> Int? {
        (try? run(["rev-list", "--count", from + ".." + to])).flatMap { Int($0) }
    }

    /// Whether there is a remote called `origin`: git's answer is exit 2 when there is none.
    var hasOrigin: Bool {
        get throws { try ask(["remote", "get-url", "origin"], none: [2]) != nil }
    }

    /// `branch` fetched into `origin/<branch>`, by an explicit forced refspec: `git fetch origin
    /// <branch>` updates the tracking ref only when `remote.origin.fetch` covers it.
    func fetchFromOrigin(_ branch: String) throws {
        try runRemote(["fetch", "--quiet", "origin", "+refs/heads/\(branch):refs/remotes/origin/\(branch)"])
    }

    /// `branch` brought to `origin/<branch>` where no checkout lists it: a fetch from the repository
    /// into itself, which refuses a branch mid-rebase as it refuses a checked-out one, and anything
    /// but a fast-forward.
    func fastForward(_ branch: String) throws {
        try run(["fetch", "--quiet", "--no-write-fetch-head", "--no-prune", "--no-recurse-submodules", ".",
                 "refs/remotes/origin/\(branch):refs/heads/\(branch)"])
    }

    // -- worktrees -----------------------------------------------------------------------

    /// One of the repository's worktrees: where, on which branch, and why it is locked.
    public struct Worktree: Equatable, Sendable {
        public var path: String
        /// The short branch name; nil when detached.
        public var branch: String?
        /// The reason it is locked for: "" for a lock without one, nil when not locked.
        public var lockReason: String?
    }

    /// Every worktree git lists, the main checkout first.
    public func worktrees() throws -> [Worktree] {
        var found: [Worktree] = []
        for line in try run(["worktree", "list", "--porcelain"]).split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                found.append(Worktree(path: String(line.dropFirst("worktree ".count)), branch: nil, lockReason: nil))
            } else if line.hasPrefix("branch refs/heads/"), !found.isEmpty {
                found[found.count - 1].branch = String(line.dropFirst("branch refs/heads/".count))
            } else if line == "locked", !found.isEmpty {
                found[found.count - 1].lockReason = ""
            } else if line.hasPrefix("locked "), !found.isEmpty {
                found[found.count - 1].lockReason = String(line.dropFirst("locked ".count))
            }
        }
        return found
    }
}
