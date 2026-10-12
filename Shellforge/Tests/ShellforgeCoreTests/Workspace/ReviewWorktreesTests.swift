// Ported from AiTerm (app/Tests/AiTermCoreTests/WorktreesTests.swift, review cases, and TaskCreatorTests.swift), GPLv3, Laurens D'Hondt.
import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#endif
@testable import ShellforgeCore

/// git that times out on any call whose arguments start with `prefix`, and runs the rest: a git
/// that could not answer, which is never taken for a "no".
struct TimingOutGit: GitCommands {
    let prefix: [String], real: LauncherGit
    func git(_ args: [String], in directory: String, remote: Bool) throws -> ChildOutput {
        if args.starts(with: prefix) { return ChildOutput(status: 15, stdout: "", stderr: "", timedOut: true) }
        return try real.git(args, in: directory, remote: remote)
    }
}

/// git that records every call it runs.
final class RecordingGit: GitCommands, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    let real: LauncherGit
    init(real: LauncherGit) { self.real = real }
    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return recorded }
    func git(_ args: [String], in directory: String, remote: Bool) throws -> ChildOutput {
        lock.lock(); recorded.append(args); lock.unlock()
        return try real.git(args, in: directory, remote: remote)
    }
}

/// A review's worktree on someone's merge-request branch, and that branch let go only when nothing
/// is lost: AiTerm's review cases, against a bare repository standing in for origin.
@Suite struct ReviewWorktreesTests {
    let launcher: CommandLauncher
    let root: String

