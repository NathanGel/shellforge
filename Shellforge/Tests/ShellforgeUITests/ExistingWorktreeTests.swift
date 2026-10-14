// Ported in part from AiTerm (app/Sources/AiTerm/ProjectActions.swift: importWorktrees), GPLv3, Laurens D'Hondt.
import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

/// New Task continued in a worktree that already exists, and Add Project's offer to import them.
@MainActor @Suite struct ExistingWorktreeTests {
    private func git(_ repo: GitRepoForUI, _ args: String...) throws {
        let out = try repo.launcher.run("git", ["-C", repo.path] + args)
        guard out.status == 0 else { throw GitFailure(command: "git", message: out.stderr) }
    }

    /// A repository with a worktree on `feat/resume`, not yet a task.
    private func repo() throws -> GitRepoForUI {
        let repo = try GitRepoForUI()
        try git(repo, "worktree", "add", "-q", "-b", "feat/resume", repo.path + "/.worktrees/resume")
        return repo
    }

    private func model(_ repo: GitRepoForUI, answers: [AlertAnswer] = []) -> (SidebarModel, FakeTerminalHost, WorkspaceDocument, ScriptedPrompter) {
        let document = WorkspaceDocument(store: WorkspaceStore(folder: TestScratch.root.appendingPathComponent("existing-\(UUID().uuidString)")))
        let host = FakeTerminalHost(), prompter = ScriptedPrompter(answers)
        let model = SidebarModel(host: host, document: document, launcher: repo.launcher, catalogue: { _ in [] }, jiraSettings: { nil })
        model.prompter = prompter
        return (model, host, document, prompter)
    }

    @Test func anExistingWorktreeBecomesATaskWithItsAgent() async throws {
        let repo = try repo()
        let (model, host, document, _) = model(repo, answers: [AlertAnswer(button: 1)])  // skip the import
        await model.addProject(folder: repo.path)
        let project = try #require(document.workspace.projects.first).id
        let sheet = try #require(model.makeNewTaskModel(for: project))
        await sheet.loadExistingWorktrees()
        #expect(sheet.kind.existing.map(\.branch) == ["feat/resume"])
        var draft = TaskDraft(baseBranch: "main", agentId: "claude", model: "opus", reasoning: nil)
        draft.useExisting = true
        draft.pick(existing: sheet.kind.existing[0])
        try await model.newTask(draft: draft, in: project)
        let task = try #require(document.workspace.tasks.first)
        #expect(task.title == "feat/resume" && task.branch == "feat/resume" && task.worktreePath.hasSuffix("/.worktrees/resume"))
        let opened = try #require(host.opened.last)
        #expect(opened.directory == task.worktreePath && opened.command == "claude --model opus")
        #expect(!FileManager.default.fileExists(atPath: repo.path + "/.worktrees/feat-resume"), "no new worktree")
        #expect(document.workspace.lastAgentByProject[project] == "claude")
    }

    @Test func stepOneNeedsAPickedWorktree() {
        let kind = TaskCreation()
        var draft = TaskDraft(baseBranch: "main", agentId: "claude", model: "opus", reasoning: nil)
        draft.useExisting = true
        #expect(!kind.firstStepDone(draft))
        draft.pick(existing: ExistingWorktree(path: "/r/.worktrees/x", branch: "feat/x", kind: .task, lastCommit: nil))
        #expect(kind.firstStepDone(draft))
        #expect(kind.slug(of: draft) == "", "no new worktree to name")
    }

    @Test func addingAProjectOffersItsWorktrees() async throws {
        let repo = try repo()
        try git(repo, "worktree", "add", "-q", "-b", "feat/second", repo.path + "/.worktrees/second")
        let (model, host, document, prompter) = model(repo, answers: [AlertAnswer(button: 0)])
        await model.addProject(folder: repo.path)
        let asked = try #require(prompter.asked.first)
        #expect(asked.message == "Import 2 worktrees?")
        #expect(asked.detail == "Adds existing worktrees as tasks without starting agents.")
        #expect(asked.buttons == ["Import", "Skip"] && asked.escapeButton == 1)
        #expect(Set(document.workspace.tasks.map(\.branch)) == ["feat/resume", "feat/second"])
        #expect(host.opened.isEmpty, "no agent started")
    }

    @Test func skippingImportsNothing() async throws {
        let repo = try repo()
        let (model, _, document, prompter) = model(repo, answers: [AlertAnswer(button: 1)])
        await model.addProject(folder: repo.path)
        #expect(prompter.asked.first?.message == "Import 1 worktree?")
        #expect(document.workspace.tasks.isEmpty && document.workspace.projects.count == 1)
    }

    @Test func noWorktreesAsksNothing() async throws {
        let repo = try GitRepoForUI()
        let (model, _, document, prompter) = model(repo)
        await model.addProject(folder: repo.path)
        #expect(prompter.asked.isEmpty && document.workspace.projects.count == 1)
    }

    /// Switching to Existing worktree picks the newest, and step 1 can go on; back to New worktree,
    /// the branch fields count again.
    @Test func choosingExistingPicksTheNewest() async throws {
        let repo = try repo()
        let (model, _, document, _) = model(repo, answers: [AlertAnswer(button: 1)])
        await model.addProject(folder: repo.path)
        let project = try #require(document.workspace.projects.first).id
        let sheet = try #require(model.makeNewTaskModel(for: project))
        await sheet.loadExistingWorktrees()
        sheet.chooseExisting(true)
        #expect(sheet.draft.existing?.branch == "feat/resume" && sheet.draft.title == "feat/resume")
        #expect(sheet.canAdvance(step: 1))
        let picked = try #require(sheet.draft.existing)
        #expect(ExistingWorktreeLabel.place(of: picked, in: sheet.project) == sheet.project.name + "/.worktrees/resume")
        sheet.chooseExisting(false)
        #expect(!sheet.draft.useExisting && sheet.draft.title == "", "the worktree's name goes with it")
        sheet.draft.setTitle("Login")
        #expect(sheet.kind.slug(of: sheet.draft) == "login")
        sheet.chooseExisting(true)
        #expect(sheet.draft.title == "Login", "a typed name stays")
    }
}
