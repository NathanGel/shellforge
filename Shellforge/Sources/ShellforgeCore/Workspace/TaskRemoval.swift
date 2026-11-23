// Ported from AiTerm (app/Sources/AiTermCore/Tasks/TaskWorkflow.swift, Git/Repository+Worktrees.swift and Git/Repository.swift), GPLv3, Laurens D'Hondt.
import Foundation

let removalLog = PackageLogger(category: "removal")

/// Removes a task's worktree and, when asked, its branch: AiTerm's `TaskWorkflow.remove` and the
/// `Repository` worktree helpers it runs, on Shellforge's `CommandLauncher` git. Blocking: callers
/// run it off the main actor.
public enum TaskRemoval {
    /// Lets the UI's removal write to the same log: `log show --predicate 'category == "removal"'`.
    public static func log(_ message: String) { removalLog.notice("\(message)") }

    /// Why the branch stayed although its deletion was asked for.
    public enum BranchRefusal: Equatable, Sendable {
        /// It has commits `base` lacks: deleting it would lose them, so the person is asked first.
        case notMerged(base: String)
        case other(reason: String)
    }

    /// Why the worktree stayed although its removal ran: thrown, the task and its row stay.
    public enum Blocked: Error, Equatable, Sendable {
        /// Something kept writing into the folder while it was deleted — a dev server, a file
        /// watcher — with the programs found holding it, which may be none.
        case folderInUse([FolderUser])
    }

    public struct Removed: Equatable, Sendable {
        public var branchRefusal: BranchRefusal?
        /// A review's local branch kept, and why: a note, not a refusal — the review is gone either way.
        public var keptBranch: ReviewBranchRelease.Kept?
        /// The branch the worktree had checked out instead of the task's — its agent switched. Deleted,
        /// by the task branch's rule, only when it is the one the person was shown and agreed to.
        public var switchedBranch: String?
        /// Why `switchedBranch` stayed although its deletion was agreed to.
        public var switchedRefusal: BranchRefusal?
        public init(branchRefusal: BranchRefusal?, keptBranch: ReviewBranchRelease.Kept? = nil, switchedBranch: String? = nil,
                    switchedRefusal: BranchRefusal? = nil) {
            self.branchRefusal = branchRefusal; self.keptBranch = keptBranch; self.switchedBranch = switchedBranch
            self.switchedRefusal = switchedRefusal
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
        // Asked before anything is removed, by Shellforge rather than the person: the worktree's
        // fsmonitor and hooks run nothing.
        return try !git(AutomaticGitRead.options + AutomaticGitRead.filterOverrides(task.worktreePath, launcher: launcher) + ["status", "--porcelain", "--ignore-submodules=none"], in: task.worktreePath, launcher).isEmpty
    }

    /// The branch the task's worktree has checked out when it is not the task's — its agent
    /// switched — for the Remove prompt to name. nil when it is the task's, detached, or there is
    /// no worktree of Shellforge's to ask.
    public static func switchedBranch(of task: TaskItem, in project: Project, launcher: CommandLauncher) -> String? {
        guard ownsWorktree(of: task, in: project), FileManager.default.fileExists(atPath: task.worktreePath),
              let checkedOut = (try? registered(task.worktreePath, in: project.path, launcher: launcher))??.branch,
              checkedOut != "refs/heads/" + task.branch else { return nil }
        return String(checkedOut.dropFirst("refs/heads/".count))
    }

    /// The worktree — or what a removal git gave up on left of it, or git's record of a folder
    /// already gone — then the branch when asked for. A branch with commits its base lacks is kept,
    /// and said so; force authorises discarding the checkout's changes, never commits.
    ///
    /// `sharedWithAnotherTask`: another task's row names the same worktree path. Its checkout on a
    /// branch other than this task's is then that task's, and is never removed. Otherwise a branch
    /// other than the task's is its agent's doing — `git switch -c` in the worktree — and the
    /// worktree still goes: its commits stay on that branch, and its changes were asked about.
    ///
    /// `deleteSwitched`: the switched branch the prompt named, agreed to be deleted with the task's.
    /// It goes by the same rule only when it is still the one checked out; any other stays. A
    /// worktree git no longer knows — a removal it gave up on halfway, tried again — or whose folder
    /// is gone tells nothing of its checkout, and the branch agreed to is taken as the one.
    public static func remove(task: TaskItem, project: Project, deleteBranch: Bool, deleteSwitched: String? = nil, force: Bool,
                              sharedWithAnotherTask: Bool, launcher: CommandLauncher) throws -> Removed {
        try remove(task: task, project: project, deleteBranch: deleteBranch, deleteSwitched: deleteSwitched, force: force,
                   sharedWithAnotherTask: sharedWithAnotherTask, launcher: launcher, deleteFolder: deleteFolder)
    }

