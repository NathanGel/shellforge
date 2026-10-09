// Ported from AiTerm (Tests/AiTermTestSupport/Eventually.swift), GPLv3, Laurens D'Hondt.
// Debug only: these record issues through swift-testing, whose macros a plain release build of the
// package (the library is built with it, though only tests use it) does not have.
#if DEBUG
import Foundation
import Testing

/// Waits for something a test expects to happen, instead of sleeping for as long as it usually
/// takes. A pass ends the moment `condition` holds, so the wait costs what the thing costs; only a
/// failure waits out `timeout`, which is `TestDeadline`'s so a loaded machine does not flake it.
///
/// `condition` is checked in the caller's isolation, between turns of its executor, so a test on
/// the main actor reads its own state and the thing it waits for can run on that actor meanwhile.
/// A timeout is recorded as an issue, at the caller's line and saying what was waited for, so a
/// caller that ignores the result still fails. It also returns whether the condition held, for a
/// test that wants to stop there (`try #require(await eventually …)`).
///
/// Only for what is *expected*. A test that shows something does not happen keeps a fixed window,
/// which stays as short as it can be.
///
/// The timeout counts the time the condition had to come true, not time the caller spent waiting
/// for a turn: a check that comes back later than ``lateTurn`` counts as that long. Under the
/// parallel runner a main-actor test's next check queues behind every other main-actor test the
/// runner has started — over ten seconds of their bodies, at the start of the app's run — and the
/// thing it waits for, due on the same actor a moment after the check was, queues right behind it.
/// Charged in full, that queue alone timed out a wait whose condition held at the very next check.
///
/// The wall clock still has the last word: a wait that has lasted ``wallClockFactor`` times its
/// timeout ends there, whatever it was charged, so a condition that never holds on a host that
/// stays busy fails within a minute rather than as long as the host is busy.
///
/// Neither ends the wait on a check that came back late, though, while it has not had the turn
/// after it: what came due while the caller was kept waiting is queued right behind that check,
/// so it gets one more turn — once, so a host that stays busy still ends the wait. A busy run
/// otherwise timed out a wait at a late check whose condition held at the next one.
@discardableResult
func eventually(describing what: @autoclosure () -> String = "the condition", timeout: TimeInterval = TestDeadline.seconds,
                every interval: Duration = .milliseconds(5), sourceLocation: SourceLocation = #_sourceLocation,
                isolation: isolated (any Actor)? = #isolation, _ condition: () -> Bool) async -> Bool {
    let budget = Duration.seconds(timeout), started = ContinuousClock.now
    var waited = Duration.zero, checked = started, cameLate = false, hadTheTurnAfter = false
    while !condition() {
        if Task.isCancelled { return false }
        let elapsed = ContinuousClock.now - started
        let overBudget = waited >= budget, pastCeiling = elapsed >= budget * wallClockFactor
        if overBudget || pastCeiling {
            if cameLate && !hadTheTurnAfter {
                hadTheTurnAfter = true
            } else if pastCeiling {
                // The wall clock's verdict wins when both have run out: on a busy host the turn
                // after a late one can be late too, and charge the budget past its end as well.
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                Issue.record("Timed out after \(timeout) s waiting for \(what()) (wall clock: \(String(format: "%.1f", seconds)) s)",
                             sourceLocation: sourceLocation)
                return false
            } else {
                Issue.record("Timed out after \(timeout) s waiting for \(what())", sourceLocation: sourceLocation)
                return false
            }
        }
        try? await Task.sleep(for: interval)
        let now = ContinuousClock.now
        cameLate = now - checked > lateTurn
        waited += min(now - checked, lateTurn)
        checked = now
    }
    return true
}

/// How long a wait between two checks of `eventually` is charged at most. Longer is the caller
/// kept from its turn — its actor, or Swift's cooperative pool, busy with other tests' work —
/// rather than anything the condition was given; a loaded machine's jitter stays well below it.
private let lateTurn = Duration.milliseconds(100)

/// How many times its timeout `eventually` waits by the wall clock before it gives up, however
/// little of that it was charged: a minute, for `TestDeadline`'s ten seconds.
let wallClockFactor = 6

/// `eventually` for a synchronous test that waits on threads it started: the wait blocks the test's
/// own thread rather than suspending, so neither it nor what it waits for needs another worker of
/// Swift's cooperative pool — which the parallel runner can keep busy with blocking tests for longer
/// than any deadline. Not for async code, where it would park a worker itself.
@available(*, noasync, message: "Blocks its thread; await `eventually` instead.")
@discardableResult
func blockUntil(describing what: @autoclosure () -> String = "the condition", timeout: TimeInterval = TestDeadline.seconds,
                sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline {
            Issue.record("Timed out after \(timeout) s waiting for \(what())", sourceLocation: sourceLocation)
            return false
        }
        Thread.sleep(forTimeInterval: 0.005)
    }
    return true
}
#endif
