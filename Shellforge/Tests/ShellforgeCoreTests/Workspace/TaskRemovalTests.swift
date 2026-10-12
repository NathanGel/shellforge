// Ported from AiTerm (app/Tests/AiTermCoreTests/TaskWorkflowTests.swift and WorktreesTests.swift), GPLv3, Laurens D'Hondt.
import Foundation
import Testing
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
}
