// Ported in part from AiTerm (app/Sources/AiTerm/ProjectActions.swift: importWorktrees, and
// app/Sources/AiTermCore/Git/Worktree.swift: importedKind), GPLv3, Laurens D'Hondt.
import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeTestSupport

/// A worktree that already exists, continued as a task: offered when it is on a branch, on disk
/// and nobody's task yet; adopted without git changing anything.
@Suite struct ExistingWorktreesTests {
    /// A repository with two worktrees on branches, made a second apart so their last commits differ.
    private func repo() throws -> (GitRepoFixture, older: String, newer: String) {
        let repo = try GitRepoFixture()
        let older = repo.path + "/.worktrees/older", newer = repo.path + "/.worktrees/newer"
        try repo.git("worktree", "add", "-q", "-b", "feat/older", older)
        try repo.git(["commit", "-q", "--allow-empty", "-m", "old", "--date", "2026-01-01T00:00:00"], in: older)
        try repo.git("worktree", "add", "-q", "-b", "feat/newer", newer)
        try repo.git(["commit", "-q", "--allow-empty", "-m", "new"], in: newer)
        return (repo, older, newer)
    }

    private func list(_ repo: GitRepoFixture, taken: [String] = []) throws -> [ExistingWorktree] {
        try ExistingWorktrees.list(project: repo.project, taken: taken, launcher: repo.launcher)
    }

    @Test func offersOnlyBranchesOnDiskThatAreNotTasks() throws {
        let (repo, older, newer) = try repo()
        try repo.git("worktree", "add", "-q", "--detach", repo.path + "/.worktrees/detached")
        let gone = repo.path + "/.worktrees/gone"
        try repo.git("worktree", "add", "-q", "-b", "feat/gone", gone)
        try FileManager.default.removeItem(atPath: gone)
        let offered = try list(repo, taken: [older])
        #expect(offered.map(\.branch) == ["feat/newer"], "not the checkout, a task's, a detached one or one gone from disk")
        #expect(offered.first?.path.hasSuffix("/.worktrees/newer") == true)
        _ = newer
    }

    @Test func newestFirst() throws {
        let (repo, _, _) = try repo()
        let offered = try list(repo)
        #expect(offered.map(\.branch) == ["feat/newer", "feat/older"])
        #expect(offered.allSatisfy { $0.lastCommit != nil })
    }

    @Test func aReviewsWorktreeImportsAsAReview() throws {
        let (repo, _, _) = try repo()
        try repo.git("worktree", "add", "-q", "--lock", "--reason", GitRepository.reviewLockReason, "-b", "mr/x", repo.path + "/.worktrees/locked-review")
        try repo.git("worktree", "add", "-q", "--lock", "--reason", "aiterm review", "-b", "mr/z", repo.path + "/.worktrees/aiterms")
        try repo.git("worktree", "add", "-q", "-b", "mr/y", repo.path + "/.worktrees/review-y")
        let kinds = Dictionary(uniqueKeysWithValues: try list(repo).map { ($0.branch, $0.kind) })
        #expect(kinds["mr/x"] == .review && kinds["mr/z"] == .review && kinds["mr/y"] == .review && kinds["feat/newer"] == .task)
    }

    @Test func adoptingChangesNothingInGit() throws {
        let (repo, _, newer) = try repo()
        let before = try repo.git("worktree", "list", "--porcelain"), branches = try repo.git("branch", "--list")
        var draft = TaskDraft(baseBranch: "main", agentId: "claude", model: "opus", reasoning: nil)
        draft.useExisting = true
        draft.pick(existing: try #require(try list(repo).first { $0.branch == "feat/newer" }))
        let task = try ExistingWorktrees.adopt(draft: draft, in: repo.project, launcher: repo.launcher)
        #expect(task.branch == "feat/newer" && task.title == "feat/newer" && task.baseBranch == "main")
        #expect(URL(fileURLWithPath: task.worktreePath).resolvingSymlinksInPath().path == URL(fileURLWithPath: newer).resolvingSymlinksInPath().path)
        #expect(task.agent == "claude" && task.model == "opus" && task.kind == .task)
        #expect(try repo.git("worktree", "list", "--porcelain") == before)
        #expect(try repo.git("branch", "--list") == branches)
    }

    @Test func aWorktreeGoneOrTakenIsRefused() throws {
        let (repo, older, newer) = try repo()
        let offered = try list(repo)
        var draft = TaskDraft(baseBranch: "main", agentId: "claude", model: "opus", reasoning: nil)
        draft.useExisting = true
        draft.pick(existing: try #require(offered.first { $0.branch == "feat/newer" }))
        try FileManager.default.removeItem(atPath: newer)
        #expect(throws: ExistingWorktrees.Refusal.gone("feat/newer")) {
            try ExistingWorktrees.adopt(draft: draft, in: repo.project, launcher: repo.launcher)
        }
        draft.pick(existing: try #require(offered.first { $0.branch == "feat/older" }))
        #expect(throws: ExistingWorktrees.Refusal.taken("feat/older")) {
            try ExistingWorktrees.adopt(draft: draft, in: repo.project, taken: [older], launcher: repo.launcher)
        }
        #expect(ExistingWorktrees.Refusal.gone("x").errorDescription == "The worktree for x is no longer there.")
        #expect(ExistingWorktrees.Refusal.taken("x").errorDescription == "x is already a task’s worktree.")
        #expect(ExistingWorktrees.Refusal.noneChosen.errorDescription == "Choose a worktree to continue in.")
    }

    /// A task saved under one spelling of a folder and listed by git under another — /tmp and
    /// /private/tmp — is still the same worktree.
    @Test func pathsAreComparedResolved() throws {
        let (repo, older, _) = try repo()
        let resolved = URL(fileURLWithPath: older).resolvingSymlinksInPath().path
        let other = resolved.hasPrefix("/private/") ? String(resolved.dropFirst("/private".count)) : "/private" + resolved
        let spelled = FileManager.default.fileExists(atPath: other) ? other : older
        #expect(try list(repo, taken: [spelled]).map(\.branch) == ["feat/newer"])
    }

    @Test func aPickedWorktreeNamesTheTask() throws {
        let wt = ExistingWorktree(path: "/r/.worktrees/x", branch: "fix/login-bug", kind: .task, lastCommit: nil)
        var draft = TaskDraft(baseBranch: "main", agentId: "claude", model: "opus", reasoning: nil)
        draft.pick(existing: wt)
        #expect(draft.title == "fix/login-bug" && draft.existing == wt)
        draft.setTitle("Fix the login")
        draft.pick(existing: ExistingWorktree(path: "/r/.worktrees/y", branch: "feat/y", kind: .task, lastCommit: nil))
        #expect(draft.title == "Fix the login", "a typed name stays")
    }

    @Test func importedTasksStartNoAgent() throws {
        let (repo, _, _) = try repo()
        let project = repo.project  // the fixture makes a new project, with a new id, on each read
        let tasks = ExistingWorktrees.imported(try list(repo), project: project, baseBranch: "main", agent: "claude", model: nil, reasoning: nil)
        #expect(tasks.map(\.title) == ["feat/newer", "feat/older"])
        #expect(tasks.allSatisfy { $0.projectId == project.id && $0.baseBranch == "main" && $0.agent == "claude" })
    }
}
