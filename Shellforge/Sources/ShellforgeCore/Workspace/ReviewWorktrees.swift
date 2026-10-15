// Ported from AiTerm (app/Sources/AiTermCore/Git/Repository+Worktrees.swift, Repository+ReviewBranch.swift, WorktreeError.swift, Tasks/TaskCreator.swift and AiTerm/BranchOutcomeCopy.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// Why a review's checkout was refused, in words to show: AiTerm's review cases of `WorktreeError`.
public enum ReviewRefusal: Error, Equatable, LocalizedError {
    /// A branch git will not check out a second time, and where it already is.
    case branchCheckedOut(String, at: String)
    /// A local branch with commits origin lacks while origin has commits it lacks.
    case branchDiverged(String)
    case branchNotOnOrigin(String)
    case symlinkRefused(String)

    public var errorDescription: String? {
        switch self {
        case .branchCheckedOut(let branch, let path):
            "“\(branch)” is checked out at \(path). Switch that checkout to another branch, then review it."
        case .branchDiverged(let branch):
            "Your local “\(branch)” and origin’s have diverged. Reconcile them (pull or reset), then review it."
        case .branchNotOnOrigin(let branch):
            "“\(branch)” is not on origin, so a review couldn’t push to it. A fork’s branch is not supported."
        case .symlinkRefused(let path): "Refusing to create a worktree through the symlink at \(path)."
        }
    }
}

/// What `releaseReviewBranch(_:target:)` did with a review's local branch.
public enum ReviewBranchRelease: Equatable, Sendable {
    case deleted
    /// Kept, and why — it holds work that exists nowhere else, or that could not be ruled out.
    case kept(Kept)
    /// Absent, or with no origin to judge it against.
    case untouched

    /// Why a review's local branch was kept.
    public enum Kept: Equatable, Sendable {
        /// A worktree has it checked out, at this path.
        case checkedOut(at: String)
        /// Origin could not be asked, for git's reason.
        case originUnreachable(String)
        /// Origin's tip of the branch could not be fetched to compare against.
        case originNotFetched
        /// It has this many commits origin's branch lacks — nil when git could not count them.
        case unpushed(commits: Int?)
        /// Origin no longer has it, and its work is not on this target — "" for a review that has none.
        case unmerged(target: String)
        /// git refused to delete it, for this reason.
        case notDeleted(String)
        /// git could not say whether its work is anywhere else, for this reason.
        case unchecked(String)
    }
}

extension ReviewBranchRelease.Kept {
    /// What a removed review says about its local `branch`: "Branch feat/x kept: 1 commit not on origin."
    public func note(branch: String) -> String { "Branch \(branch) kept: \(reason(branch: branch))." }

    private func reason(branch: String) -> String {
        switch self {
        case .checkedOut(let path): "checked out at \(path)"
        case .originUnreachable(let why): "couldn’t check origin (\(why))"
        case .originNotFetched: "couldn’t fetch origin’s \(branch) to compare"
        case .unpushed(let count?): "\(count == 1 ? "1 commit" : "\(count) commits") not on origin"
        case .unpushed(nil): "commits not on origin"
        case .unmerged(let target): "not on origin and not merged into \(target.isEmpty ? "its target" : target)"
        case .notDeleted(let why): why
        case .unchecked(let why): "couldn’t check where its commits are (\(why))"
        }
    }
}

extension GitRepository {
    /// What a review's worktree is locked for, so `git worktree prune` cannot take it and a lock
    /// tells a review's worktree from a task's: AiTerm's `aiterm review`.
    public static let reviewLockReason = "shellforge review"

