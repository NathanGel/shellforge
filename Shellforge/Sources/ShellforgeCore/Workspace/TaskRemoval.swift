// Ported from AiTerm (app/Sources/AiTermCore/Tasks/TaskWorkflow.swift, Git/Repository+Worktrees.swift and Git/Repository.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// Removes a task's worktree and, when asked, its branch: AiTerm's `TaskWorkflow.remove` and the
/// `Repository` worktree helpers it runs, on Shellforge's `CommandLauncher` git. Blocking: callers
/// run it off the main actor.
public enum TaskRemoval {
    /// Why the branch stayed although its deletion was asked for.
    public enum BranchRefusal: Equatable, Sendable {
        /// It has commits `base` lacks: deleting it would lose them, so the person is asked first.
        case notMerged(base: String)
        case other(reason: String)
    }

    public struct Removed: Equatable, Sendable {
        public var branchRefusal: BranchRefusal?
        /// A review's local branch kept, and why: a note, not a refusal — the review is gone either way.
        public var keptBranch: ReviewBranchRelease.Kept?
        /// The branch the worktree had checked out instead of the task's — its agent switched — which
        /// the removal never deletes: only the task's own branch is ever asked about.
        public var switchedBranch: String?
        public init(branchRefusal: BranchRefusal?, keptBranch: ReviewBranchRelease.Kept? = nil, switchedBranch: String? = nil) {
            self.branchRefusal = branchRefusal; self.keptBranch = keptBranch; self.switchedBranch = switchedBranch
        }
    }

    /// Whether `git worktree remove` would refuse the task's worktree without `--force`: git's own
    /// check, asked ahead of it so the task's tabs can close before anything is deleted. False for a
    /// folder git does not know as a worktree — `git status` there would answer for the project's
    /// checkout.
    /// Whether the task's worktree is one Shellforge keeps — in the project's `.worktrees/` — and so
    /// its to delete. A worktree continued from elsewhere (New Task's Existing worktree) is not:
    /// removing its task only forgets the task.
    public static func ownsWorktree(of task: TaskItem, in project: Project) -> Bool {
        ExistingWorktrees.resolved(task.worktreePath).hasPrefix(ExistingWorktrees.resolved(project.path) + "/.worktrees/")
    }

    public static func hasUnsavedWork(task: TaskItem, project: Project, launcher: CommandLauncher) throws -> Bool {
        // Nothing is deleted from a worktree Shellforge does not keep, so nothing can be lost.
        guard ownsWorktree(of: task, in: project) else { return false }
        guard FileManager.default.fileExists(atPath: task.worktreePath),
              try registered(task.worktreePath, in: project.path, launcher: launcher) != nil else { return false }
        return try !git(["status", "--porcelain", "--ignore-submodules=none"], in: task.worktreePath, launcher).isEmpty
    }

