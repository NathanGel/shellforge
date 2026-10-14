// Ported from AiTerm (app/Tests/AiTermCoreTests: pullDefaultBranch), GPLv3, Laurens D'Hondt.
import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeTestSupport

/// "Pull main": the local default branch brought to origin's, fast-forward only — merged in the
/// checkout that holds it, else the ref alone moved — and left as it is when ahead or diverged.
@Suite struct PullDefaultBranchTests {
    /// A repository with a bare origin holding its main, and a second clone that pushes to it.
    private struct Setup {
        let repo: GitRepoFixture, other: String
        var git: GitRepository { GitRepository(repo.path, launcher: repo.launcher) }
        /// `n` commits made in the other clone and pushed to origin.
        func originGains(_ n: Int) throws {
            for i in 0..<n { try repo.git(["commit", "-q", "--allow-empty", "-m", "origin \(i)"], in: other) }
            try repo.git(["push", "-q", "origin", "main"], in: other)
        }
        func head(_ ref: String = "main") throws -> String { try repo.git("rev-parse", ref) }
    }

    private func setup() throws -> Setup {
        let repo = try GitRepoFixture()
        let root = (repo.path as NSString).deletingLastPathComponent
        try repo.git("init", "-q", "--bare", "-b", "main", root + "/remote.git")
        try repo.git("remote", "add", "origin", root + "/remote.git")
        try repo.git("push", "-q", "origin", "main")
        try repo.git(["clone", "-q", root + "/remote.git", root + "/other"], in: root)
        return Setup(repo: repo, other: root + "/other")
    }

    @Test func aBehindBranchFastForwardsInItsCheckout() throws {
        let s = try setup()
        try s.originGains(2)
        #expect(try s.git.pullDefaultBranch("main") == .fastForwarded("main", commits: 2))
        #expect(try s.head() == s.repo.git(["rev-parse", "HEAD"], in: s.other))
        #expect(try s.repo.git("status", "--porcelain").isEmpty, "the checkout moved with the branch")
    }

    @Test func aBranchCheckedOutNowhereMovesOnlyItsRef() throws {
        let s = try setup()
        try s.repo.git("checkout", "-q", "-b", "work")
        try s.originGains(1)
        #expect(try s.git.pullDefaultBranch("main") == .fastForwarded("main", commits: 1))
        #expect(try s.head() == s.repo.git(["rev-parse", "HEAD"], in: s.other))
        #expect(try s.repo.git("rev-parse", "--abbrev-ref", "HEAD") == "work")
    }

    @Test func upToDateSaysSo() throws {
        let s = try setup()
        #expect(try s.git.pullDefaultBranch("main") == .upToDate("main"))
    }

    @Test func localCommitsAreLeft() throws {
        let s = try setup()
        try s.repo.git("commit", "-q", "--allow-empty", "-m", "mine")
        let before = try s.head()
        #expect(try s.git.pullDefaultBranch("main") == .ahead("main", commits: 1))
        #expect(try s.head() == before)
    }

    @Test func divergedIsRefused() throws {
        let s = try setup()
        try s.repo.git("commit", "-q", "--allow-empty", "-m", "mine")
        try s.originGains(2)
        let before = try s.head()
        #expect(throws: DefaultBranchError.diverged("main", local: 1, remote: 2)) { try s.git.pullDefaultBranch("main") }
        #expect(try s.head() == before)
        #expect(DefaultBranchError.diverged("main", local: 1, remote: 2).errorDescription
                == "Your local “main” has 1 commit that isn’t on origin, and origin has 2 commits it doesn’t.")
    }

    /// git refuses to overwrite a changed file: the branch stays, and git's words say why.
    @Test func uncommittedChangesInTheCheckoutAreRefused() throws {
        let s = try setup()
        let file = s.repo.path + "/notes.txt"
        try "one\n".write(toFile: file, atomically: true, encoding: .utf8)
        try s.repo.git("add", "notes.txt"); try s.repo.git("commit", "-q", "-m", "notes")
        try s.repo.git("push", "-q", "origin", "main")
        try s.repo.git(["pull", "-q", "origin", "main"], in: s.other)
        try "origin\n".write(toFile: s.other + "/notes.txt", atomically: true, encoding: .utf8)
        try s.repo.git(["commit", "-q", "-am", "theirs"], in: s.other)
        try s.repo.git(["push", "-q", "origin", "main"], in: s.other)
        try "mine, unsaved\n".write(toFile: file, atomically: true, encoding: .utf8)
        let before = try s.head()
        #expect(throws: GitFailure.self) { try s.git.pullDefaultBranch("main") }
        #expect(try s.head() == before)
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "mine, unsaved\n")
    }

    @Test func noOriginAndNoLocalBranchAreSaid() throws {
        let bare = try GitRepoFixture()
        let git = GitRepository(bare.path, launcher: bare.launcher)
        #expect(throws: DefaultBranchError.noOrigin) { try git.pullDefaultBranch("main") }
        #expect(DefaultBranchError.noOrigin.errorDescription == "This project has no origin to pull from.")
        let s = try setup()
        try s.repo.git(["push", "-q", "origin", "main:trunk"], in: s.other)
        #expect(throws: DefaultBranchError.noLocalBranch("trunk")) { try s.git.pullDefaultBranch("trunk") }
        #expect(DefaultBranchError.noLocalBranch("trunk").errorDescription == "There is no local “trunk” to bring up to date.")
    }

    @Test func eachOutcomeIsSaid() {
        #expect(DefaultBranchPull.upToDate("main").summary == "main is already up to date.")
        #expect(DefaultBranchPull.fastForwarded("main", commits: 1).summary == "main updated with 1 new commit.")
        #expect(DefaultBranchPull.fastForwarded("main", commits: 3).summary == "main updated with 3 new commits.")
        #expect(DefaultBranchPull.fastForwarded("main", commits: nil).summary == "main updated with origin’s new commits.")
        #expect(DefaultBranchPull.ahead("main", commits: 2).summary == "main is 2 commits ahead of origin, so there was nothing to pull.")
        #expect(DefaultBranchPull.ahead("main", commits: nil).summary == "main is ahead of origin, so there was nothing to pull.")
    }
}
