import AppKit
import Combine
import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

/// A window's sidebar goes when its window does: nothing it subscribed to, scheduled or handed out
/// keeps it, its host or its feed's subscriptions alive (PRD goal 7).
@MainActor @Suite struct ReleaseTests {
    @Test func aUsedSidebarModelIsReleased() async throws {
        let repo = try GitRepoForUI()
        let document = WorkspaceDocument(store: WorkspaceStore(folder: TestScratch.root.appendingPathComponent("release-\(UUID().uuidString)")))
        let feed = FakeFeed()
        weak var released: SidebarModel?
        weak var releasedHost: FakeTerminalHost?
        do {
            let host = FakeTerminalHost()
            let model = SidebarModel(host: host, document: document, launcher: repo.launcher, feed: feed, jiraSettings: { nil })
            released = model; releasedHost = host
            model.diffStats = DiffStats(git: LauncherGit(launcher: repo.launcher), ttl: 0)
            await model.addProject(folder: repo.path)
            let project = try #require(document.workspace.projects.first)
            await model.newTask(title: "Release", in: project.id)
            await model.refreshDiffs()
            model.noticeLifetime = .milliseconds(20)
            model.show(notice: "said")
            _ = model.rows
            await eventually { model.providers[project.id] != nil }
        }
        // Background work a model started ends; then nothing may hold it.
        #expect(await eventually { released == nil }, "the model outlived its window")
        #expect(releasedHost == nil)
        _ = feed
    }

    /// ⌘B's registry keeps what a window registered only while the window lives: its presenter —
    /// which holds the window's whole sidebar — goes with it, not whenever the table next resizes.
    @Test func aClosedWindowsBackpackPresenterIsReleased() {
        final class Probe {}
        let sheets = BackpackSheets()
        weak var probe: Probe?
        autoreleasepool {
            let window = NSObject(), held = Probe()
            probe = held
            sheets.register(window) { _ = held }
            #expect(sheets.count == 1)
        }
        #expect(probe == nil, "the presenter outlived its window")
        #expect(sheets.count == 0)
        #expect(sheets.present(for: nil) == false)
    }

    /// Thirty windows opened and closed as the app opens them — each a real sidebar view in a real
    /// window, registered for ⌘B — leave no sidebar behind (M6c's churn).
    @Test func aChurnOfWindowsLeavesNoSidebars() async throws {
        let document = WorkspaceDocument(store: WorkspaceStore(folder: TestScratch.root.appendingPathComponent("churn-\(UUID().uuidString)")))
        let launcher = try GitRepoForUI().launcher
        let home = TestScratch.root.appendingPathComponent("churn-home-\(UUID().uuidString)")
        let hooks = AgentHooksModel(integrations: HookIntegrations(home: home, resources: .bundled(resourceURL: nil)), names: [:])
        let machine = MachineMonitor(sensor: InertMachineSensor(), power: InertPower())
        let backpack = BackpackController(ports: .inert, settings: BackpackSettings(defaults: nil), toast: { _ in })
        let sheets = BackpackSheets()
        var models: [WeakModel] = []
        for _ in 0..<30 {
            autoreleasepool {
                let model = SidebarModel(host: FakeTerminalHost(), document: document, launcher: launcher, jiraSettings: { nil })
                models.append(WeakModel(model))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 400), styleMask: [.titled],
                                      backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = ShellforgeSidebar.makeView(model: model, chooseFolder: { nil }, hooks: hooks, machine: machine,
                                                                backpack: backpack, zoom: SidebarZoom(settings: SidebarLayoutSettings(defaults: ScratchDefaults.make())),
                                                                showBackpack: { [weak window] present in
                    if let window { sheets.register(window, present) }
                })
                window.displayIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                window.close()
                window.contentView = nil
            }
        }
        #expect(sheets.count == 0)
        #expect(await eventually { models.allSatisfy { $0.model == nil } }, "\(models.filter { $0.model != nil }.count) sidebars outlived their windows")
    }
}

private final class WeakModel {
    weak var model: SidebarModel?
    init(_ model: SidebarModel) { self.model = model }
}
