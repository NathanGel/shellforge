import Foundation
import Testing
@testable import ShellforgeCore

/// Rearrange mode's draft: what may move where, and how the draft lands on a workspace that may have
/// changed since it was made.
@Suite struct RearrangeDraftTests {
    private let a: Project, b: Project, d: SidebarDivider
    private let t1: TaskItem, t2: TaskItem, tb: TaskItem, x: TerminalItem
    private let workspace: Workspace

    init() {
        var a = Project(name: "A", path: "/a")
        a.tunnels = [TunnelDefinition(alias: "a1", autoStart: .onLaunch, keepRunning: true),
                     TunnelDefinition(alias: "a2", autoStart: .onTaskOpen)]
        let b = Project(name: "B", path: "/b")
        let d = SidebarDivider(name: "D", position: 1)
        let t1 = Self.task(a, "t1", at: 1), t2 = Self.task(a, "t2", at: 2), tb = Self.task(b, "tb", at: 3)
        let x = Self.terminal(a, at: 4)
        var workspace = Workspace(projects: [a, b], tasks: [t1, t2, tb])
        workspace.terminals = [x]
        workspace.dividers = [d]
        (self.a, self.b, self.d, self.t1, self.t2, self.tb, self.x, self.workspace) = (a, b, d, t1, t2, tb, x, workspace)
    }

    private static func task(_ project: Project, _ title: String, at seconds: Double) -> TaskItem {
        TaskItem(projectId: project.id, title: title, branch: title, worktreePath: "/r/.worktrees/\(title)",
                 baseBranch: "main", createdAt: Date(timeIntervalSince1970: seconds))
    }

    private static func terminal(_ project: Project, at seconds: Double) -> TerminalItem {
        TerminalItem(projectId: project.id, name: "logs", createdAt: Date(timeIntervalSince1970: seconds))
    }

    private func project(_ id: UUID, in workspace: Workspace) -> Project? {
        workspace.projects.first { $0.id == id }
    }