    /// How a leftover folder is deleted.
    typealias FolderDeletion = @Sendable (String) throws -> Void
    static let deleteFolder: FolderDeletion = { try FileManager.default.removeItem(atPath: $0) }

    /// `remove`, with the leftover's deletion handed in: a test's can fail as a folder filling up
    /// again does, which no real deletion does on cue.
    static func remove(task: TaskItem, project: Project, deleteBranch: Bool, deleteSwitched: String? = nil, force: Bool,
                       sharedWithAnotherTask: Bool, launcher: CommandLauncher, deleteFolder: FolderDeletion) throws -> Removed {
        let owned = ownsWorktree(of: task, in: project)
        removalLog.notice("remove task=\(task.id.uuidString) worktree=\(task.worktreePath) branch=\(task.branch) base=\(task.baseBranch) deleteBranch=\(deleteBranch) force=\(force) owned=\(owned)")
        // Not Shellforge's worktree: the task goes, the checkout and its branch stay.
        guard owned else { return Removed(branchRefusal: nil) }
        var switchedBranch: String?
        var checkoutKnown = false
        if FileManager.default.fileExists(atPath: task.worktreePath) {
            (switchedBranch, checkoutKnown) = try removeWorktree(at: task.worktreePath, branch: task.branch, in: project.path, force: force,
                                                                 sharedWithAnotherTask: sharedWithAnotherTask, launcher: launcher,
                                                                 deleteFolder: deleteFolder)
        } else {
            // Locked worktrees cannot be pruned until their lock is released. Refused for one that is
            // not locked, which is no reason to stop.
            _ = try? launcher.run("git", ["-C", project.path, "worktree", "unlock", task.worktreePath])
            try git(["worktree", "prune"], in: project.path, launcher)
        }
        if !checkoutKnown { switchedBranch = deleteSwitched }
        // A review's branch is the merge request's: never deleted on request — a caller may ask and
        // simply not get it — but released, which deletes only a local copy with nothing origin lacks.
        if task.kind == .review {
            guard case .kept(let why) = GitRepository(project.path, launcher: launcher)
                .releaseReviewBranch(task.branch, target: task.baseBranch) else { return Removed(branchRefusal: nil, switchedBranch: switchedBranch) }
            removalLog.notice("review branch \(task.branch) kept: \(String(describing: why))")
            ErrorLogging.record("removal", "Review removed. " + why.note(branch: task.branch))
            return Removed(branchRefusal: nil, keptBranch: why, switchedBranch: switchedBranch)
        }
        guard deleteBranch else { return Removed(branchRefusal: nil, switchedBranch: switchedBranch) }
        let refusal = delete(task.branch, base: task.baseBranch, in: project.path, launcher: launcher)
        // Only the branch the person was shown: one the agent moved to since then stays.
        guard let switchedBranch, switchedBranch == deleteSwitched else {
            return Removed(branchRefusal: refusal, switchedBranch: switchedBranch)
        }
        return Removed(branchRefusal: refusal, switchedBranch: switchedBranch,
                       switchedRefusal: delete(switchedBranch, base: task.baseBranch, in: project.path, launcher: launcher))
    }

