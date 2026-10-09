// Ported from AiTerm (app/Tests/AiTermTestSupport/TestClock.swift), GPLv3, Laurens D'Hondt.
import Foundation
import ShellforgeCore

/// A clock a test moves by hand. A resolver reads its clock from whichever thread asks it, so the
/// time lives behind a lock rather than in a `var` the `now` closure captures.
final class TestClock: Sendable {
    private let date: Locked<Date>
    init(_ start: Date = Date(timeIntervalSince1970: 0)) { date = Locked(start) }

    var now: Date { date.withLock { $0 } }
    func advance(by seconds: TimeInterval) { date.withLock { $0 += seconds } }
}
