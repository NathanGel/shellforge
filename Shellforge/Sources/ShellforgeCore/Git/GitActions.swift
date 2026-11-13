import Foundation

/// A branch Switch Branch… offers: a local one, or one only on a remote, shown as
/// `<remote>/<name>`, which switching to makes a local `<name>` tracking it.
public struct GitBranch: Equatable, Hashable, Sendable {
    public var title: String
    /// The local branch the folder ends on.
    public var name: String
    public var remote: String?

    public init(title: String, name: String, remote: String?) {
        self.title = title
        self.name = name
        self.remote = remote
    }
}

/// What the Git panel does to a repository. Every function blocks: callers run them off the main
/// actor. A failure throws `GitFailure` in plain words; git's own stderr goes to the error log.
public enum GitActions {
    static let localTimeout: TimeInterval = 30
    static let remoteTimeout: TimeInterval = 60
    static let commitTimeout: TimeInterval = 120

    /// A file's path as a pathspec git takes literally: `app/[id]/page.tsx` is that file, never a
    /// glob that also matches `app/i/page.tsx`.
    public static func literal(_ path: String) -> String { ":(literal)" + path }

    public static func stage(_ paths: [String], in repo: String, launcher: CommandLauncher) throws {
        guard !paths.isEmpty else { return }
        try run(["add", "-A", "--"] + paths.map(literal), in: repo, action: "stage", launcher: launcher)
    }

    /// Stages every change, task worktrees left out, with no path list on the command line. While
    /// files are conflicted it stages exactly `status`'s unstaged changes instead: staging a
    /// conflict marks it resolved, and no exclusion keeps git from doing that when `.` is given.
    public static func stageAll(in repo: String, status: GitStatus, launcher: CommandLauncher) throws {
        guard !status.conflicted.isEmpty else {
            try run(["add", "-A", "--", ".", ":(exclude).worktrees"], in: repo, action: "stage", launcher: launcher)
            return
        }
        try run(["add", "-A"], pathspecs: bothPaths(of: status.unstaged), in: repo, action: "stage", launcher: launcher)
    }

    /// Unstages everything; on an unborn branch the index entries are dropped instead. While files
    /// are conflicted it unstages exactly `status`'s staged changes: `.` would throw the conflicts
    /// away and leave their markers as plain changes.
    public static func unstageAll(in repo: String, status: GitStatus, launcher: CommandLauncher) throws {
        let unborn = try isUnborn(repo, action: "unstage", launcher: launcher)
        let args = unborn ? ["rm", "--cached", "-r", "-q", "-f"] : ["restore", "--staged"]
        guard !status.conflicted.isEmpty else {
            try run(args + ["--", "."], in: repo, action: "unstage", launcher: launcher)
            return
        }
        try run(args, pathspecs: bothPaths(of: status.staged), in: repo, action: "unstage", launcher: launcher)
    }

    /// Each change's path, and a rename's or copy's original path too.
    private static func bothPaths(of changes: [GitChange]) -> [String] {
        changes.flatMap { [$0.originalPath, $0.path].compactMap { $0 } }
    }

    private static func isUnborn(_ repo: String, action: String, launcher: CommandLauncher) throws -> Bool {
        try run(["rev-parse", "--verify", "-q", "HEAD"], in: repo, action: action, launcher: launcher, allowFailure: true).status != 0
    }

    /// `git restore --staged`, which needs a commit to restore from; on an unborn branch the index
    /// entries are dropped instead.
    public static func unstage(_ paths: [String], in repo: String, launcher: CommandLauncher) throws {
        guard !paths.isEmpty else { return }
        let unborn = try isUnborn(repo, action: "unstage", launcher: launcher)
        let args = unborn ? ["rm", "--cached", "-r", "-q", "-f", "--"] : ["restore", "--staged", "--"]
        try run(args + paths.map(literal), in: repo, action: "unstage", launcher: launcher)
    }

    /// Unstages `change`; a rename takes both its paths, so the old path's deletion goes too.
    public static func unstage(_ change: GitChange, in repo: String, launcher: CommandLauncher) throws {
        try unstage([change.originalPath, change.path].compactMap { $0 }, in: repo, launcher: launcher)
    }

