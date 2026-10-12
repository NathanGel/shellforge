// Ported from AiTerm (app/Tests/AiTermTests/ReviewCreationModelTests.swift, NewReviewSheetTests.swift and CodeHostReviewCopyTests.swift), GPLv3, Laurens D'Hondt.
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import ShellforgeCore
import ShellforgeDesign
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

/// New Review's own part of the creation model: which host it searches and why it cannot, a pick
/// and its refusal for a fork, and the branch field's filter. The agent step and create are New
/// Task's `CreationModel`, tested there.
@Suite @MainActor struct ReviewCreationModelTests {
    let project = Project(name: "acme-web", path: "/tmp/p")
    let mr = MergeRequest(iid: 4, title: "Add gift card", sourceBranch: "feat-gift-card",
                          targetBranch: "main", author: "L", state: "opened", draft: false,
                          url: "https://git.example.net/web/acme-web/-/merge_requests/4")
    private let opus = AgentModel(id: "opus", label: "Opus", detail: nil, efforts: [], defaultEffort: nil)

    private func model(search: @escaping @MainActor (String) async throws -> [MergeRequest] = { _ in [] },
                       branches: [String] = [],
                       create: @escaping @MainActor (ReviewDraft) async throws -> Void = { _ in }) -> ReviewCreationModel {
        ReviewCreationModel(project: project, agents: AgentPresets.all, available: ["claude"],
                            draft: ReviewDraft(mr: nil, agentId: "claude", model: "opus", reasoning: nil), rememberedModels: [:],
                            catalogue: { [opus] _ in [opus] }, branches: { branches }, codeHost: .gitLab,
                            searchMergeRequests: search, submit: create,
                            home: FileManager.default.temporaryDirectory.appendingPathComponent("rv-home-\(UUID().uuidString)"))
    }