    /// `realpath(3)`, which is what git reports for a temporary directory (`/private/var/...`).
    private static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    init() throws {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("rv-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: raw, withIntermediateDirectories: true)
        root = Self.realPath(raw)
        let env = ["PATH": "/usr/bin:/bin", "HOME": root, "GIT_CONFIG_NOSYSTEM": "1",
                   "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"]
        launcher = CommandLauncher { ResolvedEnvironment(variables: env, source: .loginShell("/bin/sh")) }
    }

    private var git: LauncherGit { LauncherGit(launcher: launcher) }
    private func repository(_ path: String, git: (any GitCommands)? = nil) -> GitRepository { GitRepository(path, git: git ?? self.git) }

    @discardableResult
    private func run(_ args: [String], in dir: String) throws -> String {
        let out = try launcher.run("git", ["-C", dir] + args)
        guard out.status == 0 else { throw GitFailure(command: "git " + args.joined(separator: " "), message: out.stderr) }
        return out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A bare remote carrying `feat/mr-branch`, cloned into a working repo whose only local branch is
    /// `main`: the shape a review meets — the branch is on origin and nowhere else.
    private func repoWithRemoteOnlyBranch() throws -> String {
        let remote = root + "/remote.git", work = root + "/work"
        try run(["init", "-q", "--bare", "-b", "main", remote], in: root)
        try run(["clone", "-q", remote, work], in: root)
        try run(["commit", "-q", "--allow-empty", "-m", "init"], in: work)
        try run(["push", "-q", "origin", "HEAD:main"], in: work)
        try run(["checkout", "-q", "-b", "feat/mr-branch"], in: work)
        try run(["commit", "-q", "--allow-empty", "-m", "mr"], in: work)
        try run(["push", "-q", "origin", "feat/mr-branch"], in: work)
        try run(["checkout", "-q", "main"], in: work)
        try run(["branch", "-D", "feat/mr-branch"], in: work)
        return work
    }

    /// A repository with no origin.
    private func plainRepo() throws -> String {
        let repo = root + "/plain"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try run(["init", "-q", "-b", "main"], in: repo)
        try run(["commit", "-q", "--allow-empty", "-m", "init"], in: repo)
        return repo
    }

    private var origin: String { root + "/remote.git" }

    /// A second clone of the same origin: someone else, whose pushes this one has not fetched.
    private func otherClone(branch: String? = nil) throws -> String {
        let other = root + "/other"
        try run(["clone", "-q"] + (branch.map { ["-b", $0] } ?? []) + [origin, other], in: root)
        return other
    }

    private func sha(_ ref: String, in dir: String) throws -> String { try run(["rev-parse", ref], in: dir) }
    private func commit(_ message: String, in dir: String) throws { try run(["commit", "-q", "--allow-empty", "-m", message], in: dir) }
    private func hasLocalBranch(_ branch: String, in repo: String) throws -> Bool {
        !(try run(["for-each-ref", "--format=%(refname)", "refs/heads/" + branch], in: repo)).isEmpty
    }

    /// The worktree gone as Remove takes it, the branch left for `releaseReviewBranch`.
    private func removeWorktree(_ path: String, in repo: String) throws {
        try run(["worktree", "unlock", path], in: repo)
        try run(["worktree", "remove", "--force", path], in: repo)
    }

    /// One more commit on `feat/mr-branch` from a second clone, the merge request's author's; this
    /// repo's own refs know nothing of it until a fetch.
    private func pushNewCommitToMRBranch() throws -> String {
        let other = try otherClone(branch: "feat/mr-branch")
        try commit("later", in: other)
        try run(["push", "-q", "origin", "feat/mr-branch"], in: other)
        return try sha("HEAD", in: other)
    }

    // -- checking out a review --------------------------------------------------------------

    @Test func aReviewCreatesALocalBranchTrackingOriginLocked() throws {
        let repo = try repoWithRemoteOnlyBranch()
        let path = try repository(repo).addReviewWorktree(slug: "review-mr-branch", branch: "feat/mr-branch")
        #expect(path == repo + "/.worktrees/review-mr-branch")
        #expect(try run(["rev-parse", "--abbrev-ref", "HEAD"], in: path) == "feat/mr-branch")
        #expect(try run(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], in: path) == "origin/feat/mr-branch")
        // Locked, so `git worktree prune` cannot take it, and the lock says it is a review's.
        #expect(try repository(repo).worktrees().first { $0.path == path }?.lockReason == GitRepository.reviewLockReason)
    }

    /// A `--single-branch` clone's `remote.origin.fetch` covers only its own branch: the review's
    /// push target is written as config, which `--track` would refuse.
    @Test func aReviewOfABranchOnlyOriginHasWorksInASingleBranchClone() throws {
        _ = try repoWithRemoteOnlyBranch()
        let clone = root + "/single"
        try run(["clone", "-q", "--single-branch", "-b", "main", origin, clone], in: root)
        let path = try repository(clone).addReviewWorktree(slug: "review-mr-branch", branch: "feat/mr-branch")
        #expect(try run(["rev-parse", "--abbrev-ref", "HEAD"], in: path) == "feat/mr-branch")
        #expect(try run(["config", "branch.feat/mr-branch.remote"], in: clone) == "origin")
        #expect(try run(["config", "branch.feat/mr-branch.merge"], in: clone) == "refs/heads/feat/mr-branch")
    }

    @Test func aBranchCheckedOutElsewhereIsRefusedAndNothingIsMade() throws {
        let repo = try repoWithRemoteOnlyBranch()
        try run(["checkout", "-q", "feat/mr-branch"], in: repo)
        #expect(throws: ReviewRefusal.branchCheckedOut("feat/mr-branch", at: repo)) {
            try repository(repo).addReviewWorktree(slug: "review-mr-branch", branch: "feat/mr-branch")
        }
        #expect(!FileManager.default.fileExists(atPath: repo + "/.worktrees/review-mr-branch"))
        #expect(try run(["rev-parse", "--abbrev-ref", "HEAD"], in: repo) == "feat/mr-branch", "the checkout is untouched")
    }

    /// Behind origin, the local branch is fast-forwarded, so the review starts from what was pushed.
    @Test func aStaleLocalBranchIsFastForwarded() throws {
        let repo = try repoWithRemoteOnlyBranch()
        try run(["branch", "-q", "--track", "feat/mr-branch", "origin/feat/mr-branch"], in: repo)
        let fresh = try pushNewCommitToMRBranch()
        let path = try repository(repo).addReviewWorktree(slug: "review-mr-branch", branch: "feat/mr-branch")
        #expect(try sha("HEAD", in: path) == fresh)
    }

    /// Ahead of origin is not stale: those are unpushed commits, an earlier review's fixes.
    @Test func aLocalBranchThatIsAheadIsKept() throws {
        let repo = try repoWithRemoteOnlyBranch()
        try run(["branch", "-q", "--track", "feat/mr-branch", "origin/feat/mr-branch"], in: repo)
        try run(["checkout", "-q", "feat/mr-branch"], in: repo)
        try commit("my fix", in: repo)
        let mine = try sha("HEAD", in: repo)
        try run(["checkout", "-q", "main"], in: repo)
        let path = try repository(repo).addReviewWorktree(slug: "review-mr-branch", branch: "feat/mr-branch")
        #expect(try sha("HEAD", in: path) == mine)
    }

    /// Diverged, neither side can move without losing the other's commits: that is for a person.
    @Test func aDivergedLocalBranchIsRefused() throws {
        let repo = try repoWithRemoteOnlyBranch()
        try run(["branch", "-q", "--track", "feat/mr-branch", "origin/feat/mr-branch"], in: repo)
        try run(["checkout", "-q", "feat/mr-branch"], in: repo)
        try commit("mine", in: repo)
        let mine = try sha("HEAD", in: repo)
        try run(["checkout", "-q", "main"], in: repo)
        _ = try pushNewCommitToMRBranch()
        #expect(throws: ReviewRefusal.branchDiverged("feat/mr-branch")) {
            try repository(repo).addReviewWorktree(slug: "review-mr-branch", branch: "feat/mr-branch")
        }
        #expect(try sha("feat/mr-branch", in: repo) == mine)
        #expect(!FileManager.default.fileExists(atPath: repo + "/.worktrees/review-mr-branch"))
    }

