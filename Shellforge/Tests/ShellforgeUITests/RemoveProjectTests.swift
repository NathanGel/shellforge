// Ported from AiTerm (app/Sources/AiTerm/ProjectActions.swift: confirmRemove), GPLv3, Laurens D'Hondt.
import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

/// Remove Project…: asked first, refused while something is still being made or removed in it, and
/// then only forgotten — its tasks and terminals go from the sidebar, files and tabs stay.
@MainActor @Suite struct RemoveProjectTests {
    @MainActor private struct Setup {
        let model: SidebarModel, document: WorkspaceDocument, host: FakeTerminalHost, prompter: ScriptedPrompter
        let a: Project, b: Project, task: TaskItem, terminal: TerminalItem
    }

    private func setup(_ answers: [AlertAnswer]) throws -> Setup {
        let folder = TestScratch.root.appendingPathComponent("shellforge-remove-project-\(UUID().uuidString)")
        let document = WorkspaceDocument(store: WorkspaceStore(folder: folder))
        let a = Project(name: "api", path: "/api"), b = Project(name: "web", path: "/web")
        let task = TaskItem(projectId: a.id, title: "Fix login", branch: "fix-login", worktreePath: "/api-worktrees/fix-login", baseBranch: "main")
        let terminal = TerminalItem(projectId: a.id, name: "Terminal")
        let other = TaskItem(projectId: b.id, title: "Docs", branch: "docs", worktreePath: "/web-worktrees/docs", baseBranch: "main")
        try document.update { w in
            w.projects += [a, b]; w.tasks += [task, other]; w.terminals.append(terminal)
            w.lastAgentByProject[a.id] = "claude"; w.lastOpenSSHByProject[a.id] = true
        }
        let launcher = CommandLauncher(resolve: { ResolvedEnvironment(variables: ["PATH": "/usr/bin"], source: .loginShell("/bin/zsh")) })
        let host = FakeTerminalHost(), prompter = ScriptedPrompter(answers)
        let model = SidebarModel(host: host, document: document, launcher: launcher, jiraSettings: { nil })
        model.prompter = prompter
        host.openTab(in: task.worktreePath, taskId: task.id, projectId: a.id, title: "claude", command: nil, environment: [:])
        return Setup(model: model, document: document, host: host, prompter: prompter, a: a, b: b, task: task, terminal: terminal)
    }

    private static let remove = AlertAnswer(button: 0)

    @Test func removingAProjectForgetsItAndItsTasksAndTerminals() async throws {
        let s = try setup([Self.remove])
        #expect(await s.model.confirmRemove(project: s.a.id))
        let w = s.document.workspace
        #expect(w.projects.map(\.name) == ["web"])
        #expect(w.tasks.map(\.title) == ["Docs"])
        #expect(w.terminals.isEmpty)
        #expect(w.lastAgentByProject[s.a.id] == nil && w.lastOpenSSHByProject[s.a.id] == nil)
        // Tabs stay open, and fall under Other tabs.
        #expect(s.host.closed.isEmpty && s.host.closedTasks.isEmpty)
        #expect(s.model.tree.otherTabs.map(\.taskId) == [s.task.id])
    }

    @Test func theAlertListsTheWorktreesKept() async throws {
        let s = try setup([AlertAnswer(button: 1)])
        #expect(await s.model.confirmRemove(project: s.a.id) == false)
        let asked = try #require(s.prompter.asked.first)
        #expect(asked.message == "Remove project “api”?")
        #expect(asked.detail == "Removes the project, tasks, and terminals from Shellforge. Files and tabs are kept, including these worktrees:\n\n/api-worktrees/fix-login")
        #expect(asked.buttons == ["Remove", "Cancel"] && asked.escapeButton == 1 && !asked.defaultDeletes)
    }

    @Test func aProjectWithNoTasksSaysOnlyFilesAndTabsStay() async throws {
        let s = try setup([AlertAnswer(button: 1)])
        _ = await s.model.confirmRemove(project: s.b.id)
        let asked = try #require(s.prompter.asked.first)
        #expect(asked.detail == "Removes the project, tasks, and terminals from Shellforge. Files and tabs are kept, including these worktrees:\n\n/web-worktrees/docs")
        try s.document.update { $0.tasks.removeAll { $0.projectId == s.b.id } }
        _ = await s.model.confirmRemove(project: s.b.id)
        #expect(s.prompter.asked.last?.detail == "Removes the project from Shellforge. Files are kept and tabs stay open.")
    }

