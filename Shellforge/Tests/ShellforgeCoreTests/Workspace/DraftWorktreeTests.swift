import Foundation
import Testing
@testable import ShellforgeCore

@Suite struct DraftWorktreeTests {
    @Test func aTakenWorktreeGetsTheNextFreeName() throws {
        let repo = try GitRepoFixture()
        try FileManager.default.createDirectory(atPath: repo.path + "/.worktrees/login", withIntermediateDirectories: true)
        var draft = TaskDraft(baseBranch: "main", agentId: "claude", model: "opus", reasoning: "high")
        draft.setTitle("Login")
        #expect(draft.branch == "feat/login")
        #expect(BranchNaming.unused(draft.worktreeSlug, in: repo.path) == "login-2")
        let task = try TaskWorktrees.create(draft: draft, in: repo.project, launcher: repo.launcher)
        #expect(task.worktreePath == repo.path + "/.worktrees/login-2")
        #expect(task.branch == "feat/login")
        #expect(task.baseBranch == "main")
        #expect(task.agent == "claude" && task.model == "opus" && task.reasoning == "high")
        #expect(try repo.git(["rev-parse", "--abbrev-ref", "HEAD"], in: task.worktreePath) == "feat/login")
    }

    @Test func anInvalidBranchIsRefusedBeforeGitRuns() throws {
        let repo = try GitRepoFixture()
        var draft = TaskDraft(baseBranch: "main", agentId: "claude", model: "opus", reasoning: nil)
        draft.setTitle("x")
        draft.setBranch("bad..name")
        #expect(throws: TaskWorktrees.Refusal.invalidBranch("feat/bad..name")) {
            try TaskWorktrees.create(draft: draft, in: repo.project, launcher: repo.launcher)
        }
        #expect(!FileManager.default.fileExists(atPath: repo.path + "/.worktrees"))
    }

    @Test func anOldWorkspaceFileReadsWithNoRememberedChoices() throws {
        let json = #"{"version":1,"projects":[],"tasks":[]}"#
        let workspace = try JSONDecoder().decode(Workspace.self, from: Data(json.utf8))
        #expect(workspace.lastAgentByProject.isEmpty && workspace.lastModelByAgent.isEmpty)
    }
}

@Suite struct RepositoryTests {
    @Test func theDefaultBranchComesFirstThenTheNewest() throws {
        let repo = try GitRepoFixture()
        _ = try repo.git("branch", "older")
        _ = try repo.git("checkout", "-q", "-b", "newer")
        // A minute later, so the newest-first order never rests on two commits in one second.
        let later = repo.launcher.environment.variables.merging(["GIT_COMMITTER_DATE": "2100-01-01T00:00:00"]) { $1 }
        _ = try ChildProcess.run("/usr/bin/git", ["-C", repo.path, "commit", "-q", "--allow-empty", "-m", "n"],
                                 environment: later, directory: nil, timeout: 10)
        #expect(Repository.defaultBranch(of: repo.path, launcher: repo.launcher) == "main")
        #expect(Repository.branches(of: repo.path, launcher: repo.launcher) == ["main", "newer", "older"])
    }

    @Test func aRepositoryWithNoUsualBranchFallsBackToMain() throws {
        let repo = try GitRepoFixture(branch: "trunk")
        #expect(Repository.defaultBranch(of: repo.path, launcher: repo.launcher) == "main")
    }
}