    /// `branch` deleted when its commits are all on `base`; else git's `-d` decides. nil when it went,
    /// or was gone already. A `.notMerged` refusal is recorded in the error log — the person is asked,
    /// not told — while an `.other` one is left to the caller that reports it, so it is one line.
    private static func delete(_ branch: String, base: String, in projectPath: String, launcher: CommandLauncher) -> BranchRefusal? {
        if let refusal = refusal(toDelete: branch, base: base) {
            removalLog.notice("branch \(branch) kept, refused: \(refusal)")
            return .other(reason: refusal)
        }
        do {
            // Already-deleted branches are a successful retry.
            // Not recorded by `git`: the catches below write the one line, the kept branch's.
            let refs = try git(["for-each-ref", "--format=%(refname)", "refs/heads/" + branch], in: projectPath, launcher, record: false)
            if refs.split(separator: "\n").contains(Substring("refs/heads/" + branch)) {
                // `git branch -d` asks about HEAD and the branch's upstream, and the project's checkout
                // is usually on some other branch; that refused branches already merged into their
                // base. Ask about the base ourselves: `-D` is then no less safe than `-d`, the commits
                // demonstrably living on in the base. Not merged there, git has the last word.
                let merged = isMerged(branch, into: base, in: projectPath, launcher: launcher)
                try git(["branch", merged ? "-D" : "-d", branch], in: projectPath, launcher, record: false)
            }
            return nil
        } catch let failure as GitFailure where failure.message.contains("not fully merged") {
            removalLog.notice("branch \(branch) kept: notMerged into \(base)")
            ErrorLogging.record("removal", "Branch \(branch) kept: not merged into \(base)")
            return .notMerged(base: base)
        } catch {
            let message = (error as? GitFailure)?.message ?? String(describing: error)
            removalLog.notice("branch \(branch) kept: other: \(message)")
            return .other(reason: firstLine(of: message))
        }
    }

    /// `git branch -D`: the branch goes with the commits only it has. Only once someone has agreed
    /// to lose them, after `remove` refused with `.notMerged`.
    public static func deleteUnmergedBranch(of task: TaskItem, in project: Project, launcher: CommandLauncher) throws {
        try deleteUnmergedBranch(task.branch, of: task, in: project, launcher: launcher)
    }

    /// `deleteUnmergedBranch` for a branch of the task's other than its own: the one its agent
    /// switched to, after `remove` refused it with `.notMerged`.
    public static func deleteUnmergedBranch(_ branch: String, of task: TaskItem, in project: Project, launcher: CommandLauncher) throws {
        if let refusal = refusal(toDelete: branch, base: task.baseBranch) { throw GitFailure(command: "git branch -D", message: refusal) }
        try git(["branch", "-D", branch], in: project.path, launcher)
    }

    /// Why `branch` is not one to delete: a damaged row naming its own base, an agent that checked
    /// the base out, or a name git would read as an option. nil for an ordinary task branch.
    private static func refusal(toDelete branch: String, base: String) -> String? {
        if branch.isEmpty || branch.hasPrefix("-") { return "“\(branch)” isn’t a branch name." }
        if branch == base { return "\(branch) is the task’s base branch." }
        return nil
    }

    // -- the worktree ----------------------------------------------------------------------

    /// The worktree removed: registered, through git; else a leftover git no longer knows. Returns
    /// the branch it had checked out when that was not the task's, and whether git still knew the
    /// checkout to say so.
    private static func removeWorktree(at worktreePath: String, branch: String, in projectPath: String, force: Bool,
                                       sharedWithAnotherTask: Bool, launcher: CommandLauncher,
                                       deleteFolder: FolderDeletion) throws -> (switched: String?, known: Bool) {
        var known = false
        var switchedBranch: String?
        if let worktree = try registered(worktreePath, in: projectPath, launcher: launcher) {
            known = true
            if let checkedOut = worktree.branch, checkedOut != "refs/heads/" + branch {
                let name = checkedOut.replacingOccurrences(of: "refs/heads/", with: "")
                // The path is the task's, the checkout another task's: a row left by a worktree deleted
                // outside Shellforge shares its path with a newer task's.
                if sharedWithAnotherTask {
                    throw GitFailure(command: "git worktree remove \(worktreePath)",
                                     message: "\(worktreePath) has \(name) checked out, not \(branch).")
                }
                switchedBranch = name
                // Not an error: whether it goes is the caller's to decide, and to say.
                removalLog.notice("worktree \(worktreePath) has \(name) checked out instead of \(branch): switchedBranch")
            }
            try removeRegistered(worktreePath, lockedWith: worktree.lockReason, in: projectPath, force: force,
                                 launcher: launcher, deleteFolder: deleteFolder)
        } else {
            // A removal git gave up on halfway, retried: there is nothing left to unlock or refuse.
            // git not listing the folder is no proof of that — a listing misread, or a folder that
            // was never a worktree — so it goes only when it shows it was one.
            guard isAbandonedWorktree(worktreePath) else {
                removalLog.notice("worktree \(worktreePath) not listed by git and not an abandoned worktree: kept")
                ErrorLogging.record("removal", "\(worktreePath) kept: git doesn’t list it and nothing shows a removal left it")
                throw GitFailure(command: "remove \(worktreePath)",
                                 message: "\(worktreePath) isn’t a worktree git knows, so it was left in place. Delete it yourself if you don’t need it, then remove the task again.")
            }
            try deleteLeftover(worktreePath, in: projectPath, launcher: launcher, deleteFolder: deleteFolder)
        }
        // The checkout is gone either way.
        _ = try? git(["worktree", "prune"], in: projectPath, launcher, record: false)
        return (switchedBranch, known)
    }