    /// The connection and the remote are read once, when the sheet is prepared, and every query
    /// uses what was read then.
    @Test func aSearchUsesTheConnectionAndRemoteItWasPreparedWith() async {
        let remote = ProviderDetector.detect(remoteUrl: "git@git.example.net:web/acme-web.git")
        let disconnected = ReviewCreationModel.searcher(gitLab: nil, remote: remote)
        await #expect { try await disconnected("card") } throws: {
            ($0 as? ActionUnavailable)?.message == "Connect GitLab in Settings, or pick a branch instead."
        }
        let elsewhere = ReviewCreationModel.searcher(gitLab: GitLabConfig(hostURL: URL(string: "https://gitlab.com")!, token: "t"), remote: remote)
        await #expect { try await elsewhere("card") } throws: {
            ($0 as? ActionUnavailable)?.message == "This project’s remote is git.example.net; GitLab is configured for gitlab.com."
        }
    }

    @Test func aGitHubProjectSearchesGitHubWithItsToken() async {
        let gitHubRemote = ProviderDetector.detect(remoteUrl: "git@github.com:octocat/hello.git")
        let disconnected = ReviewCreationModel.searcher(gitLab: nil, gitHub: nil, remote: gitHubRemote)
        await #expect { try await disconnected("x") } throws: {
            ($0 as? ActionUnavailable)?.message == "Connect GitHub in Settings, or pick a branch instead."
        }
        let pathless = ReviewCreationModel.searcher(gitLab: nil, gitHub: GitHubConfig(token: "t"),
                                                    remote: RemoteInfo(host: "github.com", path: "", provider: .github))
        await #expect { try await pathless("x") } throws: {
            ($0 as? ActionUnavailable)?.message == "Couldn’t read a GitHub repository from this repository’s remote."
        }
    }

    /// A self-hosted GitLab the detector calls plain git still searches GitLab.
    @Test func aPlainGitRemoteOnTheConfiguredGitLabHostStillSearchesGitLab() async {
        let remote = ProviderDetector.detect(remoteUrl: "https://code.example.com/a/b.git", repoPath: "/nonexistent")
        #expect(remote.provider == .git)
        let search = ReviewCreationModel.searcher(gitLab: GitLabConfig(hostURL: URL(string: "https://gitlab.com")!, token: "t"),
                                                  gitHub: GitHubConfig(token: "t"), remote: remote)
        await #expect { try await search("x") } throws: {
            ($0 as? ActionUnavailable)?.message == "This project’s remote is code.example.com; GitLab is configured for gitlab.com."
        }
    }

    /// The picker clears its query after a pick, which re-searches; the refusal must outlive that.
    @Test func pickingAForksPullRequestIsRefusedWithTheFork() async {
        let m = model()
        let fork = MergeRequest(iid: 5, title: "Fix typo", sourceBranch: "patch-1", targetBranch: "main", author: "someone",
                                state: "open", draft: false, url: "https://github.com/octocat/hello/pull/5", forkHead: "someone:patch-1")
        let refusal = "This pull request’s branch is in a fork (someone:patch-1). Shellforge reviews branches on origin."
        m.pick(fork)
        await m.search(text: "")
        #expect(m.pickRefusal == refusal)
        #expect(m.draft.mr == nil && m.draft.branch == "")
        m.pick(mr)
        #expect(m.pickRefusal == nil)
        #expect(m.draft.mr == mr && m.draft.branch == "feat-gift-card" && m.draft.title == "Add gift card")
        m.pick(fork)
        m.clearPick()
        #expect(m.pickRefusal == nil && m.draft.mr == nil)
    }

    @Test func resultsLandAndClearTheError() async {
        let m = model(search: { _ in [self.mr] })
        await m.search(text: "")
        #expect(m.results == [mr])
        #expect(m.searchError == nil)
    }

    @Test func unauthorizedBecomesAnInstruction() async {
        let m = model(search: { _ in throw GitLabError.unauthorized })
        await m.search(text: "")
        #expect(m.searchError == "Check your GitLab access token in Settings.")
        #expect(m.results.isEmpty)
    }

    /// A failed create leaves the draft intact so the branch can be corrected and retried, saying
    /// git's own reason.
    @Test func aFailedCreateKeepsTheDraftAndShowsGitsOwnMessage() async {
        let m = model(create: { _ in throw GitFailure(command: "git worktree add", message: "fatal: already used by worktree") })
        m.draft.apply(mr: mr)
        await m.loadCatalogue()
        #expect(await m.create() == false)
        #expect(m.error?.reason == "fatal: already used by worktree")
        #expect(m.draft.branch == "feat-gift-card")
    }

    /// The branch field's matches are kept with the model and filtered when the query or the list
    /// changes, so a render reads them rather than filtering every branch again.
    @Test func branchMatchesFollowTheQueryAndTheBranchList() async {
        let m = model(branches: ["main", "feat/gift-card", "fix/hero-spacing"])
        await m.loadBranches()
        #expect(m.branchMatches == ["main", "feat/gift-card", "fix/hero-spacing"])
        m.branchQuery = "hero"
        #expect(m.branchMatches == ["fix/hero-spacing"])
        m.branchQuery = "FEAT"
        #expect(m.branchMatches == ["feat/gift-card"])
        m.branchQuery = ""
        #expect(m.branchMatches == m.branches)
    }

    /// A slow earlier search landing after a fast later one must not overwrite the newer results,
    /// and an abandoned one must not clobber a request picked afterward.
    @Test func lateSearchCannotReplaceNewerResultsOrAPickedMergeRequest() async throws {
        var pending: [String: CheckedContinuation<[MergeRequest], Error>] = [:]
        let m = model(search: { text in try await withCheckedThrowingContinuation { pending[text] = $0 } })
        let first = Task { await m.search(text: "old") }
        await eventually { pending["old"] != nil }
        let second = Task { await m.search(text: "new") }
        await eventually { pending["new"] != nil }
        let newest = MergeRequest(iid: 9, title: "Newest", sourceBranch: "feat-newest", targetBranch: "main",
                                  author: "L", state: "opened", draft: false, url: "https://git.example.net/web/acme-web/-/merge_requests/9")
        try #require(pending["new"]).resume(returning: [newest])
        await second.value
        try #require(pending["old"]).resume(returning: [])
        await first.value
        #expect(m.results == [newest])
        let third = Task { await m.search(text: "abandoned") }
        await eventually { pending["abandoned"] != nil }
        m.cancelSearch()
        m.draft.apply(mr: newest)
        try #require(pending["abandoned"]).resume(throwing: GitLabError.unauthorized)
        await third.value
        #expect(m.draft.mr == newest)
        #expect(m.searchError == nil)
    }

    // -- the sheet's rules (NewReviewSheetTests) -------------------------------------------------

    @Test func stepOneNeedsBothANameAndABranch() {
        #expect(!NewReviewSheet.canAdvance(step: 1, title: "", branch: "feat-x", creating: false))
        #expect(!NewReviewSheet.canAdvance(step: 1, title: "Review", branch: "", creating: false))
        #expect(NewReviewSheet.canAdvance(step: 1, title: "Review", branch: "feat-x", creating: false))
        #expect(!NewReviewSheet.canAdvance(step: 1, title: "   ", branch: "feat-x", creating: false), "whitespace is not a name")
        #expect(!NewReviewSheet.canAdvance(step: 1, title: "Review", branch: "  ", creating: false))
        #expect(!NewReviewSheet.canAdvance(step: 1, title: "Review", branch: "feat-x", creating: true))
    }

    @Test func theDestinationIsTheReviewsOwnWorktreeOnStepsOneAndThree() {
        let project = Project(name: "acme-web", path: "/p")
        #expect(NewReviewSheet.destination(step: 2, project: project, slug: "review-x", branch: "feat/x") == nil)
        #expect(NewReviewSheet.destination(step: 1, project: project, slug: "review-x", branch: "") == nil)
        #expect(NewReviewSheet.destination(step: 3, project: project, slug: "review-x", branch: "feat/x")?.text
                == "Opens in Shellforge · acme-web/.worktrees/review-x · feat/x")
    }

    @Test func eachHostNamesItsOwnRequests() {
        #expect(CodeHost.gitLab.reviewField == "Merge request (optional)")
        #expect(CodeHost.gitHub.reviewField == "Pull request (optional)")
        #expect(CodeHost.gitLab.reviewPlaceholder == "Search by !number, title or branch")
        #expect(CodeHost.gitHub.reviewPlaceholder == "Search by #number, title or branch")
        #expect(CodeHost.gitHub.reviewHint == "Select a pull request to fill in the name and branch.")
        #expect(CodeHost.gitHub.brand == Palette.github)
        #expect(CodeHost.gitLab.brand == Palette.gitlab)
    }
}

