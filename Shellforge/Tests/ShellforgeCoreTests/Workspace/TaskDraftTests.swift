// Ported from AiTerm (app/Tests/AiTermCoreTests/TaskCreatorTests.swift and WorktreesTests.swift), GPLv3, Laurens D'Hondt.
import Foundation
import Testing
@testable import ShellforgeCore

/// AiTerm's draft and create cases that need no Jira ticket (those return with M1d).
@Suite struct TaskDraftTests {
    private func draft() -> TaskDraft { TaskDraft(baseBranch: "main", agentId: "claude", model: "opus", reasoning: nil) }

    @Test func testSlugAndBranchName() {
        #expect(BranchNaming.slug("Add graceful SIGTERM shutdown to the worker (drain in-flight tasks, fail-fast the rest)") == "add-graceful-sigterm-shutdown-to-the-worker-drai")
        #expect(BranchNaming.branchSlug(key: "WEB-5447", summary: "Add graceful SIGTERM") == "web-5447-add-graceful-sigterm")
        #expect(BranchNaming.branchSlug(key: nil, summary: "Sidebar avatars") == "sidebar-avatars")
    }

    @Test func gitJudgesABranchName() throws {
        let repo = try GitRepoFixture()
        #expect(BranchNaming.isValid("feat/x-1", launcher: repo.launcher))
        #expect(!BranchNaming.isValid("feat//bad..name", launcher: repo.launcher))
    }

    @Test func testAWriteOfTheSameValueIsNotAnEdit() {
        var d = draft()
        d.setTitle("First name")
        #expect(d.branch == "feat/first-name")
        d.setBranch(d.branch)
        d.setTitle(d.title)
        d.setTitle("Second Name Here")
        #expect(d.title == "Second Name Here")
        #expect(d.branch == "feat/second-name-here", "the branch still follows the task name")
    }

    @Test func testAnEditedNameStillTakesANewType() {
        var d = draft()
        d.setBranch("my-own-name")
        #expect(d.branchName == "my-own-name"); #expect(d.branch == "feat/my-own-name")
        d.setBranchType(.chore)
        #expect(d.branch == "chore/my-own-name")
        d.setTitle("Something else")
        #expect(d.branch == "chore/my-own-name", "the edited name is kept")
    }

    @Test func testATypedPrefixMovesIntoTheType() {
        var d = draft()
        d.setBranch("fix/shop-12-broken-link")
        #expect(d.branchType == .fix); #expect(d.branchName == "shop-12-broken-link")
        d.setBranch("release/x")
        #expect(d.branch == "fix/release/x")
    }

    @Test func testATypedTaskNameLowercasesAndDashesIntoTheBranch() {
        var d = draft()
        d.setTitle("Fix the JIRA select  (again!)")
        #expect(d.branch == "feat/fix-the-jira-select-again")
    }

    @Test func testAnEmptyBranchNamePreviewsNoWorktreeDirectory() {
        var d = draft()
        #expect(d.worktreeSlug == "")
        d.setTitle("Broken link")
        #expect(d.worktreeSlug == "broken-link")
        d.setBranch("")
        #expect(d.worktreeSlug == "")
    }

    @Test func testSetModelKeepsASupportedEffortAndReplacesAnUnsupportedOne() {
        var d = draft()
        let catalog = [AgentModel(id: "a", label: "A", detail: nil, efforts: ["low", "high"], defaultEffort: "high"),
                       AgentModel(id: "b", label: "B", detail: nil, efforts: ["max"], defaultEffort: "max")]
        d.reasoning = "low"
        d.setModel("a", catalog: catalog, efforts: ["low"], defaultEffort: "low")
        #expect(d.reasoning == "low", "a level the model supports is kept")
        d.setModel("b", catalog: catalog, efforts: ["low"], defaultEffort: "low")
        #expect(d.reasoning == "max", "a level it does not support becomes the model's default")
        d.setModel("not-listed", catalog: catalog, efforts: ["low", "high"], defaultEffort: "high")
        #expect(d.reasoning == "high", "a model with no levels of its own takes the agent's")
    }

    @Test func testCreateBuildsWorktreeAndTaskItem() throws {
        let repo = try GitRepoFixture()
        var d = draft()
        d.setTitle("Thing")
        d.promptText = "/plan"
        let task = try TaskWorktrees.create(draft: d, in: repo.project, launcher: repo.launcher)
        #expect(task.worktreePath == repo.path + "/.worktrees/thing")
        #expect(task.branch == "feat/thing"); #expect(task.title == "Thing")
        #expect(FileManager.default.fileExists(atPath: task.worktreePath + "/.git"))
    }

    @Test func testBranchWithoutAsciiStillGetsItsOwnWorktreeDirectory() throws {
        let repo = try GitRepoFixture()
        var d = draft()
        d.setTitle("x"); d.setBranch("feat/日本語")
        let task = try TaskWorktrees.create(draft: d, in: repo.project, launcher: repo.launcher)
        let worktreesDir = repo.path + "/.worktrees/"
        #expect(task.worktreePath.hasPrefix(worktreesDir))
        #expect(task.worktreePath.count > worktreesDir.count, "the slug must never be empty: \(task.worktreePath)")
        #expect(FileManager.default.fileExists(atPath: task.worktreePath + "/.git"))
    }

    @Test func testBranchesThatDifferOnlyInTypeGetTheirOwnWorktrees() throws {
        let repo = try GitRepoFixture()
        var paths: [String] = []
        for type in ["feat", "fix", "chore"] {
            var d = draft()
            d.setTitle("Login"); d.setBranch("\(type)/login")
            paths.append(try TaskWorktrees.create(draft: d, in: repo.project, launcher: repo.launcher).worktreePath)
        }
        #expect(paths == ["login", "login-2", "login-3"].map { repo.path + "/.worktrees/" + $0 })
    }

    @Test func anUnusedSlugSkipsEveryDirectoryAlreadyThere() throws {
        let repo = try GitRepoFixture()
        #expect(BranchNaming.unused("login", in: repo.path) == "login")
        for taken in ["login", "login-2"] {
            try FileManager.default.createDirectory(atPath: repo.path + "/.worktrees/" + taken, withIntermediateDirectories: true)
        }
        #expect(BranchNaming.unused("login", in: repo.path) == "login-3")
    }

    @Test func testAnEmptyModelIsRejectedBeforeTouchingGit() throws {
        let repo = try GitRepoFixture()
        var d = TaskDraft(baseBranch: "main", agentId: "claude", model: "", reasoning: nil)
        d.setTitle("No model")
        #expect(throws: TaskWorktrees.Refusal.emptyModel) { try TaskWorktrees.create(draft: d, in: repo.project, launcher: repo.launcher) }
        #expect(!FileManager.default.fileExists(atPath: repo.path + "/.worktrees/no-model"))
    }
}