    /// A worktree on `branch` — someone's merge request — at `<project>/.worktrees/<slug>`.
    ///
    /// Origin's tip is fetched first. A local branch is whatever was last pulled, and the fetch
    /// never moves it: behind origin, it is fast-forwarded; ahead, its unpushed commits are kept;
    /// diverged, it is refused rather than moved. Only on origin, it gets a local branch tracking
    /// origin's, which `releaseReviewBranch` takes back once the review is removed. Every refusal
    /// comes before anything is created, and no failure path deletes a branch.
    public func addReviewWorktree(slug: String, branch: String) throws -> String {
        let hasOrigin = try hasOrigin
        if hasOrigin { try? fetchFromOrigin(branch) }
        let local = sha("refs/heads/" + branch)
        let remote = hasOrigin ? sha("refs/remotes/origin/" + branch) : nil
        if let holder = try worktrees().first(where: { $0.branch == branch }) {
            throw ReviewRefusal.branchCheckedOut(branch, at: holder.path)
        }
        switch (local, remote) {
        case (nil, nil): throw ReviewRefusal.branchNotOnOrigin(branch)
        case let (l?, r?) where l != r:
            // Ahead: origin's tip is in it, and its unpushed commits are kept as they are.
            if try isAncestor(r, of: l) { break }
            guard try isAncestor(l, of: r) else { throw ReviewRefusal.branchDiverged(branch) }
            // Behind: a fast-forward, which git refuses for a branch being rebased in some checkout.
            try fastForward(branch)
        default: break
        }
        let worktreePath = try prepareWorktree(slug: slug)
        let created = local == nil
        // AiTerm's five minutes: a checkout killed halfway leaves a locked worktree that every retry
        // is refused over, which is worse than waiting.
        try run(["worktree", "add", "--lock", "--reason", Self.reviewLockReason]
                + (created ? ["-b", branch, worktreePath, "origin/" + branch] : [worktreePath, branch]), timeout: 300)
        // So that a plain `git push` from the review lands on origin's branch. Written as config
        // rather than asked of `--track`, which refuses an `origin/<branch>` that
        // `remote.origin.fetch` does not cover — a single-branch clone's. Best-effort: the checkout
        // works without an upstream, so a failed write must not strand the review's worktree.
        if remote != nil {
            _ = try? run(["config", "branch.\(branch).remote", "origin"])
            _ = try? run(["config", "branch.\(branch).merge", "refs/heads/" + branch])
        }
        return worktreePath
    }

    /// Where a new worktree goes, made ready for `git worktree add`: never through a symlink, with
    /// `.worktrees/` in the repository's exclude file so it does not show as untracked.
    private func prepareWorktree(slug: String) throws -> String {
        let dir = path + "/.worktrees", worktreePath = dir + "/" + slug
        for p in [dir, worktreePath] where (try? FileManager.default.destinationOfSymbolicLink(atPath: p)) != nil {
            throw ReviewRefusal.symlinkRefused(p)
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let gitDir = try run(["rev-parse", "--git-common-dir"])
        try TaskWorktrees.exclude(".worktrees/", inGitDir: gitDir.hasPrefix("/") ? gitDir : path + "/" + gitDir)
        return worktreePath
    }

    // -- releasing a review's branch -------------------------------------------------------

    /// The local branch a removed review leaves behind, deleted when that loses nothing: every
    /// commit on it is on origin's branch, or — once GitLab has deleted that after a merge — in
    /// `target`, the branch the merge request landed on. Otherwise it is kept, with the reason.
    /// Origin's branch is never touched, and without an origin there is nothing to judge by.
    ///
    /// Origin is asked directly (`ls-remote`), never through `refs/remotes/origin/*`: those are
    /// whatever the last fetch saw. If origin cannot be asked at all, the branch is kept; so it is
    /// when git here could not answer.
    public func releaseReviewBranch(_ branch: String, target: String) -> ReviewBranchRelease {
        do { return try release(branch, target: target) }
        catch { return .kept(.unchecked(Self.reason(of: error))) }
    }

    private func release(_ branch: String, target: String) throws -> ReviewBranchRelease {
        guard try hasOrigin, let local = try commit("refs/heads/" + branch) else { return .untouched }
        if let holder = (try? worktrees())?.first(where: { $0.branch == branch }) {
            return .kept(.checkedOut(at: holder.path))
        }
        let onOrigin: [String: String]
        do { onOrigin = try originHeads([branch, target].filter { !$0.isEmpty }) }
        catch { return .kept(.originUnreachable(Self.reason(of: error))) }
        if let remote = onOrigin[branch] {
            guard fetched(remote, branch: branch) else { return .kept(.originNotFetched) }
            guard try !isAncestor(local, of: remote) else { return delete(branch, at: local) }
            return .kept(.unpushed(commits: count(remote, local)))
        }
        // Origin no longer has the branch. Its commits are safe only where they still live: on the
        // target as origin has it now, or on a local branch of that name — never a cached copy.
        let retained = try !target.isEmpty && target != branch && (
            onOrigin[target].map { try fetched($0, branch: target) && isAncestor(local, of: $0) } == true
                || sha("refs/heads/" + target).map { try isAncestor(local, of: $0) } == true)
        guard retained else { return .kept(.unmerged(target: target)) }
        return delete(branch, at: local)
    }

    /// What origin has for each of `branches` right now: a name absent from the answer is a branch
    /// origin confirms it does not have. Throws when origin could not be asked.
    private func originHeads(_ branches: [String]) throws -> [String: String] {
        let refs = branches.map { "refs/heads/" + $0 }
        var heads: [String: String] = [:]
        for line in try runRemote(["ls-remote", "origin"] + refs).split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 1).map(String.init)
            // `ls-remote` matches a pattern against the tail of a ref name; only the exact ref counts.
            guard fields.count == 2, let i = refs.firstIndex(of: fields[1]) else { continue }
            heads[branches[i]] = fields[0]
        }
        return heads
    }

    /// Whether `commit` — the tip origin reported for `branch` — is here to compare against,
    /// fetching the branch when it is not.
    private func fetched(_ commit: String, branch: String) -> Bool {
        if sha(commit) != nil { return true }
        try? fetchFromOrigin(branch)
        return sha(commit) != nil
    }

    /// The branch deleted only if it is still at `commit`, the one judged safe above: git refuses
    /// the update when the ref has moved on since — someone's new commit, not on origin — and the
    /// branch is kept. AiTerm runs `branch -D` by name; the question `-d` asks — merged into HEAD or
    /// the upstream — is not the one answered above either way.
    private func delete(_ branch: String, at commit: String) -> ReviewBranchRelease {
        do { try run(["update-ref", "-d", "refs/heads/" + branch, commit]); return .deleted }
        catch { return .kept(.notDeleted(Self.reason(of: error))) }
    }
}