    /// Whether discarding the unstaged `change` moves its file to the Trash rather than restoring it.
    public static func discardTrashes(_ change: GitChange) -> Bool {
        isIntentToAdd(change) || change.letter == .untracked
    }

    private static func isIntentToAdd(_ change: GitChange) -> Bool {
        [.added, .renamed, .copied].contains(change.letter)
    }

    /// Throws away an unstaged `change`. A tracked file goes back to the index. An untracked file,
    /// and an intent-to-add one (`git add -N`: shown as an unstaged add, or a worktree rename, whose
    /// index blob is empty, so restoring would blank it), is moved to the Trash. Never for a conflict.
    public static func discard(_ change: GitChange, in repo: String, launcher: CommandLauncher,
                               trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) throws {
        guard change.letter != .conflicted else {
            throw GitFailure(message: "Resolve this file’s conflict instead of discarding it.")
        }
        if isIntentToAdd(change) {
            try run(["rm", "--cached", "-q", "--", literal(change.path)], in: repo, action: "discard", launcher: launcher)
        }
        if discardTrashes(change) {
            let url = URL(fileURLWithPath: repo).appendingPathComponent(change.path)
            do {
                try trash(url)
            } catch {
                ErrorLogging.record("git", "trash: \(error.localizedDescription)")
                throw GitFailure(message: "Couldn’t move \(change.path) to the Trash.")
            }
            if change.letter == .renamed, let original = change.originalPath {
                try run(["restore", "--worktree", "--", literal(original)], in: repo, action: "discard", launcher: launcher)
            }
            return
        }
        try run(["restore", "--worktree", "--", literal(change.path)], in: repo, action: "discard", launcher: launcher)
    }

