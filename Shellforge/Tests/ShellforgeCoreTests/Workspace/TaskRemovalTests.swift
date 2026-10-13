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

    @Test func anUnmergedBranchIsKeptAndDeletedOnlyOnRequest() throws {
        let repo = try GitRepoFixture()
        let task = try task(repo)
        try repo.git(["commit", "-q", "--allow-empty", "-m", "work"], in: task.worktreePath)
        let result = try TaskRemoval.remove(task: task, project: repo.project, deleteBranch: true, force: true, launcher: repo.launcher)
        // The one refusal Shellforge can put in its own words: commits the base lacks.
        #expect(result.branchRefusal == .notMerged(base: "main"))
        #expect(!FileManager.default.fileExists(atPath: task.worktreePath))
        #expect(try branchExists(repo, task.branch))

        try TaskRemoval.deleteUnmergedBranch(of: task, in: repo.project, launcher: repo.launcher)
        #expect(try !branchExists(repo, task.branch))
        // Removing again is a finished retry, not an error.
        #expect(try TaskRemoval.remove(task: task, project: repo.project, deleteBranch: true, force: false,
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
            _ = try TaskRemoval.remove(task: task, project: repo.project, deleteBranch: false, force: false, launcher: repo.launcher)
        }
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "work in progress")
        #expect(try repo.git("worktree", "list", "--porcelain").contains("locked mine"))
    }

    /// git drops its record of a worktree even when it cannot delete all of it. What it leaves is
    /// a folder no git knows, and removing that again used to fail "is not a working tree" for good.
    @Test func aRemovalGitGaveUpOnHalfwayIsFinishedByTheNext() throws {
        let repo = try GitRepoFixture()
        let task = try task(repo)
        try repo.git("worktree", "remove", task.worktreePath)
        try FileManager.default.createDirectory(atPath: task.worktreePath + "/app/node_modules/.cache", withIntermediateDirectories: true)

        let result = try TaskRemoval.remove(task: task, project: repo.project, deleteBranch: true, force: false, launcher: repo.launcher)

        #expect(result.branchRefusal == nil)
        #expect(!FileManager.default.fileExists(atPath: task.worktreePath))
        #expect(try !branchExists(repo, task.branch))
    }

    /// The folder deleted by hand, git's record of it left: the record is pruned and the task goes.
    @Test func aMissingWorktreeIsPrunedAndTheTaskStillGoes() throws {
        let repo = try GitRepoFixture()
        let task = try task(repo)
        try FileManager.default.removeItem(atPath: task.worktreePath)

        let result = try TaskRemoval.remove(task: task, project: repo.project, deleteBranch: false, force: false, launcher: repo.launcher)

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

        let result = try TaskRemoval.remove(task: task, project: repo.project, deleteBranch: true, force: false, launcher: repo.launcher)

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

        let result = try TaskRemoval.remove(task: task, project: repo.project, deleteBranch: true, force: true, launcher: repo.launcher)

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
            _ = try TaskRemoval.remove(task: task, project: repo.project, deleteBranch: false, force: false, launcher: flaky)
        }
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "work in progress")
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
            _ = try TaskRemoval.remove(task: old, project: repo.project, deleteBranch: false, force: true, launcher: repo.launcher)
        }
        #expect(FileManager.default.fileExists(atPath: file))
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
            let result = try TaskRemoval.remove(task: damaged, project: repo.project, deleteBranch: true, force: false, launcher: repo.launcher)
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

        #expect(throws: (any Error).self) {
            _ = try TaskRemoval.remove(task: stray, project: repo.project, deleteBranch: false, force: true, launcher: repo.launcher)
        }
        #expect(FileManager.default.fileExists(atPath: elsewhere + "/keep"))
    }

    /// Only a leftover of Shellforge's own is deleted: a folder outside `.worktrees/` that git does
    /// not know as a worktree is refused and kept, whatever is in it.
    @Test func aFolderOutsideTheWorktreesIsNeverDeleted() throws {
        let repo = try GitRepoFixture()
        let folder = repo.path + "/notes"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let stray = TaskItem(projectId: repo.project.id, title: "Notes", branch: "notes", worktreePath: folder, baseBranch: "main")

        #expect(throws: (any Error).self) {
            _ = try TaskRemoval.remove(task: stray, project: repo.project, deleteBranch: false, force: true, launcher: repo.launcher)
        }
        #expect(FileManager.default.fileExists(atPath: folder))
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
        let result = try TaskRemoval.remove(task: review, project: repo.project, deleteBranch: true, force: true, launcher: repo.launcher)
        #expect(try branchExists(repo, "feat/mr-branch"))
        #expect(!FileManager.default.fileExists(atPath: review.worktreePath))
        #expect(result.branchRefusal == nil && result.keptBranch == nil)
    }

    /// Pushed, the local copy is deleted; unpushed fixes keep it, and the removal says so.
    @Test func removingAReviewReleasesItsBranchOnlyWhenPushed() throws {
        let (pushed, clean) = try review(withOrigin: true)
        let released = try TaskRemoval.remove(task: clean, project: pushed.project, deleteBranch: false, force: false, launcher: pushed.launcher)
        #expect(try !branchExists(pushed, "feat/mr-branch"))
        #expect(released.branchRefusal == nil && released.keptBranch == nil)

        let (unpushed, fixed) = try review(withOrigin: true)
        try unpushed.git(["commit", "-q", "--allow-empty", "-m", "fix"], in: fixed.worktreePath)
        let kept = try TaskRemoval.remove(task: fixed, project: unpushed.project, deleteBranch: true, force: false, launcher: unpushed.launcher)
        #expect(try branchExists(unpushed, "feat/mr-branch"))
        #expect(kept.branchRefusal == nil)
        #expect(kept.keptBranch == .unpushed(commits: 1))
    }

    /// A refused removal relocks a review as a review, not as something else.
    @Test func aRefusedRemovalRestoresAReviewsOwnLockReason() throws {
        let (repo, review) = try review(withOrigin: false)
        try "scratch".write(toFile: review.worktreePath + "/untracked.txt", atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) {
            _ = try TaskRemoval.remove(task: review, project: repo.project, deleteBranch: false, force: false, launcher: repo.launcher)
        }
        #expect(try GitRepository(repo.path, launcher: repo.launcher).worktrees().first { $0.path.hasSuffix("review-mr-branch") }?.lockReason
                == GitRepository.reviewLockReason)
    }
}