    /// A git that could not say whether one side contains the other has not said they diverged.
    @Test func aBranchGitCannotCompareFailsWithGitsReason() throws {
        let repo = try repoWithRemoteOnlyBranch()
        try run(["branch", "-q", "--track", "feat/mr-branch", "origin/feat/mr-branch"], in: repo)
        _ = try pushNewCommitToMRBranch()
        #expect(throws: GitTimedOut.self) {
            try repository(repo, git: TimingOutGit(prefix: ["merge-base"], real: git)).addReviewWorktree(slug: "review-mr-branch", branch: "feat/mr-branch")
        }
        #expect(!FileManager.default.fileExists(atPath: repo + "/.worktrees/review-mr-branch"))
    }

    /// Nor has one that could not say whether there is an origin said there is none.
    @Test func aRepositoryGitCannotAskForItsOriginFailsWithGitsReason() throws {
        let repo = try repoWithRemoteOnlyBranch()
        #expect(throws: GitTimedOut.self) {
            try repository(repo, git: TimingOutGit(prefix: ["remote", "get-url"], real: git)).addReviewWorktree(slug: "review-mr-branch", branch: "feat/mr-branch")
        }
        #expect(!FileManager.default.fileExists(atPath: repo + "/.worktrees/review-mr-branch"))
    }

    /// Neither local nor on origin — a fork's branch, say — is nothing that could be pushed to.
    @Test func aBranchThatIsNowhereIsRefused() throws {
        let repo = try repoWithRemoteOnlyBranch()
        #expect(throws: ReviewRefusal.branchNotOnOrigin("feat/from-a-fork")) {
            try repository(repo).addReviewWorktree(slug: "review-from-a-fork", branch: "feat/from-a-fork")
        }
    }

    /// Without an origin the local branch is all there is.
    @Test func withoutOriginTheLocalBranchIsCheckedOut() throws {
        let repo = try plainRepo()
        try run(["branch", "feat/local"], in: repo)
        let path = try repository(repo).addReviewWorktree(slug: "review-local", branch: "feat/local")
        #expect(try run(["rev-parse", "--abbrev-ref", "HEAD"], in: path) == "feat/local")
    }

    /// The lock is written by `worktree add` itself: no second command that could fail with a
    /// finished checkout on disk, no moment in which the worktree exists unlocked.
    @Test func aReviewWorktreeIsLockedByTheCommandThatCreatesIt() throws {
        let repo = try repoWithRemoteOnlyBranch()
        let recording = RecordingGit(real: git)
        _ = try repository(repo, git: recording).addReviewWorktree(slug: "review-mr-branch", branch: "feat/mr-branch")
        #expect(!recording.calls.contains { $0.starts(with: ["worktree", "lock"]) }, "no separate lock step")
        #expect(recording.calls.contains { $0.starts(with: ["worktree", "add", "--lock", "--reason", GitRepository.reviewLockReason]) })
    }

    // -- releasing a review's branch ----------------------------------------------------------

    /// Deleted when every commit on it is on origin, kept — and why — when some are not. The remote
    /// branch is never touched.
    @Test func aReviewBranchIsDeletedOnlyWhenEverythingIsPushed() throws {
        let repo = try repoWithRemoteOnlyBranch()
        let path = try repository(repo).addReviewWorktree(slug: "review-mr-branch", branch: "feat/mr-branch")
        try commit("fix one", in: path)
        try commit("fix two", in: path)
        try removeWorktree(path, in: repo)
        #expect(repository(repo).releaseReviewBranch("feat/mr-branch", target: "main") == .kept(.unpushed(commits: 2)))
        #expect(try hasLocalBranch("feat/mr-branch", in: repo))

        try run(["push", "-q", "origin", "feat/mr-branch"], in: repo)
        #expect(repository(repo).releaseReviewBranch("feat/mr-branch", target: "main") == .deleted)
        #expect(try !hasLocalBranch("feat/mr-branch", in: repo))
        #expect(!(try run(["ls-remote", "--heads", "origin", "feat/mr-branch"], in: repo)).isEmpty, "origin keeps it")
        #expect(repository(repo).releaseReviewBranch("feat/mr-branch", target: "main") == .untouched)
    }

    /// GitLab deletes a merged branch on origin: merged into the target, the local copy holds nothing
    /// that is not there. Not merged, it is the only copy left.
    @Test func aReviewBranchWhoseRemoteIsGone() throws {
        let repo = try repoWithRemoteOnlyBranch()
        let path = try repository(repo).addReviewWorktree(slug: "review-mr-branch", branch: "feat/mr-branch")
        try removeWorktree(path, in: repo)
        try run(["push", "-q", "origin", "--delete", "feat/mr-branch"], in: repo)
        #expect(repository(repo).releaseReviewBranch("feat/mr-branch", target: "main") == .kept(.unmerged(target: "main")))

        try run(["push", "-q", "origin", "feat/mr-branch:main"], in: repo)
        try run(["fetch", "-q", "origin"], in: repo)
        #expect(repository(repo).releaseReviewBranch("feat/mr-branch", target: "main") == .deleted)
    }

    /// Origin is asked, not its cached tracking ref: deleted there by someone else, behind a stale
    /// `origin/feat/mr-branch`, the local branch is the only copy of work never merged.
    @Test func aReviewBranchDeletedOnOriginBehindAStaleTrackingRefIsKept() throws {
        let repo = try repoWithRemoteOnlyBranch()
        let path = try repository(repo).addReviewWorktree(slug: "review-mr-branch", branch: "feat/mr-branch")
        try removeWorktree(path, in: repo)
        try run(["branch", "-D", "feat/mr-branch"], in: origin)
        #expect(!(try run(["rev-parse", "--verify", "--quiet", "refs/remotes/origin/feat/mr-branch"], in: repo)).isEmpty,
                "the tracking ref is stale, which is the point")
        #expect(repository(repo).releaseReviewBranch("feat/mr-branch", target: "main") == .kept(.unmerged(target: "main")))
        #expect(try hasLocalBranch("feat/mr-branch", in: repo))
    }

    /// Force-pushed on origin to something else: the stale tracking ref holds the review's commit,
    /// origin's branch no longer does.
    @Test func aReviewBranchForcePushedOnOriginIsKept() throws {
        let repo = try repoWithRemoteOnlyBranch()
        let path = try repository(repo).addReviewWorktree(slug: "review-mr-branch", branch: "feat/mr-branch")
        try removeWorktree(path, in: repo)
        let other = try otherClone()
        try run(["checkout", "-q", "-B", "feat/mr-branch", "origin/main"], in: other)
        try commit("rewritten", in: other)
        try run(["push", "-q", "--force", "origin", "feat/mr-branch"], in: other)
        #expect(repository(repo).releaseReviewBranch("feat/mr-branch", target: "main") == .kept(.unpushed(commits: 1)))
        #expect(try hasLocalBranch("feat/mr-branch", in: repo))
    }

    /// Origin cannot be asked: that confirms nothing, so the branch stays.
    @Test func aReviewBranchIsKeptWhenOriginCannotBeChecked() throws {
        let repo = try repoWithRemoteOnlyBranch()
        let path = try repository(repo).addReviewWorktree(slug: "review-mr-branch", branch: "feat/mr-branch")
        try removeWorktree(path, in: repo)
        try run(["remote", "set-url", "origin", repo + "/../gone.git"], in: repo)
        guard case .kept(.originUnreachable(let why)) = repository(repo).releaseReviewBranch("feat/mr-branch", target: "main") else {
            Issue.record("expected the branch to be kept as origin could not be asked"); return
        }
        #expect(!why.isEmpty, "with git's reason")
        #expect(try hasLocalBranch("feat/mr-branch", in: repo))
    }

    /// Merged on origin and deleted there since this clone last fetched: origin's target as it is
    /// now holds every commit, so the local copy goes.
    @Test func aReviewBranchMergedOnOriginSinceTheLastFetchIsDeleted() throws {
        let repo = try repoWithRemoteOnlyBranch()
        let path = try repository(repo).addReviewWorktree(slug: "review-mr-branch", branch: "feat/mr-branch")
        try removeWorktree(path, in: repo)
        let other = try otherClone()
        try run(["push", "-q", "origin", "origin/feat/mr-branch:main"], in: other)
        try run(["push", "-q", "origin", "--delete", "feat/mr-branch"], in: other)
        #expect(repository(repo).releaseReviewBranch("feat/mr-branch", target: "main") == .deleted)
        #expect(try !hasLocalBranch("feat/mr-branch", in: repo))
    }

    /// A branch another worktree has checked out is someone's checkout: never deleted.
    @Test func aReviewBranchCheckedOutElsewhereIsKept() throws {
        let repo = try repoWithRemoteOnlyBranch()
        let path = try repository(repo).addReviewWorktree(slug: "review-mr-branch", branch: "feat/mr-branch")
        #expect(repository(repo).releaseReviewBranch("feat/mr-branch", target: "main") == .kept(.checkedOut(at: path)))
    }

    /// A git that could not say where the commits are has not said they are nowhere: kept, with
    /// git's reason.
    @Test func aReviewBranchGitCannotJudgeIsKeptWithGitsReason() throws {
        let repo = try repoWithRemoteOnlyBranch()
        let path = try repository(repo).addReviewWorktree(slug: "review-mr-branch", branch: "feat/mr-branch")
        try removeWorktree(path, in: repo)
        for prefix in [["merge-base"], ["remote", "get-url"]] {
            let release = repository(repo, git: TimingOutGit(prefix: prefix, real: git)).releaseReviewBranch("feat/mr-branch", target: "main")
            guard case .kept(.unchecked(let why)) = release else {
                Issue.record("expected the branch kept as git could not be asked, got \(release)"); continue
            }
            #expect(why.contains("timed out"))
        }
        #expect(try hasLocalBranch("feat/mr-branch", in: repo))
    }

    /// Commits origin lacks that git could not count: kept all the same, with no number.
    @Test func aReviewBranchWhoseUnpushedCommitsGitCannotCountIsKeptWithoutANumber() throws {
        let repo = try repoWithRemoteOnlyBranch()
        let path = try repository(repo).addReviewWorktree(slug: "review-mr-branch", branch: "feat/mr-branch")
        try commit("fix", in: path)
        try removeWorktree(path, in: repo)
        let release = repository(repo, git: TimingOutGit(prefix: ["rev-list"], real: git)).releaseReviewBranch("feat/mr-branch", target: "main")
        #expect(release == .kept(.unpushed(commits: nil)))
        #expect(try hasLocalBranch("feat/mr-branch", in: repo))
    }

    /// No origin, nothing to judge the branch against: it is left as it was.
    @Test func withoutOriginAReviewBranchIsLeftAlone() throws {
        let repo = try plainRepo()
        try run(["branch", "feat/local"], in: repo)
        #expect(repository(repo).releaseReviewBranch("feat/local", target: "main") == .untouched)
        #expect(try hasLocalBranch("feat/local", in: repo))
    }

    /// AiTerm's BranchOutcomeCopyTests: what the banner says of a kept branch.
    @Test func aKeptReviewBranchSaysWhy() {
        #expect(ReviewBranchRelease.Kept.unpushed(commits: 2).note(branch: "feat/x") == "Branch feat/x kept: 2 commits not on origin.")
        #expect(ReviewBranchRelease.Kept.unpushed(commits: 1).note(branch: "feat/x") == "Branch feat/x kept: 1 commit not on origin.")
        #expect(ReviewBranchRelease.Kept.unmerged(target: "").note(branch: "feat/x") == "Branch feat/x kept: not on origin and not merged into its target.")
    }

    // -- the review's task (TaskCreatorTests) -----------------------------------------------------

    private static let mergeRequest = MergeRequest(iid: 4, title: "Add gift card", sourceBranch: "feat/mr-branch", targetBranch: "develop",
                                                   author: "Sam", state: "opened", draft: false, url: "https://gitlab/x/-/merge_requests/4")

    @Test func aReviewIsStampedAsOneAndCarriesItsMergeRequest() throws {
        let repo = try plainRepo()
        try run(["branch", "feat/mr-branch"], in: repo)
        var draft = ReviewDraft(mr: nil, agentId: "claude", model: "opus", reasoning: nil)
        draft.apply(mr: Self.mergeRequest)
        let task = try ReviewWorktrees.create(draft: draft, in: Project(name: "repo", path: repo), launcher: launcher)
        #expect(task.kind == .review, "a review must be recognisable as one; nothing else distinguishes it")
        #expect(task.worktreePath == repo + "/.worktrees/review-mr-branch")
        #expect(task.branch == "feat/mr-branch" && task.title == "Add gift card")
        #expect(task.mr == MergeRequestRef(iid: 4, title: "Add gift card", url: "https://gitlab/x/-/merge_requests/4"))
        #expect(task.jira == nil, "a review has no ticket")
        #expect(task.baseBranch == "develop", "the merge request's target branch is what it lands on")
        #expect(FileManager.default.fileExists(atPath: task.worktreePath + "/.git"))
    }

    @Test func reviewsOfBranchesThatDifferOnlyInTypeGetTheirOwnWorktrees() throws {
        let repo = try plainRepo()
        var paths: [String] = []
        for branch in ["feat/card", "fix/card"] {
            try run(["branch", branch], in: repo)
            var draft = ReviewDraft(mr: nil, agentId: "claude", model: "opus", reasoning: nil)
            draft.setTitle("Card"); draft.setBranch(branch)
            paths.append(try ReviewWorktrees.create(draft: draft, in: Project(name: "repo", path: repo), launcher: launcher).worktreePath)
        }
        #expect(paths == ["review-card", "review-card-2"].map { repo + "/.worktrees/" + $0 })
    }

    @Test func aReviewWithoutAMergeRequestIsStillAReview() throws {
        let repo = try plainRepo()
        try run(["branch", "feat/teammate-work"], in: repo)
        var draft = ReviewDraft(mr: nil, agentId: "claude", model: "opus", reasoning: nil)
        draft.setTitle("Look at Sam's branch"); draft.setBranch("feat/teammate-work")
        let task = try ReviewWorktrees.create(draft: draft, in: Project(name: "repo", path: repo), launcher: launcher)
        #expect(task.kind == .review && task.mr == nil)
        #expect(task.baseBranch == "", "no merge request means nothing to land on")
    }

    @Test func anEmptyOrInvalidBranchIsRefusedBeforeGitIsTouched() throws {
        let repo = try plainRepo()
        var draft = ReviewDraft(mr: nil, agentId: "claude", model: "opus", reasoning: nil)
        draft.setTitle("Review")
        #expect(throws: TaskWorktrees.Refusal.invalidBranch("")) {
            try ReviewWorktrees.create(draft: draft, in: Project(name: "repo", path: repo), launcher: launcher)
        }
        draft.setBranch("bad..branch")
        #expect(throws: TaskWorktrees.Refusal.invalidBranch("bad..branch")) {
            try ReviewWorktrees.create(draft: draft, in: Project(name: "repo", path: repo), launcher: launcher)
        }
        #expect(!FileManager.default.fileExists(atPath: repo + "/.worktrees"))
    }
}
