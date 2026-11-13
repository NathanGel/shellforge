import Foundation
import Testing
@testable import ShellforgeTestSupport
@testable import ShellforgeCore

@Suite struct TaskWorktreesTests {
    @Test(arguments: [("Fix login", "fix-login"), ("  Café: tests & docs!! ", "cafe-tests-docs"), ("PROJ-12 Add API", "proj-12-add-api")])
    func aTitleBecomesASlug(title: String, slug: String) {
        #expect(TaskWorktrees.slug(for: title) == slug)
    }

    @Test func anEmptyTitleStillGivesASlug() {
        #expect(TaskWorktrees.slug(for: "!!!") == "task")
    }

    @Test func aTaskGetsItsOwnWorktreeAndBranchFromTheBase() throws {
        let repo = try GitRepoFixture()
        let project = Project(name: "repo", path: repo.path)
        let task = try TaskWorktrees.create(title: "Fix login", in: project, base: "main", launcher: repo.launcher)
        #expect(task.branch == "fix-login" && task.baseBranch == "main" && task.projectId == project.id)
        #expect(task.worktreePath == "\(repo.path)/.worktrees/fix-login")
        #expect(try repo.git("-C", task.worktreePath, "rev-parse", "--abbrev-ref", "HEAD") == "fix-login")
    }

    @Test func theWorktreesFolderIsExcludedNotGitignored() throws {
        let repo = try GitRepoFixture()
        _ = try TaskWorktrees.create(title: "One", in: Project(name: "repo", path: repo.path), base: "main", launcher: repo.launcher)
        let exclude = try String(contentsOfFile: "\(repo.path)/.git/info/exclude", encoding: .utf8)
        #expect(exclude.components(separatedBy: "\n").contains(".worktrees/"))
        #expect(!FileManager.default.fileExists(atPath: "\(repo.path)/.gitignore"))
        #expect(try repo.git("status", "--porcelain") == "")
    }

    @Test func aSecondTaskWithTheSameTitleGetsANumberedSlug() throws {
        let repo = try GitRepoFixture()
        let project = Project(name: "repo", path: repo.path)
        _ = try TaskWorktrees.create(title: "Fix login", in: project, base: "main", launcher: repo.launcher)
        let second = try TaskWorktrees.create(title: "Fix login", in: project, base: "main", launcher: repo.launcher)
        #expect(second.branch == "fix-login-2")
        #expect(second.worktreePath.hasSuffix("/.worktrees/fix-login-2"))
    }

    @Test func withoutABaseTheCurrentBranchIsUsed() throws {
        let repo = try GitRepoFixture(branch: "trunk")
        let task = try TaskWorktrees.create(title: "X", in: Project(name: "repo", path: repo.path), base: nil, launcher: repo.launcher)
        #expect(task.baseBranch == "trunk")
    }

