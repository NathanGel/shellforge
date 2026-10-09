// Ported from AiTerm (Tests/AiTermTestSupport/TestDeadline.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// How long a test waits for something it expects to happen. Only a failure waits it out — a pass
/// ends the moment its condition holds — so it is long enough for a loaded machine, where the three
/// seconds these waits used to have flaked. A wait that shows something does *not* happen is an
/// absence window instead, and stays as short as it was.
enum TestDeadline {
    static let seconds: TimeInterval = 10
    static func fromNow() -> Date { Date().addingTimeInterval(seconds) }
}
