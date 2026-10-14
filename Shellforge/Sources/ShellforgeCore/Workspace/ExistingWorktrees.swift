// Ported in part from AiTerm (app/Sources/AiTerm/ProjectActions.swift: importWorktrees, and
// app/Sources/AiTermCore/Git/Worktree.swift: importedKind), GPLv3, Laurens D'Hondt.
import Foundation

/// A worktree of a project's repository that is not a task yet: one to continue in.
public struct ExistingWorktree: Equatable, Hashable, Sendable, Identifiable {
    public var path: String, branch: String, kind: TaskKind
    /// When its last commit was made; nil when git could not say.
    public var lastCommit: Date?
    public var id: String { path }

    public init(path: String, branch: String, kind: TaskKind, lastCommit: Date?) {
        self.path = path; self.branch = branch; self.kind = kind; self.lastCommit = lastCommit
    }
}

/// New Task's "Existing worktree", and Add Project's offer to import them: a worktree made earlier
/// — by Shellforge, AiTerm, an agent or by hand — becomes a task without git changing anything.
public enum ExistingWorktrees {
    public enum Refusal: Error, Equatable, LocalizedError {
        case noneChosen, gone(String), taken(String)
        public var errorDescription: String? {
            switch self {
            case .noneChosen: return "Choose a worktree to continue in."
            case .gone(let branch): return "The worktree for \(branch) is no longer there."
            case .taken(let branch): return "\(branch) is already a task’s worktree."
            }
        }
    }

    /// The project repository's worktrees that could be continued: on a branch, still on disk, not
    /// the project's own checkout and not any of `taken` (the tasks' worktrees). Newest commit first.
    /// Blocks on git: call it off the main actor.
    public static func list(project: Project, taken: [String], launcher: CommandLauncher) throws -> [ExistingWorktree] {
        let excluded = Set((taken + [project.path]).map(resolved))
        let candidates = try GitRepository(project.path, launcher: launcher).worktrees().filter { worktree in
            worktree.branch != nil && !excluded.contains(resolved(worktree.path))
                && FileManager.default.fileExists(atPath: worktree.path)
        }
        return candidates.compactMap { worktree -> ExistingWorktree? in
            guard let branch = worktree.branch else { return nil }
            return ExistingWorktree(path: worktree.path, branch: branch, kind: kind(of: worktree),
                                    lastCommit: lastCommit(in: worktree.path, launcher: launcher))
        }
        .sorted { ($0.lastCommit ?? .distantPast) > ($1.lastCommit ?? .distantPast) }
    }

    /// The task for the draft's picked worktree, checked against git again first: a worktree gone
    /// from disk, or taken by a task since the sheet listed it, is refused. Nothing in git changes.
    public static func adopt(draft: TaskDraft, in project: Project, taken: [String] = [], launcher: CommandLauncher) throws -> TaskItem {
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TaskWorktrees.Refusal.emptyTitle }
        guard !draft.model.isEmpty else { throw TaskWorktrees.Refusal.emptyModel }
        guard let picked = draft.existing else { throw Refusal.noneChosen }
        if Set(taken.map(resolved)).contains(resolved(picked.path)) { throw Refusal.taken(picked.branch) }
        let listed = try GitRepository(project.path, launcher: launcher).worktrees()
        guard FileManager.default.fileExists(atPath: picked.path),
              let current = listed.first(where: { resolved($0.path) == resolved(picked.path) }), let branch = current.branch
        else { throw Refusal.gone(picked.branch) }
        return TaskItem(projectId: project.id, title: draft.title, branch: branch, worktreePath: current.path,
                        baseBranch: draft.baseBranch, agent: draft.agentId, model: draft.model, reasoning: draft.reasoning,
                        jira: draft.ticket.map { JiraRef(key: $0.key, summary: $0.summary, url: $0.url) }, kind: kind(of: current))
    }

    /// AiTerm's import: each worktree a task named after its branch, with no agent started.
    public static func imported(_ worktrees: [ExistingWorktree], project: Project, baseBranch: String,
                                agent: String?, model: String?, reasoning: String?) -> [TaskItem] {
        worktrees.map { worktree in
            TaskItem(projectId: project.id, title: worktree.branch, branch: worktree.branch, worktreePath: worktree.path,
                     baseBranch: baseBranch, agent: agent, model: model, reasoning: reasoning, kind: worktree.kind)
        }
    }

    /// AiTerm's `importedKind`: a review's lock reason is the authority, a `review-` folder the
    /// fallback. A review taken for a task would offer to delete its merge request's branch.
    static func kind(of worktree: GitRepository.Worktree) -> TaskKind {
        // AiTerm's own reviews carry its lock reason: a worktree it made is continued here too.
        if let reason = worktree.lockReason, [GitRepository.reviewLockReason, "aiterm review"].contains(reason) { return .review }
        return URL(fileURLWithPath: worktree.path).lastPathComponent.hasPrefix("review-") ? .review : .task
    }

    private static func lastCommit(in path: String, launcher: CommandLauncher) -> Date? {
        guard let out = try? launcher.run("git", ["-C", path, "log", "-1", "--format=%ct"]), out.status == 0,
              let seconds = TimeInterval(out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    static func resolved(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
}
