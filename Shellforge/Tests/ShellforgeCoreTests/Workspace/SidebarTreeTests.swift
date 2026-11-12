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

    @Test func buildCarriesTheMixedOrder() {
        var arranged = project
        let (a, b) = (login, docs)
        let x = TerminalItem(projectId: project.id, name: "logs", createdAt: Date(timeIntervalSince1970: 0))
        arranged.childOrder = [b.id, x.id, a.id]
        var workspace = Workspace(projects: [arranged], tasks: [a, b])
        workspace.terminals = [x]
        let tree = SidebarTree.build(workspace, tabs: [])
        #expect(tree.projects[0].children == workspace.children(in: arranged.id))
        #expect(tree.projects[0].children == [.task(b.id), .terminal(x.id), .task(a.id)])
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

    /// A terminal whose project is gone — a hand-edited workspace — draws no row: its tab falls
    /// back to Other tabs rather than vanishing.
    @Test func aTabOfATerminalWithNoProjectIsAnOtherTab() {
        let orphan = TerminalItem(projectId: UUID(), name: "logs")
        let tab = TabSnapshot(id: "s1", tabId: 1, title: "logs", taskId: nil, projectId: nil, terminalId: orphan.id)
        var workspace = Workspace(projects: [project], tasks: [])
        workspace.terminals = [orphan]
        let tree = SidebarTree.build(workspace, tabs: [tab])
        #expect(tree.otherTabs.map(\.id) == ["s1"])
        #expect(tree.projects[0].terminals.isEmpty)
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

    // MARK: Panel tabs

    private func panelTab(_ id: String, _ tabId: Int, _ panel: PanelTab, task: UUID? = nil) -> TabSnapshot {
        TabSnapshot(id: id, tabId: tabId, title: id, taskId: task, projectId: task == nil ? nil : project.id, panel: panel)
    }

    @Test func aTaggedTabIsNotAnOtherTab() {
        let tab = panelTab("s1", 1, .ssh(alias: "staging"))
        let tree = SidebarTree.build(Workspace(projects: [project], tasks: []), tabs: [tab, self.tab("s2", 2, task: nil)])
        #expect(tree.panelTabs.map(\.id) == ["s1"])
        #expect(tree.otherTabs.map(\.id) == ["s2"])
    }

    @Test func anOrphanedPanelTabIsAnOtherTab() {
        let tab = panelTab("s1", 1, .ssh(alias: "staging"))
        let tree = SidebarTree.build(Workspace(projects: [project], tasks: []), tabs: [tab], isOwned: { _ in false })
        #expect(tree.panelTabs.isEmpty)
        #expect(tree.otherTabs.map(\.id) == ["s1"])
    }

    @Test func aSplitKeepsItsPanelTag() {
        let panel = PanelTab.file(project: project.id, path: "src/app.ts")
        let found = TabSnapshot.panel(ofPanes: [nil, panel.tagValue])
        let tab = TabSnapshot(id: "s1", tabId: 1, title: "app.ts", taskId: nil, projectId: nil, paneCount: 2, panel: found)
        let tree = SidebarTree.build(Workspace(projects: [project], tasks: []), tabs: [tab])
        #expect(tree.panelTabs.map(\.id) == ["s1"])
        #expect(tree.panelTabs[0].panel == panel)
    }

    @Test func aTaskTagWinsOverAPanelTag() {
        let a = login
        let tab = panelTab("s1", 1, .ssh(alias: "staging"), task: a.id)
        let tree = SidebarTree.build(Workspace(projects: [project], tasks: [a]), tabs: [tab])
        #expect(tree.projects[0].tasks[0].tabs.map(\.id) == ["s1"])
        #expect(tree.panelTabs.isEmpty)
        #expect(tree.otherTabs.isEmpty)
    }
}
