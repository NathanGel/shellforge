import Testing
import Foundation
@testable import ShellforgeCore
@testable import ShellforgeTestSupport

@Suite struct ActivityLayoutTests {
    @Test func defaultOrderIsSessionsThenMetrics() {
        #expect(ActivityLayout(saved: nil).order == [.sessions, .metrics])
    }

    @Test func unknownPanelsAreDroppedAndMissingOnesAppended() {
        #expect(ActivityLayout(saved: ["git", "metrics", "metrics"]).order == [.metrics, .sessions])
    }

    @Test func moveReorders() {
        var layout = ActivityLayout(saved: nil)
        layout.move(.metrics, before: .sessions)
        #expect(layout.order == [.metrics, .sessions])
        layout.move(.metrics, before: nil)
        #expect(layout.order == [.sessions, .metrics])
    }

    @Test func movingAPanelBeforeItselfChangesNothing() {
        var layout = ActivityLayout(saved: nil)
        layout.move(.sessions, before: .sessions)
        #expect(layout.order == [.sessions, .metrics])
    }

    @Test func savedValueRoundTrips() {
        let defaults = ScratchDefaults.make()
        #expect(ActivityOrderStore.load(defaults) == nil)
        var layout = ActivityLayout(saved: ActivityOrderStore.load(defaults))
        layout.move(.metrics, before: .sessions)
        ActivityOrderStore.save(layout.savedValue, to: defaults)
        #expect(ActivityLayout(saved: ActivityOrderStore.load(defaults)).order == [.metrics, .sessions])
    }
}
