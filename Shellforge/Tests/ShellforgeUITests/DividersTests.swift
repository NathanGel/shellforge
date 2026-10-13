import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

/// Dividers in the sidebar, and projects moved past them.
@MainActor @Suite struct DividersTests {
    private func model() throws -> (SidebarModel, WorkspaceDocument, UUID, UUID) {
        let folder = TestScratch.root.appendingPathComponent("shellforge-dividers-\(UUID().uuidString)")
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

    /// With no projects, the empty state stands alone: no bare rules under it.
    @Test func withNoProjectsTheEmptyStateHasNoRules() throws {
        let folder = TestScratch.root.appendingPathComponent("shellforge-dividers-\(UUID().uuidString)")
        let document = WorkspaceDocument(store: WorkspaceStore(folder: folder))
        try document.update { $0.dividers = [SidebarDivider(name: "Work", position: 0)] }
        let launcher = CommandLauncher(resolve: { ResolvedEnvironment(variables: ["PATH": "/usr/bin"], source: .loginShell("/bin/zsh")) })
        let model = SidebarModel(host: FakeTerminalHost(), document: document, launcher: launcher, jiraSettings: { nil })
        #expect(model.rows == [.empty])
    }

    /// Each divider's ends come from its place among everything drawn: two at the top, one between.
    @Test func eachDividerKnowsItsEnds() throws {
        let (model, _, _, _) = try model()
        model.addDivider(name: "One")
        model.addDivider(name: "Two")
        let ends = model.rows.compactMap { if case .divider(let row) = $0 { [row.canMoveUp, row.canMoveDown] } else { nil } }
        #expect(ends == [[true, true], [true, false]])
    }

    /// VoiceOver gets the context menu's actions, those it can take now.
    @Test func voiceOverOffersTheMenusEnabledItems() throws {
        let divider = SidebarDivider(name: "Work", position: 0)
        #expect(DividerRow.voiceOverActions(DividerRowItem(divider: divider, canMoveUp: false, canMoveDown: true))
                == ["Rename", "Move Down", "Remove Divider"])
        #expect(DividerRow.voiceOverActions(DividerRowItem(divider: divider, canMoveUp: true, canMoveDown: true))
                == ["Rename", "Move Up", "Move Down", "Remove Divider"])
        #expect(TerminalRowView.voiceOverActions == ["Rename", "Remove Terminal"])
    }

    /// With no project a divider would divide nothing, and would not be drawn to remove again.
    @Test func addDividerNeedsAProject() throws {
        let folder = TestScratch.root.appendingPathComponent("shellforge-dividers-\(UUID().uuidString)")
        let document = WorkspaceDocument(store: WorkspaceStore(folder: folder))
        let launcher = CommandLauncher(resolve: { ResolvedEnvironment(variables: ["PATH": "/usr/bin"], source: .loginShell("/bin/zsh")) })
        let empty = SidebarModel(host: FakeTerminalHost(), document: document, launcher: launcher, jiraSettings: { nil })
        #expect(!empty.can(.addDivider))
        let (model, _, _, _) = try model()
        #expect(model.can(.addDivider))
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
