import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

/// Dividers in the sidebar, and projects moved past them.
@MainActor @Suite struct DividersTests {
    private func model() throws -> (SidebarModel, WorkspaceDocument, UUID, UUID) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shellforge-dividers-\(UUID().uuidString)")
        let document = WorkspaceDocument(store: WorkspaceStore(folder: folder))
        let a = Project(name: "a", path: "/a"), b = Project(name: "b", path: "/b")
        try document.update { $0.projects += [a, b] }
        let launcher = CommandLauncher(resolve: { ResolvedEnvironment(variables: ["PATH": "/usr/bin"], source: .loginShell("/bin/zsh")) })
        return (SidebarModel(host: FakeTerminalHost(), document: document, launcher: launcher, jiraSettings: { nil }), document, a.id, b.id)
    }

    private func titles(_ model: SidebarModel) -> [String] {
        model.rows.compactMap { row in
            switch row {
            case .project(let node, _): node.project.name
            case .divider(let row): "—" + row.divider.name
            default: nil
            }
        }
    }

    @Test func aDividerIsAddedAtTheEnd() throws {
        let (model, document, _, _) = try model()
        model.addDivider(name: "  Work ")
        #expect(document.workspace.dividers.map(\.name) == ["Work"])
        #expect(titles(model) == ["a", "b", "—Work"])
    }

    @Test func dividersRenameMoveAndGo() throws {
        let (model, document, a, _) = try model()
        model.addDivider(name: "Work")
        let id = try #require(document.workspace.dividers.first).id
        model.move(.divider(id), up: true)
        #expect(titles(model) == ["a", "—Work", "b"])
        model.move(.project(a), up: false)
        #expect(titles(model) == ["—Work", "a", "b"], "a crossed the divider")
        model.renameDivider(id, to: "  ")
        #expect(document.workspace.dividers.first?.name == "", "an empty name is a plain rule")
        model.removeDivider(id)
        #expect(document.workspace.dividers.isEmpty)
    }

    @Test func theRowSaysWhichWayItCanMove() throws {
        let (model, document, _, _) = try model()
        model.addDivider(name: "End")
        let row = model.rows.compactMap { if case .divider(let row) = $0 { row } else { nil } }.first
        #expect(row?.canMoveUp == true && row?.canMoveDown == false)
        _ = document
    }

    @Test func addDividerIsACommand() throws {
        let (model, _, _, _) = try model()
        var requests: [SidebarSheetRequest] = []
        let subscription = model.sheetRequests.sink { requests.append($0) }
        model.perform(.addDivider)
        #expect(requests == [.addDivider])
        _ = subscription
    }
}
