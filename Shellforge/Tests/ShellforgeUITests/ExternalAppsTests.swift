import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI

/// AiTerm's Open in Finder and Open in VS Code: each row hands its own folder over — a project its
/// checkout, a task or review its worktree, a terminal its project's folder — and VS Code's items
/// are absent, not greyed, when it is not installed.
@Suite struct ExternalAppsTests {
    private let project = Project(name: "api", path: "/api")

    @Test func eachRowOpensItsOwnFolder() {
        let task = TaskItem(projectId: project.id, title: "Login", branch: "feat/login", worktreePath: "/api/.worktrees/login", baseBranch: "main")
        let terminal = TerminalItem(projectId: project.id, name: "logs")
        #expect(OpenIn.folder(of: .project(project)) == "/api")
        #expect(OpenIn.folder(of: .task(task)) == "/api/.worktrees/login")
        #expect(OpenIn.folder(of: .terminal(terminal, project: project)) == "/api")
        #expect(OpenIn.items(folder: "/api", vsCodeInstalled: true) == [
            OpenIn.Item(title: "Open in Finder", app: .finder, folder: "/api"),
            OpenIn.Item(title: "Open in VS Code", app: .vsCode, folder: "/api"),
        ])
    }

    /// A row with no folder offers no Open in: Finder would open at /.
    @Test func anEmptyFolderOffersNoOpenIn() {
        #expect(OpenIn.items(folder: "", vsCodeInstalled: true).isEmpty)
    }

    @Test func vsCodeItemsAreAbsentWithoutIt() {
        #expect(OpenIn.items(folder: "/api", vsCodeInstalled: false).map(\.title) == ["Open in Finder"])
    }
}
