import Foundation
import Testing
@testable import ShellforgeCore

@Suite struct ProjectFolderSwitchTests {
    private func current(_ repo: GitRepoFixture) throws -> String { try repo.git("symbolic-ref", "--short", "HEAD") }

    /// A branch `name` whose `file.txt` says `text`, with the folder back on main.
    private func branch(_ repo: GitRepoFixture, _ name: String, file text: String) throws {
        try repo.git("switch", "-q", "-c", name)
        try text.write(toFile: repo.path + "/file.txt", atomically: true, encoding: .utf8)
        try repo.git("add", "file.txt")
        try repo.git("commit", "-q", "-m", name)
        try repo.git("switch", "-q", "main")
    }

    // -- check ---------------------------------------------------------------------------

    @Test func aLocalBranchHasNoObstacle() throws {
        let repo = try GitRepoFixture()
        try repo.git("branch", "feat/a")
        #expect(try ProjectFolderSwitch.check("feat/a", in: repo.project, launcher: repo.launcher) == nil)
    }

    @Test func anUnknownBranchIsMissing() throws {
        let repo = try GitRepoFixture()
        #expect(try ProjectFolderSwitch.check("feat/nope", in: repo.project, launcher: repo.launcher) == .missing)
    }

    @Test func aBranchInAnotherWorktreeIsElsewhere() throws {
        let repo = try GitRepoFixture()
        let other = repo.path + "-wt"
        try repo.git("worktree", "add", "-q", "-b", "feat/b", other)
        let obstacle = try ProjectFolderSwitch.check("feat/b", in: repo.project, launcher: repo.launcher)
        guard case .elsewhere(let path) = obstacle else { Issue.record("expected elsewhere, got \(String(describing: obstacle))"); return }
        #expect(ExistingWorktrees.resolved(path) == ExistingWorktrees.resolved(other))
    }

    // -- perform -------------------------------------------------------------------------

    @Test func switchesToAnExistingBranch() throws {
        let repo = try GitRepoFixture()
        try repo.git("branch", "feat/a")
        #expect(try ProjectFolderSwitch.perform("feat/a", in: repo.project, create: false, stash: nil, launcher: repo.launcher) == .switched)
        #expect(try current(repo) == "feat/a")
    }

    @Test func createsAMissingBranchFromTheCurrentOne() throws {
        let repo = try GitRepoFixture()
        let head = try repo.git("rev-parse", "HEAD")
        #expect(try ProjectFolderSwitch.perform("feat/new", in: repo.project, create: true, stash: nil, launcher: repo.launcher) == .switched)
        #expect(try current(repo) == "feat/new")
        #expect(try repo.git("rev-parse", "HEAD") == head)
    }

    @Test func changesThatDoNotClashComeAlong() throws {
        let repo = try GitRepoFixture()
        try repo.git("branch", "feat/a")
        try "mine".write(toFile: repo.path + "/notes.txt", atomically: true, encoding: .utf8)
        #expect(try ProjectFolderSwitch.perform("feat/a", in: repo.project, create: false, stash: nil, launcher: repo.launcher) == .switched)
        #expect(try current(repo) == "feat/a")
        #expect(try String(contentsOfFile: repo.path + "/notes.txt", encoding: .utf8) == "mine")
    }

    @Test func clashingChangesAreReportedAndNothingChanges() throws {
        let repo = try GitRepoFixture()
        try branch(repo, "feat/a", file: "theirs")
        try "mine".write(toFile: repo.path + "/file.txt", atomically: true, encoding: .utf8)
        #expect(try ProjectFolderSwitch.perform("feat/a", in: repo.project, create: false, stash: nil, launcher: repo.launcher) == .blockedByChanges)
        #expect(try current(repo) == "main")
        #expect(try String(contentsOfFile: repo.path + "/file.txt", encoding: .utf8) == "mine")
    }

    @Test func stashingClearsTheWayAndKeepsTheChangesInAStash() throws {
        let repo = try GitRepoFixture()
        try branch(repo, "feat/a", file: "theirs")
        try "mine".write(toFile: repo.path + "/file.txt", atomically: true, encoding: .utf8)
        #expect(try ProjectFolderSwitch.perform("feat/a", in: repo.project, create: false, stash: "Shellforge: before Fix", launcher: repo.launcher) == .switched)
        #expect(try current(repo) == "feat/a")
        #expect(try String(contentsOfFile: repo.path + "/file.txt", encoding: .utf8) == "theirs")
        #expect(try repo.git("stash", "list").contains("Shellforge: before Fix"))
    }

    @Test func stashMessageNamesTheTask() {
        #expect(ProjectFolderSwitch.stashMessage(task: "Fix login") == "Shellforge: before “Fix login”")
    }
}
