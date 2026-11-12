import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

/// A tab a panel opened carries its panel’s tag; the sidebar lists it by owner while that owner
/// exists, and under Other Tabs once it is gone.
@MainActor @Suite struct PanelTabsModelTests {
    @MainActor private struct Setup {
        let model: SidebarModel, document: WorkspaceDocument, host: FakeTerminalHost
        let demo: Project, task: TaskItem
    }

    private func setup() throws -> Setup {
        let folder = TestScratch.root.appendingPathComponent("shellforge-panel-tabs-\(UUID().uuidString)")
        let document = WorkspaceDocument(store: WorkspaceStore(folder: folder))
        let demo = Project(name: "demo", path: "/demo")
        let task = TaskItem(projectId: demo.id, title: "Fix login", branch: "fix-login", worktreePath: "/demo-worktrees/fix-login",
                            baseBranch: "main")
        try document.update { w in w.projects.append(demo); w.tasks.append(task) }
        let launcher = CommandLauncher(resolve: { ResolvedEnvironment(variables: ["PATH": "/usr/bin"], source: .loginShell("/bin/zsh")) })
        let host = FakeTerminalHost()
        let model = SidebarModel(host: host, document: document, launcher: launcher, jiraSettings: { nil })
        return Setup(model: model, document: document, host: host, demo: demo, task: task)
    }

    private func tab(_ n: Int, _ panel: PanelTab?) -> TabSnapshot {
        TabSnapshot(id: "s\(n)", tabId: n, title: "tab \(n)", taskId: nil, projectId: nil, panel: panel)
    }

    @Test func openTabPassesItsPanelTag() throws {
        let s = try setup()
        s.host.openTab(in: "/demo", title: "ssh staging", command: "ssh staging", panel: .ssh(alias: "staging"))
        s.host.openTab(in: "/demo", title: "db-tunnel", command: "ssh db-tunnel")
        #expect(s.host.openedPlain.map(\.panel) == [.ssh(alias: "staging"), nil], "the old call opens a tab of no panel")
        #expect(s.model.panelTabs(for: .ssh(alias: "staging")).map(\.title) == ["ssh staging"])
        #expect(s.model.tree.otherTabs.map(\.title) == ["db-tunnel"])
    }

    @Test func panelTabsAreListedByOwner() throws {
        let s = try setup()
        let file = PanelTab.file(project: s.demo.id, path: "src/app.ts")
        s.host.tabs = [tab(4, .ssh(alias: "staging")), tab(1, file), tab(2, .ssh(alias: "staging")), tab(3, nil)]
        s.host.onChange?()
        #expect(s.model.panelTabs(for: .ssh(alias: "staging")).map(\.id) == ["s2", "s4"], "in tab order")
        #expect(s.model.panelTabs(for: file).map(\.id) == ["s1"])
        #expect(s.model.panelTabs(for: .ssh(alias: "db-tunnel")).isEmpty)
        #expect(s.model.tree.otherTabs.map(\.id) == ["s3"])
    }

    /// Owned until the config is read; once read, only while the alias is in it.
    @Test func anSSHTabLeavesForOtherTabsWhenItsHostLeavesTheConfig() throws {
        let s = try setup()
        s.host.tabs = [tab(1, .ssh(alias: "staging"))]
        s.host.onChange?()
        #expect(s.model.sshHosts == nil)
        #expect(s.model.panelTabs(for: .ssh(alias: "staging")).map(\.id) == ["s1"], "owned before the config is read")

        s.model.take([SSHHost(alias: "staging", forwards: [])], generation: s.model.beginSSHRead())
        #expect(s.model.panelTabs(for: .ssh(alias: "staging")).map(\.id) == ["s1"])

        s.model.take([SSHHost(alias: "db-tunnel", forwards: [])], generation: s.model.beginSSHRead())
        #expect(s.model.panelTabs(for: .ssh(alias: "staging")).isEmpty, "rebuilt when the hosts change")
        #expect(s.model.tree.otherTabs.map(\.id) == ["s1"])
    }

