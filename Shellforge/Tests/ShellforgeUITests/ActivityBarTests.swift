import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

/// The activity bar's model: each window picks its own panel, every window shares one saved order,
/// and the Sessions panel's state and commands live on while another panel shows.
@MainActor @Suite struct ActivityBarTests {
    private func task(_ title: String, in project: UUID) -> TaskItem {
        TaskItem(projectId: project, title: title, branch: "feat/\(title)", worktreePath: "/wt/\(title)", baseBranch: "main")
    }

    /// Project `demo` with tasks `a1` and `a2`, and the sidebar model over it.
    private func sidebarModel() throws -> (SidebarModel, [String: UUID]) {
        let folder = TestScratch.root.appendingPathComponent("shellforge-activity-\(UUID().uuidString)")
        let document = WorkspaceDocument(store: WorkspaceStore(folder: folder))
        let project = Project(name: "demo", path: "/demo")
        try document.update { workspace in
            workspace.projects.append(project)
            workspace.tasks += [task("a1", in: project.id), task("a2", in: project.id)]
        }
        var ids = ["demo": project.id]
        for task in document.workspace.tasks { ids[task.title] = task.id }
        let launcher = CommandLauncher(resolve: { ResolvedEnvironment(variables: ["PATH": "/usr/bin"], source: .loginShell("/bin/zsh")) })
        return (SidebarModel(host: FakeTerminalHost(), document: document, launcher: launcher, jiraSettings: { nil }), ids)
    }

    @Test func selectionIsPerWindow() {
        let source = ActivityOrderSource(defaults: ScratchDefaults.make())
        let first = ActivityModel(source: source), second = ActivityModel(source: source)
        first.select(.metrics)
        #expect(first.layout.selected == .metrics)
        #expect(second.layout.selected == .sessions)
    }

    @Test func orderIsSharedAndSaved() {
        let defaults = ScratchDefaults.make()
        let source = ActivityOrderSource(defaults: defaults)
        let first = ActivityModel(source: source), second = ActivityModel(source: source)
        first.move(.metrics, before: .sessions)
        #expect(first.layout.order == [.metrics, .sessions])
        #expect(second.layout.order == [.metrics, .sessions])
        #expect(ActivityOrderStore.load(defaults) == ["metrics", "sessions"])
        #expect(ActivityModel(defaults: defaults).layout.order == [.metrics, .sessions], "a new window reads the saved order")
    }

    @Test func movingKeepsTheSelection() {
        let model = ActivityModel(source: ActivityOrderSource(defaults: ScratchDefaults.make()))
        model.select(.metrics)
        model.move(.metrics, before: .sessions)
        #expect(model.layout.selected == .metrics)
    }

    /// The bar's List hands back offsets; dropping a panel where it already is changes nothing.
    @Test func listOffsetsMoveThePanel() {
        let defaults = ScratchDefaults.make()
        let model = ActivityModel(defaults: defaults)
        model.move(fromOffsets: IndexSet(integer: 0), toOffset: 0)
        model.move(fromOffsets: IndexSet(integer: 0), toOffset: 1)
        #expect(model.layout.order == [.sessions, .metrics])
        #expect(ActivityOrderStore.load(defaults) == nil, "nothing moved, so nothing is saved")
        model.move(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        #expect(model.layout.order == [.metrics, .sessions])
        model.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        #expect(model.layout.order == [.sessions, .metrics])
    }

    @Test func leavingSessionsWhileRearrangingCancelsNothing() throws {
        let (sidebar, _) = try sidebarModel()
        let activity = ActivityModel(source: ActivityOrderSource(defaults: ScratchDefaults.make()))
        sidebar.beginRearrange()
        #expect(sidebar.rearrange != nil)
        activity.select(.metrics)
        activity.select(.sessions)
        #expect(sidebar.rearrange != nil)
    }

    @Test func commandsWorkWhileAnotherPanelShows() throws {
        let (sidebar, ids) = try sidebarModel()
        let activity = ActivityModel(source: ActivityOrderSource(defaults: ScratchDefaults.make()))
        activity.select(.metrics)
        #expect(sidebar.can(.newTask), "the only project is New Task’s target")
        sidebar.perform(.nextTask)
        #expect(sidebar.selectedTaskId == ids["a1"])
        sidebar.perform(.nextTask)
        #expect(sidebar.selectedTaskId == ids["a2"])
    }
}
