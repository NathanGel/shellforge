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
        let project = Project(name: "demo", path: "/demo")
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
    }

    /// Branch Names comes after the SSH host’s own items, which stay together, and before Pull.
    @Test func branchNamesFollowsTheSSHHostItemsAndPrecedesPull() {
        let titles = ProjectHeaderRow.menuTitles(provider: .gitlab, sshHost: "dev", canOpenSSHHost: true, pullTitle: "Pull main")
        let ssh = SidebarModel.sshHostMenuTitle("dev"), open = SidebarModel.openSSHHostTitle("dev")
        let i = { (title: String) in titles.firstIndex(of: title) ?? -1 }
        #expect(i(open) == i(ssh) + 1, "got \(titles)")
        #expect(i("Branch Names") == i(open) + 1, "got \(titles)")
        #expect(i("Pull main") == i("Branch Names") + 1, "got \(titles)")
        // Without an SSH host to open, it follows SSH Host… itself.
        let plain = ProjectHeaderRow.menuTitles(provider: .git, sshHost: nil, canOpenSSHHost: false, pullTitle: nil)
        #expect(plain.firstIndex(of: "Branch Names") == plain.firstIndex(of: SidebarModel.sshHostMenuTitle(nil)).map { $0 + 1 })
    }

    /// VoiceOver says which format is in use, as the menu’s checkmark does.
    @Test func voiceOverSaysWhichFormatIsCurrent() {
        #expect(BranchFormat.allCases.map { ProjectHeaderRow.voiceOverBranchAction($0, current: .typeAndName) }
                    == ["Branch Names: Type and Name (current)", "Branch Names: Ticket Key Only"])
        #expect(BranchFormat.allCases.map { ProjectHeaderRow.voiceOverBranchAction($0, current: .ticketKey) }
                    == ["Branch Names: Type and Name", "Branch Names: Ticket Key Only (current)"])
    }
}
