// Ported from AiTerm (app/Tests/AiTermTests/AlertPromptTests.swift and TaskRemoverTests), GPLv3, Laurens D'Hondt.
import Foundation
import Testing
@testable import ShellforgeTestSupport
@testable import ShellforgeCore
@testable import ShellforgeUI

/// Answers each question from a script, and records what was asked. A held answer waits until the
/// test lets it go.
@MainActor final class ScriptedPrompter: Prompter {
    var answers: [AlertAnswer]
    private(set) var asked: [AlertPrompt] = []
    var hold = false
    private var held: CheckedContinuation<Void, Never>?

    init(_ answers: [AlertAnswer]) { self.answers = answers }

    func ask(_ prompt: AlertPrompt) async -> AlertAnswer {
        asked.append(prompt)
        if hold { await withCheckedContinuation { held = $0 } }
        return answers.isEmpty ? AlertAnswer(button: prompt.escapeButton ?? 0) : answers.removeFirst()
    }

    func release() { held?.resume(); held = nil }
}

/// The person's Remove, as AiTerm's `TaskRemover` takes it: asked first, uncommitted work asked
/// about before anything closes, the task's tabs closed before git deletes its worktree, a branch
/// with commits its base lacks kept until the person agrees to lose them, and the row gone last.
@MainActor @Suite(.serialized) struct TaskRemoverTests {
    private let folder = TestScratch.root.appendingPathComponent("shellforge-remove-\(UUID().uuidString)")

    @MainActor private struct Setup {
        let sidebar: SidebarModel, host: FakeTerminalHost, prompter: ScriptedPrompter
        let repo: GitRepoForUI, document: WorkspaceDocument, task: TaskItem
        func git(_ args: String..., in dir: String? = nil) throws -> String {
            let out = try repo.launcher.run("git", ["-C", dir ?? repo.path] + args)
            guard out.status == 0 else { throw GitFailure(command: "git", message: out.stderr) }
            return out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func branchExists() throws -> Bool { !(try git("for-each-ref", "--format=%(refname)", "refs/heads/" + task.branch)).isEmpty }
        var row: TaskItem? { document.workspace.tasks.first { $0.id == task.id } }
    }

    private func setup(_ answers: [AlertAnswer]) async throws -> Setup {
        let repo = try GitRepoForUI()
        let document = WorkspaceDocument(store: WorkspaceStore(folder: folder))
        let host = FakeTerminalHost(), prompter = ScriptedPrompter(answers)
        let sidebar = SidebarModel(host: host, document: document, launcher: repo.launcher, jiraSettings: { nil })
        sidebar.prompter = prompter
        await sidebar.addProject(folder: repo.path)
        let project = try #require(document.workspace.projects.first)
        let task = try TaskWorktrees.create(title: "Fix login", in: project, base: "main", launcher: repo.launcher)
        try document.update { $0.tasks.append(task) }
        host.openTab(in: task.worktreePath, taskId: task.id, projectId: project.id, title: "claude", command: nil, environment: [:])
        return Setup(sidebar: sidebar, host: host, prompter: prompter, repo: repo, document: document, task: task)
    }

    private static let remove = AlertAnswer(button: 0), cancel = AlertAnswer(button: 1)
    private static let removeAndBranch = AlertAnswer(button: 0, checked: true)

    @Test func theRemoveAlertHasARedDefaultAndCancelOnEscape() async throws {
        let s = try await setup([])
        #expect(await s.sidebar.confirmRemove(taskId: s.task.id) == false, "⎋ cancels")
        let asked = try #require(s.prompter.asked.first)
        #expect(asked.message == "Remove task “Fix login”?")
        #expect(asked.detail == "Deletes the worktree and closes its tabs:\n\n\(s.task.worktreePath)")
        #expect(asked.buttons == ["Remove", "Cancel"])
        #expect(asked.checkbox == "Also delete branch \(s.task.branch)")
        #expect(asked.defaultDeletes && asked.escapeButton == 1)
        #expect(s.row != nil && s.host.closedTasks.isEmpty)
    }

