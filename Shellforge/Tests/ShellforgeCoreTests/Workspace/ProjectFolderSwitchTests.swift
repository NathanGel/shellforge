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

    /// `feature/login-page` only on the remote `remote`: pushed there, then deleted here.
    private func remoteOnlyBranch(_ repo: GitRepoFixture, remote: String) throws {
        let bare = repo.path + "-\(remote).git"
        try repo.git(["init", "-q", "--bare", "-b", "main", bare], in: repo.path)
        try repo.git("remote", "add", remote, bare)
        try branch(repo, "feature/login-page", file: "login")
        try repo.git("push", "-q", remote, "feature/login-page")
        try repo.git("branch", "-q", "-D", "feature/login-page")
    }

    /// Switch Branch… lists a remote-only branch as `<remote>/<name>`; switching to it ends on the
    /// local `<name>`, tracking the remote's, whatever the remote is called.
    @Test(arguments: ["origin", "upstream"])
    func aRemoteBranchSwitchesToALocalOneTrackingIt(remote: String) throws {
        let repo = try GitRepoFixture()
        try remoteOnlyBranch(repo, remote: remote)
        let listed = try #require(try GitActions.branches(in: repo.path, launcher: repo.launcher).first { $0.remote != nil })
        #expect(listed == GitBranch(title: "\(remote)/feature/login-page", name: "feature/login-page", remote: remote))
        #expect(try ProjectFolderSwitch.check(listed.name, in: repo.project, launcher: repo.launcher) == nil, "not missing")
        #expect(try ProjectFolderSwitch.perform(listed.name, in: repo.project, create: false, stash: nil, launcher: repo.launcher) == .switched)
        #expect(try current(repo) == "feature/login-page")
        #expect(try repo.git("rev-parse", "--abbrev-ref", "feature/login-page@{upstream}") == "\(remote)/feature/login-page")
        #expect(try GitActions.branches(in: repo.path, launcher: repo.launcher).map(\.title) == ["feature/login-page", "main"],
                "a remote branch with a local one is listed once")
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

    @Test func stashMessageSaysWhatCameNext() {
        #expect(ProjectFolderSwitch.stashMessage(before: "“Fix login”") == "Shellforge: before “Fix login”")
        #expect(ProjectFolderSwitch.stashMessage(before: "switching to “main”") == "Shellforge: before switching to “main”")
    }
}
