import Combine
import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

/// `@Published` announces every assignment, equal or not, and every announcement redraws the
/// window's whole sidebar. The daemon's events and iTerm2's notifications arrive many times a
/// minute: one that changes nothing redraws nothing.
@MainActor @Suite struct RedrawTests {
    private func model() throws -> (SidebarModel, FakeTerminalHost, FakeFeed) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shellforge-redraw-\(UUID().uuidString)")
        let document = WorkspaceDocument(store: WorkspaceStore(folder: folder))
        try document.update { $0.projects.append(Project(name: "api", path: "/api")) }
        let launcher = CommandLauncher(resolve: { ResolvedEnvironment(variables: ["PATH": "/usr/bin"], source: .loginShell("/bin/zsh")) })
        let host = FakeTerminalHost(), feed = FakeFeed()
        return (SidebarModel(host: host, document: document, launcher: launcher, feed: feed, jiraSettings: { nil }), host, feed)
    }

    private func redraws(of model: SidebarModel, during work: () -> Void) -> Int {
        var count = 0
        let subscription = model.objectWillChange.sink { count += 1 }
        work()
        subscription.cancel()
        return count
    }

    @Test func anEqualStoreRedrawsNothing() throws {
        let (model, _, feed) = try model()
        feed.sayAll([(state: .working, session: "s1", task: UUID(), agent: .claude)])
        let same = feed.store
        #expect(redraws(of: model) { feed.store = same } == 0)
    }

    @Test func anEqualRefreshRedrawsNothing() throws {
        let (model, host, _) = try model()
        host.onChange?()
        #expect(redraws(of: model) { host.onChange?() } == 0)
    }
}