    /// Close Tab on a task's last tab: once Remove is confirmed, that tab closes as iTerm2's Close
    /// Tab does — a running job asks — before the rest of the removal.
    @Test func aRemoveFromCloseTabClosesThatTabAsCloseTabDoes() async throws {
        let s = try await setup([Self.remove])
        let tab = try #require(s.host.tabs.first).id
        #expect(await s.sidebar.confirmRemove(taskId: s.task.id, closingFirst: tab))
        #expect(s.host.closed == [tab])
        #expect(s.row == nil)
    }

    /// From Close Pane in a shared tab: the removal closes that pane, not the tab around it.
    @Test func aRemoveFromClosePaneClosesOnlyThePane() async throws {
        let s = try await setup([Self.remove])
        let tab = try #require(s.host.tabs.first).id
        s.host.tabs[0].paneCount = 2
        #expect(await s.sidebar.confirmRemove(taskId: s.task.id, closingFirst: tab, paneOnly: true))
        #expect(s.host.closedPanes == [tab] && s.host.closed.isEmpty)
    }

    /// The running job's alert answered Cancel: nothing is removed, and the row stays as it was.
    @Test func aTabThatWillNotCloseStopsTheRemove() async throws {
        let s = try await setup([Self.remove])
        let tab = try #require(s.host.tabs.first).id
        s.host.refusesClose = true
        #expect(await s.sidebar.confirmRemove(taskId: s.task.id, closingFirst: tab) == false)
        #expect(FileManager.default.fileExists(atPath: s.task.worktreePath))
        #expect(s.row != nil && s.sidebar.removals[s.task.id] == nil)
    }

    @Test func removingATaskClosesItsTabsThenDeletesItsWorktreeAndRow() async throws {
        let s = try await setup([Self.remove])
        #expect(await s.sidebar.confirmRemove(taskId: s.task.id))
        #expect(s.host.closedTasks == [s.task.id])
        #expect(s.host.tabs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: s.task.worktreePath))
        #expect(try s.branchExists(), "the branch stays unless asked for")
        #expect(s.row == nil)
        #expect(s.sidebar.removals[s.task.id] == nil)
    }

    @Test func alsoDeletingTheBranchDeletesAMergedOne() async throws {
        let s = try await setup([Self.removeAndBranch])
        #expect(await s.sidebar.confirmRemove(taskId: s.task.id))
        #expect(try !s.branchExists())
    }

    @Test func cancelChangesNothing() async throws {
        let s = try await setup([Self.cancel])
        #expect(await s.sidebar.confirmRemove(taskId: s.task.id) == false)
        #expect(FileManager.default.fileExists(atPath: s.task.worktreePath))
        #expect(s.row != nil && s.host.closedTasks.isEmpty)
    }

    @Test func uncommittedChangesAskBeforeAnythingCloses() async throws {
        let s = try await setup([Self.remove, AlertAnswer(button: 0)])
        let file = s.task.worktreePath + "/notes.txt"
        try "draft".write(toFile: file, atomically: true, encoding: .utf8)

        #expect(await s.sidebar.confirmRemove(taskId: s.task.id) == false)
        let unsaved = try #require(s.prompter.asked.last)
        #expect(unsaved.message == "The worktree has uncommitted changes")
        #expect(unsaved.buttons == ["Keep Task", "Delete Changes and Remove"] && unsaved.escapeButton == 0)
        #expect(s.host.closedTasks.isEmpty, "nothing closes before the answer")
        #expect(FileManager.default.fileExists(atPath: file))
        #expect(s.row != nil && s.sidebar.removals[s.task.id] == nil)

        s.prompter.answers = [Self.remove, AlertAnswer(button: 1)]
        #expect(await s.sidebar.confirmRemove(taskId: s.task.id))
        #expect(!FileManager.default.fileExists(atPath: s.task.worktreePath))
        #expect(s.row == nil)
    }

