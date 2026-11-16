import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

/// The Sessions panel's filter: text matched against a task's title, ticket and branch or its
/// project's name, and a status; tunnels and dividers out of the way while it's on.
@MainActor @Suite struct RowFilterTests {
    private let project = Project(name: "harbor", path: "/harbor")
    private var login: TaskItem {
        TaskItem(projectId: project.id, title: "Fix login", branch: "fix/ABC-12-login", worktreePath: "/w/1", baseBranch: "main",
                 jira: JiraRef(key: "ABC-12", summary: "", url: ""))
    }
    private var intake: TaskItem {
        TaskItem(projectId: project.id, title: "Intake format", branch: "feat/intake", worktreePath: "/w/2", baseBranch: "main")
    }

    private func node(_ tasks: [TaskItem]) -> ProjectNode {
        var node = ProjectNode(project: project, tasks: tasks.map { TaskNode(task: $0, tabs: []) })
        node.children = tasks.map { .task($0.id) }
        return node
    }

    private func kept(_ filter: RowFilter, _ tasks: [TaskItem], status: [UUID: SessionState] = [:]) -> [UUID]? {
        filter.children(of: node(tasks), status: { child in
            if case .task(let id) = child { return status[id] ?? .idle }
            return .idle
        })?.compactMap { if case .task(let id) = $0 { id } else { nil } }
    }

    @Test func anEmptyFilterIsOff() {
        #expect(!RowFilter().isActive)
        #expect(!RowFilter(text: "   ").isActive)
        #expect(RowFilter(text: "x").isActive)
        #expect(RowFilter(status: .needsInput).isActive)
    }

    @Test func textMatchesTitleTicketAndBranchIgnoringCase() {
        let (a, b) = (login, intake)
        #expect(kept(RowFilter(text: "LOGIN"), [a, b]) == [a.id])
        #expect(kept(RowFilter(text: "abc-12"), [a, b]) == [a.id])
        #expect(kept(RowFilter(text: "feat/int"), [a, b]) == [b.id])
        #expect(kept(RowFilter(text: "nothing"), [a, b]) == nil, "a project with no match isn't shown")
    }

    @Test func aMatchingProjectNameShowsAllItsTasks() {
        let (a, b) = (login, intake)
        #expect(kept(RowFilter(text: "harb"), [a, b]) == [a.id, b.id])
        // An empty project whose name matches still shows.
        #expect(kept(RowFilter(text: "harb"), []) == [])
    }

    @Test func aStatusKeepsOnlyThatStatus() {
        let (a, b) = (login, intake)
        let status = [a.id: SessionState.needsInput, b.id: .working]
        #expect(kept(RowFilter(status: .needsInput), [a, b], status: status) == [a.id])
        #expect(kept(RowFilter(text: "harb", status: .working), [a, b], status: status) == [b.id])
        #expect(kept(RowFilter(status: .done), [a, b], status: status) == nil)
    }

    // -- in the model ---------------------------------------------------------------------------

    private func model() throws -> (SidebarModel, TaskItem, TaskItem) {
        let folder = TestScratch.root.appendingPathComponent("shellforge-filter-\(UUID().uuidString)")
        let document = WorkspaceDocument(store: WorkspaceStore(folder: folder))
        let (a, b) = (login, intake)
        try document.update { w in
            w.projects.append(project); w.addTask(a); w.addTask(b)
            w.projects[0].collapsed = true
            w.dividers.append(SidebarDivider(name: "Client work", position: 0))
        }
        let launcher = CommandLauncher(resolve: { ResolvedEnvironment(variables: ["PATH": "/usr/bin"], source: .loginShell("/bin/zsh")) })
        return (SidebarModel(host: FakeTerminalHost(), document: document, launcher: launcher, jiraSettings: { nil }), a, b)
    }

    private func taskIds(_ rows: [SidebarRow]) -> [UUID] {
        rows.compactMap { if case .task(let node, _) = $0 { node.id } else { nil } }
    }

    @Test func theFilterRevealsMatchesInAFoldedProjectAndHidesDividers() throws {
        let (model, a, _) = try model()
        #expect(taskIds(model.rows).isEmpty, "folded")
        model.rowFilter = RowFilter(text: "login")
        #expect(taskIds(model.rows) == [a.id])
        #expect(!model.rows.contains { if case .divider = $0 { true } else { false } })
    }

    @Test func aFilteredOutSelectionSelectsNoRowAndStepsWalkWhatIsShown() throws {
        let (model, a, b) = try model()
        model.rowFilter = RowFilter(text: "intake")
        model.select(task: a.id)
        #expect(!model.rows.contains { if case .task(_, true) = $0 { true } else { false } })
        #expect(model.steppableTasks == [b.id])
    }

    @Test func rearrangingShowsEverything() throws {
        let (model, _, _) = try model()
        model.rowFilter = RowFilter(text: "login")
        model.beginRearrange()
        #expect(model.rows.contains { if case .divider = $0 { true } else { false } })
        model.cancelRearrange()
    }
}