/// The keys, through a hosted sheet: two pickers and a footer share ⎋ and ↩.
@MainActor
@Suite(.serialized) struct NewReviewSheetKeyboardTests {
    private nonisolated static let first = MergeRequest(iid: 4, title: "Add gift card", sourceBranch: "feat-gift-card",
                                                        targetBranch: "main", author: "L", state: "opened", draft: false,
                                                        url: "https://git.example.net/x/-/merge_requests/4")
    private nonisolated static let second = MergeRequest(iid: 7, title: "Drop the legacy importer", sourceBranch: "chore-drop-importer",
                                                         targetBranch: "main", author: "S", state: "opened", draft: true,
                                                         url: "https://git.example.net/x/-/merge_requests/7")
    private static let mrPlaceholder = "Search by !number, title or branch"
    private static let branchPlaceholder = "Search branches"

    @MainActor private final class Created { var drafts: [ReviewDraft] = [] }
    private struct Refused: Error, LocalizedError { var errorDescription: String? { "Refused." } }

    private struct Harness {
        let model: ReviewCreationModel
        let host: NSHostingView<NewReviewSheet>
        let window: NSWindow
        let created: Created
    }

    /// Hosted and waited on by sleeping, so the sheet's own search and branch loads land.
    private func harness(step: Int = 1, title: String = "", branch: String = "",
                         mrOpen: Bool = true, branchOpen: Bool = false) async throws -> Harness {
        let created = Created()
        let opus = AgentModel(id: "opus", label: "Opus", detail: nil, efforts: [], defaultEffort: nil)
        let model = ReviewCreationModel(project: Project(name: "acme-web", path: "/tmp/p"), agents: AgentPresets.all, available: ["claude"],
                                        draft: ReviewDraft(mr: nil, agentId: "claude", model: "opus", reasoning: nil), rememberedModels: [:],
                                        catalogue: { _ in [opus] }, branches: { ["main", "feat-gift-card", "chore-drop-importer"] },
                                        codeHost: .gitLab, searchMergeRequests: { _ in [Self.first, Self.second] },
                                        submit: { draft in created.drafts.append(draft); throw Refused() },
                                        home: FileManager.default.temporaryDirectory.appendingPathComponent("rv-home-\(UUID().uuidString)"))
        if !title.isEmpty { model.draft.setTitle(title) }
        if !branch.isEmpty { model.draft.setBranch(branch) }
        model.listOpen = mrOpen
        model.branchListOpen = branchOpen
        let host = NSHostingView(rootView: NewReviewSheet(model: model, dismiss: {}).seeded(step: step))
        host.frame = NSRect(x: 0, y: 0, width: Sheet.width, height: Sheet.height)
        let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        // The sheet's own search, landed: the first hosted sheet of a run can take a while to.
        await eventually { model.results.count == 2 }
        try await pause()
        return Harness(model: model, host: host, window: window, created: created)
    }

    private func pause() async throws { try await Task.sleep(for: .milliseconds(200)) }

    private func field(_ placeholder: String, in host: NSView) -> NSTextField? {
        descendants(of: NSTextField.self, in: host).first { $0.placeholderString == placeholder }
    }

