import Foundation

/// What the Git panel does to a repository. Every function blocks: callers run them off the main
/// actor. A failure throws `GitFailure` in plain words; git's own stderr goes to the error log.
public enum GitActions {
    static let localTimeout: TimeInterval = 30
    static let remoteTimeout: TimeInterval = 60
    static let commitTimeout: TimeInterval = 120

    public static func stage(_ paths: [String], in repo: String, launcher: CommandLauncher) throws {
        guard !paths.isEmpty else { return }
        try run(["add", "-A", "--"] + paths, in: repo, action: "stage", launcher: launcher)
    }

    /// `git restore --staged`, which needs a commit to restore from; on an unborn branch the index
    /// entries are dropped instead.
    public static func unstage(_ paths: [String], in repo: String, launcher: CommandLauncher) throws {
        guard !paths.isEmpty else { return }
        let unborn = try run(["rev-parse", "--verify", "-q", "HEAD"], in: repo, action: "unstage", launcher: launcher, allowFailure: true).status != 0
        let args = unborn ? ["rm", "--cached", "-r", "-q", "--"] : ["restore", "--staged", "--"]
        try run(args + paths, in: repo, action: "unstage", launcher: launcher)
    }

    /// Tracked files go back to the index; an untracked file goes to the Trash. Never for a conflict.
    public static func discard(_ change: GitChange, in repo: String, launcher: CommandLauncher) throws {
        guard change.letter != .conflicted else {
            throw GitFailure(message: "Resolve this file’s conflict instead of discarding it.")
        }
        if change.letter == .untracked {
            let url = URL(fileURLWithPath: repo).appendingPathComponent(change.path)
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                ErrorLogging.record("git", "trash \(url.path): \(error.localizedDescription)")
                throw GitFailure(message: "Couldn’t move \(change.path) to the Trash.")
            }
            return
        }
        let paths = [change.originalPath, change.path].compactMap { $0 }
        try run(["restore", "--worktree", "--"] + paths, in: repo, action: "discard", launcher: launcher)
    }

    /// Commits what is staged; with nothing staged, everything (untracked files included).
    public static func commit(message: String, in repo: String, status: GitStatus, launcher: CommandLauncher) throws {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitFailure(message: "Write a commit message first.")
        }
        if status.staged.isEmpty {
            try run(["add", "-A"], in: repo, action: "commit", launcher: launcher)
        }
        try run(["commit", "-q", "-m", message], in: repo, action: "commit", launcher: launcher, timeout: commitTimeout)
    }

    /// With an upstream, `git push`; without one, publishes the branch to origin.
    public static func push(in repo: String, status: GitStatus, launcher: CommandLauncher) throws {
        if status.upstream == nil, case .branch(let name) = status.head {
            try run(["push", "-u", "origin", name], in: repo, action: "push", launcher: launcher, remote: true)
        } else {
            try run(["push"], in: repo, action: "push", launcher: launcher, remote: true)
        }
    }

    public static func pull(in repo: String, launcher: CommandLauncher) throws {
        try run(["pull", "--ff-only"], in: repo, action: "pull", launcher: launcher, remote: true)
    }

    /// Local branches, then remote ones; `origin/HEAD` and remote copies of a local name are left out.
    public static func branches(in repo: String, launcher: CommandLauncher) throws -> [String] {
        let out = try run(["for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/remotes"],
                          in: repo, action: "branches", launcher: launcher)
        let all = out.stdout.split(separator: "\n").map(String.init)
        let remotes = Set(try run(["remote"], in: repo, action: "branches", launcher: launcher)
            .stdout.split(separator: "\n").map(String.init))
        func remote(_ name: String) -> String? {
            guard let slash = name.firstIndex(of: "/"), remotes.contains(String(name[..<slash])) else { return nil }
            return String(name[name.index(after: slash)...])
        }
        // `origin/HEAD` shortens to plain `origin`: not a branch.
        let locals = all.filter { remote($0) == nil && !remotes.contains($0) }
        let localSet = Set(locals)
        let remoteOnly = all.filter { name in
            guard let short = remote(name) else { return false }
            return short != "HEAD" && !localSet.contains(short)
        }
        return locals + remoteOnly
    }

    /// The command line that shows `change` in a terminal.
    public static func diffLine(for change: GitChange, staged: Bool) -> String {
        let path = AgentCommand.shellWord(change.path)
        if change.letter == .untracked { return "git diff --no-index -- /dev/null \(path)" }
        return "git diff\(staged ? " --staged" : "") -- \(path)"
    }

    /// A refusal of `action`, from git's stderr (read under `LC_ALL=C`), in words a person can act on.
    public static func plainWords(stderr: String, action: String) -> String {
        let first = stderr.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        func has(_ needles: String...) -> Bool { needles.contains { stderr.contains($0) } }
        if action == "push", has("rejected", "non-fast-forward", "fetch first") {
            return "The remote has commits this branch doesn’t. Pull first, then push."
        }
        if action == "pull", has("Not possible to fast-forward", "diverging") {
            return "This branch and its upstream have both moved. Pull in a terminal to merge or rebase."
        }
        if has("Could not resolve host", "unable to access", "Could not read from remote repository",
               "Authentication failed", "terminal prompts disabled") {
            return "Git couldn’t reach origin: \(first)"
        }
        if has("index.lock") { return "Another git is running in this repository. Try again when it’s done." }
        if has("nothing to commit") { return "Nothing to commit." }
        return "git: \(first)"
    }

    @discardableResult
    private static func run(_ args: [String], in repo: String, action: String, launcher: CommandLauncher,
                            remote: Bool = false, timeout: TimeInterval? = nil,
                            allowFailure: Bool = false) throws -> ChildOutput {
        var extra = ["LC_ALL": "C"]
        if remote { extra["GIT_TERMINAL_PROMPT"] = "0" }
        let out: ChildOutput
        do {
            out = try launcher.run("git", ["-C", repo] + args, extra: extra, timeout: timeout ?? (remote ? remoteTimeout : localTimeout))
        } catch {
            ErrorLogging.record("git", "git \(args.joined(separator: " ")): \(error.localizedDescription)")
            throw GitFailure(message: "git: \(error.localizedDescription)")
        }
        if out.timedOut {
            ErrorLogging.record("git", "git \(args.joined(separator: " ")) timed out")
            throw GitFailure(message: "git timed out.")
        }
        guard out.status == 0 || allowFailure else {
            // git reports some refusals on stdout (“nothing to commit”).
            let text = out.stderr.isEmpty ? out.stdout : out.stderr
            ErrorLogging.record("git", "git \(args.joined(separator: " ")) failed: \(text)")
            throw GitFailure(message: plainWords(stderr: text, action: action))
        }
        return out
    }
}
