import Foundation
import Testing
@testable import ShellforgeUI

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
    @Test func aDelayedScheduleFiresOnceForSignalsBeforeIt() async {
        var fired = 0
        let coalescer = ChangeCoalescer(schedule: ChangeCoalescer.after(0.3), fire: { fired += 1 })
        coalescer.signal()
        await Task.yield()
        coalescer.signal()
        #expect(fired == 0, "nothing fires before the delay")
        while fired == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        coalescer.signal()
        #expect(fired == 1, "both signals before the delay were one fire")
        while fired == 1 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(fired == 2)
    }
}
