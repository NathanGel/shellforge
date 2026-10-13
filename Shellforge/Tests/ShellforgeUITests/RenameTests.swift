import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

/// AiTerm's Rename: a task's, a review's, a terminal's or a divider's name, and nothing else.
@MainActor @Suite struct RenameTests {
    private func model() throws -> (SidebarModel, WorkspaceDocument, TaskItem) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shellforge-rename-\(UUID().uuidString)")
        let document = WorkspaceDocument(store: WorkspaceStore(folder: folder))
        let project = Project(name: "api", path: "/api")
        let task = TaskItem(projectId: project.id, title: "Login", branch: "feat/login", worktreePath: "/api/.worktrees/login", baseBranch: "main")
        try document.update { $0.projects.append(project); $0.tasks.append(task) }
        let launcher = CommandLauncher(resolve: { ResolvedEnvironment(variables: ["PATH": "/usr/bin"], source: .loginShell("/bin/zsh")) })
        return (SidebarModel(host: FakeTerminalHost(), document: document, launcher: launcher, jiraSettings: { nil }), document, task)
    }

    @Test func aTaskKeepsItsBranchAndWorktree() throws {
        let (model, document, task) = try model()
        model.renameTask(task.id, to: "  Sign in ")
        let renamed = try #require(document.workspace.tasks.first)
        #expect(renamed.title == "Sign in")
        #expect(renamed.branch == "feat/login" && renamed.worktreePath == "/api/.worktrees/login" && renamed.baseBranch == "main")
    }

    @Test func anEmptyNameKeepsTheOld() throws {
        let (model, document, task) = try model()
        model.renameTask(task.id, to: "   ")
        #expect(document.workspace.tasks.first?.title == "Login")
    }

    @Test func theCopyIsAiTerms() {
        #expect(RenameCopy.task == RenameCopy(title: "Rename task", field: "Task name",
                                              subtitle: "The branch and worktree keep their names."), "a review's too, as in AiTerm")
        #expect(RenameCopy.terminal.subtitle == "Renames the row in the sidebar; its iTerm2 tabs keep their titles.")
        #expect(RenameCopy.divider.subtitle == "Changes the heading over the projects under it.")
    }
}