/// A review's task: AiTerm's `TaskCreator.createReview`.
public enum ReviewWorktrees {
    /// `cancellation` stops it as it stops a task's create, taking back the half-made worktree; the
    /// branch stays, as a review's branch may have been there before. `progress` hears its step.
    public static func create(draft: ReviewDraft, in project: Project, launcher: CommandLauncher,
                              cancellation: CreationCancellation? = nil,
                              progress: (@Sendable (CreationStep) -> Void)? = nil) throws -> TaskItem {
        if cancellation?.isCancelled == true { throw CreationCancelled() }
        progress?(.creatingWorktree(runsHook: TaskWorktrees.hasCheckoutHook(project: project, launcher: launcher)))
        let slug = BranchNaming.unused(BranchNaming.reviewSlug(branch: draft.branch), in: project.path)
        do {
            return try create(draft: draft, in: project, git: LauncherGit(launcher: launcher, cancellation: cancellation), launcher: launcher)
        } catch let cancelled as CreationCancelled {
            let path = "\(project.path)/.worktrees/\(slug)"
            _ = try? launcher.run("git", ["-C", project.path, "worktree", "remove", "--force", path])
            if FileManager.default.fileExists(atPath: path) { try? FileManager.default.removeItem(atPath: path) }
            _ = try? launcher.run("git", ["-C", project.path, "worktree", "prune"])
            throw cancelled
        }
    }

    static func create(draft: ReviewDraft, in project: Project, git: any GitCommands, launcher: CommandLauncher) throws -> TaskItem {
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TaskWorktrees.Refusal.emptyTitle }
        guard !draft.model.isEmpty else { throw TaskWorktrees.Refusal.emptyModel }
        guard !draft.branch.trimmingCharacters(in: .whitespaces).isEmpty,
              BranchNaming.isValid(draft.branch, launcher: launcher) else { throw TaskWorktrees.Refusal.invalidBranch(draft.branch) }
        let slug = BranchNaming.unused(BranchNaming.reviewSlug(branch: draft.branch), in: project.path)
        let path = try GitRepository(project.path, git: git).addReviewWorktree(slug: slug, branch: draft.branch)
        return TaskItem(projectId: project.id, title: draft.title, branch: draft.branch, worktreePath: path,
                        baseBranch: draft.mr?.targetBranch ?? "", agent: draft.agentId, model: draft.model,
                        reasoning: draft.reasoning, kind: .review,
                        mr: draft.mr.map { MergeRequestRef(iid: $0.iid, title: $0.title, url: $0.url) })
    }
}
