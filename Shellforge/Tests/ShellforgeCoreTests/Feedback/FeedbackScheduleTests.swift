import Foundation
import Testing
@testable import ShellforgeCore

@Suite struct FeedbackScheduleTests {
    private let first = Date(timeIntervalSince1970: 1_000_000)

    @Test func dueAtExactlyFourteenDays() {
        let at = first.addingTimeInterval(FeedbackSchedule.firstAskDelay)
        #expect(FeedbackSchedule.isDue(firstSeen: first, nextAsk: nil, enabled: true, channel: .release, now: at))
        #expect(!FeedbackSchedule.isDue(firstSeen: first, nextAsk: nil, enabled: true, channel: .release,
                                        now: at.addingTimeInterval(-1)))
    }

    @Test func notDueWhileNextAskIsAhead() {
        let now = first.addingTimeInterval(FeedbackSchedule.firstAskDelay + 100)
        #expect(!FeedbackSchedule.isDue(firstSeen: first, nextAsk: now.addingTimeInterval(1), enabled: true,
                                        channel: .release, now: now))
        #expect(FeedbackSchedule.isDue(firstSeen: first, nextAsk: now, enabled: true, channel: .release, now: now))
    }

    @Test func neverDueWhenDisabledOrDev() {
        let now = first.addingTimeInterval(1000 * 86_400)
        #expect(!FeedbackSchedule.isDue(firstSeen: first, nextAsk: nil, enabled: false, channel: .release, now: now))
        #expect(!FeedbackSchedule.isDue(firstSeen: first, nextAsk: nil, enabled: true, channel: .dev, now: now))
    }

    @Test func delays() {
        #expect(FeedbackSchedule.firstAskDelay == 14 * 86_400)
        #expect(FeedbackSchedule.notNowDelay == 90 * 86_400)
        #expect(FeedbackSchedule.afterSendDelay == 180 * 86_400)
    }
}