    @Test func gitsOwnReasonIsReportedWhenItFails() throws {
        let repo = try GitRepoFixture()
        let error = try #require(throws: GitFailure.self) {
            try TaskWorktrees.create(title: "X", in: Project(name: "repo", path: repo.path), base: "no-such-branch", launcher: repo.launcher)
        }
        #expect(error.message.contains("no-such-branch"))
    }

    private func draft(_ title: String) -> TaskDraft {
        var draft = TaskDraft(baseBranch: "main", agentId: "claude", model: "opus", reasoning: nil)
        draft.setTitle(title)
        return draft
    }

    private func hasBranch(_ repo: GitRepoFixture, _ branch: String) -> Bool {
        (try? repo.git("rev-parse", "--verify", "--quiet", "refs/heads/\(branch)")) != nil
    }

    /// A repository that committed `.worktrees` as a link to a folder elsewhere: New Task checks
    /// nothing out through it, by either create, and makes no branch.
    @Test func aSymlinkedWorktreesFolderIsRefused() throws {
        let repo = try GitRepoFixture()
        let elsewhere = TestScratch.root.appendingPathComponent("link-target-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: repo.path + "/.worktrees", withDestinationPath: elsewhere)
        let draft = draft("Fix login")

        #expect(throws: TaskWorktrees.Refusal.symlink(repo.path + "/.worktrees")) {
            try TaskWorktrees.create(draft: draft, in: repo.project, launcher: repo.launcher)
        }
        #expect(throws: TaskWorktrees.Refusal.self) {
            try TaskWorktrees.create(title: "Fix login", in: repo.project, base: "main", launcher: repo.launcher)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere).isEmpty, "nothing checked out there")
        #expect(!hasBranch(repo, draft.branch))
        #expect(!hasBranch(repo, "fix-login"))
    }

    /// The task's own folder a link, in a real `.worktrees`: refused too.
    @Test func aSymlinkedWorktreeFolderIsRefused() throws {
        let repo = try GitRepoFixture()
        let elsewhere = TestScratch.root.appendingPathComponent("link-target-\(UUID().uuidString)").path
        let draft = draft("Fix login")
        try FileManager.default.createDirectory(atPath: repo.path + "/.worktrees", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: repo.path + "/.worktrees/\(draft.worktreeSlug)", withDestinationPath: elsewhere)
        #expect(throws: TaskWorktrees.Refusal.self) {
            try TaskWorktrees.refuseSymlinks(slug: draft.worktreeSlug, project: repo.project)
        }
        #expect(!FileManager.default.fileExists(atPath: elsewhere))
    }

    /// `git worktree add -b` makes the branch and the folder, then exits with the checkout hook's
    /// status. A failing hook leaves neither behind, so the same name works once the hook is fixed.
    @Test func aFailingCheckoutHookLeavesNoBranchOrFolder() throws {
        let repo = try GitRepoFixture()
        let hook = "\(repo.path)/.git/hooks/post-checkout"
        try "#!/bin/sh\necho 'install failed' >&2\nexit 1\n".write(toFile: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)
        let draft = draft("Fix login")
        let path = "\(repo.path)/.worktrees/\(draft.worktreeSlug)"

        #expect(throws: GitFailure.self) { try TaskWorktrees.create(draft: draft, in: repo.project, launcher: repo.launcher) }
        #expect(!FileManager.default.fileExists(atPath: path), "no folder left")
        #expect(!hasBranch(repo, draft.branch), "no branch left")
        #expect(!(try repo.git("worktree", "list", "--porcelain")).contains(".worktrees/"), "no worktree record left")

        try FileManager.default.removeItem(atPath: hook)
        let task = try TaskWorktrees.create(draft: draft, in: repo.project, launcher: repo.launcher)
        #expect(task.branch == draft.branch && task.worktreePath == path)
    }

    /// A failed create never takes a branch that was there before it.
    @Test func aFailingCheckoutHookKeepsABranchThatWasThereBefore() throws {
        let repo = try GitRepoFixture()
        let draft = draft("Fix login")
        try repo.git("branch", draft.branch)
        let before = try repo.git("rev-parse", draft.branch)
        #expect(throws: GitFailure.self) { try TaskWorktrees.create(draft: draft, in: repo.project, launcher: repo.launcher) }
        #expect(try repo.git("rev-parse", draft.branch) == before)
    }

    /// A worktree whose folder is gone but whose record git keeps is not this create's: a failed
    /// add at that path leaves the earlier record as it was.
    @Test func aFailedCreateKeepsAStaleRecordAtItsPath() throws {
        let repo = try GitRepoFixture()
        let draft = draft("Fix login")
        let path = "\(repo.path)/.worktrees/\(draft.worktreeSlug)"
        try repo.git("worktree", "add", "-q", "-b", "earlier", path)
        try FileManager.default.removeItem(atPath: path)

        #expect(throws: GitFailure.self) { try TaskWorktrees.create(draft: draft, in: repo.project, launcher: repo.launcher) }
        #expect(try repo.git("worktree", "list", "--porcelain").contains("branch refs/heads/earlier"), "the earlier record survives")
    }
}