    /// The worktree — or what a removal git gave up on left of it, or git's record of a folder
    /// already gone — then the branch when asked for. A branch with commits its base lacks is kept,
    /// and said so; force authorises discarding the checkout's changes, never commits.
    ///
    /// `sharedWithAnotherTask`: another task's row names the same worktree path. Its checkout on a
    /// branch other than this task's is then that task's, and is never removed. Otherwise a branch
    /// other than the task's is its agent's doing — `git switch -c` in the worktree — and the
    /// worktree still goes: its commits stay on that branch, and its changes were asked about.
    public static func remove(task: TaskItem, project: Project, deleteBranch: Bool, force: Bool,
                              sharedWithAnotherTask: Bool, launcher: CommandLauncher) throws -> Removed {
        // Not Shellforge's worktree: the task goes, the checkout and its branch stay.
        guard ownsWorktree(of: task, in: project) else { return Removed(branchRefusal: nil) }
        var switchedBranch: String?
        if FileManager.default.fileExists(atPath: task.worktreePath) {
            switchedBranch = try removeWorktree(at: task.worktreePath, branch: task.branch, in: project.path, force: force,
                                                sharedWithAnotherTask: sharedWithAnotherTask, launcher: launcher)
        } else {
            // Locked worktrees cannot be pruned until their lock is released. Refused for one that is
            // not locked, which is no reason to stop.
            _ = try? git(["worktree", "unlock", task.worktreePath], in: project.path, launcher)
            try git(["worktree", "prune"], in: project.path, launcher)
        }
        // A review's branch is the merge request's: never deleted on request — a caller may ask and
        // simply not get it — but released, which deletes only a local copy with nothing origin lacks.
        if task.kind == .review {
            guard case .kept(let why) = GitRepository(project.path, launcher: launcher)
                .releaseReviewBranch(task.branch, target: task.baseBranch) else { return Removed(branchRefusal: nil, switchedBranch: switchedBranch) }
            return Removed(branchRefusal: nil, keptBranch: why, switchedBranch: switchedBranch)
        }
        guard deleteBranch else { return Removed(branchRefusal: nil, switchedBranch: switchedBranch) }
        if let refusal = refusal(toDelete: task) { return Removed(branchRefusal: .other(reason: refusal), switchedBranch: switchedBranch) }
        do {
            // Already-deleted branches are a successful retry.
            let refs = try git(["for-each-ref", "--format=%(refname)", "refs/heads/" + task.branch], in: project.path, launcher)
            if refs.split(separator: "\n").contains(Substring("refs/heads/" + task.branch)) {
                // `git branch -d` asks about HEAD and the branch's upstream, and the project's checkout
                // is usually on some other branch; that refused branches already merged into their
                // base. Ask about the base ourselves: `-D` is then no less safe than `-d`, the commits
                // demonstrably living on in the base. Not merged there, git has the last word.
                let merged = isMerged(task.branch, into: task.baseBranch, in: project.path, launcher: launcher)
                try git(["branch", merged ? "-D" : "-d", task.branch], in: project.path, launcher)
            }
            return Removed(branchRefusal: nil, switchedBranch: switchedBranch)
        } catch let failure as GitFailure where failure.message.contains("not fully merged") {
            return Removed(branchRefusal: .notMerged(base: task.baseBranch), switchedBranch: switchedBranch)
        } catch let failure as GitFailure {
            return Removed(branchRefusal: .other(reason: firstLine(of: failure.message)), switchedBranch: switchedBranch)
        }
    }

    /// `git branch -D`: the branch goes with the commits only it has. Only once someone has agreed
    /// to lose them, after `remove` refused with `.notMerged`.
    public static func deleteUnmergedBranch(of task: TaskItem, in project: Project, launcher: CommandLauncher) throws {
        if let refusal = refusal(toDelete: task) { throw GitFailure(command: "git branch -D", message: refusal) }
        try git(["branch", "-D", task.branch], in: project.path, launcher)
    }

    /// Why the task's branch is not one to delete: a damaged row naming its own base, or a name git
    /// would read as an option. nil for an ordinary task branch.
    private static func refusal(toDelete task: TaskItem) -> String? {
        if task.branch.isEmpty || task.branch.hasPrefix("-") { return "“\(task.branch)” isn’t a branch name." }
        if task.branch == task.baseBranch { return "\(task.branch) is the task’s base branch." }
        return nil
    }

    // -- the worktree ----------------------------------------------------------------------

    /// The worktree removed: registered, through git; else a leftover git no longer knows. Returns
    /// the branch it had checked out when that was not the task's.
    private static func removeWorktree(at worktreePath: String, branch: String, in projectPath: String, force: Bool,
                                       sharedWithAnotherTask: Bool, launcher: CommandLauncher) throws -> String? {
        var switchedBranch: String?
        if let worktree = try registered(worktreePath, in: projectPath, launcher: launcher) {
            if let checkedOut = worktree.branch, checkedOut != "refs/heads/" + branch {
                let name = checkedOut.replacingOccurrences(of: "refs/heads/", with: "")
                // The path is the task's, the checkout another task's: a row left by a worktree deleted
                // outside Shellforge shares its path with a newer task's.
                if sharedWithAnotherTask {
                    throw GitFailure(command: "git worktree remove \(worktreePath)",
                                     message: "\(worktreePath) has \(name) checked out, not \(branch).")
                }
                switchedBranch = name
            }
            try removeRegistered(worktreePath, lockedWith: worktree.lockReason, in: projectPath, force: force, launcher: launcher)
        } else {
            // A removal git gave up on halfway, retried: there is nothing left to unlock or refuse.
            try deleteLeftover(worktreePath, in: projectPath)
        }
        // The checkout is gone either way.
        _ = try? git(["worktree", "prune"], in: projectPath, launcher)
        return switchedBranch
    }

