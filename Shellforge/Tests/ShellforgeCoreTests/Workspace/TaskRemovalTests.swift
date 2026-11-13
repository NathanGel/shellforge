// Ported from AiTerm (app/Tests/AiTermCoreTests/TaskWorkflowTests.swift and WorktreesTests.swift), GPLv3, Laurens D'Hondt.
import Foundation
import Testing
@testable import ShellforgeTestSupport
@testable import ShellforgeCore

/// Removing a task's worktree and branch, as AiTerm's `TaskWorkflow.remove` does: git's own
/// refusals kept, a half-removed worktree finished, and a branch with commits its base lacks kept
/// until the person agrees to lose them.
@Suite struct TaskRemovalTests {
    private func task(_ repo: GitRepoFixture, _ title: String = "Fix login") throws -> TaskItem {
        try TaskWorktrees.create(title: title, in: repo.project, base: "main", launcher: repo.launcher)
    }

    private func branchExists(_ repo: GitRepoFixture, _ branch: String) throws -> Bool {
        !(try repo.git("for-each-ref", "--format=%(refname)", "refs/heads/" + branch)).isEmpty
    }

    /// A worktree continued from outside the project's `.worktrees/` is not Shellforge's to delete:
    /// removing the task leaves it, and its branch, where they are.
    @Test func aWorktreeOutsideTheProjectsFolderIsLeftAlone() throws {
        let repo = try GitRepoFixture()
        let outside = (repo.path as NSString).deletingLastPathComponent + "/hand-made"
        try repo.git("worktree", "add", "-q", "-b", "feat/hand", outside)
        let project = repo.project
        let task = TaskItem(projectId: project.id, title: "hand", branch: "feat/hand", worktreePath: outside, baseBranch: "main")
        #expect(!TaskRemoval.ownsWorktree(of: task, in: project))
        #expect(TaskRemoval.ownsWorktree(of: TaskItem(projectId: project.id, title: "t", branch: "b", worktreePath: repo.path + "/.worktrees/t", baseBranch: "main"), in: project))
        _ = try TaskRemoval.remove(task: task, project: project, deleteBranch: true, force: true, sharedWithAnotherTask: false, launcher: repo.launcher)
        #expect(FileManager.default.fileExists(atPath: outside))
        #expect(try branchExists(repo, "feat/hand"))
    }

