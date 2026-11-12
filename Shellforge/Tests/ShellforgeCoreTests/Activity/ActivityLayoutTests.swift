import Testing
import Foundation
@testable import ShellforgeCore
@testable import ShellforgeTestSupport

@Suite struct ActivityLayoutTests {
    @Test func defaultOrderIsSessionsMetricsFilesThenGit() {
        #expect(ActivityLayout(saved: nil).order == [.sessions, .metrics, .files, .git, .ssh])
    }

    @Test func unknownPanelsAreDroppedAndMissingOnesAppended() {
        #expect(ActivityLayout(saved: ["svn", "metrics", "metrics"]).order == [.metrics, .sessions, .files, .git, .ssh])
    }

    @Test func moveReorders() {
        var layout = ActivityLayout(saved: nil)
        layout.move(.metrics, before: .sessions)
        #expect(layout.order == [.metrics, .sessions, .files, .git, .ssh])
        layout.move(.metrics, before: nil)
        #expect(layout.order == [.sessions, .files, .git, .ssh, .metrics])
    }

    @Test func movingAPanelBeforeItselfChangesNothing() {
        var layout = ActivityLayout(saved: nil)
        layout.move(.sessions, before: .sessions)
        #expect(layout.order == [.sessions, .metrics, .files, .git, .ssh])
    }

    /// A saved order from before the Files panel keeps its order and gains Files (then Git) at the end.
    @Test func filesIsAPanel() {
        #expect(ActivityLayout(saved: ["sessions", "metrics"]).order == [.sessions, .metrics, .files, .git, .ssh])
        #expect(ActivityPanel.files.title == "Files")
        #expect(ActivityPanel.files.symbol == "folder")
    }

    @Test func savedValueRoundTrips() {
        let defaults = ScratchDefaults.make()
        #expect(ActivityOrderStore.load(defaults) == nil)
        var layout = ActivityLayout(saved: ActivityOrderStore.load(defaults))
        layout.move(.metrics, before: .sessions)
        ActivityOrderStore.save(layout.savedValue, to: defaults)
        #expect(ActivityLayout(saved: ActivityOrderStore.load(defaults)).order == [.metrics, .sessions, .files, .git, .ssh])
    }
}