    /// `lockReason` is the one git listed before unlocking: a refused removal puts back what was
    /// there. A worktree that was not locked is left unlocked.
    private static func removeRegistered(_ worktreePath: String, lockedWith lockReason: String?, in projectPath: String,
                                         force: Bool, launcher: CommandLauncher) throws {
        if lockReason != nil { _ = try? git(["worktree", "unlock", worktreePath], in: projectPath, launcher) }
        do {
            try git(["worktree", "remove"] + (force ? ["--force"] : []) + [worktreePath], in: projectPath, launcher)
        } catch {
            // git drops its record of the worktree even when it cannot delete all of it — a process
            // still running there wrote files back — and every later `remove` then fails "is not a
            // working tree". The checkout is gone; what is left is files nothing tracks.
            if (try? registered(worktreePath, in: projectPath, launcher: launcher) == nil) == true {
                return try deleteLeftover(worktreePath, in: projectPath)
            }
            if let lockReason {
                _ = try? git(["worktree", "lock", worktreePath] + (lockReason.isEmpty ? [] : ["--reason", lockReason]),
                             in: projectPath, launcher)
            }
            throw error
        }
    }

    /// What a half-finished removal left of a worktree git no longer knows. Only ever a folder
    /// directly under the project's `.worktrees/`, and never through a symlink: anywhere else, a
    /// folder git does not know is not Shellforge's to delete.
    private static func deleteLeftover(_ worktreePath: String, in projectPath: String) throws {
        guard FileManager.default.fileExists(atPath: worktreePath) else { return }
        let parent = URL(fileURLWithPath: worktreePath).deletingLastPathComponent().path
        guard resolved(parent) == resolved(projectPath + "/.worktrees"),
              (try? FileManager.default.destinationOfSymbolicLink(atPath: projectPath + "/.worktrees")) == nil,
              (try? FileManager.default.destinationOfSymbolicLink(atPath: worktreePath)) == nil else {
            throw GitFailure(command: "remove \(worktreePath)", message: "\(worktreePath) is not a worktree of this project.")
        }
        try FileManager.default.removeItem(atPath: worktreePath)
    }

    struct Registered: Equatable {
        var lockReason: String?
        /// The ref checked out there, `refs/heads/<name>`; nil when detached.
        var branch: String? = nil
    }

    /// git's record of the worktree at `worktreePath`, with the reason it is locked for, if it is;
    /// nil when git does not know it.
    static func registered(_ worktreePath: String, in projectPath: String, launcher: CommandLauncher) throws -> Registered? {
        let wanted = resolved(worktreePath)
        var current: String?, found: Registered?
        for line in try git(["worktree", "list", "--porcelain"], in: projectPath, launcher).split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                current = resolved(String(line.dropFirst("worktree ".count)))
                if current == wanted { found = Registered(lockReason: nil) }
            } else if current == wanted, line == "locked" {
                found?.lockReason = ""
            } else if current == wanted, line.hasPrefix("locked ") {
                found?.lockReason = String(line.dropFirst("locked ".count))
            } else if current == wanted, line.hasPrefix("branch ") {
                found?.branch = String(line.dropFirst("branch ".count))
            }
        }
        return found
    }

    /// Whether `branch`'s commits are all on `base`, locally or at origin.
    static func isMerged(_ branch: String, into base: String, in projectPath: String, launcher: CommandLauncher) -> Bool {
        guard !base.isEmpty, base != branch else { return false }
        return ["refs/heads/" + base, "refs/remotes/origin/" + base].contains { ref in
            (try? launcher.run("git", ["-C", projectPath, "merge-base", "--is-ancestor", branch, ref]).status) == 0
        }
    }

    // -- git -------------------------------------------------------------------------------

    @discardableResult
    private static func git(_ args: [String], in directory: String, _ launcher: CommandLauncher) throws -> String {
        let out = try launcher.run("git", ["-C", directory] + args)
        guard out.status == 0 else { throw GitFailure(command: "git " + args.joined(separator: " "), message: out.stderr) }
        return out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func firstLine(of message: String) -> String {
        message.split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? message
    }
}
