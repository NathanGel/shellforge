import Combine
import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

/// Claude's spinner retitles its tab several times a second. A retitle no row draws is kept
/// without redrawing the sidebar; one a row draws redraws it.
@MainActor @Suite struct TabRetitleTests {
    @MainActor private struct Setup {
        let model: SidebarModel, host: FakeTerminalHost, document: WorkspaceDocument
        let first: TaskItem, second: TaskItem
    }

    /// A project with two tasks: the first has one tab, the second two; and a tab of no task.
    private func setup() throws -> Setup {
        let folder = TestScratch.root.appendingPathComponent("shellforge-retitle-\(UUID().uuidString)")
        let document = WorkspaceDocument(store: WorkspaceStore(folder: folder))
        let demo = Project(name: "demo", path: "/demo")
        let first = TaskItem(projectId: demo.id, title: "Fix login", branch: "fix-login", worktreePath: "/demo/.worktrees/fix-login",
                             baseBranch: "main")
        let second = TaskItem(projectId: demo.id, title: "Search page", branch: "search-page", worktreePath: "/demo/.worktrees/search-page",
                              baseBranch: "main")
        try document.update { w in w.projects.append(demo); w.tasks += [first, second] }
        let launcher = CommandLauncher(resolve: { ResolvedEnvironment(variables: ["PATH": "/usr/bin"], source: .loginShell("/bin/zsh")) })
        let host = FakeTerminalHost()
        host.tabs = [
            TabSnapshot(id: "s1", tabId: 1, title: "claude", taskId: first.id, projectId: demo.id),
            TabSnapshot(id: "s2", tabId: 2, title: "claude", taskId: second.id, projectId: demo.id),
            TabSnapshot(id: "s3", tabId: 3, title: "zsh", taskId: second.id, projectId: demo.id),
            TabSnapshot(id: "s4", tabId: 4, title: "htop", taskId: nil, projectId: nil),
        ]
        let model = SidebarModel(host: host, document: document, launcher: launcher, jiraSettings: { nil })
        host.onChange?()
        return Setup(model: model, host: host, document: document, first: first, second: second)
    }

    /// Counts the model's announcements while `change` runs.
    private func announcements(_ model: SidebarModel, _ change: () -> Void) -> Int {
        var count = 0
        let watching = model.objectWillChange.sink { count += 1 }
        change()
        watching.cancel()
        return count
    }

    private func retitle(_ s: Setup, _ id: String, _ title: String) {
        s.host.tabs[s.host.tabs.firstIndex { $0.id == id }!].title = title
        s.host.onChange?()
    }

    @Test func aRetitleOfAnUndrawnTabDoesNotRepublish() throws {
        let s = try setup()
        #expect(s.model.selectedTaskId == nil)
        let count = announcements(s.model) {
            for frame in ["✳ Thinking", "✶ Thinking", "✻ Thinking"] { retitle(s, "s1", frame) }
        }
        #expect(count == 0, "a task's single tab draws no title")
        // Kept all the same: the next redraw reads it.
        #expect(s.model.tree.projects[0].tasks[0].tabs[0].title == "✻ Thinking")
    }

    @Test func aRetitleOfADrawnTabRepublishes() throws {
        let s = try setup()
        #expect(announcements(s.model) { retitle(s, "s4", "top") } > 0, "an other tab's row shows its title")
        #expect(s.model.rows.contains { if case .tab(let tab, _) = $0 { tab.title == "top" } else { false } })

        // The second task selected: its two tabs are drawn under it.
        s.host.select(tab: "s2")
        #expect(s.model.selectedTaskId == s.second.id)
        #expect(announcements(s.model) { retitle(s, "s3", "vim") } > 0)
        #expect(s.model.rows.contains { if case .tab(let tab, _) = $0 { tab.title == "vim" } else { false } })
        // The first task's single tab still draws nothing.
        #expect(announcements(s.model) { retitle(s, "s1", "✳ Thinking") } == 0)
    }

    /// A tab that changes more than its title (it closes, opens, moves to a task) still redraws.
    @Test func aStructuralChangeStillRepublishes() throws {
        let s = try setup()
        #expect(announcements(s.model) {
            s.host.tabs.removeAll { $0.id == "s1" }
            s.host.onChange?()
        } > 0)
    }
}
