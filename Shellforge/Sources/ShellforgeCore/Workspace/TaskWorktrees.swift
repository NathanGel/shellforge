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
    public static func create(draft: TaskDraft, in project: Project, launcher: CommandLauncher) throws -> TaskItem {
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Refusal.emptyTitle }
        guard !draft.model.isEmpty else { throw Refusal.emptyModel }
        guard BranchNaming.isValid(draft.branch, launcher: launcher) else { throw Refusal.invalidBranch(draft.branch) }
        func git(_ args: [String]) throws -> String {
            let out = try launcher.run("git", ["-C", project.path] + args)
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
            _ = try? launcher.run("git", ["-C", project.path, "fetch", "--quiet", "origin",
                                          "+refs/heads/\(draft.baseBranch):refs/remotes/origin/\(draft.baseBranch)"],
                                  extra: ["GIT_TERMINAL_PROMPT": "0"], timeout: 30)
            if (try? git(["rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(draft.baseBranch)^{commit}"])) != nil {
                start = "origin/\(draft.baseBranch)"
            }
        }
        _ = try git(["worktree", "add", "-q", "-b", draft.branch, path, start])
        return TaskItem(projectId: project.id, title: draft.title, branch: draft.branch, worktreePath: path,
                        baseBranch: draft.baseBranch, agent: draft.agentId, model: draft.model, reasoning: draft.reasoning)
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