    /// `lockReason` is the one git listed before unlocking: a refused removal puts back what was
    /// there. A worktree that was not locked is left unlocked.
    private static func removeRegistered(_ worktreePath: String, lockedWith lockReason: String?, in projectPath: String,
                                         force: Bool, launcher: CommandLauncher, deleteFolder: FolderDeletion) throws {
        if lockReason != nil { _ = try? git(["worktree", "unlock", worktreePath], in: projectPath, launcher, record: false) }
        do {
            try git(["worktree", "remove"] + (force ? ["--force"] : []) + [worktreePath], in: projectPath, launcher)
        } catch {
            // git drops its record of the worktree even when it cannot delete all of it — a process
            // still running there wrote files back — and every later `remove` then fails "is not a
            // working tree". The checkout is gone; what is left is files nothing tracks.
            if (try? registered(worktreePath, in: projectPath, launcher: launcher) == nil) == true {
                return try deleteLeftover(worktreePath, in: projectPath, launcher: launcher, deleteFolder: deleteFolder)
            }
            if let lockReason {
                _ = try? git(["worktree", "lock", worktreePath] + (lockReason.isEmpty ? [] : ["--reason", lockReason]),
                             in: projectPath, launcher, record: false)
            }
            throw stillInUse(worktreePath, after: error, launcher: launcher) ?? error
        }
    }

