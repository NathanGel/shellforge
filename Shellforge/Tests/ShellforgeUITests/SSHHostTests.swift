import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

/// A project's one SSH host: chosen from `~/.ssh/config` (here a temporary file), kept with the
/// project, offered by New Task as a pane beside the agent.
@MainActor @Suite struct SSHHostTests {
    private let folder = TestScratch.root.appendingPathComponent("shellforge-sshhost-\(UUID().uuidString)")

    private func model() async throws -> (SidebarModel, WorkspaceDocument, UUID) {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let config = folder.appendingPathComponent("ssh_config")
        try "Host box\n  HostName box.example\nHost db\n  LocalForward 5432 db:5432\nHost *\n  User me\n".write(to: config, atomically: true, encoding: .utf8)
        let repo = try GitRepoForUI(installed: ["claude"])
        let document = WorkspaceDocument(store: WorkspaceStore(folder: folder))
        let model = SidebarModel(host: FakeTerminalHost(), document: document, launcher: repo.launcher, catalogue: { _ in [] },
                                 jiraSettings: { nil }, sshConfig: SSHConfigSource(file: config, home: folder))
        await model.addProject(folder: repo.path)
        return (model, document, try #require(document.workspace.projects.first).id)
    }

    @Test func settingTheHostSavesIt() async throws {
        let (model, document, project) = try await model()
        model.setSSHHost("box", on: project)
        #expect(document.workspace.projects[0].sshHost == "box")
        #expect(try WorkspaceStore(folder: folder).load().workspace.projects[0].sshHost == "box")
    }

    @Test func clearingTheHostRemovesIt() async throws {
        let (model, document, project) = try await model()
        model.setSSHHost("box", on: project)
        model.setSSHHost(nil, on: project)
        #expect(document.workspace.projects[0].sshHost == nil)
    }

    @Test func theSheetOffersEveryConcreteHost() async throws {
        let (model, _, _) = try await model()
        let hosts = await model.loadSSHHosts()
        #expect(SSHHostSheet.offered(hosts: hosts, query: "").map(\.alias) == ["box", "db"])
        #expect(SSHHostSheet.offered(hosts: hosts, query: "BO").map(\.alias) == ["box"])
        #expect(SSHHostSheet.statusLine(loading: false, hosts: hosts, current: "gone") == "gone is no longer in ~/.ssh/config.")
        #expect(SSHHostSheet.statusLine(loading: false, hosts: [], current: nil) == "No hosts in ~/.ssh/config.")
        #expect(SSHHostSheet.statusLine(loading: true, hosts: [], current: nil) == "Reading ~/.ssh/config…")
    }

    @Test func anOldProjectHasNoHost() throws {
        let old = #"{"id":"6F0E2C1A-9B3D-4E5F-8A7B-0C1D2E3F4A5B","name":"r","path":"/r","addedAt":0}"#
        #expect(try JSONDecoder().decode(Project.self, from: Data(old.utf8)).sshHost == nil)
        var project = Project(name: "r", path: "/r")
        project.sshHost = "box"
        #expect(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project)).sshHost == "box")
    }
}
