// Ported from AiTerm (app/Sources/AiTermCore/Git/Repository+DefaultBranch.swift, WorktreeError.swift,
// app/Sources/AiTerm/BranchOutcomeCopy.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// What `GitRepository.pullDefaultBranch` found, each with the branch it is about. A count of
/// commits is nil when git could not make it.
public enum DefaultBranchPull: Equatable, Sendable {
    case upToDate(String)
    case fastForwarded(String, commits: Int?)
    /// Local commits origin lacks, and nothing of origin's to take: left as it is.
    case ahead(String, commits: Int?)

    /// AiTerm's toast for it; Shellforge says it in the sidebar's notice.
    public var summary: String {
        switch self {
        case .upToDate(let branch): "\(branch) is already up to date."
        case .fastForwarded(let branch, let count?): "\(branch) updated with \(commits(count, adjective: "new"))."
        case .fastForwarded(let branch, nil): "\(branch) updated with origin’s new commits."
        case .ahead(let branch, let count?): "\(branch) is \(commits(count)) ahead of origin, so there was nothing to pull."
        case .ahead(let branch, nil): "\(branch) is ahead of origin, so there was nothing to pull."
        }
    }
}

/// Why "Pull main" was refused, in words to show.
public enum DefaultBranchError: Error, Equatable, LocalizedError {
    case noOrigin
    case noLocalBranch(String)
    /// The local branch with `local` commits origin lacks while origin has `remote` it lacks.
    case diverged(String, local: Int?, remote: Int?)

    public var errorDescription: String? {
        switch self {
        case .noOrigin: return "This project has no origin to pull from."
        case .noLocalBranch(let branch): return "There is no local “\(branch)” to bring up to date."
        case .diverged(let branch, let local, let remote):
            return "Your local “\(branch)” has \(commits(local)) that \(local == 1 ? "isn’t" : "aren’t") on origin, "
                + "and origin has \(commits(remote)) it doesn’t."
        }
    }
}

extension GitRepository {
    /// "Pull main": `branch` brought to origin's, fast-forward only. Checked out somewhere — usually
    /// the project's own checkout — it is merged there, so the files move with it and git refuses
    /// to overwrite uncommitted changes; checked out nowhere, only the ref moves. Ahead of origin it
    /// is left alone, and diverged it is refused: nothing here merges, rebases or resets.
    public func pullDefaultBranch(_ branch: String) throws -> DefaultBranchPull {
        guard try hasOrigin else { throw DefaultBranchError.noOrigin }
        try fetchFromOrigin(branch)
        guard let local = sha("refs/heads/" + branch) else { throw DefaultBranchError.noLocalBranch(branch) }
        guard let remote = sha("refs/remotes/origin/" + branch) else { throw DefaultBranchError.noOrigin }
        if local == remote { return .upToDate(branch) }
        if try isAncestor(remote, of: local) { return .ahead(branch, commits: count(remote, local)) }
        guard try isAncestor(local, of: remote) else {
            throw DefaultBranchError.diverged(branch, local: count(remote, local), remote: count(local, remote))
        }
        let commits = count(local, remote)
        if let holder = try worktrees().first(where: { $0.branch == branch }) {
            // No autostash, whatever the config says: stashed, the changes git cannot put back end
            // as conflict markers in the files, and the merge still exits 0.
            try run(["merge", "--ff-only", "--no-autostash", "--quiet", remote], in: holder.path)
        } else {
            try fastForward(branch)
        }
        return .fastForwarded(branch, commits: commits)
    }
}

/// "1 commit", "3 new commits"; just "commits" when git could not count them.
private func commits(_ count: Int?, adjective: String? = nil) -> String {
    guard let count else { return "commits" }
    return ([String(count)] + [adjective].compactMap { $0 } + [count == 1 ? "commit" : "commits"]).joined(separator: " ")
}