    @Test func anUnmergedBranchAsksBeforeItsCommitsGo() async throws {
        let s = try await setup([Self.removeAndBranch, AlertAnswer(button: 0)])
        _ = try s.git("commit", "-q", "--allow-empty", "-m", "work", in: s.task.worktreePath)

        #expect(await s.sidebar.confirmRemove(taskId: s.task.id))
        let asked = try #require(s.prompter.asked.last)
        #expect(asked.message == "Delete branch \(s.task.branch)?")
        #expect(asked.detail == "It has commits that aren’t on main. Deleting the branch deletes them too.")
        // Asked straight after Remove, so ↩ pressed twice must not lose commits: keeping is the
        // default, on ↩ and ⎋ both, and deleting the plain grey button beside it.
        #expect(asked.buttons == ["Keep Branch", "Delete Branch"] && !asked.defaultDeletes && asked.escapeButton == 0)
        #expect(s.row == nil, "Keep Branch still removes the task")
        #expect(try s.branchExists())

        // A second task, its branch's commits given up.
        let project = try #require(s.document.workspace.projects.first)
        let second = try TaskWorktrees.create(title: "Fix logout", in: project, base: "main", launcher: s.repo.launcher)
        try s.document.update { $0.tasks.append(second) }
        _ = try s.git("commit", "-q", "--allow-empty", "-m", "work", in: second.worktreePath)
        s.prompter.answers = [Self.removeAndBranch, AlertAnswer(button: 1)]
        #expect(await s.sidebar.confirmRemove(taskId: second.id))
        #expect(try s.git("for-each-ref", "--format=%(refname)", "refs/heads/" + second.branch).isEmpty)
    }

    @Test func aSecondRemoveWhileOneRunsDoesNothing() async throws {
        let s = try await setup([Self.cancel])
        s.prompter.hold = true
        let first = Task { await s.sidebar.confirmRemove(taskId: s.task.id) }
        while s.prompter.asked.isEmpty { await Task.yield() }
        #expect(await s.sidebar.confirmRemove(taskId: s.task.id) == false)
        #expect(s.prompter.asked.count == 1, "the second Remove asks nothing")
        s.prompter.release()
        #expect(await first.value == false)
    }

    /// Every window has a sidebar of its own over the one workspace: a Remove in one window is the
    /// task's only Remove, and every window's row says what it left.
    @Test func oneRemovalAtATimeAcrossWindows() async throws {
        let s = try await setup([Self.remove])
        s.host.closesTabs = false
        let other = SidebarModel(host: FakeTerminalHost(), document: s.document, launcher: s.repo.launcher, jiraSettings: { nil })
        let otherPrompter = ScriptedPrompter([Self.remove])
        other.prompter = otherPrompter

        s.prompter.hold = true
        let first = Task { await s.sidebar.confirmRemove(taskId: s.task.id) }
        while s.prompter.asked.isEmpty { await Task.yield() }
        #expect(await other.confirmRemove(taskId: s.task.id) == false)
        #expect(otherPrompter.asked.isEmpty, "the other window's Remove asks nothing")
        s.prompter.release()
        #expect(await first.value == false)
        #expect(other.removals[s.task.id] == .stopped("Not removed: its tabs did not close"))
    }

    @Test func tabsThatWillNotCloseStopTheRemoval() async throws {
        let s = try await setup([Self.remove])
        s.host.closesTabs = false
        #expect(await s.sidebar.confirmRemove(taskId: s.task.id) == false)
        #expect(FileManager.default.fileExists(atPath: s.task.worktreePath))
        #expect(s.row != nil)
        #expect(s.sidebar.removals[s.task.id] == .stopped("Not removed: its tabs did not close"))
        #expect(s.sidebar.lastError == "Couldn’t remove the task. Its tabs did not close, so nothing was deleted.")
    }

