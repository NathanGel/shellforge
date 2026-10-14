import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

/// A project's SSH host is seen where it is set — the project's menu says it — and can be opened
/// on its own, not only beside a new task's agent.
@MainActor @Suite struct SSHHostMenuTests {
    private func model(sshHost: String?) throws -> (SidebarModel, FakeTerminalHost, UUID) {
        let document = WorkspaceDocument(store: WorkspaceStore(folder: TestScratch.root.appendingPathComponent("sshhost-\(UUID().uuidString)")))
        var project = Project(name: "orion", path: "/r/orion")
        project.sshHost = sshHost
        try document.update { $0.projects.append(project) }
        let launcher = CommandLauncher(resolve: { ResolvedEnvironment(variables: ["PATH": "/usr/bin"], source: .loginShell("/bin/zsh")) })
        let host = FakeTerminalHost()
        return (SidebarModel(host: host, document: document, launcher: launcher, jiraSettings: { nil }), host, project.id)
    }

    @Test func theMenuNamesTheHost() {
        #expect(SidebarModel.sshHostMenuTitle(nil) == "SSH Host…")
        #expect(SidebarModel.sshHostMenuTitle("orion-dev") == "SSH Host: orion-dev…")
        #expect(SidebarModel.openSSHHostTitle("orion-dev") == "Open ssh orion-dev")
    }

    @Test func openingTheHostIsATabOfItsOwnInTheProjectFolder() throws {
        let (model, host, project) = try model(sshHost: "orion-dev")
        model.openSSHHost(of: project)
        let opened = try #require(host.openedPlain.last)
        #expect(opened.directory == "/r/orion" && opened.title == "orion-dev")
        #expect(opened.command == SSHConfig.paneCommand(alias: "orion-dev"))
    }

    @Test func aProjectWithNoHostOpensNothing() throws {
        let (model, host, project) = try model(sshHost: nil)
        model.openSSHHost(of: project)
        #expect(host.openedPlain.isEmpty)
    }
}
