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
}
