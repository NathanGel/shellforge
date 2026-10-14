import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

/// A project's SSH host is seen where it is set — the project's menu says it — and can be opened
/// on its own, not only beside a new task's agent.
@MainActor @Suite struct SSHHostMenuTests {
    private func config(_ text: String) throws -> SSHConfigSource {
        let file = TestScratch.root.appendingPathComponent("ssh-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: TestScratch.root, withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
        return SSHConfigSource(file: file, home: TestScratch.root)
    }

    private func model(sshHost: String?, config text: String = "Host orion-dev\n  HostName example.invalid\n") throws -> (SidebarModel, FakeTerminalHost, UUID) {
        let document = WorkspaceDocument(store: WorkspaceStore(folder: TestScratch.root.appendingPathComponent("sshhost-\(UUID().uuidString)")))
        var project = Project(name: "orion", path: "/r/orion")
        project.sshHost = sshHost
        try document.update { $0.projects.append(project) }
        let launcher = CommandLauncher(resolve: { ResolvedEnvironment(variables: ["PATH": "/usr/bin"], source: .loginShell("/bin/zsh")) })
        let host = FakeTerminalHost()
        return (SidebarModel(host: host, document: document, launcher: launcher, jiraSettings: { nil }, sshConfig: try config(text)), host, project.id)
    }

    @Test func theMenuNamesTheHost() {
        #expect(SidebarModel.sshHostMenuTitle(nil) == "SSH Host…")
        #expect(SidebarModel.sshHostMenuTitle("orion-dev") == "SSH Host: orion-dev…")
        #expect(SidebarModel.openSSHHostTitle("orion-dev") == "Open ssh orion-dev")
    }

    @Test func openingTheHostIsATabOfItsOwnInTheProjectFolder() async throws {
        let (model, host, project) = try model(sshHost: "orion-dev")
        await model.openSSHHost(of: project)
        let opened = try #require(host.openedPlain.last)
        #expect(opened.directory == "/r/orion" && opened.title == "orion-dev")
        #expect(opened.command == SSHConfig.paneCommand(alias: "orion-dev"))
    }

    @Test func aProjectWithNoHostOpensNothing() async throws {
        let (model, host, project) = try model(sshHost: nil)
        await model.openSSHHost(of: project)
        #expect(host.openedPlain.isEmpty)
    }

    /// A host since gone from ~/.ssh/config is neither offered nor run: the sidebar says so.
    @Test func aHostNoLongerInTheConfigIsNotOpened() async throws {
        let (model, host, project) = try model(sshHost: "orion-dev", config: "Host other\n  HostName example.invalid\n")
        #expect(await eventually { model.sshHosts != nil })
        #expect(!model.canOpenSSHHost(of: project))
        await model.openSSHHost(of: project)
        #expect(host.openedPlain.isEmpty)
        #expect(model.lastError == "orion-dev isn’t in ~/.ssh/config.")
    }
}
