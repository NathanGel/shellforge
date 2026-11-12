import Foundation

/// Puts a project's own folder on another branch before a Project folder task starts there. Every
/// call blocks: callers run it off the main actor.
public enum ProjectFolderSwitch {
    /// What stands in the way of the switch, found before anything changes.
    public enum Obstacle: Equatable, Sendable {
        /// No local branch of that name, and none on a remote for git to start one from.
        case missing
        /// Another worktree has it checked out, and git keeps a branch to one worktree.
        case elsewhere(path: String)
    }

    public enum Outcome: Equatable, Sendable {
        case switched
        /// Uncommitted changes in the folder clash with the branch: nothing changed.
        case blockedByChanges
    }

    public static func check(_ branch: String, in project: Project, launcher: CommandLauncher) throws -> Obstacle? {
        let repo = GitRepository(project.path, launcher: launcher)
        let here = ExistingWorktrees.resolved(project.path)
        if let other = try repo.worktrees().first(where: { $0.branch == branch && ExistingWorktrees.resolved($0.path) != here }) {
            return .elsewhere(path: other.path)
        }
        if try repo.ask(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], none: [1]) != nil { return nil }
        // On any remote, git's `switch` makes the local branch tracking it.
        for remote in try repo.run(["remote"]).split(separator: "\n").map(String.init) {
            if try repo.ask(["rev-parse", "--verify", "--quiet", "refs/remotes/\(remote)/\(branch)"], none: [1]) != nil { return nil }
        }
        return .missing
    }

    /// Switches the folder to `branch`, made from the current commit when `create`. With `track`
    /// (`<remote>/<branch>`), and not `create`, a local `branch` is made tracking that remote
    /// branch: git won't guess which one when several remotes have the name. With `stash`, the
    /// folder's changes are stashed under that message first, untracked files included, so the
    /// switch can go through; should it still fail, they are put back.
    public static func perform(_ branch: String, in project: Project, create: Bool, track: String? = nil,
                               stash: String?, launcher: CommandLauncher) throws -> Outcome {
        let repo = GitRepository(project.path, launcher: launcher)
        let switchArgs: [String]
        if create {
            switchArgs = ["switch", "-q", "-c", branch]
        } else if let track, try !hasLocal(branch, in: repo) {
            switchArgs = ["switch", "-q", "-c", branch, "--track", track]
        } else {
            switchArgs = ["switch", "-q", branch]
        }
        var stashed = false
        if let stash, try !repo.run(["status", "--porcelain"]).isEmpty {
            try repo.run(["stash", "push", "--include-untracked", "-m", stash])
            stashed = true
        }
        do {
            try repo.run(switchArgs)
            return .switched
        } catch {
            if stashed {
                _ = try? repo.run(["stash", "pop", "-q"])
                throw error
            }
            // git refused: changes in the way, or a reason of its own. A name on several remotes
            // is git's own reason, which stashing would not get past.
            if !create, try isOnSeveralRemotesOnly(branch, in: repo) { throw error }
            if try !repo.run(["status", "--porcelain"]).isEmpty { return .blockedByChanges }
            throw error
        }
    }

    private static func hasLocal(_ branch: String, in repo: GitRepository) throws -> Bool {
        try repo.ask(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], none: [1]) != nil
    }

    /// No local `branch`, and more than one remote has one: a plain `git switch` won't pick.
    private static func isOnSeveralRemotesOnly(_ branch: String, in repo: GitRepository) throws -> Bool {
        guard try !hasLocal(branch, in: repo) else { return false }
        let remotes = try repo.run(["remote"]).split(separator: "\n").map(String.init)
        return try remotes.filter {
            try repo.ask(["rev-parse", "--verify", "--quiet", "refs/remotes/\($0)/\(branch)"], none: [1]) != nil
        }.count > 1
    }

    /// The stash's message, with `label` saying what came next: “Fix login”, quotes included, or
    /// switching to “main”.
    public static func stashMessage(before label: String) -> String { "Shellforge: before \(label)" }
}
