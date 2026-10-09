import Foundation
import Testing
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
}