    @Test func anUnmergedBranchIsKeptAndDeletedOnlyOnRequest() throws {
        let repo = try GitRepoFixture()
        let task = try task(repo)
        try repo.git(["commit", "-q", "--allow-empty", "-m", "work"], in: task.worktreePath)
        let result = try TaskRemoval.remove(task: task, project: repo.project, deleteBranch: true, force: true, sharedWithAnotherTask: false, launcher: repo.launcher)
        // The one refusal Shellforge can put in its own words: commits the base lacks.
        #expect(result.branchRefusal == .notMerged(base: "main"))
        #expect(!FileManager.default.fileExists(atPath: task.worktreePath))
        #expect(try branchExists(repo, task.branch))

        try TaskRemoval.deleteUnmergedBranch(of: task, in: repo.project, launcher: repo.launcher)
        #expect(try !branchExists(repo, task.branch))
        // Removing again is a finished retry, not an error.
        #expect(try TaskRemoval.remove(task: task, project: repo.project, deleteBranch: true, force: false, sharedWithAnotherTask: false,
                                       launcher: repo.launcher).branchRefusal == nil)
    }

    /// A worktree locked by hand keeps its lock, and its files, when git refuses the removal.
    @Test func aRefusedRemovalKeepsTheCheckoutAndItsLock() throws {
        let repo = try GitRepoFixture()
        let task = try task(repo)
        try repo.git("worktree", "lock", "--reason", "mine", task.worktreePath)
        let file = task.worktreePath + "/important.txt"
        try "work in progress".write(toFile: file, atomically: true, encoding: .utf8)
        #expect(throws: GitFailure.self) {
            _ = try TaskRemoval.remove(task: task, project: repo.project, deleteBranch: false, force: false, sharedWithAnotherTask: false, launcher: repo.launcher)
        }
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "work in progress")
        #expect(try repo.git("worktree", "list", "--porcelain").contains("locked mine"))
    }

    /// git drops its record of a worktree even when it cannot delete all of it. What it leaves is
    /// a folder no git knows, and removing that again used to fail "is not a working tree" for good.
    @Test func aRemovalGitGaveUpOnHalfwayIsFinishedByTheNext() throws {
        let repo = try GitRepoFixture()
        let task = try task(repo)
        let dotGit = try String(contentsOfFile: task.worktreePath + "/.git", encoding: .utf8)
        try repo.git("worktree", "remove", task.worktreePath)
        // What git left: files it could not delete, and the `.git` file naming its gitdir, now gone.
        try FileManager.default.createDirectory(atPath: task.worktreePath + "/app/node_modules/.cache", withIntermediateDirectories: true)
        try dotGit.write(toFile: task.worktreePath + "/.git", atomically: true, encoding: .utf8)

        let result = try TaskRemoval.remove(task: task, project: repo.project, deleteBranch: true, force: false, sharedWithAnotherTask: false, launcher: repo.launcher)

        #expect(result.branchRefusal == nil)
        #expect(!FileManager.default.fileExists(atPath: task.worktreePath))
        #expect(try !branchExists(repo, task.branch))
    }

    /// The folder deleted by hand, git's record of it left: the record is pruned and the task goes.
    @Test func aMissingWorktreeIsPrunedAndTheTaskStillGoes() throws {
        let repo = try GitRepoFixture()
        let task = try task(repo)
        try FileManager.default.removeItem(atPath: task.worktreePath)

        let result = try TaskRemoval.remove(task: task, project: repo.project, deleteBranch: false, force: false, sharedWithAnotherTask: false, launcher: repo.launcher)

        #expect(result.branchRefusal == nil)
        #expect(!(try repo.git("worktree", "list", "--porcelain")).contains(".worktrees/"))
    }

    /// The project's checkout is rarely on the base branch. `git branch -d` judges "merged" against
    /// HEAD and the upstream only, so a branch already merged into its base was refused.
    @Test func aMergedBranchGoesWhileAnotherBranchIsCheckedOut() throws {
        let repo = try GitRepoFixture()
        let task = try task(repo)
        try repo.git(["commit", "-q", "--allow-empty", "-m", "work"], in: task.worktreePath)
        try repo.git("merge", "-q", "--ff-only", task.branch)
        try repo.git("checkout", "-q", "-b", "feat/elsewhere", "main~1")
        try repo.git("commit", "-q", "--allow-empty", "-m", "elsewhere")

        let result = try TaskRemoval.remove(task: task, project: repo.project, deleteBranch: true, force: false, sharedWithAnotherTask: false, launcher: repo.launcher)

        #expect(result.branchRefusal == nil)
        #expect(try !branchExists(repo, task.branch))
    }

    /// The other half: merged-ness judged against the base must not become an unconditional `-D`.
    @Test func aBranchMissingFromItsBaseStaysWhileAnotherBranchIsCheckedOut() throws {
        let repo = try GitRepoFixture()
        let task = try task(repo)
        try repo.git(["commit", "-q", "--allow-empty", "-m", "work"], in: task.worktreePath)
        try repo.git("checkout", "-q", "-b", "feat/elsewhere")
        try repo.git("commit", "-q", "--allow-empty", "-m", "elsewhere")

        let result = try TaskRemoval.remove(task: task, project: repo.project, deleteBranch: true, force: true, sharedWithAnotherTask: false, launcher: repo.launcher)

        #expect(result.branchRefusal == .notMerged(base: "main"))
        #expect(try branchExists(repo, task.branch))
    }

    /// git refusing a dirty worktree, then failing to list the worktrees when asked again: a failed
    /// answer is not "git no longer knows it", and the checkout — its changes — must stay.
    @Test func aWorktreeListThatFailsNeverCountsAsGone() throws {
        let repo = try GitRepoFixture()
        let task = try task(repo)
        let file = task.worktreePath + "/important.txt"
        try "work in progress".write(toFile: file, atomically: true, encoding: .utf8)
        // A git that answers the first `worktree list` and fails every one after it.
        let bin = TestScratch.root.appendingPathComponent("flaky-git-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        case "$*" in *"worktree list"*)
          if [ -e "\(bin)/listed" ]; then exit 1; fi
          touch "\(bin)/listed";;
        esac
        exec /usr/bin/git "$@"
        """
        try script.write(toFile: bin + "/git", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin + "/git")
        var variables = repo.launcher.reload().variables
        variables["PATH"] = bin + ":" + (variables["PATH"] ?? "/usr/bin:/bin")
        let env = variables
        let flaky = CommandLauncher { ResolvedEnvironment(variables: env, source: .loginShell("/bin/sh")) }

        #expect(throws: (any Error).self) {
            _ = try TaskRemoval.remove(task: task, project: repo.project, deleteBranch: false, force: false, sharedWithAnotherTask: false, launcher: flaky)
        }
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "work in progress")
    }

    /// The error log's lines, each one.
    private func logLines(_ log: ErrorLog) -> [String] {
        ((try? String(contentsOf: log.fileURL, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private func scratchLog(_ name: String) -> ErrorLog {
        ErrorLog(folder: TestScratch.root.appendingPathComponent("\(name)-\(UUID().uuidString)"), version: "1")
    }

    /// A branch kept because it isn’t merged is one line in the error log — the kept one — not git’s
    /// own refusal as well.
    @Test func anUnmergedBranchKeptIsOneLineInTheErrorLog() throws {
        let repo = try GitRepoFixture()
        let task = try task(repo)
        try repo.git(["commit", "-q", "--allow-empty", "-m", "work"], in: task.worktreePath)
        let log = scratchLog("kept-log")
        let result = try ErrorLogging.$testLog.withValue(log) {
            try TaskRemoval.remove(task: task, project: repo.project, deleteBranch: true, force: true, sharedWithAnotherTask: false, launcher: repo.launcher)
        }
        #expect(result.branchRefusal == .notMerged(base: "main"))
        let lines = logLines(log)
        #expect(lines.count == 1, "\(lines)")
        #expect(lines.first?.hasSuffix(" · removal · Branch \(task.branch) kept: not merged into main") == true, "\(lines)")
    }

    /// The routine git calls whose failures removal ignores — unlocking, locking again, pruning —
    /// write nothing to the error log when they fail.
    @Test func routineGitCallsThatFailWriteNothingToTheErrorLog() throws {
        let repo = try GitRepoFixture()
        let bin = TestScratch.root.appendingPathComponent("routine-git-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        case "$*" in *"worktree prune"*|*"worktree unlock"*|*"worktree lock"*)
          echo "fatal: refused for the test" >&2; exit 128;;
        esac
        exec /usr/bin/git "$@"
        """
        try script.write(toFile: bin + "/git", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin + "/git")
        var variables = repo.launcher.reload().variables
        variables["PATH"] = bin + ":" + (variables["PATH"] ?? "/usr/bin:/bin")
        let env = variables
        let refusing = CommandLauncher { ResolvedEnvironment(variables: env, source: .loginShell("/bin/sh")) }

        // A removal that works: its prune afterwards fails, and is no problem.
        let merged = try task(repo, "Merged work")
        let log = scratchLog("routine-log")
        try ErrorLogging.$testLog.withValue(log) {
            _ = try TaskRemoval.remove(task: merged, project: repo.project, deleteBranch: true, force: true, sharedWithAnotherTask: false, launcher: refusing)
        }
        #expect(!FileManager.default.fileExists(atPath: merged.worktreePath))
        #expect(logLines(log).isEmpty, "\(logLines(log))")

        // A locked one git refuses: the refusal is written; the failed unlock and lock again are not.
        let locked = try task(repo, "Locked work")
        try repo.git("worktree", "lock", "--reason", "mine", locked.worktreePath)
        ErrorLogging.$testLog.withValue(log) {
            #expect(throws: (any Error).self) {
                _ = try TaskRemoval.remove(task: locked, project: repo.project, deleteBranch: false, force: false, sharedWithAnotherTask: false, launcher: refusing)
            }
        }
        let lines = logLines(log)
        #expect(lines.contains { $0.contains("git worktree remove") }, "\(lines)")
        #expect(!lines.contains { $0.contains("worktree unlock") || $0.contains("worktree lock") || $0.contains("worktree prune") }, "\(lines)")
    }

    /// A git whose `worktree remove` fails as it does while a dev server writes into the folder,
    /// deleting nothing; every other command is the real git.
    private func busyGit(_ repo: GitRepoFixture) throws -> CommandLauncher {
        let bin = TestScratch.root.appendingPathComponent("busy-git-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        case "$*" in *"worktree remove"*)
          echo "error: failed to delete '$5': Directory not empty" >&2; exit 255;;
        esac
        exec /usr/bin/git "$@"
        """
        try script.write(toFile: bin + "/git", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin + "/git")
        var variables = repo.launcher.reload().variables
        variables["PATH"] = bin + ":" + (variables["PATH"] ?? "/usr/bin:/bin")
        let env = variables
        return CommandLauncher { ResolvedEnvironment(variables: env, source: .loginShell("/bin/sh")) }
    }

    /// git failing “Directory not empty”: something still writes there. The removal says the folder
    /// is in use — by whom, when lsof finds it — rather than git's bare error, and the checkout stays.
    @Test func aDirectoryNotEmptyFailureReportsTheFolderInUse() throws {
        let repo = try GitRepoFixture()
        let task = try task(repo)
        let log = ErrorLog(folder: TestScratch.root.appendingPathComponent("busy-log-\(UUID().uuidString)"), version: "1")
        let busy = try busyGit(repo)

        let thrown = ErrorLogging.$testLog.withValue(log) {
            #expect(throws: TaskRemoval.Blocked.self) {
                _ = try TaskRemoval.remove(task: task, project: repo.project, deleteBranch: true, force: false,
                                           sharedWithAnotherTask: false, launcher: busy)
            }
        }
        guard case .folderInUse? = thrown else { Issue.record("not .folderInUse: \(String(describing: thrown))"); return }
        #expect(FileManager.default.fileExists(atPath: task.worktreePath))
        #expect(try branchExists(repo, task.branch))
        let written = (try? String(contentsOf: log.fileURL, encoding: .utf8)) ?? ""
        #expect(written.contains("still in use"), "\(written)")
    }

    /// The real case: git deletes its record of the worktree even when deleting the folder fails,
    /// so the removal goes on to delete the leftover, and that deletion finds the folder refilling.
    /// The git stub drops the record, as git does, and leaves the files; the deletion fails as
    /// `FileManager` does with a writer still busy there.
    @Test func aLeftoverThatRefillsWhileDeletedReportsTheFolderInUse() throws {
        let repo = try GitRepoFixture()
        let task = try task(repo)
        let bin = TestScratch.root.appendingPathComponent("unregistering-git-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        case "$*" in *"worktree remove"*)
          for admin in "$2"/.git/worktrees/*; do
            grep -q "/$(basename "$5")/.git$" "$admin/gitdir" && rm -rf "$admin"
          done
          echo "error: failed to delete '$5': Directory not empty" >&2; exit 255;;
        esac
        exec /usr/bin/git "$@"
        """
        try script.write(toFile: bin + "/git", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin + "/git")
        var variables = repo.launcher.reload().variables
        variables["PATH"] = bin + ":" + (variables["PATH"] ?? "/usr/bin:/bin")
        let env = variables
        let unregistering = CommandLauncher { ResolvedEnvironment(variables: env, source: .loginShell("/bin/sh")) }
        let deletions = Locked<[String]>([])
        let refilling: TaskRemoval.FolderDeletion = { path in
            deletions.withLock { $0.append(path) }
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                          userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTEMPTY))])
        }

        let thrown = #expect(throws: TaskRemoval.Blocked.self) {
            _ = try TaskRemoval.remove(task: task, project: repo.project, deleteBranch: false, force: false,
                                       sharedWithAnotherTask: false, launcher: unregistering, deleteFolder: refilling)
        }
        guard case .folderInUse? = thrown else { Issue.record("not .folderInUse: \(String(describing: thrown))"); return }
        // The leftover branch ran: git no longer knows the worktree, and its folder was being deleted.
        #expect(try TaskRemoval.registered(task.worktreePath, in: repo.path, launcher: repo.launcher) == nil)
        #expect(deletions.withLock { $0 } == [task.worktreePath])
        #expect(FileManager.default.fileExists(atPath: task.worktreePath))
    }

    /// Only a deletion that found the folder filling up counts as “in use”: not a refused permission.
    @Test func onlyAFolderRefillingCountsAsInUse() {
        let posix = { (code: Int32) in NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
        let cocoa = { (code: Int32) in
            NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [NSUnderlyingErrorKey: posix(code)])
        }
        #expect(TaskRemoval.refillsWhileDeleted(cocoa(ENOTEMPTY)))
        #expect(TaskRemoval.refillsWhileDeleted(posix(EBUSY)))
        #expect(TaskRemoval.refillsWhileDeleted(GitFailure(command: "git worktree remove", message: "error: failed to delete 'x': Directory not empty")))
        #expect(!TaskRemoval.refillsWhileDeleted(cocoa(EACCES)))
        #expect(!TaskRemoval.refillsWhileDeleted(posix(EACCES)))
        #expect(!TaskRemoval.refillsWhileDeleted(GitFailure(command: "git worktree remove", message: "fatal: contains modified or untracked files")))
    }

    /// A row left behind by a worktree deleted outside Shellforge shares its path with a newer task
    /// of the same title: removing the old row must not take the new task's worktree.
    @Test func aWorktreeOfAnotherBranchAtTheTasksPathIsNeverRemoved() throws {
        let repo = try GitRepoFixture()
        let old = try task(repo)
        try repo.git("worktree", "remove", old.worktreePath)
        try repo.git("worktree", "add", "-q", "-b", "fix-login-2", old.worktreePath, "main")
        let file = old.worktreePath + "/new.txt"
        try "the new task's".write(toFile: file, atomically: true, encoding: .utf8)

        #expect(throws: (any Error).self) {
            _ = try TaskRemoval.remove(task: old, project: repo.project, deleteBranch: false, force: true, sharedWithAnotherTask: true, launcher: repo.launcher)
        }
        #expect(FileManager.default.fileExists(atPath: file))
    }

    /// An agent that ran `git switch -c` in its worktree: the worktree is still the task's, and goes.
    /// Refused, the row stayed "Not removed" for good. The agent's branch — its commits — stays,
    /// and so does the task's when it holds work; only a branch with nothing to lose is deleted.
    @Test func aWorktreeItsAgentSwitchedToAnotherBranchIsStillRemoved() throws {
        let repo = try GitRepoFixture()
        let task = try task(repo)
        try repo.git(["switch", "-q", "-c", "claude/feature-x"], in: task.worktreePath)
        try repo.git(["commit", "-q", "--allow-empty", "-m", "agent's work"], in: task.worktreePath)

        let result = try TaskRemoval.remove(task: task, project: repo.project, deleteBranch: true, force: false,
                                            sharedWithAnotherTask: false, launcher: repo.launcher)

        #expect(result.switchedBranch == "claude/feature-x")
        #expect(result.branchRefusal == nil)
        #expect(!FileManager.default.fileExists(atPath: task.worktreePath))
        #expect(!(try repo.git("worktree", "list", "--porcelain")).contains(".worktrees/"))
        #expect(try branchExists(repo, "claude/feature-x"))
        #expect(try !branchExists(repo, task.branch))
    }

    /// A damaged row naming its own base, or an option, as its branch never deletes it.
    @Test func theBaseBranchAndOptionLikeNamesAreNeverDeleted() throws {
        let repo = try GitRepoFixture()
        let made = try task(repo)
        // Its worktree already gone, so removal goes straight to the branch.
        try repo.git("worktree", "remove", made.worktreePath)
        try repo.git("checkout", "-q", "-b", "elsewhere")
        for branch in ["main", "-D"] {
            var damaged = made
            damaged.branch = branch
            let result = try TaskRemoval.remove(task: damaged, project: repo.project, deleteBranch: true, force: false, sharedWithAnotherTask: false, launcher: repo.launcher)
            #expect(result.branchRefusal != nil, "\(branch)")
        }
        #expect(try branchExists(repo, "main"))
        #expect(throws: (any Error).self) {
            var damaged = made
            damaged.branch = "main"
            try TaskRemoval.deleteUnmergedBranch(of: damaged, in: repo.project, launcher: repo.launcher)
        }
        #expect(try branchExists(repo, "main"))
    }

    /// `.worktrees` a symlink to somewhere else: nothing there is Shellforge's leftover to delete.
    @Test func aSymlinkedWorktreesFolderIsNeverDeletedThrough() throws {
        let repo = try GitRepoFixture()
        let elsewhere = TestScratch.root.appendingPathComponent("elsewhere-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: elsewhere + "/keep", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: repo.path + "/.worktrees", withDestinationPath: elsewhere)
        let stray = TaskItem(projectId: repo.project.id, title: "Keep", branch: "keep", worktreePath: repo.path + "/.worktrees/keep", baseBranch: "main")

        // Not Shellforge's worktree, through the link: the task is only forgotten, nothing is deleted.
        #expect(!TaskRemoval.ownsWorktree(of: stray, in: repo.project))
        _ = try TaskRemoval.remove(task: stray, project: repo.project, deleteBranch: false, force: true, sharedWithAnotherTask: false, launcher: repo.launcher)
        #expect(FileManager.default.fileExists(atPath: elsewhere + "/keep"))
    }

    /// Only a leftover of Shellforge's own is deleted: a folder outside `.worktrees/` is kept,
    /// whatever is in it; its task is only forgotten.
    @Test func aFolderOutsideTheWorktreesIsNeverDeleted() throws {
        let repo = try GitRepoFixture()
        let folder = repo.path + "/notes"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let stray = TaskItem(projectId: repo.project.id, title: "Notes", branch: "notes", worktreePath: folder, baseBranch: "main")

        _ = try TaskRemoval.remove(task: stray, project: repo.project, deleteBranch: false, force: true, sharedWithAnotherTask: false, launcher: repo.launcher)
        #expect(FileManager.default.fileExists(atPath: folder))
    }

    /// A folder in `.worktrees/` git does not list is deleted only when it shows it was a worktree
    /// whose removal git gave up on: a `.git` file naming a gitdir that is gone. git not listing
    /// it is no such proof.
    @Test func aLeftoverNeedsEvidenceBeforeDeletion() throws {
        let repo = try GitRepoFixture()
        let task = try task(repo)
        let dotGit = try String(contentsOfFile: task.worktreePath + "/.git", encoding: .utf8)
        try repo.git("worktree", "remove", task.worktreePath)
        let file = task.worktreePath + "/notes.txt"
        try FileManager.default.createDirectory(atPath: task.worktreePath, withIntermediateDirectories: true)
        try "only copy".write(toFile: file, atomically: true, encoding: .utf8)

        // No `.git` at all: kept, and the removal says so.
        #expect(throws: GitFailure.self) {
            _ = try TaskRemoval.remove(task: task, project: repo.project, deleteBranch: false, force: true, sharedWithAnotherTask: false, launcher: repo.launcher)
        }
        #expect(FileManager.default.fileExists(atPath: file))

        // A `.git` naming a gitdir that exists: not an abandoned worktree either.
        try "gitdir: \(repo.path)/.git\n".write(toFile: task.worktreePath + "/.git", atomically: true, encoding: .utf8)
        #expect(throws: GitFailure.self) {
            _ = try TaskRemoval.remove(task: task, project: repo.project, deleteBranch: false, force: true, sharedWithAnotherTask: false, launcher: repo.launcher)
        }
        #expect(FileManager.default.fileExists(atPath: file))

        // Its own `.git` file, naming the gitdir git removed: the leftover goes.
        try dotGit.write(toFile: task.worktreePath + "/.git", atomically: true, encoding: .utf8)
        _ = try TaskRemoval.remove(task: task, project: repo.project, deleteBranch: false, force: true, sharedWithAnotherTask: false, launcher: repo.launcher)
        #expect(!FileManager.default.fileExists(atPath: task.worktreePath))
    }

    /// git prints a newline in a path as it is in `worktree list --porcelain`: a project folder
    /// with one in its name must still find its task's worktree, so its unsaved work is asked
    /// about and never deleted as a leftover.
    @Test func aNewlineInTheProjectPathStillFindsTheWorktree() throws {
        let repo = try GitRepoFixture(folder: "client\nportal")
        let task = try task(repo)
        try "draft".write(toFile: task.worktreePath + "/notes.txt", atomically: true, encoding: .utf8)

        #expect(try TaskRemoval.registered(task.worktreePath, in: repo.path, launcher: repo.launcher) != nil)
        #expect(try GitRepository(repo.path, launcher: repo.launcher).worktrees()
            .contains { ExistingWorktrees.resolved($0.path) == ExistingWorktrees.resolved(task.worktreePath) && $0.branch == task.branch })
        #expect(try TaskRemoval.hasUnsavedWork(task: task, project: repo.project, launcher: repo.launcher))
        // Without force, git refuses the dirty worktree, and nothing is deleted.
        #expect(throws: (any Error).self) {
            _ = try TaskRemoval.remove(task: task, project: repo.project, deleteBranch: false, force: false, sharedWithAnotherTask: false, launcher: repo.launcher)
        }
        #expect(try String(contentsOfFile: task.worktreePath + "/notes.txt", encoding: .utf8) == "draft")
    }

    /// Unsaved work is what `git worktree remove` refuses without `--force` — and never asked of a
    /// folder git no longer knows, where `git status` would answer for the project's own checkout.
    @Test func unsavedWorkIsWhatRemoveWouldRefuse() throws {
        let repo = try GitRepoFixture()
        let task = try task(repo)
        #expect(try !TaskRemoval.hasUnsavedWork(task: task, project: repo.project, launcher: repo.launcher))
        try "draft".write(toFile: task.worktreePath + "/notes.txt", atomically: true, encoding: .utf8)
        #expect(try TaskRemoval.hasUnsavedWork(task: task, project: repo.project, launcher: repo.launcher))

        try "dirty".write(toFile: repo.path + "/project.txt", atomically: true, encoding: .utf8)
        try repo.git("worktree", "remove", "--force", task.worktreePath)
        try FileManager.default.createDirectory(atPath: task.worktreePath + "/app", withIntermediateDirectories: true)
        #expect(try !TaskRemoval.hasUnsavedWork(task: task, project: repo.project, launcher: repo.launcher))
    }

    // -- reviews (AiTerm TaskWorkflowTests) ----------------------------------------------------

    /// A merge request's branch checked out as a review, with or without an origin holding it.
    private func review(withOrigin: Bool) throws -> (GitRepoFixture, TaskItem) {
        let repo = try GitRepoFixture()
        try repo.git("branch", "feat/mr-branch")
        if withOrigin {
            let remote = (repo.path as NSString).deletingLastPathComponent + "/remote.git"
            try repo.git("init", "-q", "--bare", remote)
            try repo.git("remote", "add", "origin", remote)
            try repo.git("push", "-q", "origin", "main", "feat/mr-branch")
            try repo.git("branch", "-q", "-D", "feat/mr-branch")
        }
        let path = try GitRepository(repo.path, launcher: repo.launcher).addReviewWorktree(slug: "review-mr-branch", branch: "feat/mr-branch")
        return (repo, TaskItem(projectId: repo.project.id, title: "Add gift card", branch: "feat/mr-branch", worktreePath: path,
                               baseBranch: "main", agent: "claude", model: "sonnet", kind: .review))
    }

    /// A review's branch goes only when that loses nothing, whatever the caller asks: without an
    /// origin there is nothing to judge by, so it stays.
    @Test func removingAReviewWithoutOriginKeepsItsBranch() throws {
        let (repo, review) = try review(withOrigin: false)
        let result = try TaskRemoval.remove(task: review, project: repo.project, deleteBranch: true, force: true, sharedWithAnotherTask: false, launcher: repo.launcher)
        #expect(try branchExists(repo, "feat/mr-branch"))
        #expect(!FileManager.default.fileExists(atPath: review.worktreePath))
        #expect(result.branchRefusal == nil && result.keptBranch == nil)
    }

    /// Pushed, the local copy is deleted; unpushed fixes keep it, and the removal says so.
    @Test func removingAReviewReleasesItsBranchOnlyWhenPushed() throws {
        let (pushed, clean) = try review(withOrigin: true)
        let released = try TaskRemoval.remove(task: clean, project: pushed.project, deleteBranch: false, force: false, sharedWithAnotherTask: false, launcher: pushed.launcher)
        #expect(try !branchExists(pushed, "feat/mr-branch"))
        #expect(released.branchRefusal == nil && released.keptBranch == nil)

        let (unpushed, fixed) = try review(withOrigin: true)
        try unpushed.git(["commit", "-q", "--allow-empty", "-m", "fix"], in: fixed.worktreePath)
        let kept = try TaskRemoval.remove(task: fixed, project: unpushed.project, deleteBranch: true, force: false, sharedWithAnotherTask: false, launcher: unpushed.launcher)
        #expect(try branchExists(unpushed, "feat/mr-branch"))
        #expect(kept.branchRefusal == nil)
        #expect(kept.keptBranch == .unpushed(commits: 1))
    }

    /// A refused removal relocks a review as a review, not as something else.
    @Test func aRefusedRemovalRestoresAReviewsOwnLockReason() throws {
        let (repo, review) = try review(withOrigin: false)
        try "scratch".write(toFile: review.worktreePath + "/untracked.txt", atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) {
            _ = try TaskRemoval.remove(task: review, project: repo.project, deleteBranch: false, force: false, sharedWithAnotherTask: false, launcher: repo.launcher)
        }
        #expect(try GitRepository(repo.path, launcher: repo.launcher).worktrees().first { $0.path.hasSuffix("review-mr-branch") }?.lockReason
                == GitRepository.reviewLockReason)
    }
}