    @Test func aProjectMovesWithEverythingUnderIt() throws {
        #expect(SidebarLayout.entries(projects: workspace.projects, dividers: workspace.dividers)
                == [.project(a.id), .divider(d.id), .project(b.id)])
        var draft = RearrangeDraft(workspace)
        let moved = draft.move(.entry(.project(b.id)), before: .entry(.project(a.id)))
        #expect(moved)
        var applied = workspace
        draft.apply(to: &applied)
        #expect(SidebarLayout.entries(projects: applied.projects, dividers: applied.dividers)
                == [.project(b.id), .project(a.id), .divider(d.id)])
        #expect(applied.dividers.map(\.position) == [2])
        let movedA = try #require(project(a.id, in: applied))
        #expect(movedA.childOrder == [t1.id, t2.id, x.id])
        #expect(movedA.tunnels == a.tunnels)
    }

    @Test func aDividerMovesAlone() {
        var draft = RearrangeDraft(workspace)
        let moved = draft.move(.entry(.divider(d.id)), before: nil)
        #expect(moved)
        var applied = workspace
        draft.apply(to: &applied)
        #expect(applied.projects.map(\.id) == [a.id, b.id])
        #expect(applied.dividers.map(\.position) == [2])
    }

    @Test func tasksAndTerminalsMix() {
        var draft = RearrangeDraft(workspace)
        let moved = draft.move(.child(project: a.id, .terminal(x.id)), before: .child(project: a.id, .task(t1.id)))
        #expect(moved)
        var applied = workspace
        draft.apply(to: &applied)
        #expect(project(a.id, in: applied)?.childOrder == [x.id, t1.id, t2.id])
    }

    @Test func aTaskCannotLeaveItsProject() {
        var draft = RearrangeDraft(workspace)
        let before = draft
        let moved = draft.move(.child(project: a.id, .task(t1.id)), before: .child(project: b.id, .task(tb.id)))
        #expect(!moved)
        let moved2 = draft.move(.child(project: a.id, .task(t1.id)), before: .child(project: a.id, .task(tb.id)))
        #expect(!moved2, "naming the wrong project does not smuggle it across")
        let moved3 = draft.move(.child(project: a.id, .task(t1.id)), before: .entry(.project(b.id)))
        #expect(!moved3)
        let moved4 = draft.move(.entry(.project(a.id)), before: .child(project: b.id, .task(tb.id)))
        #expect(!moved4)
        #expect(draft == before)
    }

    @Test func nothingGoesAboveTheSSHRows() {
        var draft = RearrangeDraft(workspace)
        let before = draft
        let moved = draft.move(.child(project: a.id, .task(t1.id)), before: .tunnel(project: a.id, alias: "a1"))
        #expect(!moved)
        let moved2 = draft.move(.tunnel(project: a.id, alias: "a1"), before: .child(project: a.id, .task(t1.id)))
        #expect(!moved2)
        #expect(draft == before)
    }

    @Test func sshRowsReorderAmongThemselves() throws {
        var draft = RearrangeDraft(workspace)
        let moved = draft.move(.tunnel(project: a.id, alias: "a2"), before: .tunnel(project: a.id, alias: "a1"))
        #expect(moved)
        var applied = workspace
        draft.apply(to: &applied)
        let tunnels = try #require(project(a.id, in: applied)).tunnels
        #expect(tunnels.map(\.alias) == ["a2", "a1"])
        #expect(tunnels == [a.tunnels[1], a.tunnels[0]], "every field kept")
    }

    @Test func stepMovesOneAndStopsAtTheEdges() {
        var draft = RearrangeDraft(workspace)
        let first = ProjectChild.task(t1.id)
        #expect(!draft.canStep(.child(project: a.id, first), up: true))
        let stepped = draft.step(.child(project: a.id, first), up: true)
        #expect(!stepped)
        #expect(!draft.canStep(.child(project: a.id, .terminal(x.id)), up: false))
        #expect(draft.canStep(.child(project: a.id, first), up: false))
        let stepped2 = draft.step(.child(project: a.id, first), up: false)
        #expect(stepped2)
        #expect(draft.children[a.id] == [.task(t2.id), .task(t1.id), .terminal(x.id)])
        #expect(!draft.canStep(.entry(.project(a.id)), up: true))
        let stepped3 = draft.step(.entry(.project(a.id)), up: false)
        #expect(stepped3, "a step crosses the adjacent divider")
        #expect(draft.entries == [.divider(d.id), .project(a.id), .project(b.id)])
    }

    @Test func applyKeepsItemsAddedSinceTheDraft() {
        let draft = RearrangeDraft(workspace)
        var changed = workspace
        let t3 = Self.task(a, "t3", at: 5), y = Self.terminal(a, at: 6)
        changed.addTask(t3)
        changed.addTerminal(y)
        let c = Project(name: "C", path: "/c")
        changed.projects.append(c)
        let e = SidebarDivider(name: "E", position: 0)
        changed.dividers.append(e)
        draft.apply(to: &changed)
        #expect(changed.children(in: a.id) == [.task(t1.id), .task(t2.id), .terminal(x.id), .task(t3.id), .terminal(y.id)])
        #expect(project(a.id, in: changed)?.childOrder == [t1.id, t2.id, x.id, t3.id, y.id])
        #expect(changed.tasks.count == 4 && changed.terminals.count == 2)
        #expect(SidebarLayout.entries(projects: changed.projects, dividers: changed.dividers)
                == [.project(a.id), .divider(d.id), .project(b.id), .divider(e.id), .project(c.id)],
                "new entries follow the draft, in the order they draw now")
    }

    @Test func applyKeepsTunnelsAddedSinceTheDraft() throws {
        var draft = RearrangeDraft(workspace)
        let moved = draft.move(.tunnel(project: a.id, alias: "a1"), before: nil)
        #expect(moved)
        var changed = workspace
        let i = try #require(changed.projects.firstIndex { $0.id == a.id })
        changed.projects[i].tunnels.insert(TunnelDefinition(alias: "new"), at: 0)
        draft.apply(to: &changed)
        #expect(changed.projects[i].tunnels.map(\.alias) == ["a2", "a1", "new"])
    }

    @Test func applyDropsItemsRemovedSinceTheDraft() throws {
        var draft = RearrangeDraft(workspace)
        let moved = draft.move(.entry(.project(b.id)), before: .entry(.project(a.id)))
        #expect(moved)
        var changed = workspace
        changed.projects.removeAll { $0.id == b.id }
        changed.tasks.removeAll { $0.id == t2.id || $0.projectId == b.id }
        let i = try #require(changed.projects.firstIndex { $0.id == a.id })
        changed.projects[i].tunnels.removeAll { $0.alias == "a1" }
        draft.apply(to: &changed)
        #expect(changed.projects.map(\.id) == [a.id], "B is not back")
        #expect(changed.dividers.map(\.id) == [d.id])
        #expect(project(a.id, in: changed)?.childOrder == [t1.id, x.id])
        #expect(changed.projects[i].tunnels.map(\.alias) == ["a2"])
    }
}
