// Ported from AiTerm (app/Tests/AiTermCoreTests/BranchTypeTests.swift), GPLv3, Laurens D'Hondt.
import Testing
@testable import ShellforgeCore

@Suite struct BranchTypeTests {
    /// Jira's own issue types, stock and common custom ones, land on the Conventional Commits type
    /// the work usually is. A Task is feature work in these projects, so it stays `feat`.
    @Test(arguments: [
        ("Bug", BranchType.fix), ("Defect", .fix), ("Incident", .fix), ("Production bug", .fix),
        ("Story", .feat), ("Epic", .feat), ("Task", .feat), ("Sub-task", .feat), ("Subtask", .feat),
        ("New Feature", .feat), ("Improvement", .feat),
        ("Chore", .chore), ("Maintenance", .chore), ("Tech Debt", .chore), ("Technical debt", .chore),
        ("Refactor", .chore), ("Documentation", .chore), ("Performance", .feat),
    ])
    func testAJiraIssueTypeMapsToABranchType(issueType: String, expected: BranchType) {
        #expect(BranchType(issueType: issueType) == expected)
    }

    @Test func testAnUnknownOrMissingIssueTypeIsAFeature() {
        #expect(BranchType(issueType: "Spike") == .feat)
        #expect(BranchType(issueType: nil) == .feat)
        #expect(BranchType(issueType: "") == .feat)
    }

    /// A branch typed or pasted whole splits into its type and the rest; an unknown prefix is not a
    /// type, so nothing splits and the caller keeps the text as the name.
    @Test func testABranchSplitsOnlyOnAKnownType() {
        #expect(BranchType.split("fix/shop-12-broken-link")! == (.fix, "shop-12-broken-link"))
        #expect(BranchType.split("chore/a/b")! == (.chore, "a/b"))
        #expect(BranchType.split("release/x") == nil)
        #expect(BranchType.split("refactor/x") == nil, "only feat, fix and chore are types")
        #expect(BranchType.split("feature-x") == nil)
        #expect(BranchType.split("FIX/x") == nil, "git branches are case-sensitive; FIX is not fix")
    }
}
