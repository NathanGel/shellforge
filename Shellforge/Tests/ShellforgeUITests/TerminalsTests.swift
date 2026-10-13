import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

/// AiTerm's terminals: a named shell row under a project, its tabs opened in the project folder and
/// tagged as the terminal's, kept until removed. Workspaces are written directly; tabs are fake.
@MainActor @Suite struct TerminalsTests {
    private func model(feed: FakeFeed = FakeFeed()) throws -> (SidebarModel, FakeTerminalHost, WorkspaceDocument, UUID) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shellforge-terminals-\(UUID().uuidString)")
        let document = WorkspaceDocument(store: WorkspaceStore(folder: folder))
        let project = Project(name: "api", path: "/api")
        try document.update { $0.projects.append(project) }
        let launcher = CommandLauncher(resolve: { ResolvedEnvironment(variables: ["PATH": "/usr/bin"], source: .loginShell("/bin/zsh")) })
        let host = FakeTerminalHost()
        return (SidebarModel(host: host, document: document, launcher: launcher, feed: feed, jiraSettings: { nil }), host, document, project.id)
    }

    @Test func aNewTerminalOpensATabInTheProjectFolder() throws {
        let (model, host, document, project) = try model()
        model.newTerminal(name: "  logs ", in: project)
        let terminal = try #require(document.workspace.terminals.first)
        #expect(terminal.name == "logs" && terminal.projectId == project)
        let tab = try #require(host.openedTerminals.last)
        #expect(tab.directory == "/api" && tab.terminalId == terminal.id && tab.title == "logs")
        #expect(model.rows.contains { if case .terminal(let node, _) = $0 { node.id == terminal.id } else { false } })
    }

    @Test func namesAreTerminalThenTerminalN() throws {
        let (model, _, document, project) = try model()
        #expect(model.suggestedTerminalName(in: project) == "Terminal")
        model.newTerminal(name: "", in: project)
        #expect(document.workspace.terminals.last?.name == "Terminal", "an empty name takes the suggestion")
        #expect(model.suggestedTerminalName(in: project) == "Terminal 2")
        model.newTerminal(name: "Terminal 2", in: project)
        #expect(model.suggestedTerminalName(in: project) == "Terminal 3")
    }

    @Test func aTerminalWithNoTabOpensOneWhenSelected() throws {
        let (model, host, document, project) = try model()
        model.newTerminal(name: "logs", in: project)
        let terminal = try #require(document.workspace.terminals.first)
        host.close(try #require(host.tabs.first).id)
        #expect(model.rows.contains { if case .terminal = $0 { true } else { false } }, "the row stays when its tab closes")
        model.select(terminal: terminal.id)
        #expect(host.openedTerminals.count == 2)
        model.select(terminal: terminal.id)
        #expect(host.openedTerminals.count == 2, "with a tab open, it is shown, not opened again")
    }

    @Test func removeClosesItsTabsAndDropsTheRow() throws {
        let (model, host, document, project) = try model()
        model.newTerminal(name: "logs", in: project)
        let terminal = try #require(document.workspace.terminals.first)
        model.removeTerminal(terminal.id)
        #expect(host.closedTerminals == [terminal.id])
        #expect(document.workspace.terminals.isEmpty)
        #expect(!model.rows.contains { if case .terminal = $0 { true } else { false } })
    }

    @Test func renamingATerminalChangesOnlyItsName() throws {
        let (model, _, document, project) = try model()
        model.newTerminal(name: "logs", in: project)
        let terminal = try #require(document.workspace.terminals.first)
        model.renameTerminal(terminal.id, to: " tail ")
        #expect(document.workspace.terminals.first?.name == "tail")
        model.renameTerminal(terminal.id, to: "  ")
        #expect(document.workspace.terminals.first?.name == "tail", "an empty name keeps the old one")
    }

    @Test func anOldWorkspaceHasNoTerminals() throws {
        let old = #"{"version":1,"projects":[],"tasks":[]}"#
        #expect(try JSONDecoder().decode(Workspace.self, from: Data(old.utf8)).terminals.isEmpty)
    }

    @Test func terminalsShowTheirAgentsAndStatus() throws {
        let (model, host, document, project) = try model()
        model.newTerminal(name: "logs", in: project)
        let terminal = try #require(document.workspace.terminals.first)
        let tab = try #require(host.tabs.first)
        #expect(tab.terminalId == terminal.id)
        #expect(model.avatars(forTerminal: terminal.id).isEmpty)
        #expect(model.status(ofTerminal: terminal.id) == .idle)
    }

    @Test func newTerminalIsACommandOnTheTargetProject() throws {
        let (model, _, _, project) = try model()
        var requests: [SidebarSheetRequest] = []
        let subscription = model.sheetRequests.sink { requests.append($0) }
        model.perform(.newTerminal)
        #expect(requests == [.newTerminal(project)])
        _ = subscription
    }

    // -- the final review --

    @Test func focusViewKeepsAProjectWithAWaitingTerminalOpen() throws {
        let (model, host, document, project) = try model()
        model.newTerminal(name: "logs", in: project)
        let tab = try #require(host.tabs.first)
        var snapshot = DaemonSnapshot(protocolVersion: 1, connected: true, sessions: [
            SessionInfo(sessionId: tab.id, windowId: "w", tabIndex: 0, taskId: nil, projectId: nil, agent: .claude, model: nil,
                        state: .needsInput, title: "logs", cwd: "/api")], usage: .empty)
        snapshot.tunnels = []
        var store = SessionStore()
        store.apply(.snapshot(snapshot))
        (model.feed as? FakeFeed)?.store = store
        model.perform(.focusView)
        #expect(document.workspace.projects.first?.collapsed == false, "a waiting terminal keeps its project open")
        let node = try #require(model.tree.projects.first)
        #expect(ProjectHeaderRow.collapses(node), "a project with only terminals still folds and unfolds")
    }

    @Test func aTerminalTabHasAFooterRow() throws {
        let (model, host, _, project) = try model()
        model.newTerminal(name: "logs", in: project)
        let tab = try #require(host.tabs.first)
        var snapshot = DaemonSnapshot(protocolVersion: 1, connected: true, sessions: [
            SessionInfo(sessionId: tab.id, windowId: "w", tabIndex: 0, taskId: nil, projectId: nil, agent: .claude, model: nil,
                        state: .working, title: "logs", cwd: "/api")], usage: .empty)
        snapshot.tunnels = []
        var store = SessionStore()
        store.apply(.snapshot(snapshot))
        (model.feed as? FakeFeed)?.store = store
        #expect(model.footerRow != nil, "a terminal's tab is the footer's row, as an other tab was")
    }

    @Test func oneRowIsSelectedAtATime() throws {
        let (model, _, document, project) = try model()
        let task = TaskItem(projectId: project, title: "Login", branch: "feat/login", worktreePath: "/wt", baseBranch: "main")
        try document.update { $0.tasks.append(task) }
        model.newTerminal(name: "logs", in: project)
        #expect(model.selectedTerminalId != nil)
        model.show(task: task.id)
        #expect(model.selectedTaskId == task.id && model.selectedTerminalId == nil)
        model.select(terminal: try #require(document.workspace.terminals.first).id)
        #expect(model.selectedTaskId == nil)
    }

    @Test func aSelectedTerminalIsTheTargetProject() throws {
        let (model, _, document, project) = try model()
        try document.update { $0.projects.append(Project(name: "web", path: "/web")) }
        model.newTerminal(name: "logs", in: project)
        #expect(model.targetProject == project)
        #expect(model.can(.newTask))
    }

    /// Saving refuses a repeated id, but a hand-edited or sync-merged file is loaded as it is.
    @Test func aWorkspaceWithARepeatedProjectDrawsWithoutCrashing() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shellforge-repeated-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = Project(name: "api", path: "/api")
        var workspace = Workspace(projects: [project, project])
        workspace.dividers = [SidebarDivider(name: "Work", position: 1)]
        try JSONEncoder.workspace.encode(workspace).write(to: folder.appendingPathComponent("workspace.json"))
        let launcher = CommandLauncher(resolve: { ResolvedEnvironment(variables: ["PATH": "/usr/bin"], source: .loginShell("/bin/zsh")) })
        let model = SidebarModel(host: FakeTerminalHost(), document: WorkspaceDocument(store: WorkspaceStore(folder: folder)),
                                 launcher: launcher, jiraSettings: { nil })
        #expect(model.rows.count >= 2)
        _ = model.canMove(.project(project.id), up: false)
    }
}
