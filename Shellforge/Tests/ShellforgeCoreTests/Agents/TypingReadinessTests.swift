import Foundation
import Testing
@testable import ShellforgeCore

@Suite struct TypingReadinessTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    @Test func waitsForTheAgent() {
        var r = TypingReadiness(armedAt: t0)
        #expect(r.observe(.shell, outputBytes: 0, now: at(0)) == .wait)
        #expect(r.observe(.shell, outputBytes: 500, now: at(10)) == .wait)
    }

    @Test func typesAfterQuietFollowingOutput() {
        var r = TypingReadiness(armedAt: t0)
        _ = r.observe(.agent, outputBytes: 0, now: at(0))
        _ = r.observe(.agent, outputBytes: 2000, now: at(0.5))
        for t in stride(from: 1.0, to: 3.0, by: 0.5) {
            #expect(r.observe(.agent, outputBytes: 2000, now: at(t)) == .wait)
        }
        #expect(r.observe(.agent, outputBytes: 2000, now: at(3.0)) == .type)
    }

    /// Banner, a 1.5 s load, a second draw: the pause is not the agent being ready.
    @Test func aStartUpPauseIsNotQuiet() {
        var r = TypingReadiness(armedAt: t0)
        _ = r.observe(.agent, outputBytes: 0, now: at(0))
        _ = r.observe(.agent, outputBytes: 3000, now: at(0.5))
        for t in stride(from: 1.0, through: 2.0, by: 0.5) {
            #expect(r.observe(.agent, outputBytes: 3000, now: at(t)) == .wait)
        }
        #expect(r.observe(.agent, outputBytes: 6000, now: at(2.5)) == .wait)
        // Within a second of the second draw there is no type, even though the window is old enough.
        #expect(r.observe(.agent, outputBytes: 6000, now: at(3.0)) == .wait)
        #expect(r.observe(.agent, outputBytes: 6000, now: at(3.5)) == .type)
    }

    @Test func aBurstInOneHalfIsQuiet() {
        var r = TypingReadiness(armedAt: t0)
        _ = r.observe(.agent, outputBytes: 0, now: at(0))
        _ = r.observe(.agent, outputBytes: 4000, now: at(0.5))
        var d = TypingReadiness.Decision.wait
        for t in stride(from: 1.0, through: 3.0, by: 0.5) { d = r.observe(.agent, outputBytes: 4000, now: at(t)) }
        #expect(d == .type)
    }

    @Test func typesAtTheCeilingUnderSteadyOutput() {
        var r = TypingReadiness(armedAt: t0)
        var bytes = 0
        var decisions: [TypingReadiness.Decision] = []
        for i in 0...16 {
            bytes += 100
            decisions.append(r.observe(.agent, outputBytes: bytes, now: at(Double(i) * 0.5)))
        }
        #expect(decisions[0..<16].allSatisfy { $0 == .wait })
        #expect(decisions[16] == .type)
    }

    @Test func typesAtTheCeilingWithNoOutput() {
        var r = TypingReadiness(armedAt: t0)
        #expect(r.observe(.agent, outputBytes: 0, now: at(0)) == .wait)
        #expect(r.observe(.agent, outputBytes: 0, now: at(7.9)) == .wait)
        #expect(r.observe(.agent, outputBytes: 0, now: at(8)) == .type)
    }

    @Test func typesOnlyOnce() {
        var r = TypingReadiness(armedAt: t0)
        _ = r.observe(.agent, outputBytes: 0, now: at(0))
        #expect(r.observe(.agent, outputBytes: 0, now: at(8)) == .type)
        #expect(r.observe(.agent, outputBytes: 0, now: at(8.5)) == .abandon)
        #expect(r.observe(.agent, outputBytes: 0, now: at(20)) == .abandon)
    }

    @Test func neverTypesIntoAShellAfterTheAgentExits() {
        var r = TypingReadiness(armedAt: t0)
        _ = r.observe(.agent, outputBytes: 0, now: at(0))
        #expect(r.observe(.shell, outputBytes: 50, now: at(2)) == .abandon)
        #expect(r.observe(.shell, outputBytes: 50, now: at(9)) == .abandon)
        #expect(r.observe(.agent, outputBytes: 50, now: at(10)) == .abandon)
    }

    @Test func abandonsWhenNoAgentRuns() {
        var r = TypingReadiness(armedAt: t0)
        #expect(r.observe(.shell, outputBytes: 0, now: at(29.9)) == .wait)
        #expect(r.observe(.shell, outputBytes: 0, now: at(30)) == .abandon)
    }

    @Test func outputBeforeTheAgentRanIsNotTheAgents() {
        var r = TypingReadiness(armedAt: t0)
        _ = r.observe(.shell, outputBytes: 100, now: at(0))
        _ = r.observe(.shell, outputBytes: 5000, now: at(1))
        // The agent starts at 5000 bytes and prints nothing: only the ceiling types.
        for t in stride(from: 2.0, to: 9.0, by: 0.5) {
            #expect(r.observe(.agent, outputBytes: 5000, now: at(t)) == .wait)
        }
        #expect(r.observe(.agent, outputBytes: 5000, now: at(10)) == .type)
    }

    @Test func aCounterThatGoesBackIsStartedOver() {
        var r = TypingReadiness(armedAt: t0)
        _ = r.observe(.agent, outputBytes: 0, now: at(0))
        _ = r.observe(.agent, outputBytes: 9000, now: at(0.5))
        // The counter restarts at 0: nothing printed since, so no quiet verdict before the ceiling.
        for t in stride(from: 1.0, to: 8.0, by: 0.5) {
            #expect(r.observe(.agent, outputBytes: 0, now: at(t)) == .wait)
        }
        #expect(r.observe(.agent, outputBytes: 0, now: at(8)) == .type)
    }

    @Test func twoSamplesAtOneTimeGiveNoVerdictError() {
        var r = TypingReadiness(armedAt: t0)
        _ = r.observe(.agent, outputBytes: 0, now: at(0))
        _ = r.observe(.agent, outputBytes: 500, now: at(1))
        #expect(r.observe(.agent, outputBytes: 600, now: at(1)) == .wait)
    }

    @Test func rateMatchesTheHelper() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: repo.appendingPathComponent("daemon/shellforged/auto_status.py"), encoding: .utf8)
        let match = try #require(source.firstMatch(of: /(?m)^MIN_OUTPUT_RATE\s*=\s*([0-9.]+)\s*(#.*)?$/),
                                 "auto_status.py has no MIN_OUTPUT_RATE = <number> line")
        #expect(Double(match.1) == TypingReadiness.minOutputRate)
    }

    /// The runner (`shellforge-run`) waits up to the helper's take; it is not the agent, so its time
    /// in the foreground counts toward no ceiling, and when it exits to the shell nothing is typed.
    @Test func aRunnerPastTheCeilingThatExitsIsAbandoned() {
        var r = TypingReadiness(armedAt: t0)
        #expect(r.observe(.shell, outputBytes: 0, now: at(0)) == .wait)
        for t in stride(from: 0.25, through: 12.0, by: 0.25) {
            #expect(r.observe(.runner, outputBytes: 80, now: at(t)) == .wait, "at \(t) s")
        }
        #expect(r.observe(.shell, outputBytes: 200, now: at(12.25)) == .abandon)
        #expect(r.observe(.agent, outputBytes: 200, now: at(13)) == .abandon)
    }

    /// An agent that appears late, after 9 s of the runner, gets its own quiet window and ceiling.
    @Test func anAgentThatAppearsLateTypesAfterItsOwnQuietWindow() {
        var r = TypingReadiness(armedAt: t0)
        for t in stride(from: 0.0, to: 9.0, by: 0.25) {
            #expect(r.observe(.runner, outputBytes: 0, now: at(t)) == .wait, "at \(t) s")
        }
        #expect(r.observe(.agent, outputBytes: 0, now: at(9)) == .wait)
        #expect(r.observe(.agent, outputBytes: 2000, now: at(9.5)) == .wait)
        for t in stride(from: 10.0, to: 12.0, by: 0.5) {
            #expect(r.observe(.agent, outputBytes: 2000, now: at(t)) == .wait, "at \(t) s")
        }
        #expect(r.observe(.agent, outputBytes: 2000, now: at(12.0)) == .type)
    }

    /// Another program in the foreground is never typed into; the prompt is given up in time.
    @Test func anotherProgramIsNeverTypedInto() {
        var r = TypingReadiness(armedAt: t0)
        for t in stride(from: 0.0, to: TypingReadiness.giveUp, by: 0.5) {
            #expect(r.observe(.other, outputBytes: Int(t * 100), now: at(t)) == .wait, "at \(t) s")
        }
        #expect(r.observe(.other, outputBytes: 9000, now: at(TypingReadiness.giveUp)) == .abandon)
    }
}
