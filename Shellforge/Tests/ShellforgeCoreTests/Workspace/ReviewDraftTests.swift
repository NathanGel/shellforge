// Ported from AiTerm (app/Tests/AiTermCoreTests/ReviewDraftTests.swift), GPLv3, Laurens D'Hondt.
import Testing
import Foundation
@testable import ShellforgeCore

@Suite struct ReviewDraftTests {
    let mr = MergeRequest(iid: 4, title: "Add gift card", sourceBranch: "feat-gift-card",
                          targetBranch: "main", author: "Sam Rivera", state: "opened", draft: false,
                          url: "https://git.example.net/web/acme-web/-/merge_requests/4")

    private func draft() -> ReviewDraft {
        ReviewDraft(mr: nil, agentId: "claude", model: "sonnet", reasoning: nil)
    }

    @Test func testPickingAMergeRequestFillsTheNameAndBranch() {
        var d = draft()
        d.apply(mr: mr)
        #expect(d.title == "Add gift card")
        #expect(d.branch == "feat-gift-card")
    }

    @Test func testHandEditedFieldsSurviveALaterPick() {
        var d = draft()
        d.setTitle("Second pass on the hero")
        d.apply(mr: mr)
        #expect(d.title == "Second pass on the hero")
        #expect(d.branch == "feat-gift-card")
    }

    /// A clickable `!4` chip above a branch that is not the merge request's source branch would be
    /// a lie that navigates somewhere, so editing the branch drops the merge request.
    @Test func testEditingTheBranchClearsTheMergeRequest() {
        var d = draft()
        d.apply(mr: mr)
        d.setBranch("feat-something-else")
        #expect(d.mr == nil)
        #expect(d.branch == "feat-something-else")
        #expect(d.title == "Add gift card")
    }

    /// SwiftUI writes a TextField's value back through its binding when editing begins and ends,
    /// not only when the text changes — so being handed the value it already holds must be a no-op
    /// or a click into another field would clear the merge request.
    @Test func testBeingHandedTheSameBranchIsANoOp() {
        var d = draft()
        d.apply(mr: mr)
        d.setBranch("feat-gift-card")
        #expect(d.mr == mr)
    }

    @Test func testClearingTheMergeRequestLeavesTheBranchAndName() {
        var d = draft()
        d.apply(mr: mr)
        d.apply(mr: nil)
        #expect(d.mr == nil)
        #expect(d.branch == "feat-gift-card")
        #expect(d.title == "Add gift card")
    }

    @Test func testReviewWorktreeDirectoryIsPrefixed() {
        #expect(BranchNaming.reviewSlug(branch: "feat/gift-card") == "review-gift-card")
        #expect(BranchNaming.reviewSlug(branch: "feat-gift-card") == "review-feat-gift-card")
    }
}