    @Test func aFileTabIsOwnedWhileItsProjectExists() throws {
        let s = try setup()
        let file = PanelTab.file(project: s.demo.id, path: "src/app.ts")
        s.host.tabs = [tab(1, file), tab(2, .file(project: UUID(), path: "src/app.ts"))]
        s.host.onChange?()
        #expect(s.model.panelTabs(for: file).map(\.id) == ["s1"])
        #expect(s.model.tree.otherTabs.map(\.id) == ["s2"], "a project that isn’t there")

        try s.document.update { $0.tasks.removeAll(); $0.projects.removeAll() }
        #expect(s.model.panelTabs(for: file).isEmpty)
        #expect(s.model.tree.otherTabs.map(\.id) == ["s1", "s2"])
    }

    /// A selected panel tab is the footer's row, as it was under Other Tabs.
    @Test func aSelectedSSHTabHasAFooterRow() throws {
        let s = try setup()
        s.host.tabs = [tab(1, .ssh(alias: "staging"))]
        s.host.selectedTabId = "s1"
        s.host.onChange?()
        #expect(s.model.panelTabs(for: .ssh(alias: "staging")).map(\.id) == ["s1"])
        #expect(s.model.footerRow != nil)
    }

    /// An ssh tab open before the config was ever read has it read, though no project names a host:
    /// the tab of a host the config no longer has returns to Other Tabs without the SSH panel.
    @Test func anSSHTabHasTheConfigRead() async throws {
        let folder = TestScratch.root.appendingPathComponent("shellforge-panel-tabs-ssh-\(UUID().uuidString)")
        let config = folder.appendingPathComponent("ssh/config")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "Host build-box\n  HostName build-box.example.com\n".write(to: config, atomically: true, encoding: .utf8)
        let document = WorkspaceDocument(store: WorkspaceStore(folder: folder.appendingPathComponent("workspace")))
        try document.update { $0.projects.append(Project(name: "demo", path: "/demo")) }
        let launcher = CommandLauncher(resolve: { ResolvedEnvironment(variables: ["PATH": "/usr/bin"], source: .loginShell("/bin/zsh")) })
        let host = FakeTerminalHost()
        let model = SidebarModel(host: host, document: document, launcher: launcher, jiraSettings: { nil },
                                 sshConfig: SSHConfigSource(file: config, home: folder))
        host.onChange?()
        #expect(model.sshHosts == nil, "no project names a host and no ssh tab is open: nothing is read")
        host.tabs = [tab(1, .ssh(alias: "staging"))]
        host.onChange?()
        #expect(await eventually { model.sshHosts != nil })
        #expect(model.tree.otherTabs.map(\.id) == ["s1"])
    }

    /// A repository id is `project:<uuid>` or `task:<uuid>`, in either case, as the Git panel writes it.
    @Test func aDiffTabIsOwnedWhileItsRepositoriesProjectOrTaskExists() throws {
        let s = try setup()
        let ofProject = PanelTab.diff(repo: "project:" + s.demo.id.uuidString, path: "src/app.ts")
        let ofTask = PanelTab.diff(repo: "task:" + s.task.id.uuidString.lowercased(), path: "src/app.ts")
        let ofGoneTask = PanelTab.diff(repo: "task:" + UUID().uuidString, path: "src/app.ts")
        let ofProjectAsTask = PanelTab.diff(repo: "task:" + s.demo.id.uuidString, path: "src/app.ts")
        s.host.tabs = [tab(1, ofProject), tab(2, ofTask), tab(3, ofGoneTask), tab(4, ofProjectAsTask)]
        s.host.onChange?()
        #expect(s.model.tree.panelTabs.map(\.id) == ["s1", "s2"])
        #expect(s.model.tree.otherTabs.map(\.id) == ["s3", "s4"])

        try s.document.update { $0.tasks.removeAll() }
        #expect(s.model.tree.panelTabs.map(\.id) == ["s1"])
        #expect(s.model.tree.otherTabs.map(\.id) == ["s2", "s3", "s4"])
    }
}
