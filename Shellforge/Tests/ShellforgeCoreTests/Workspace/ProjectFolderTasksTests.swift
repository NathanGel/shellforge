import Foundation
import Testing
@testable import ShellforgeCore

@Suite struct ProjectFolderTasksTests {
    private func draft(title: String = "Home", model: String = "m") -> TaskDraft {
        var d = TaskDraft(baseBranch: "main", agentId: "claude", model: model, reasoning: nil)
        d.setTitle(title)
        return d
    }

    @Test func makeUsesTheCheckedOutBranch() throws {
        let repo = try GitRepoFixture()
        let before = try repo.git("worktree", "list")
        let task = try ProjectFolderTasks.make(draft: draft(), in: repo.project, launcher: repo.launcher)
        #expect(task.branch == "main" && task.worktreePath == repo.project.path && task.kind == .task)
        #expect(try repo.git("worktree", "list") == before)
    }

    @Test func makeOnDetachedHeadUsesShortSha() throws {
        let repo = try GitRepoFixture()
        try repo.git("checkout", "-q", "--detach")
        let task = try ProjectFolderTasks.make(draft: draft(), in: repo.project, launcher: repo.launcher)
        #expect(task.branch == (try repo.git("rev-parse", "--short", "HEAD")))
    }

    @Test func makeRefusesEmptyTitleAndModel() throws {
        let repo = try GitRepoFixture()
        #expect(throws: TaskWorktrees.Refusal.emptyTitle) {
            try ProjectFolderTasks.make(draft: draft(title: "  "), in: repo.project, launcher: repo.launcher)
        }
        #expect(throws: TaskWorktrees.Refusal.emptyModel) {
            try ProjectFolderTasks.make(draft: draft(model: ""), in: repo.project, launcher: repo.launcher)
        }
    }

    @Test func isProjectFolderMatchesThroughSymlinks() throws {
        let repo = try GitRepoFixture()
        let project = repo.project
        let task = try ProjectFolderTasks.make(draft: draft(), in: project, launcher: repo.launcher)
        var other = task
        other.worktreePath = ExistingWorktrees.resolved(project.path)
        #expect(ProjectFolderTasks.isProjectFolder(other, in: project))
        other.worktreePath = project.path.hasPrefix("/private") ? String(project.path.dropFirst("/private".count)) : "/private" + project.path
        try #require(FileManager.default.fileExists(atPath: other.worktreePath), "this test needs a symlinked scratch folder")
        #expect(ProjectFolderTasks.isProjectFolder(other, in: project))
        other.worktreePath = project.path + "/.worktrees/x"
        #expect(!ProjectFolderTasks.isProjectFolder(other, in: project))
    }

    @Test func undoRefusesAPathOutsideWorktrees() throws {
        let repo = try GitRepoFixture()
        try "keep".write(toFile: repo.path + "/file.txt", atomically: true, encoding: .utf8)
        TaskWorktrees.undo(worktree: repo.path, branch: nil, project: repo.project, launcher: repo.launcher)
        #expect(FileManager.default.fileExists(atPath: repo.path + "/file.txt"))
        #expect(FileManager.default.fileExists(atPath: repo.path + "/.git"))
    }

    @Test func undoKeepsTheBranchWhenItRefusedTheFolder() throws {
        let repo = try GitRepoFixture()
        try repo.git("branch", "feat/keep")
        TaskWorktrees.undo(worktree: repo.project.path, branch: "feat/keep", project: repo.project, launcher: repo.launcher)
        #expect(try repo.git("show-ref", "--verify", "refs/heads/feat/keep").contains("refs/heads/feat/keep"))
        #expect(FileManager.default.fileExists(atPath: repo.path + "/.git"))
    }

    @Test func undoWithNoPathStillDeletesTheBranch() throws {
        let repo = try GitRepoFixture()
        try repo.git("branch", "feat/gone")
        TaskWorktrees.undo(worktree: nil, branch: "feat/gone", project: repo.project, launcher: repo.launcher)
        #expect(try repo.git("branch", "--list", "feat/gone").isEmpty)
    }

    @Test func chooseProjectFolderThenNewKeepsTypedTitle() {
        var d = draft(title: "Typed")
        d.choose(.projectFolder)
        #expect(d.worktree == .projectFolder && d.title == "Typed")
        d.choose(.new)
        #expect(d.worktree == .new && d.title == "Typed")
    }

    @Test func choosingExistingThenProjectFolderClearsThePickedTitle() {
        var d = draft(title: "")
        d.choose(.existing)
        d.pick(existing: ExistingWorktree(path: "/r/.worktrees/x", branch: "feat/x", kind: .task, lastCommit: nil))
        #expect(d.title == "feat/x")
        d.choose(.projectFolder)
        #expect(d.title == "")
    }

    @Test func worktreesFolderCheckStandardisesThePath() {
        let project = Project(name: "p", path: "/tmp/p")
        #expect(TaskWorktrees.isInWorktreesFolder("/tmp/p/.worktrees/x", project: project))
        #expect(!TaskWorktrees.isInWorktreesFolder("/tmp/p/.worktrees/.", project: project))
        #expect(!TaskWorktrees.isInWorktreesFolder("/tmp/p/.worktrees/x/..", project: project))
    }

    @Test func undoRefusesThroughASymlinkedWorktreesFolder() throws {
        let repo = try GitRepoFixture()
        let elsewhere = repo.path + "-elsewhere"
        try FileManager.default.createDirectory(atPath: elsewhere + "/x", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: repo.path + "/.worktrees", withDestinationPath: elsewhere)
        defer { try? FileManager.default.removeItem(atPath: elsewhere) }
        TaskWorktrees.undo(worktree: repo.path + "/.worktrees/x", branch: nil, project: repo.project, launcher: repo.launcher)
        #expect(FileManager.default.fileExists(atPath: elsewhere + "/x"))
    }
}
