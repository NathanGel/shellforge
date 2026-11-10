import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

/// The project menu’s Branch Names: saved on the project, and used by the New Task sheet for it.
@MainActor @Suite struct BranchFormatMenuTests {
    private func setup() throws -> (SidebarModel, WorkspaceDocument, Project, WorkspaceStore) {
        let folder = TestScratch.root.appendingPathComponent("shellforge-branch-format-\(UUID().uuidString)")
        let store = WorkspaceStore(folder: folder)
        let document = WorkspaceDocument(store: store)
        let project = Project(name: "jarvis", path: "/jarvis")
        try document.update { $0.projects.append(project) }
        let launcher = CommandLauncher(resolve: { ResolvedEnvironment(variables: ["PATH": "/usr/bin"], source: .loginShell("/bin/zsh")) })
        return (SidebarModel(host: FakeTerminalHost(), document: document, launcher: launcher, jiraSettings: { nil }), document, project, store)
    }

    @Test func theSetterPersistsAndOnlyForThatProject() throws {
        let (model, document, project, store) = try setup()
        model.setBranchFormat(.ticketKey, of: project.id)
        #expect(document.workspace.projects[0].branchFormat == .ticketKey)
        let reloaded = try store.load().workspace
        #expect(reloaded.projects[0].branchFormat == .ticketKey)
        model.setBranchFormat(.typeAndName, of: project.id)
        #expect(document.workspace.projects[0].branchFormat == .typeAndName)
    }

    @Test func theSheetOpensWithTheProjectsFormat() throws {
        let (model, _, project, _) = try setup()
        #expect(model.makeNewTaskModel(for: project.id)?.draft.branchFormat == .typeAndName)
        model.setBranchFormat(.ticketKey, of: project.id)
        #expect(model.makeNewTaskModel(for: project.id)?.draft.branchFormat == .ticketKey)
    }

    @Test func theMenuOffersBothFormatsAndMarksTheCurrent() {
        #expect(BranchFormat.allCases.map(\.menuTitle) == ["Type and Name", "Ticket Key Only"])
        #expect(ProjectHeaderRow.menuTitles(provider: .git, sshHost: nil, canOpenSSHHost: false, pullTitle: nil).contains("Branch Names"))
        #expect(ProjectHeaderRow.voiceOverBranchActions == ["Branch Names: Type and Name", "Branch Names: Ticket Key Only"])
    }
}
