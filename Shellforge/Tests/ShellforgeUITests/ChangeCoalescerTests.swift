import Foundation
import Testing
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

/// iTerm2 posts a notification per title change — several a second while an agent works — and each
/// rebuilt the sidebar and resent the session list. A burst in one run-loop turn is one change.
@MainActor @Suite struct ChangeCoalescerTests {
    @Test func titleBurstsCoalesce() {
        var scheduled: [@MainActor () -> Void] = []
        var fired = 0
        let coalescer = ChangeCoalescer(schedule: { scheduled.append($0) }, fire: { fired += 1 })
        coalescer.signal()
        coalescer.signal()
        coalescer.signal()
        #expect(scheduled.count == 1 && fired == 0, "one turn scheduled, nothing fired yet")
        scheduled.removeFirst()()
        #expect(fired == 1)
        coalescer.signal()
        #expect(scheduled.count == 1, "a signal after the fire schedules again")
        scheduled.removeFirst()()
        #expect(fired == 2)
    }

    /// The session report's: signals spread over a quarter of a second are one fire, at its end.
    /// The delay's clock is the test's: what is due runs when the test says the time has come.
    @Test func aDelayedScheduleFiresOnceForSignalsBeforeIt() {
        var due: [(seconds: TimeInterval, work: @MainActor () -> Void)] = []
        var fired = 0
        let coalescer = ChangeCoalescer(schedule: ChangeCoalescer.after(0.3, later: { due.append(($0, $1)) }), fire: { fired += 1 })
        coalescer.signal()
        coalescer.signal()
        #expect(due.map(\.seconds) == [0.3], "one fire, the delay out")
        #expect(fired == 0, "nothing fires before the delay")
        due.removeFirst().work()
        #expect(fired == 1, "both signals before the delay were one fire")
        coalescer.signal()
        #expect(due.map(\.seconds) == [0.3], "a signal after the fire waits the delay again")
        #expect(fired == 1)
        due.removeFirst().work()
        #expect(fired == 2)
    }

    /// The live delay runs on the main queue, `seconds` out.
    @Test func theLiveDelayRunsLater() async {
        var fired = false
        ChangeCoalescer.mainQueueAfter(0.01) { fired = true }
        #expect(!fired, "not at once")
        #expect(await eventually { fired })
    }
}
