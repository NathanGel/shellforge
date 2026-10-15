import Foundation

/// A git command that exited non-zero, with git's own words.
public struct GitFailure: Error, CustomStringConvertible, Equatable {
    public var command: String
    public var message: String
    public var description: String { "\(command) failed: \(message.trimmingCharacters(in: .whitespacesAndNewlines))" }
}

/// Makes a task's checkout: `<project>/.worktrees/<slug>` on a new branch `<slug>` from the base.
/// git runs through `CommandLauncher`, so the repository's hooks see the login shell's `PATH`.
public enum TaskWorktrees {
    /// Lowercase ASCII letters and digits, runs of anything else as one `-`; "task" when nothing is left.
    public static func slug(for title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var slug = "", dash = false
        for scalar in folded.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                if dash, !slug.isEmpty { slug.append("-") }
                slug.unicodeScalars.append(scalar)
                dash = false
            } else {
                dash = true
            }
        }
        return slug.isEmpty ? "task" : slug.lowercased()
    }

    public static func create(title: String, in project: Project, base: String?, launcher: CommandLauncher) throws -> TaskItem {
        func git(_ args: [String]) throws -> String {
            let out = try launcher.run("git", ["-C", project.path] + args)
            guard out.status == 0 else { throw GitFailure(command: "git " + args.joined(separator: " "), message: out.stderr) }
            return out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let base = try base ?? git(["rev-parse", "--abbrev-ref", "HEAD"])
        let root = "\(project.path)/.worktrees"
        let stem = slug(for: title)
        var name = stem, n = 1
        while FileManager.default.fileExists(atPath: "\(root)/\(name)")
                || (try? git(["rev-parse", "--verify", "--quiet", "refs/heads/\(name)"])) != nil {
            n += 1
            name = "\(stem)-\(n)"
        }
        try exclude(".worktrees/", gitDir: git(["rev-parse", "--git-common-dir"]), project: project)
        _ = try git(["worktree", "add", "-q", "-b", name, "\(root)/\(name)", base])
        return TaskItem(projectId: project.id, title: title, branch: name, worktreePath: "\(root)/\(name)", baseBranch: base)
    }

    public enum Refusal: Error, Equatable, LocalizedError {
        case invalidBranch(String), emptyTitle, emptyModel
        public var errorDescription: String? {
            switch self {
            case .invalidBranch(let branch): return "“\(branch)” is not a valid Git branch name."
            case .emptyTitle: return "Enter a task name."
            case .emptyModel: return "Choose an available model."
            }
        }
    }

    /// AiTerm's `TaskCreator.create`: `<project>/.worktrees/<unused slug>` on the draft's branch from its base.
    ///
    /// `cancellation` stops it — between steps, or by ending the step's command and what it started,
    /// the repository's checkout hook included — and undoes the worktree and branch it made;
    /// `progress` hears each step as it starts.
    public static func create(draft: TaskDraft, in project: Project, launcher: CommandLauncher,
                              cancellation: CreationCancellation? = nil,
                              progress: (@Sendable (CreationStep) -> Void)? = nil) throws -> TaskItem {
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Refusal.emptyTitle }
        guard !draft.model.isEmpty else { throw Refusal.emptyModel }
        func checkCancelled() throws { if cancellation?.isCancelled == true { throw CreationCancelled() } }
        try checkCancelled()
        guard BranchNaming.isValid(draft.branch, launcher: launcher) else { throw Refusal.invalidBranch(draft.branch) }
        func git(_ args: [String]) throws -> String {
            let out = try launcher.run("git", ["-C", project.path] + args, cancellation: cancellation)
            try checkCancelled()
            guard out.status == 0 else { throw GitFailure(command: "git " + args.joined(separator: " "), message: out.stderr) }
            return out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let slug = BranchNaming.unused(draft.worktreeSlug, in: project.path)
        let path = "\(project.path)/.worktrees/\(slug)"
        try exclude(".worktrees/", gitDir: git(["rev-parse", "--git-common-dir"]), project: project)
        // As AiTerm: best-effort, so a new worktree starts from the remote's latest when it can;
        // offline, from what was last fetched. An explicit, forced refspec, because `git fetch origin
        // <base>` updates the tracking ref only when `remote.origin.fetch` covers it.
        var start = draft.baseBranch
        if (try? git(["remote", "get-url", "origin"])) != nil {
            try checkCancelled()
            progress?(.fetching(base: draft.baseBranch))
            _ = try? launcher.run("git", ["-C", project.path, "fetch", "--quiet", "origin",
                                          "+refs/heads/\(draft.baseBranch):refs/remotes/origin/\(draft.baseBranch)"],
                                  extra: ["GIT_TERMINAL_PROMPT": "0"], timeout: 30, cancellation: cancellation)
            try checkCancelled()
            if (try? git(["rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(draft.baseBranch)^{commit}"])) != nil {
                start = "origin/\(draft.baseBranch)"
            }
        }
        try checkCancelled()
        progress?(.creatingWorktree(runsHook: hasCheckoutHook(project: project, launcher: launcher)))
        // What was there before this create: a cancel takes back only what it made.
        let branchWasThere = (try? launcher.run("git", ["-C", project.path, "show-ref", "--verify", "--quiet",
                                                         "refs/heads/\(draft.branch)"]))?.status == 0
        let pathWasThere = FileManager.default.fileExists(atPath: path)
        do {
            _ = try git(["worktree", "add", "-q", "-b", draft.branch, path, start])
        } catch let cancelled as CreationCancelled {
            undo(worktree: pathWasThere ? nil : path, branch: branchWasThere ? nil : draft.branch, project: project, launcher: launcher)
            throw cancelled
        }
        return TaskItem(projectId: project.id, title: draft.title, branch: draft.branch, worktreePath: path,
                        baseBranch: draft.baseBranch, agent: draft.agentId, model: draft.model, reasoning: draft.reasoning,
                    jira: draft.ticket.map { JiraRef(key: $0.key, summary: $0.summary, url: $0.url) })
    }

    /// Whether the repository runs a post-checkout hook of its own — a pre-commit `uv sync`, say — which
    /// `worktree add` waits for.
    public static func hasCheckoutHook(project: Project, launcher: CommandLauncher) -> Bool {
        guard let out = try? launcher.run("git", ["-C", project.path, "rev-parse", "--git-path", "hooks/post-checkout"]),
              out.status == 0 else { return false }
        let relative = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let hook = relative.hasPrefix("/") ? relative : "\(project.path)/\(relative)"
        return FileManager.default.isExecutableFile(atPath: hook)
    }

    /// Takes back what a stopped create made — its worktree, whatever state it was left in (locked
    /// too), and its branch — and nothing else: pass nil for anything that was there before it. A
    /// branch it made was new, with no commits of its own, so nothing of the user's goes.
    public static func undo(worktree path: String?, branch: String?, project: Project, launcher: CommandLauncher) {
        if let path {
            _ = try? launcher.run("git", ["-C", project.path, "worktree", "remove", "--force", "--force", path])
            if FileManager.default.fileExists(atPath: path) { try? FileManager.default.removeItem(atPath: path) }
            _ = try? launcher.run("git", ["-C", project.path, "worktree", "prune"])
        }
        if let branch { _ = try? launcher.run("git", ["-C", project.path, "branch", "-D", branch]) }
    }

    /// Adds `pattern` to the repository's `info/exclude` once, so the worktrees never show as untracked.
    private static func exclude(_ pattern: String, gitDir: String, project: Project) throws {
        try exclude(pattern, inGitDir: gitDir.hasPrefix("/") ? gitDir : "\(project.path)/\(gitDir)")
    }

    /// Adds `pattern` to `dir`'s `info/exclude` once; `dir` is a git directory, absolute.
    static func exclude(_ pattern: String, inGitDir dir: String) throws {
        let file = "\(dir)/info/exclude"
        try FileManager.default.createDirectory(atPath: "\(dir)/info", withIntermediateDirectories: true)
        let current = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        guard !current.components(separatedBy: "\n").contains(pattern) else { return }
        let joiner = current.isEmpty || current.hasSuffix("\n") ? "" : "\n"
        try (current + joiner + pattern + "\n").write(toFile: file, atomically: true, encoding: .utf8)
    }
}
