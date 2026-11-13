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
    }

    @Test func savedValueRoundTrips() {
        let defaults = ScratchDefaults.make()
        #expect(ActivityOrderStore.load(defaults) == nil)
        var layout = ActivityLayout(saved: ActivityOrderStore.load(defaults))
        layout.move(.metrics, before: .sessions)
        ActivityOrderStore.save(layout.savedValue, to: defaults)
        #expect(ActivityLayout(saved: ActivityOrderStore.load(defaults)).order == [.metrics, .sessions, .files, .git, .ssh])
    }

    /// A hidden panel leaves the bar's order of shown panels but keeps its place for when it comes back.
    @Test func hiddenPanelsLeaveTheVisibleOrder() {
        var layout = ActivityLayout(saved: nil, hidden: ["metrics", "git"])
        #expect(layout.visibleOrder == [.sessions, .files, .ssh])
        #expect(layout.order == [.sessions, .metrics, .files, .git, .ssh])
        #expect(layout.savedHidden == ["metrics", "git"])
        let shown = layout.setHidden(.metrics, false)
        #expect(shown)
        #expect(layout.visibleOrder == [.sessions, .metrics, .files, .ssh])
    }

    @Test func hidingTheSelectedPanelSelectsTheFirstShown() {
        var layout = ActivityLayout(saved: ["files", "sessions"], selected: .files)
        let hid = layout.setHidden(.files, true)
        #expect(hid)
        #expect(layout.selected == .sessions)
        #expect(ActivityLayout(saved: nil, hidden: ["sessions"], selected: .sessions).selected == .metrics, "a saved hidden selection")
    }

    @Test func theLastPanelCannotBeHidden() {
        var layout = ActivityLayout(saved: nil, hidden: ["sessions", "metrics", "files", "git"], selected: .ssh)
        let before = layout
        let hid = layout.setHidden(.ssh, true)
        #expect(!hid)
        #expect(layout == before, "the refused hide changed something")
        #expect(ActivityLayout(saved: ["git"], hidden: ActivityPanel.allCases.map(\.rawValue)).visibleOrder == [.git],
                "a saved value hiding every panel shows the first")
    }

    @Test func unknownHiddenValuesAreIgnored() {
        let layout = ActivityLayout(saved: nil, hidden: ["svn", "files", "files"])
        #expect(layout.hidden == [.files])
        #expect(layout.savedHidden == ["files"])
    }

    @Test func hiddenRoundTrips() {
        let defaults = ScratchDefaults.make()
        #expect(ActivityHiddenStore.key == "NoSyncShellforgeActivityHidden")
        #expect(ActivityHiddenStore.load(defaults) == nil)
        ActivityHiddenStore.save(["git"], to: defaults)
        #expect(ActivityLayout(saved: nil, hidden: ActivityHiddenStore.load(defaults)).hidden == [.git])
    }
}
