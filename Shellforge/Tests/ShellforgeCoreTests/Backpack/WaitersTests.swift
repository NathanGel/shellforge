import Foundation
import Testing
@testable import ShellforgeCore

/// Everyone waiting on one answer gets it: a second Allow… pressed while macOS still asks no longer
/// strands the first (LiveLocation).
@MainActor @Suite struct WaitersTests {
    @Test func twoRequestsBothReturn() async {
        let waiters = Waiters<Bool>()
        var asked = 0
        let first = Task { await waiters.wait { asked += 1 } }
        let second = Task { await waiters.wait { asked += 1 } }
        while waiters.count < 2 { await Task.yield() }
        waiters.resumeAll(true)
        let answers = (await first.value, await second.value)
        #expect(answers.0 && answers.1)
        #expect(asked == 2)
        #expect(waiters.count == 0)
    }
}
