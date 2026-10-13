import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

/// New Task's pane beside the agent: the project's SSH host, opened as a split of the task's first
/// tab when the box is ticked — the agent on the left, `ssh <host>` on the right.
@MainActor @Suite struct SSHPaneTests {
    private let folder = TestScratch.root.appendingPathComponent("shellforge-sshpane-\(UUID().uuidString)")

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

    /// The draft as the sheet hands it up: the host it offered, and the box as left.
    private func draft(openSSH: Bool, offered: String? = "box") -> TaskDraft {
        var draft = TaskDraft(baseBranch: "main", agentId: "claude", model: "opus", reasoning: nil)
        draft.setTitle("Login")
        draft.openSSH = openSSH
        draft.paneHost = offered
        return draft
    }

    @Test func aNewTaskOpensTheHostBesideTheAgent() async throws {
        let (model, host, _, project) = try await model(host: "box")
        #expect(await eventually { model.sshHosts != nil })
        #expect(model.makeNewTaskModel(for: project)?.kind.sshHost == "box")
        try await model.newTask(draft: draft(openSSH: true), in: project)
        #expect(host.opened.last?.beside == "ssh -o ClearAllForwardings=yes box")
    }

    @Test func untickedItOpensAlone() async throws {
        let (model, host, _, project) = try await model(host: "box")
        #expect(await eventually { model.sshHosts != nil })
        try await model.newTask(draft: draft(openSSH: false), in: project)
        #expect(host.opened.last?.beside == nil)
    }

    @Test func aGoneHostIsNotOffered() async throws {
        let (model, host, _, project) = try await model(host: "gone")
        let sheet = try #require(await model.prepareNewTask(for: project))
        #expect(sheet.kind.sshHost == nil && sheet.draft.paneHost == nil)
        var draft = draft(openSSH: true, offered: sheet.draft.paneHost)
        draft.openSSH = sheet.draft.openSSH
        try await model.newTask(draft: draft, in: project)
        #expect(host.opened.last?.beside == nil)
    }

    /// New Task reads the config as it opens: right after launch, before any refresh has, and after
    /// the host left the config since the last read.
    @Test func newTaskReadsTheConfigAsItOpens() async throws {
        let (model, _, _, project) = try await model(host: "box")
        model.sshHosts = nil
        #expect(await model.prepareNewTask(for: project)?.draft.paneHost == "box", "no wait for a refresh")
        let config = folder.appendingPathComponent("ssh_config")
        try "Host other\n".write(to: config, atomically: true, encoding: .utf8)
        #expect(await model.prepareNewTask(for: project)?.draft.paneHost == nil, "a host gone since the last read")
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
        #expect(SSHConfig.paneCommand(alias: "box") == "ssh -o ClearAllForwardings=yes box")
        #expect(SSHConfig.paneCommand(alias: "a$b") == "ssh -o ClearAllForwardings=yes 'a$b'")
    }

    @Test func theChoiceIsRememberedPerProject() async throws {
        let (model, _, document, project) = try await model(host: "box")
        #expect(await eventually { model.sshHosts != nil })
        #expect(model.makeNewTaskModel(for: project)?.draft.openSSH == true, "ticked the first time")
        try await model.newTask(draft: draft(openSSH: false), in: project)
        #expect(document.workspace.lastOpenSSHByProject[project] == false)
        #expect(model.makeNewTaskModel(for: project)?.draft.openSSH == false)
    }

    /// The sheet opened before the config was read showed no box: the task opens alone, whatever
    /// the config says by the time Create is clicked, and the choice is not remembered.
    @Test func aPaneTheSheetNeverOfferedIsNotOpened() async throws {
        let (model, host, document, project) = try await model(host: "box")
        #expect(await eventually { model.sshHosts != nil })
        try await model.newTask(draft: draft(openSSH: true, offered: nil), in: project)
        #expect(host.opened.last?.beside == nil)
        #expect(document.workspace.lastOpenSSHByProject[project] == nil)
    }

    @Test func theSheetCarriesTheHostItOffered() async throws {
        let (model, _, _, project) = try await model(host: "box")
        #expect(await eventually { model.sshHosts != nil })
        #expect(model.makeNewTaskModel(for: project)?.draft.paneHost == "box")
    }

    /// New Task opened right after launch reads the environment first off the main actor: its agent
    /// check must not run a login shell on the main thread.
    @Test func newTaskReadsTheEnvironmentOffTheMainThread() async throws {
        let onMain = Locked<[Bool]>([])
        let repo = try GitRepoForUI(installed: ["claude"])
        let launcher = CommandLauncher(resolve: {
            onMain.withLock { $0.append(Thread.isMainThread) }
            return repo.launcher.environment
        })
        let document = WorkspaceDocument(store: WorkspaceStore(folder: folder))
        try document.update { $0.projects.append(Project(name: "r", path: repo.path)) }
        let model = SidebarModel(host: FakeTerminalHost(), document: document, launcher: launcher, catalogue: { _ in [] },
                                 jiraSettings: { nil })
        _ = await model.prepareNewTask(for: try #require(document.workspace.projects.first).id)
        #expect(!onMain.withLock { $0 }.isEmpty && !onMain.withLock { $0 }.contains(true))
    }
}