    /// Commits what is staged; with nothing staged, everything (untracked files included, task
    /// worktrees excluded). A commit that fails then leaves the index as it was.
    public static func commit(message: String, in repo: String, status: GitStatus, launcher: CommandLauncher) throws {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitFailure(message: "Write a commit message first.")
        }
        // Committing everything would mark each conflict resolved, markers and all.
        guard status.conflicted.isEmpty else {
            throw GitFailure(message: "Resolve the merge conflicts before committing.")
        }
        let addedEverything = status.staged.isEmpty
        let headBefore = addedEverything ? head(of: repo, launcher: launcher) : nil
        if addedEverything {
            try run(["add", "-A", "--", ".", ":(exclude).worktrees"], in: repo, action: "commit", launcher: launcher)
        }
        do {
            try run(["commit", "-q", "-m", message], in: repo, action: "commit", launcher: launcher, timeout: commitTimeout)
        } catch {
            // Put the index back only when no commit was made: a commit written and then reported
            // as failed (a slow post-commit hook) must keep its index, or the next commit would
            // record every file as deleted. Read from the repository now, not the old status.
            let headNow = addedEverything ? head(of: repo, launcher: launcher) : nil
            if addedEverything, headNow == headBefore {
                let undo = headNow == nil ? ["rm", "--cached", "-r", "-q", "-f", "--", "."] : ["reset", "-q"]
                _ = try? run(undo, in: repo, action: "commit", launcher: launcher)
            }
            throw error
        }
    }

    /// The commit HEAD points at, or nil on a branch with no commits yet.
    private static func head(of repo: String, launcher: CommandLauncher) -> String? {
        guard let out = try? run(["rev-parse", "--verify", "-q", "HEAD"], in: repo, action: "commit", launcher: launcher,
                                 allowFailure: true), out.status == 0 else { return nil }
        return out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// With an upstream, `git push`; without one, publishes the branch to origin. Only from a branch.
    public static func push(in repo: String, status: GitStatus, launcher: CommandLauncher) throws {
        guard case .branch(let name) = status.head else {
            throw GitFailure(message: "Commit on a branch before pushing.")
        }
        if status.upstream == nil {
            try run(["push", "-u", "origin", name], in: repo, action: "push", launcher: launcher, remote: true)
        } else {
            try run(["push"], in: repo, action: "push", launcher: launcher, remote: true)
        }
    }

    public static func pull(in repo: String, launcher: CommandLauncher) throws {
        try run(["pull", "--ff-only"], in: repo, action: "pull", launcher: launcher, remote: true)
    }

    /// Local branches, then remote ones; `origin/HEAD` and remote copies of a local name are left out.
    public static func branches(in repo: String, launcher: CommandLauncher) throws -> [GitBranch] {
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
        var listed = Set(locals)
        var remoteOnly: [GitBranch] = []
        for name in all {
            // One entry per local name: a branch on two remotes is listed once, from the first.
            guard let short = remote(name), short != "HEAD", listed.insert(short).inserted else { continue }
            remoteOnly.append(GitBranch(title: name, name: short, remote: String(name.prefix(name.count - short.count - 1))))
        }
        return locals.map { GitBranch(title: $0, name: $0, remote: nil) } + remoteOnly
    }

    /// The command line that shows `change` in a terminal. Paths are literal pathspecs; a staged
    /// rename names both its paths, so it shows as a rename. Every path is guarded (`TypedPath`):
    /// throws `TypedPath.Unsafe` for a name that can't be typed safely.
    public static func diffLine(for change: GitChange, staged: Bool) throws -> String {
        if change.letter == .untracked {
            // `--no-index` compares two files, not pathspecs.
            return "git diff --no-index -- /dev/null \(try TypedPath.word(change.path))"
        }
        let word = { try TypedPath.word($0, pathspec: true) }
        if staged, change.letter == .renamed, let original = change.originalPath {
            return "git diff --staged -M -- \(try word(original)) \(try word(change.path))"
        }
        return "git diff\(staged ? " --staged" : "") -- \(try word(change.path))"
    }

    /// A refusal of `action`, from git's stderr (read under `LC_ALL=C`), in words a person can act on.
    public static func plainWords(stderr: String, action: String) -> String {
        let lines = stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let first = (lines.first { !$0.isEmpty && !$0.hasPrefix("hint:") } ?? "")
            .replacingOccurrences(of: "(://)[^/@\\s]+@", with: "$1", options: .regularExpression)
        func has(_ needles: String...) -> Bool { needles.contains { stderr.contains($0) } }
        if action == "push", has("[rejected]", "non-fast-forward", "fetch first") {
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

    /// `args` with `paths` as literal pathspecs, read from a NUL-separated file so a long list
    /// stays off the command line. The file is deleted after. No paths runs nothing: git would
    /// take an empty list as every file.
    private static func run(_ args: [String], pathspecs paths: [String], in repo: String, action: String,
                            launcher: CommandLauncher) throws {
        guard !paths.isEmpty else { return }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("shellforge-pathspecs-\(UUID().uuidString)")
        do {
            try Data(paths.map { literal($0) + "\0" }.joined().utf8).write(to: file)
        } catch {
            logFailure(args, "pathspec file: \(error.localizedDescription)")
            throw GitFailure(message: "Couldn’t write the list of files for git.")
        }
        defer { try? FileManager.default.removeItem(at: file) }
        try run(args + ["--pathspec-from-file=\(file.path)", "--pathspec-file-nul"], in: repo, action: action, launcher: launcher)
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
            logFailure(args, error.localizedDescription)
            throw GitFailure(message: "git: \(error.localizedDescription)")
        }
        if out.timedOut {
            logFailure(args, "timed out")
            throw GitFailure(message: "git timed out.")
        }
        guard out.status == 0 || allowFailure else {
            // git reports some refusals on stdout (“nothing to commit”).
            let text = out.stderr.isEmpty ? out.stdout : out.stderr
            logFailure(args, text)
            throw GitFailure(message: plainWords(stderr: text, action: action))
        }
        return out
    }

    /// The error log keeps git's details, but never the arguments: a commit message is typed text.
    private static func logFailure(_ args: [String], _ detail: String) {
        ErrorLogging.record("git", "git \(args.first ?? ""): \(detail)")
    }
}