    /// The row says "Removing…" while one runs, and why the last one stopped, in amber.
    @Test func theRowSaysWhatItsRemovalIsDoing() {
        #expect(TaskRowView.caption(nil) == nil)
        #expect(TaskRowView.caption(.removing)?.text == "Removing…" && TaskRowView.caption(.removing)?.warns == false)
        #expect(TaskRowView.caption(.stopped("Not removed"))?.text == "Not removed" && TaskRowView.caption(.stopped("Not removed"))?.warns == true)
    }

    /// git refusing the removal itself: the row stays, says so, and the banner gives git's reason.
    @Test func aRefusedRemovalKeepsTheRowAndSaysWhy() async throws {
        let s = try await setup([Self.remove])
        // A worktree git cannot delete: its folder's parent is read-only.
        let parent = (s.task.worktreePath as NSString).deletingLastPathComponent
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent) }

        #expect(await s.sidebar.confirmRemove(taskId: s.task.id) == false)
        #expect(s.row != nil)
        #expect(s.sidebar.removals[s.task.id] == .stopped("Not removed"))
        #expect(s.sidebar.lastError?.hasPrefix("Couldn’t remove the task.") == true, "\(s.sidebar.lastError ?? "nil")")
    }

    // -- reviews -----------------------------------------------------------------------------

    /// A merge request's branch checked out as a review in the setup's repository, its origin a
    /// bare repository holding the branch.
    private func review(in s: Setup) throws -> TaskItem {
        let remote = (s.repo.path as NSString).deletingLastPathComponent + "/remote.git"
        _ = try s.git("init", "-q", "--bare", remote)
        _ = try s.git("remote", "add", "origin", remote)
        _ = try s.git("branch", "feat/mr-branch")
        _ = try s.git("push", "-q", "origin", "main", "feat/mr-branch")
        _ = try s.git("branch", "-q", "-D", "feat/mr-branch")
        let project = try #require(s.document.workspace.projects.first)
        var draft = ReviewDraft(mr: nil, agentId: "claude", model: "opus", reasoning: nil)
        draft.setTitle("Gift card"); draft.setBranch("feat/mr-branch")
        let review = try ReviewWorktrees.create(draft: draft, in: project, launcher: s.repo.launcher)
        try s.document.update { $0.tasks.append(review) }
        return review
    }

    /// A review's branch is the merge request's: its Remove never offers to delete it, and says so.
    @Test func aReviewIsNeverOfferedItsBranch() async throws {
        let s = try await setup([Self.cancel])
        let review = try review(in: s)
        #expect(await s.sidebar.confirmRemove(taskId: review.id) == false)
        let asked = try #require(s.prompter.asked.last)
        #expect(asked.message == "Remove review “Gift card”?")
        #expect(asked.detail == "Deletes the worktree and closes its tabs. Its local branch goes too, unless it has commits origin lacks:\n\n\(review.worktreePath)")
        #expect(asked.checkbox == nil)
    }

    /// Unpushed fixes keep the review's branch; the review still goes, and the banner says why.
    @Test func removingAReviewKeepsAnUnpushedBranchAndSaysWhy() async throws {
        let s = try await setup([Self.remove])
        let review = try review(in: s)
        _ = try s.git("commit", "-q", "--allow-empty", "-m", "fix", in: review.worktreePath)
        #expect(await s.sidebar.confirmRemove(taskId: review.id))
        #expect(s.document.workspace.tasks.contains { $0.id == review.id } == false)
        #expect(!(try s.git("for-each-ref", "--format=%(refname)", "refs/heads/feat/mr-branch")).isEmpty)
        #expect(s.sidebar.lastError == "Branch feat/mr-branch kept: 1 commit not on origin.")
    }

    /// A pushed review's local branch goes with it, quietly.
    @Test func removingAPushedReviewReleasesItsBranch() async throws {
        let s = try await setup([Self.remove])
        let review = try review(in: s)
        #expect(await s.sidebar.confirmRemove(taskId: review.id))
        #expect(try s.git("for-each-ref", "--format=%(refname)", "refs/heads/feat/mr-branch").isEmpty)
        #expect(s.sidebar.lastError == nil)
    }
}