    @Test func cancelKeepsEverything() async throws {
        let s = try setup([AlertAnswer(button: 1)])
        let before = s.document.workspace
        #expect(await s.model.confirmRemove(project: s.a.id) == false)
        #expect(s.document.workspace == before)
    }

    @Test func aBusyProjectIsNotRemoved() async throws {
        let s = try setup([Self.remove, Self.remove])
        s.model.removalBoard.creating[s.a.id] = 1
        #expect(await s.model.confirmRemove(project: s.a.id) == false)
        #expect(s.prompter.asked.map(\.message) == ["“api” can’t be removed yet"])
        #expect(s.prompter.asked.last?.detail == "A task is still being created in it. Try again in a moment.")
        s.model.removalBoard.creating[s.a.id] = nil
        s.model.removalBoard.removals[s.task.id] = .removing
        #expect(await s.model.confirmRemove(project: s.a.id) == false)
        #expect(s.prompter.asked.last?.detail == "A task is still being removed. Try again in a moment.")
        #expect(s.document.workspace.projects.count == 2)
    }

    /// Asked again once answered: a create started while the alert was up refuses it.
    @Test func workStartedWhileAskingStopsTheRemoval() async throws {
        let s = try setup([Self.remove])
        s.prompter.hold = true
        async let removed = s.model.confirmRemove(project: s.a.id)
        await eventually { s.prompter.asked.count == 1 }
        s.model.removalBoard.creating[s.a.id] = 1
        s.prompter.hold = false
        s.prompter.release()
        #expect(await removed == false)
        #expect(s.prompter.asked.last?.message == "“api” can’t be removed yet")
        #expect(s.document.workspace.projects.count == 2)
    }

    /// A task made and saved while the alert was up was never listed: the removal stops, and says so.
    @Test func aTaskAddedWhileAskingStopsTheRemoval() async throws {
        let s = try setup([Self.remove])
        s.prompter.hold = true
        async let removed = s.model.confirmRemove(project: s.a.id)
        await eventually { s.prompter.asked.count == 1 }
        let late = TaskItem(projectId: s.a.id, title: "Late", branch: "late", worktreePath: "/api-worktrees/late", baseBranch: "main")
        try s.document.update { $0.tasks.append(late) }
        s.prompter.hold = false
        s.prompter.release()
        #expect(await removed == false)
        #expect(s.prompter.asked.last?.detail == "A task was added to it while you were asked. Try again in a moment.")
        #expect(s.document.workspace.projects.count == 2)
    }

    /// Dividers count the projects above them: one below the removed project moves up one, one
    /// above it stays.
    @Test func dividersKeepTheirPlace() async throws {
        let s = try setup([Self.remove])
        let above = SidebarDivider(name: "Top", position: 0), below = SidebarDivider(name: "Bottom", position: 1)
        let end = SidebarDivider(name: "End", position: 2)
        try s.document.update { $0.dividers = [above, below, end] }
        #expect(await s.model.confirmRemove(project: s.a.id))
        #expect(s.document.workspace.dividers.map(\.position) == [0, 0, 1])
    }

    @Test func removingAProjectForgetsItsCaches() async throws {
        let s = try setup([Self.remove])
        await eventually { s.model.providers[s.a.id] != nil }
        s.model.defaultBranches[s.a.id] = "main"
        #expect(await s.model.confirmRemove(project: s.a.id))
        #expect(s.model.providers[s.a.id] == nil && s.model.defaultBranches[s.a.id] == nil)
    }

    /// A New Task or New Review submitted after its project went, in another window, says so
    /// rather than closing as if it were made.
    @Test func aCreateInARemovedProjectSaysSo() async throws {
        let s = try setup([])
        let gone = UUID()
        await #expect(throws: ProjectGone()) {
            try await s.model.newTask(draft: TaskDraft(baseBranch: "main", agentId: "claude", model: "", reasoning: nil), in: gone)
        }
        await #expect(throws: ProjectGone()) {
            try await s.model.newReview(draft: ReviewDraft(mr: nil, agentId: "claude", model: "", reasoning: nil), in: gone)
        }
        #expect(ProjectGone().errorDescription == "The project was removed.")
    }

    @Test func aFailedCreateLeavesTheProjectRemovable() async throws {
        let s = try setup([])
        await #expect(throws: (any Error).self) {
            try await s.model.newTask(draft: TaskDraft(baseBranch: "main", agentId: "claude", model: "", reasoning: nil), in: s.a.id)
        }
        #expect(s.model.removalBoard.creating[s.a.id, default: 0] == 0)
    }
}
