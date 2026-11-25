import Foundation
import Testing
@testable import ShellforgeCore

/// A Custom branch-name pattern: tokens filled from the task, a token with nothing to say dropping
/// with one separator beside it.
@Suite struct BranchPatternTests {
    private func render(_ pattern: String, _ type: BranchType = .feat, key: String? = "ABC-123", summary: String = "Add login page") -> String {
        BranchPattern.render(pattern, type: type, key: key, summary: summary)
    }

    @Test func tokensAreFilledFromTheTask() {
        #expect(render("{KEY}") == "ABC-123")
        #expect(render("{KEY}-{slug}") == "ABC-123-add-login-page")
        #expect(render("{type}/{key}-{slug}", .fix) == "fix/abc-123-add-login-page")
        #expect(render("feature/{KEY}") == "feature/ABC-123")
        #expect(render("{key}_{slug}") == "abc-123_add-login-page")
    }

    /// The presets give what the two fixed formats give today.
    @Test func thePresetsMatchTodaysBranches() {
        #expect(render(BranchPattern.typeAndName) == "feat/abc-123-add-login-page")
        #expect(render(BranchPattern.typeAndName, key: nil) == "feat/add-login-page")
        #expect(render(BranchPattern.typeAndName, summary: "登录") == "feat/abc-123")
        #expect(render(BranchPattern.ticketKey) == "ABC-123")
    }

    /// No ticket: the key drops with the separator after it, else the one before.
    @Test func anEmptyTokenDropsWithOneSeparator() {
        #expect(render("{KEY}-{slug}", key: nil) == "add-login-page")
        #expect(render("{slug}-{KEY}", key: nil) == "add-login-page")
        #expect(render("{type}/{KEY}/{slug}", key: nil) == "feat/add-login-page")
    }

    /// Nothing names the work: no branch at all, never a bare literal or a type alone.
    @Test func withoutAnyNameTheBranchIsEmpty() {
        #expect(render("{KEY}", key: nil).isEmpty)
        #expect(render("{type}/{key}-{slug}", key: nil, summary: "登录").isEmpty)
        #expect(render("feature/{KEY}", key: nil).isEmpty)
        #expect(render("feature/x").isEmpty)
    }

    /// A `.` drops like any separator, and a result git would still refuse is no branch, so New Task
    /// falls back to Type and Name rather than failing to create.
    @Test func aBranchGitWouldRefuseIsNoBranch() {
        #expect(render("{KEY}.{slug}", key: nil) == "add-login-page")
        #expect(render("{slug}.{KEY}", summary: "登录") == "ABC-123")
        #expect(render("{KEY}..{slug}").isEmpty)
        #expect(render("{KEY}/.{slug}", key: nil) == "add-login-page")
        #expect(render("{KEY}~{slug}").isEmpty)
        // A separator left at either end goes too: git refuses a branch starting with `-`.
        #expect(render("{KEY}--{slug}", key: nil) == "add-login-page")
        #expect(render("{slug}__{KEY}", key: nil) == "add-login-page")
        #expect(BranchPattern.problem("-{KEY}") == "A branch name can’t start with - or end in .lock, start or end with / or ., or hold //.")
        #expect(BranchPattern.problem("{KEY}.lock/{slug}") != nil)
        // Only an end an empty token left is trimmed; the pattern's own text stays.
        #expect(render("_wip/{KEY}") == "_wip/ABC-123")
        #expect(render("{KEY}-") == "ABC-123-")
        // Git takes any text but control characters; only the slug is kept to ASCII.
        #expect(BranchPattern.problem("élodie/{KEY}") == nil)
        #expect(render("élodie/{KEY}") == "élodie/ABC-123")
    }

    @Test func aPatternNeedsANameToken() {
        #expect(BranchPattern.namesTheWork("{KEY}"))
        #expect(BranchPattern.namesTheWork("{type}/{slug}"))
        #expect(!BranchPattern.namesTheWork("{type}/wip"))
        #expect(BranchPattern.hasType("{type}/{KEY}") && !BranchPattern.hasType("{KEY}"))
    }

    /// What the Custom sheet says is wrong with a pattern; nil when it gives git a branch.
    @Test func aPatternGitWouldRefuseSaysWhy() {
        #expect(BranchPattern.problem("{KEY}-{slug}") == nil)
        #expect(BranchPattern.problem("feature/{KEY}") == nil)
        #expect(BranchPattern.problem("") == "Type a pattern.")
        #expect(BranchPattern.problem("{type}/wip") == "Use {key}, {KEY} or {slug}, so each task gets its own branch.")
        #expect(BranchPattern.problem("{KEY} {slug}") == "Git doesn’t allow spaces, ~ ^ : ? * [ \\ or .. in a branch name.")
        #expect(BranchPattern.problem("{ticket}-{slug}") == "{ticket} isn’t a token: use {type}, {key}, {KEY} or {slug}.")
        #expect(BranchPattern.problem("/{KEY}") == "A branch name can’t start with - or end in .lock, start or end with / or ., or hold //.")
        #expect(BranchPattern.problem("{KEY}.lock") == "A branch name can’t start with - or end in .lock, start or end with / or ., or hold //.")
    }
}
