import Foundation
import Testing
@testable import ShellforgeCore

@Suite struct SidebarTreeTests {
    private let project = Project(name: "aiterm", path: "/r/aiterm")
    private var login: TaskItem { TaskItem(projectId: project.id, title: "Fix login", branch: "fix-login",
                                           worktreePath: "/r/aiterm/.worktrees/fix-login", baseBranch: "main",
                                           createdAt: Date(timeIntervalSince1970: 1)) }
    private var docs: TaskItem { TaskItem(projectId: project.id, title: "Docs", branch: "docs",
                                          worktreePath: "/r/aiterm/.worktrees/docs", baseBranch: "main",
                                          createdAt: Date(timeIntervalSince1970: 2)) }

    private func tab(_ id: String, _ tabId: Int, task: UUID?) -> TabSnapshot {
        TabSnapshot(id: id, tabId: tabId, title: id, taskId: task, projectId: task == nil ? nil : project.id)
    }

    @Test func eachTabSitsUnderTheTaskItsOwnTagNames() {
        let (a, b) = (login, docs)
        let tree = SidebarTree.build(Workspace(projects: [project], tasks: [a, b]),
                                     tabs: [tab("s1", 1, task: a.id), tab("s2", 2, task: b.id), tab("s3", 3, task: a.id)])
        #expect(tree.projects.count == 1)
        #expect(tree.projects[0].tasks.map(\.task.id) == [a.id, b.id])
        #expect(tree.projects[0].tasks[0].tabs.map(\.id) == ["s1", "s3"])
        #expect(tree.projects[0].tasks[1].tabs.map(\.id) == ["s2"])
    }

    @Test func aTaskWithNoOpenTabStaysListed() {
        let tree = SidebarTree.build(Workspace(projects: [project], tasks: [login]), tabs: [])
        #expect(tree.projects[0].tasks.map(\.tabs) == [[]])
    }

    @Test func untaggedTabsAndTabsOfUnknownTasksGoUnderOtherTabs() {
        let stray = tab("s9", 9, task: UUID())
        let plain = tab("s0", 0, task: nil)
        let tree = SidebarTree.build(Workspace(projects: [project], tasks: [login]), tabs: [plain, stray])
        #expect(tree.otherTabs.map(\.id) == ["s0", "s9"])
    }

    @Test func tabsKeepTheirOrderInTheWindow() {
        let a = login
        let tree = SidebarTree.build(Workspace(projects: [project], tasks: [a]),
                                     tabs: [tab("late", 7, task: a.id), tab("early", 2, task: a.id)])
        #expect(tree.projects[0].tasks[0].tabs.map(\.id) == ["early", "late"])
    }

    @Test func aTabFindsTheTaskThatOwnsIt() {
        let a = login
        let owned = tab("s1", 1, task: a.id)
        let tree = SidebarTree.build(Workspace(projects: [project], tasks: [a]), tabs: [owned])
        #expect(tree.task(owning: owned) == a)
        #expect(tree.task(owning: tab("s2", 2, task: nil)) == nil)
    }
}