    private func send(_ selector: Selector, to field: NSTextField) -> Bool {
        field.delegate?.control?(field, textView: NSTextView(), doCommandBy: selector) ?? false
    }

    private func listIsOpen(_ placeholder: String, in host: NSView) -> Bool {
        guard let field = field(placeholder, in: host) else { return false }
        return send(#selector(NSResponder.moveDown(_:)), to: field)
    }

    private func press(_ characters: String, keyCode: UInt16, command: Bool = false, _ h: Harness) async throws {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: command ? [.command] : [], timestamp: 0,
                                     windowNumber: h.window.windowNumber, context: nil, characters: characters,
                                     charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
        _ = h.window.performKeyEquivalent(with: event)
        try await pause()
    }

    private func descendants<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        var matches = view.subviews.compactMap { $0 as? T }
        for subview in view.subviews { matches += descendants(of: type, in: subview) }
        return matches
    }

    /// ↓ then ⏎ on the merge-request field picks the highlighted request, which fills the review's
    /// name and its branch.
    @Test func arrowDownAndReturnSelectTheMergeRequestAndFillTheBranch() async throws {
        let h = try await harness()
        defer { h.window.orderOut(nil) }
        let field = try #require(self.field(Self.mrPlaceholder, in: h.host))
        #expect(self.field(Self.branchPlaceholder, in: h.host) != nil, "no branch picked yet")
        #expect(send(#selector(NSResponder.moveDown(_:)), to: field))
        #expect(send(#selector(NSResponder.insertNewline(_:)), to: field))
        try await pause()
        #expect(h.model.draft.mr == Self.second)
        #expect(h.model.draft.title == "Drop the legacy importer")
        #expect(h.model.draft.branch == "chore-drop-importer")
        #expect(self.field(Self.mrPlaceholder, in: h.host) == nil)
        #expect(self.field(Self.branchPlaceholder, in: h.host) == nil)
    }

    /// ⎋ closes the merge-request list first, then the branch list, and only then reaches the sheet.
    @Test func escapeClosesTheMergeRequestListBeforeTheBranchList() async throws {
        let h = try await harness(mrOpen: true, branchOpen: true)
        defer { h.window.orderOut(nil) }
        #expect(listIsOpen(Self.mrPlaceholder, in: h.host))
        #expect(listIsOpen(Self.branchPlaceholder, in: h.host))
        try await press("\u{1b}", keyCode: 53, h)
        #expect(!listIsOpen(Self.mrPlaceholder, in: h.host), "the merge-request list goes first")
        #expect(listIsOpen(Self.branchPlaceholder, in: h.host), "the branch list is still open")
        try await press("\u{1b}", keyCode: 53, h)
        #expect(!listIsOpen(Self.branchPlaceholder, in: h.host))
        #expect(self.field("Describe the review", in: h.host) != nil, "step 1 is still up")
        #expect(h.created.drafts.isEmpty)
    }

    /// With no list open, ⎋ is Back: one step back.
    @Test func escapeWithNoListOpenStepsBack() async throws {
        let h = try await harness(step: 2, title: "Review it", branch: "main", mrOpen: false)
        defer { h.window.orderOut(nil) }
        #expect(self.field("Describe the review", in: h.host) == nil, "step 2 is the agent step")
        try await press("\u{1b}", keyCode: 53, h)
        #expect(self.field("Describe the review", in: h.host) != nil, "⎋ went back to step 1")
    }

    /// Advancing closes a list left open, so one ⎋ on step 2 steps back.
    @Test func advancingClosesTheListsSoEscapeStepsBack() async throws {
        let h = try await harness(title: "Review it", branch: "main", mrOpen: true)
        defer { h.window.orderOut(nil) }
        try await press("\r", keyCode: 36, command: true, h)
        #expect(self.field("Describe the review", in: h.host) == nil, "⌘↩ went on to step 2")
        try await press("\u{1b}", keyCode: 53, h)
        #expect(self.field("Describe the review", in: h.host) != nil, "one ⎋ went back to step 1")
        #expect(!h.model.listOpen, "advancing closed the list")
    }

    /// A plain ↩ leaves step 1 up: the primary button answers ⌘↩ only.
    @Test func plainReturnDoesNotPressThePrimaryButton() async throws {
        let h = try await harness(title: "Review it", branch: "main", mrOpen: false)
        defer { h.window.orderOut(nil) }
        try await press("\r", keyCode: 36, h)
        #expect(self.field("Describe the review", in: h.host) != nil, "still step 1")
    }
}
