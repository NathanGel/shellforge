import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

/// New Task's pane beside the agent: the project's SSH host, opened as a split of the task's first
/// tab when the box is ticked — the agent on the left, `ssh <host>` on the right.
@MainActor @Suite struct SSHPaneTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shellforge-sshpane-\(UUID().uuidString)")

    private func model(host sshHost: String?) async throws -> (SidebarModel, FakeTerminalHost, WorkspaceDocument, UUID) {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let config = folder.appendingPathComponent("ssh_config")
        try "Host box\n  HostName box.example\nHost a$b\n  HostName odd.example\n".write(to: config, atomically: true, encoding: .utf8)
        let repo = try GitRepoForUI(installed: ["claude"])
        let host = FakeTerminalHost()
        let document = WorkspaceDocument(store: WorkspaceStore(folder: folder))
        let model = SidebarModel(host: host, document: document, launcher: repo.launcher, catalogue: { _ in [] },
                                 jiraSettings: { nil }, sshConfig: SSHConfigSource(file: config, home: folder))
        await model.addProject(folder: repo.path)
        let project = try #require(document.workspace.projects.first).id
        model.setSSHHost(sshHost, on: project)
        return (model, host, document, project)
    }

    private func draft(openSSH: Bool) -> TaskDraft {
        var draft = TaskDraft(baseBranch: "main", agentId: "claude", model: "opus", reasoning: nil)
        draft.setTitle("Login")
        draft.openSSH = openSSH
        return draft
    }

    @Test func aNewTaskOpensTheHostBesideTheAgent() async throws {
        let (model, host, _, project) = try await model(host: "box")
        #expect(await eventually { model.sshHosts != nil })
        #expect(model.makeNewTaskModel(for: project)?.kind.sshHost == "box")
        try await model.newTask(draft: draft(openSSH: true), in: project)
        #expect(host.opened.last?.beside == "ssh box")
    }

    @Test func untickedItOpensAlone() async throws {
        let (model, host, _, project) = try await model(host: "box")
        #expect(await eventually { model.sshHosts != nil })
        try await model.newTask(draft: draft(openSSH: false), in: project)
        #expect(host.opened.last?.beside == nil)
    }

    @Test func aGoneHostIsNotOffered() async throws {
        let (model, host, _, project) = try await model(host: "gone")
        #expect(await eventually { model.sshHosts != nil })
        #expect(model.makeNewTaskModel(for: project)?.kind.sshHost == nil)
        try await model.newTask(draft: draft(openSSH: true), in: project)
        #expect(host.opened.last?.beside == nil)
    }

    @Test func aRefusedSplitIsSaid() async throws {
        let (model, host, _, project) = try await model(host: "box")
        host.refusesSplit = true
        #expect(await eventually { model.sshHosts != nil })
        try await model.newTask(draft: draft(openSSH: true), in: project)
        #expect(model.lastError == "The ssh pane couldn’t open beside Login.")
        #expect(host.opened.count == 1, "the task opened all the same")
    }

    @Test func thePaneCommandQuotesTheAlias() {
        #expect(SSHConfig.paneCommand(alias: "box") == "ssh box")
        #expect(SSHConfig.paneCommand(alias: "a$b") == "ssh 'a$b'")
    }

    @Test func theChoiceIsRememberedPerProject() async throws {
        let (model, _, document, project) = try await model(host: "box")
        #expect(await eventually { model.sshHosts != nil })
        #expect(model.makeNewTaskModel(for: project)?.draft.openSSH == true, "ticked the first time")
        try await model.newTask(draft: draft(openSSH: false), in: project)
        #expect(document.workspace.lastOpenSSHByProject[project] == false)
        #expect(model.makeNewTaskModel(for: project)?.draft.openSSH == false)
    }
}
