// Ported from AiTerm (app/Sources/AiTerm/ReviewCreationModel.swift), GPLv3, Laurens D'Hondt.
import Foundation
import ShellforgeCore

/// New Review's part of `CreationModel`: it searches the project's open merge requests and filters
/// the branch list as it is typed. AiTerm's also follows which task already has the branch checked
/// out; Shellforge's refuses that branch at create instead, saying where it is.
@MainActor
public final class ReviewCreation: CreationKind {
    public typealias Draft = ReviewDraft
    public typealias Item = MergeRequest

    /// Whose requests the sheet lists: it names them in its copy and draws their mark.
    let codeHost: CodeHost
    fileprivate(set) var pickRefusal: String?
    fileprivate(set) var branchQuery = ""
    fileprivate(set) var branchMatches: [String] = []
    /// Whether the branch list hangs open under its field, as `listOpen` is the request list's.
    fileprivate(set) var branchListOpen = false

    init(codeHost: CodeHost) { self.codeHost = codeHost }

    public func slug(of draft: ReviewDraft) -> String { BranchNaming.reviewSlug(branch: draft.branch) }
    /// A review's prompt is what was typed: there is no ticket to add.
    public func prompt(of draft: ReviewDraft) -> String? { draft.promptText.isEmpty ? nil : draft.promptText }
    /// Step 1 needs both a name and a branch: a review derives neither.
    public func firstStepDone(_ draft: ReviewDraft) -> Bool {
        NewReviewSheet.canAdvance(step: 1, title: draft.title, branch: draft.branch, creating: false)
    }
    public func branchesLoaded(_ found: [String], into draft: inout ReviewDraft, opened: ReviewDraft) {
        branchMatches = Self.filtered(found, query: branchQuery)
    }

    /// A popup of every branch in a real repository is unusable, so the branch field filters by
    /// substring instead — case-insensitively, order kept (default branch first).
    static func filtered(_ branches: [String], query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return branches }
        return branches.filter { $0.range(of: q, options: .caseInsensitive) != nil }
    }
}

/// The New Review sheet's state.
public typealias ReviewCreationModel = CreationModel<ReviewCreation>

extension CreationModel where Kind == ReviewCreation {
    /// `searchMergeRequests` is required: a default that silently returned nothing would make a
    /// misconfigured sheet look merely empty, and every real call passes `searcher(gitLab:gitHub:remote:)`.
    public convenience init(project: Project, agents: [AgentDefinition], available: Set<String>, draft: ReviewDraft,
                            rememberedModels: [String: String],
                            modelDefaults: [String: ModelPreference] = [:],
                            catalogue: @escaping @Sendable (AgentDefinition) throws -> [AgentModel],
                            branches: @escaping @Sendable () -> [String],
                            codeHost: CodeHost,
                            searchMergeRequests: @escaping @MainActor (String) async throws -> [MergeRequest],
                            submit: @escaping @MainActor (ReviewDraft) async throws -> Void,
                            home: URL) {
        self.init(kind: ReviewCreation(codeHost: codeHost), project: project, agents: agents, available: available, draft: draft,
                  rememberedModels: rememberedModels, modelDefaults: modelDefaults, catalogue: catalogue, branches: branches, submit: submit,
                  search: searchMergeRequests, home: home)
    }

    var codeHost: CodeHost { kind.codeHost }

    /// `gitLab`, `gitHub` and `remote` are the connections and the project's remote as they stood
    /// when the sheet was prepared — Keychain reads and a look at the checkout, too slow for every
    /// keystroke. Which host is searched is Core's to say (`MergeRequestSearch`); why none can be is
    /// the sheet's search error, on every search.
    public static func searcher(gitLab: GitLabConfig?, gitHub: GitHubConfig? = nil, remote: RemoteInfo) -> @MainActor (String) async throws -> [MergeRequest] {
        let source = Result(catching: { () throws(MergeRequestSearch.Unavailable) -> any MergeRequestSearching in
            try MergeRequestSearch.source(for: remote, gitLab: gitLab, gitHub: gitHub)
        })
        return { text in
            switch source {
            case .success(let search): return try await search.mergeRequests(search: text)
            case .failure(let unavailable): throw ActionUnavailable(unavailable.message)
            }
        }
    }

    /// Why the last pick was refused. Apart from `searchError`: the picker clears its query after a
    /// pick, which re-searches, and a search that succeeds clears `searchError`.
    var pickRefusal: String? { kind.pickRefusal }

    /// A fork's branch is not on origin, which is where a review's worktree checks out from, so a
    /// fork's pull request is refused with the fork named rather than failing at Create.
    func pick(_ mr: MergeRequest) {
        objectWillChange.send()
        if let fork = mr.forkHead {
            kind.pickRefusal = "This pull request’s branch is in a fork (\(fork)). Shellforge reviews branches on origin."
            return
        }
        kind.pickRefusal = nil
        cancelSearch()
        searchError = nil
        draft.apply(mr: mr)
    }

    /// The sheet's clear action on a picked request.
    func clearPick() {
        objectWillChange.send()
        kind.pickRefusal = nil
        draft.apply(mr: nil)
    }

    /// What the branch field has typed, and the branches it matches: filtered when either changes,
    /// not on each read — a render reads the matches, and a repository can have hundreds of branches.
    var branchQuery: String {
        get { kind.branchQuery }
        set {
            guard newValue != kind.branchQuery else { return }
            objectWillChange.send()
            kind.branchQuery = newValue
            kind.branchMatches = ReviewCreation.filtered(branches, query: newValue)
        }
    }
    var branchMatches: [String] { kind.branchMatches }

    var branchListOpen: Bool {
        get { kind.branchListOpen }
        set {
            guard newValue != kind.branchListOpen else { return }
            objectWillChange.send()
            kind.branchListOpen = newValue
        }
    }
}

extension MergeRequestSearch.Unavailable {
    /// What the sheet says in place of merge requests.
    var message: String {
        switch self {
        case .notConnected(let host): "Connect \(host.name) in Settings, or pick a branch instead."
        case .noRepositoryPath(.gitHub): "Couldn’t read a GitHub repository from this repository’s remote."
        case .noRepositoryPath(.gitLab): "Couldn’t read a GitLab project path from this repository’s remote."
        case .otherGitLabHost(let remote, let configured):
            "This project’s remote is \(remote ?? "not a GitLab host"); GitLab is configured for \(configured ?? "another host")."
        }
    }
}
