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
        public init(branchRefusal: BranchRefusal?) { self.branchRefusal = branchRefusal }
    }

    /// Whether `git worktree remove` would refuse the task's worktree without `--force`: git's own
    /// check, asked ahead of it so the task's tabs can close before anything is deleted. False for a
    /// folder git does not know as a worktree — `git status` there would answer for the project's
    /// checkout.
    public static func hasUnsavedWork(task: TaskItem, project: Project, launcher: CommandLauncher) throws -> Bool {
        guard FileManager.default.fileExists(atPath: task.worktreePath),
              try registered(task.worktreePath, in: project.path, launcher: launcher) != nil else { return false }
        return try !git(["status", "--porcelain", "--ignore-submodules=none"], in: task.worktreePath, launcher).isEmpty
    }

    /// The worktree — or what a removal git gave up on left of it, or git's record of a folder
    /// already gone — then the branch when asked for. A branch with commits its base lacks is kept,
    /// and said so; force authorises discarding the checkout's changes, never commits.
    public static func remove(task: TaskItem, project: Project, deleteBranch: Bool, force: Bool,
                              launcher: CommandLauncher) throws -> Removed {
        if FileManager.default.fileExists(atPath: task.worktreePath) {
            try removeWorktree(at: task.worktreePath, in: project.path, force: force, launcher: launcher)
        } else {
            // Locked worktrees cannot be pruned until their lock is released. Refused for one that is
            // not locked, which is no reason to stop.
            _ = try? git(["worktree", "unlock", task.worktreePath], in: project.path, launcher)
            try git(["worktree", "prune"], in: project.path, launcher)
        }
        guard deleteBranch else { return Removed(branchRefusal: nil) }
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
            return Removed(branchRefusal: nil)
        } catch let failure as GitFailure where failure.message.contains("not fully merged") {
            return Removed(branchRefusal: .notMerged(base: task.baseBranch))
        } catch let failure as GitFailure {
            return Removed(branchRefusal: .other(reason: firstLine(of: failure.message)))
        }
    }

    /// `git branch -D`: the branch goes with the commits only it has. Only once someone has agreed
    /// to lose them, after `remove` refused with `.notMerged`.
    public static func deleteUnmergedBranch(of task: TaskItem, in project: Project, launcher: CommandLauncher) throws {
        try git(["branch", "-D", task.branch], in: project.path, launcher)
    }

    // -- the worktree ----------------------------------------------------------------------

    /// The worktree removed: registered, through git; else a leftover git no longer knows.
    private static func removeWorktree(at worktreePath: String, in projectPath: String, force: Bool,
                                       launcher: CommandLauncher) throws {
        if let worktree = try registered(worktreePath, in: projectPath, launcher: launcher) {
            try removeRegistered(worktreePath, lockedWith: worktree.lockReason, in: projectPath, force: force, launcher: launcher)
        } else {
            // A removal git gave up on halfway, retried: there is nothing left to unlock or refuse.
            try deleteLeftover(worktreePath, in: projectPath)
        }
        // The checkout is gone either way.
        _ = try? git(["worktree", "prune"], in: projectPath, launcher)
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
            if (try? registered(worktreePath, in: projectPath, launcher: launcher)) == .some(nil) {
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
              (try? FileManager.default.destinationOfSymbolicLink(atPath: worktreePath)) == nil else {
            throw GitFailure(command: "remove \(worktreePath)", message: "\(worktreePath) is not a worktree of this project.")
        }
        try FileManager.default.removeItem(atPath: worktreePath)
    }

    struct Registered: Equatable { var lockReason: String? }

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
                found = Registered(lockReason: "")
            } else if current == wanted, line.hasPrefix("locked ") {
                found = Registered(lockReason: String(line.dropFirst("locked ".count)))
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
