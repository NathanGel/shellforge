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
}
