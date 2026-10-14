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

    /// Remove on a task continued outside `.worktrees/` asks only to forget it: no delete, no branch box.
    @Test func removingAnOutsideWorktreesTaskOnlyForgetsIt() async throws {
        let repo = try GitRepoForUI()
        let outside = (repo.path as NSString).deletingLastPathComponent + "/hand-made"
        try git(repo, "worktree", "add", "-q", "-b", "feat/hand", outside)
        let (model, _, document, prompter) = model(repo, answers: [AlertAnswer(button: 1), AlertAnswer(button: 0)])
        await model.addProject(folder: repo.path)  // skips the import
        let project = try #require(document.workspace.projects.first)
        let task = TaskItem(projectId: project.id, title: "hand", branch: "feat/hand", worktreePath: outside, baseBranch: "main")
        try document.update { $0.tasks.append(task) }
        #expect(await model.confirmRemove(taskId: task.id))
        let asked = try #require(prompter.asked.last)
        #expect(asked.detail == "Removes the task from Shellforge and closes its tabs. Its worktree stays where it is, on its branch:\n\n\(outside)")
        #expect(asked.checkbox == nil && !asked.defaultDeletes)
        #expect(document.workspace.tasks.isEmpty && FileManager.default.fileExists(atPath: outside))
    }

    /// The same worktree spelled two ways — /var and /private/var — is one, at save and at import.
    @Test func aWorktreeTakenUnderAnotherSpellingIsNotTakenTwice() async throws {
        let repo = try repo()
        let (model, _, document, _) = model(repo, answers: [AlertAnswer(button: 1)])
        await model.addProject(folder: repo.path)
        let project = try #require(document.workspace.projects.first)
        let sheet = try #require(model.makeNewTaskModel(for: project.id))
        await sheet.loadExistingWorktrees()
        let picked = try #require(sheet.kind.existing.first)
        let resolved = URL(fileURLWithPath: picked.path).resolvingSymlinksInPath().path
        let other = resolved.hasPrefix("/private/") ? String(resolved.dropFirst("/private".count)) : "/private" + resolved
        try #require(FileManager.default.fileExists(atPath: other), "this test needs a symlinked scratch folder")
        // Another window made a task of it, saved under the other spelling, after this sheet listed it.
        try document.update { $0.tasks.append(TaskItem(projectId: project.id, title: "theirs", branch: picked.branch, worktreePath: other, baseBranch: "main")) }
        var draft = TaskDraft(baseBranch: "main", agentId: "claude", model: "opus", reasoning: nil)
        draft.useExisting = true
        draft.pick(existing: picked)
        await #expect(throws: ExistingWorktrees.Refusal.taken(picked.branch)) { try await model.newTask(draft: draft, in: project.id) }
        #expect(document.workspace.tasks.count == 1)
    }

    /// The import reads the worktrees again once answered: one deleted meanwhile is not imported.
    @Test func theImportReadsTheWorktreesAgainOnceAnswered() async throws {
        let repo = try repo()
        try git(repo, "worktree", "add", "-q", "-b", "feat/second", repo.path + "/.worktrees/second")
        let (model, _, document, prompter) = model(repo, answers: [AlertAnswer(button: 0)])
        prompter.hold = true
        let adding = Task { await model.addProject(folder: repo.path) }
        await eventually { prompter.asked.count == 1 }
        try git(repo, "worktree", "remove", "--force", repo.path + "/.worktrees/second")
        prompter.hold = false
        prompter.release()
        await adding.value
        #expect(document.workspace.tasks.map(\.branch) == ["feat/resume"])
    }

    /// A worktree another window is adopting right now is refused here, before anything is written.
    @Test func aWorktreeBeingAdoptedElsewhereIsRefused() async throws {
        let repo = try repo()
        let (model, host, document, _) = model(repo, answers: [AlertAnswer(button: 1)])
        await model.addProject(folder: repo.path)
        let project = try #require(document.workspace.projects.first)
        let sheet = try #require(model.makeNewTaskModel(for: project.id))
        await sheet.loadExistingWorktrees()
        let picked = try #require(sheet.kind.existing.first)
        model.removalBoard.adopting.insert(ExistingWorktrees.resolved(picked.path))
        var draft = TaskDraft(baseBranch: "main", agentId: "claude", model: "opus", reasoning: nil)
        draft.useExisting = true
        draft.pick(existing: picked)
        await #expect(throws: ExistingWorktrees.Refusal.taken(picked.branch)) { try await model.newTask(draft: draft, in: project.id) }
        #expect(document.workspace.tasks.isEmpty && host.opened.isEmpty)
    }
}