    /// Positive evidence that `folder` is what a removal git gave up on left of a worktree: its
    /// `.git` is a file (not a link, not a repository) naming a gitdir that no longer exists. git
    /// writes that file into every worktree it adds, and deletes the gitdir when it removes one.
    static func isAbandonedWorktree(_ folder: String) -> Bool {
        let dotGit = folder + "/.git"
        var isFolder: ObjCBool = false
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: dotGit)) == nil,
              FileManager.default.fileExists(atPath: dotGit, isDirectory: &isFolder), !isFolder.boolValue,
              let text = try? String(contentsOfFile: dotGit, encoding: .utf8), text.hasPrefix("gitdir:") else { return false }
        // "gitdir: <path>\n": only the one line end goes, as a newline may be part of the path.
        var named = Substring(text.dropFirst("gitdir:".count))
        while named.first == " " { named = named.dropFirst() }
        if named.last == "\n" { named = named.dropLast() }
        guard !named.isEmpty else { return false }
        let gitdir = named.hasPrefix("/") ? String(named) : folder + "/" + named
        return !FileManager.default.fileExists(atPath: gitdir)
    }

    /// What a half-finished removal left of a worktree git no longer knows. Only ever a folder
    /// directly under the project's `.worktrees/`, and never through a symlink: anywhere else, a
    /// folder git does not know is not Shellforge's to delete.
    private static func deleteLeftover(_ worktreePath: String, in projectPath: String, launcher: CommandLauncher,
                                       deleteFolder: FolderDeletion) throws {
        guard FileManager.default.fileExists(atPath: worktreePath) else { return }
        guard TaskWorktrees.isInWorktreesFolder(worktreePath, project: Project(name: "", path: projectPath)),
              (try? FileManager.default.destinationOfSymbolicLink(atPath: projectPath + "/.worktrees")) == nil,
              (try? FileManager.default.destinationOfSymbolicLink(atPath: worktreePath)) == nil else {
            throw GitFailure(command: "remove \(worktreePath)", message: "\(worktreePath) is not a worktree of this project.")
        }
        do {
            try deleteFolder(worktreePath)
        } catch {
            throw stillInUse(worktreePath, after: error, launcher: launcher) ?? error
        }
    }

    /// `.folderInUse` when `error` is a deletion that found the folder filling up again — git's
    /// “Directory not empty”, or the same from deleting a leftover — and the folder is still there,
    /// with the programs whose current directory is in it; recorded in the error log. nil for any
    /// other failure.
    private static func stillInUse(_ worktreePath: String, after error: Error, launcher: CommandLauncher) -> Blocked? {
        guard FileManager.default.fileExists(atPath: worktreePath), refillsWhileDeleted(error) else { return nil }
        let users = FolderUsers.processes(using: worktreePath, launcher: launcher)
        let holders = users.isEmpty ? "no program found with its folder there" : FolderUsers.describe(users)
        removalLog.notice("worktree \(worktreePath) still in use: \(holders)")
        ErrorLogging.record("removal", "Worktree \(worktreePath) not removed, still in use: \(holders)")
        return .folderInUse(users)
    }

    /// A folder something wrote into while it was being deleted: git's “Directory not empty”, or
    /// POSIX ENOTEMPTY or EBUSY, bare or under a Cocoa error as `FileManager` reports it.
    static func refillsWhileDeleted(_ error: Error) -> Bool {
        if let failure = error as? GitFailure { return failure.message.contains("Directory not empty") }
        let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
        return [error as NSError, underlying].contains { error in
            error?.domain == NSPOSIXErrorDomain && [Int(ENOTEMPTY), Int(EBUSY)].contains(error?.code)
        }
    }

    struct Registered: Equatable {
        var lockReason: String?
        /// The ref checked out there, `refs/heads/<name>`; nil when detached.
        var branch: String? = nil
    }

    /// git's record of the worktree at `worktreePath`, with the reason it is locked for, if it is;
    /// nil when git does not know it.
    /// Read with `-z`, so a newline anywhere in the project's path is not taken for the end of one.
    static func registered(_ worktreePath: String, in projectPath: String, launcher: CommandLauncher) throws -> Registered? {
        let wanted = resolved(worktreePath)
        let listing = try git(["worktree", "list", "--porcelain", "-z"], in: projectPath, launcher)
        guard let worktree = GitRepository.worktrees(fromPorcelainZ: listing).first(where: { resolved($0.path) == wanted }) else {
            return nil
        }
        return Registered(lockReason: worktree.lockReason, branch: worktree.branch.map { "refs/heads/" + $0 })
    }

    /// Whether `branch`'s commits are all on `base`, locally or at origin.
    static func isMerged(_ branch: String, into base: String, in projectPath: String, launcher: CommandLauncher) -> Bool {
        guard !base.isEmpty, base != branch else { return false }
        return ["refs/heads/" + base, "refs/remotes/origin/" + base].contains { ref in
            (try? launcher.run("git", ["-C", projectPath, "merge-base", "--is-ancestor", branch, ref]).status) == 0
        }
    }

    // -- git -------------------------------------------------------------------------------

    /// `record: false` for a call whose failure is routine and ignored, or one its caller records
    /// in its own words: the error log gets one line per problem, not git's stderr as well.
    @discardableResult
    private static func git(_ args: [String], in directory: String, _ launcher: CommandLauncher, record: Bool = true) throws -> String {
        let out = try launcher.run("git", ["-C", directory] + args)
        guard out.status == 0 else {
            let command = "git " + args.joined(separator: " ")
            removalLog.notice("\(command) in \(directory) failed, status \(out.status): \(out.stderr)")
            if record { ErrorLogging.record("removal", "\(command) in \(directory) failed, status \(out.status): \(out.stderr)") }
            throw GitFailure(command: command, message: out.stderr)
        }
        return out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Symlinks resolved through the deepest part of `path` that exists: Foundation leaves a path
    /// that is not there as it is (`/var/…` stays short of `/private/var/…`), and a worktree whose
    /// folder is gone is still compared with git's record of it.
    private static func resolved(_ path: String) -> String {
        var existing = URL(fileURLWithPath: path).standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        let base = existing.resolvingSymlinksInPath().standardizedFileURL
        return missing.reduce(base) { $0.appendingPathComponent($1) }.path
    }

    private static func firstLine(of message: String) -> String {
        message.split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? message
    }
}
