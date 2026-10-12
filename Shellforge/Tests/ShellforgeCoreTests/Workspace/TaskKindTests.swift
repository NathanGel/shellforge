// Ported from AiTerm (app/Tests/AiTermCoreTests/ModelsTests.swift), GPLv3, Laurens D'Hondt.
import Foundation
import Testing
@testable import ShellforgeCore

/// A task can be a review of a merge request: what the workspace file keeps of that.
@Suite struct TaskKindTests {
    /// Workspaces saved before reviews existed stay readable without a migration.
    @Test func aTaskSavedWithoutKindOrMergeRequestIsATask() throws {
        let json = """
        {"id":"9F1C5B4E-3A2D-4C7F-8E10-2B6D9A0C1E33","projectId":"0A1B2C3D-4E5F-4071-8293-A4B5C6D7E8F9",
         "title":"Add gift card","branch":"feat/gift","worktreePath":"/tmp/wt","baseBranch":"main",
         "agent":"claude","model":"sonnet","createdAt":0}
        """
        let task = try JSONDecoder().decode(TaskItem.self, from: Data(json.utf8))
        #expect(task.kind == .task)
        #expect(task.mr == nil)
        #expect(task.kindName == "Task")
        // A task is saved with no kind, as every task always was.
        #expect(!String(decoding: try JSONEncoder().encode(task), as: UTF8.self).contains("\"kind\""))
    }

    @Test func aReviewRoundTripsWithItsMergeRequest() throws {
        let mr = MergeRequestRef(iid: 4, title: "Add gift card", url: "https://git.example.net/g/p/-/merge_requests/4")
        let task = TaskItem(projectId: UUID(), title: "Review gift card", branch: "feat-gift", worktreePath: "/tmp/wt",
                            baseBranch: "main", agent: "claude", model: "sonnet", kind: .review, mr: mr)
        let decoded = try JSONDecoder().decode(TaskItem.self, from: JSONEncoder().encode(task))
        #expect(decoded.kind == .review && decoded.kindName == "Review")
        #expect(decoded.mr == mr)
        #expect(decoded == task)
    }

    /// A kind a newer build saved reads as a task here, and is written back as it was.
    @Test func anUnknownKindReadsAsATaskAndIsKept() throws {
        let json = """
        {"id":"9F1C5B4E-3A2D-4C7F-8E10-2B6D9A0C1E33","projectId":"0A1B2C3D-4E5F-4071-8293-A4B5C6D7E8F9",
         "title":"t","branch":"b","worktreePath":"/tmp/wt","baseBranch":"main","kind":"someday","createdAt":0}
        """
        let task = try JSONDecoder().decode(TaskItem.self, from: Data(json.utf8))
        #expect(task.kind == .task)
        #expect(String(decoding: try JSONEncoder().encode(task), as: UTF8.self).contains("\"kind\":\"someday\""))
    }

    /// `TaskItem`'s Codable is written by hand: every field set, each comes back as it was.
    @Test func aTaskWithEveryFieldSetRoundTripsWhole() throws {
        let task = TaskItem(projectId: UUID(), title: "Review gift card", branch: "feat-gift", worktreePath: "/tmp/wt",
                            baseBranch: "develop", agent: "grok", model: "grok-4", reasoning: "high",
                            jira: JiraRef(key: "SHOP-1", summary: "Gift card", url: "https://x.atlassian.net/browse/SHOP-1"),
                            kind: .review, mr: MergeRequestRef(iid: 4, title: "Add gift card", url: "https://git.example.net/g/p/-/merge_requests/4"))
        #expect(try JSONDecoder().decode(TaskItem.self, from: JSONEncoder().encode(task)) == task)
    }
}
