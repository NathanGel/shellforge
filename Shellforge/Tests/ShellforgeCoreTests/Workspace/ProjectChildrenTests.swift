import Foundation
import Testing
@testable import ShellforgeCore

@Suite struct ProjectChildrenTests {
    private func task(_ project: Project, _ title: String, at seconds: Double) -> TaskItem {
        TaskItem(projectId: project.id, title: title, branch: title, worktreePath: "/r/.worktrees/\(title)",
                 baseBranch: "main", createdAt: Date(timeIntervalSince1970: seconds))
    }

    private func terminal(_ project: Project, at seconds: Double) -> TerminalItem {
        TerminalItem(projectId: project.id, name: "logs", createdAt: Date(timeIntervalSince1970: seconds))
    }

    @Test func defaultOrderIsTasksThenTerminalsOldestFirst() {
        let project = Project(name: "p", path: "/r")
        let (t1, t2, x) = (task(project, "a", at: 2), task(project, "b", at: 3), terminal(project, at: 1))
        var workspace = Workspace(projects: [project], tasks: [t2, t1])
        workspace.terminals = [x]
        #expect(workspace.children(in: project.id) == [.task(t1.id), .task(t2.id), .terminal(x.id)])
    }

    @Test func childOrderMixesTasksAndTerminals() {
        var project = Project(name: "p", path: "/r")
        let (t1, t2, x) = (task(project, "a", at: 2), task(project, "b", at: 3), terminal(project, at: 1))
        project.childOrder = [t2.id, x.id, t1.id]
        var workspace = Workspace(projects: [project], tasks: [t1, t2])
        workspace.terminals = [x]
        #expect(workspace.children(in: project.id) == [.task(t2.id), .terminal(x.id), .task(t1.id)])
    }

    @Test func unknownAndGoneIdsAreHandled() {
        var project = Project(name: "p", path: "/r")
        let (t1, t2) = (task(project, "a", at: 2), task(project, "b", at: 3))
        project.childOrder = [UUID(), t1.id]
        let workspace = Workspace(projects: [project], tasks: [t1, t2])
        #expect(workspace.children(in: project.id) == [.task(t1.id), .task(t2.id)])
    }

    @Test func aNewTaskInAnUnarrangedProjectGoesToTheBottom() {
        let project = Project(name: "p", path: "/r")
        let (t1, t3, x) = (task(project, "a", at: 2), task(project, "c", at: 4), terminal(project, at: 1))
        var workspace = Workspace(projects: [project], tasks: [t1])
        workspace.terminals = [x]
        workspace.addTask(t3)
        #expect(workspace.children(in: project.id) == [.task(t1.id), .terminal(x.id), .task(t3.id)])
        #expect(workspace.projects[0].childOrder == [t1.id, x.id, t3.id])
    }

    @Test func aNewTerminalInAnArrangedProjectGoesToTheBottom() {
        var project = Project(name: "p", path: "/r")
        let (t1, t2) = (task(project, "a", at: 2), task(project, "b", at: 3))
        project.childOrder = [t2.id, t1.id]
        var workspace = Workspace(projects: [project], tasks: [t1, t2])
        let x = terminal(project, at: 1)
        workspace.addTerminal(x)
        #expect(workspace.projects[0].childOrder == [t2.id, t1.id, x.id])
        #expect(workspace.terminals == [x])
    }

    @Test func childOrderRoundTripsAndOldJSONLoads() throws {
        var project = Project(name: "p", path: "/r")
        let ids = [UUID(), UUID()]
        project.childOrder = ids
        let decoded = try JSONDecoder.workspace.decode(Project.self, from: JSONEncoder.workspace.encode(project))
        #expect(decoded.childOrder == ids)

        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder.workspace.encode(Project(name: "q", path: "/q"))) as? [String: Any])
        #expect(object["childOrder"] == nil)
        object["childOrder"] = nil
        let old = try JSONDecoder.workspace.decode(Project.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.childOrder == nil)
    }
}
