import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

@MainActor @Suite struct FeedbackPromptTests {
    private static let day: TimeInterval = 86_400

    private func make(_ defaults: UserDefaults, _ clock: TestClock, channel: BuildChannel = .release) -> FeedbackPrompt {
        FeedbackPrompt(defaults: defaults, channel: channel, now: { clock.now })
    }

    /// A prompt past its first 14 days, with the banner showing.
    private func shown() -> (FeedbackPrompt, TestClock, UserDefaults) {
        let defaults = ScratchDefaults.make(), clock = TestClock(Date(timeIntervalSince1970: 1_000_000))
        let prompt = make(defaults, clock)
        clock.advance(by: 14 * Self.day)
        prompt.refresh()
        return (prompt, clock, defaults)
    }

    @Test func firstLaunchRecordsFirstSeenAndWaits() {
        let defaults = ScratchDefaults.make(), clock = TestClock(Date(timeIntervalSince1970: 1_000_000))
        let prompt = make(defaults, clock)
        #expect(defaults.object(forKey: FeedbackPrompt.firstSeenKey) as? Date == clock.now)
        #expect(!prompt.showsBanner)
        clock.advance(by: 14 * Self.day - 1)
        prompt.refresh()
        #expect(!prompt.showsBanner)
    }

    @Test func relaunchKeepsFirstSeen() {
        let defaults = ScratchDefaults.make(), clock = TestClock(Date(timeIntervalSince1970: 1_000_000))
        _ = make(defaults, clock)
        clock.advance(by: 14 * Self.day)
        let relaunched = make(defaults, clock)
        #expect(relaunched.showsBanner)
    }

    @Test func showsAfterFourteenDaysOnRefresh() {
        let (prompt, _, _) = shown()
        #expect(prompt.showsBanner)
    }

    /// Someone who never opens a window or relaunches still sees it when they come back to the app.
    @Test func showsWhenAWatchedNotificationArrives() {
        let defaults = ScratchDefaults.make(), clock = TestClock(Date(timeIntervalSince1970: 1_000_000))
        let center = NotificationCenter(), back = Notification.Name("back")
        let prompt = make(defaults, clock)
        prompt.refresh(on: [back], from: center)
        clock.advance(by: 14 * Self.day)
        #expect(!prompt.showsBanner)
        center.post(name: back, object: nil)
        #expect(prompt.showsBanner)
    }

    @Test func aWatchedNotificationBeforeItIsDueShowsNothing() {
        let defaults = ScratchDefaults.make(), clock = TestClock(Date(timeIntervalSince1970: 1_000_000))
        let center = NotificationCenter(), back = Notification.Name("back")
        let prompt = make(defaults, clock)
        prompt.refresh(on: [back], from: center)
        clock.advance(by: 14 * Self.day - 1)
        center.post(name: back, object: nil)
        #expect(!prompt.showsBanner)
    }

    @Test func devBuildNeverShows() {
        let defaults = ScratchDefaults.make(), clock = TestClock(Date(timeIntervalSince1970: 1_000_000))
        let prompt = make(defaults, clock, channel: .dev)
        clock.advance(by: 400 * Self.day)
        prompt.refresh()
        #expect(!prompt.showsBanner)
    }

    @Test func enabledIsTrueWhenUnset() {
        let defaults = ScratchDefaults.make(), clock = TestClock()
        #expect(make(defaults, clock).isEnabled)
    }

    @Test func notNowWaitsNinetyDays() {
        let (prompt, clock, defaults) = shown()
        prompt.notNow()
        #expect(!prompt.showsBanner)
        clock.advance(by: 89 * Self.day)
        prompt.refresh()
        #expect(!prompt.showsBanner)
        clock.advance(by: Self.day)
        prompt.refresh()
        #expect(prompt.showsBanner)
        #expect(make(defaults, clock).showsBanner)
    }

    @Test func dontAskAgainIsForever() {
        let (prompt, clock, defaults) = shown()
        prompt.dontAskAgain()
        #expect(!prompt.showsBanner)
        #expect(!prompt.isEnabled)
        #expect(defaults.object(forKey: FeedbackPrompt.enabledKey) as? Bool == false)
        clock.advance(by: 3650 * Self.day)
        prompt.refresh()
        #expect(!prompt.showsBanner)
        #expect(!make(defaults, clock).showsBanner)
    }

    @Test func sentWaits180() {
        let (prompt, clock, _) = shown()
        prompt.finished(sent: true)
        #expect(!prompt.showsBanner)
        clock.advance(by: 179 * Self.day)
        prompt.refresh()
        #expect(!prompt.showsBanner)
        clock.advance(by: Self.day)
        prompt.refresh()
        #expect(prompt.showsBanner)
    }

    @Test func notSentWaits90() {
        let (prompt, clock, _) = shown()
        prompt.finished(sent: false)
        clock.advance(by: 89 * Self.day)
        prompt.refresh()
        #expect(!prompt.showsBanner)
        clock.advance(by: Self.day)
        prompt.refresh()
        #expect(prompt.showsBanner)
    }

    @Test func beginFeedbackHidesAndCountsAsNotNow() {
        let (prompt, clock, defaults) = shown()
        prompt.beginFeedback()
        #expect(!prompt.showsBanner)
        // A crash with the form open: the next launch finds the 90 days already set.
        clock.advance(by: 89 * Self.day)
        #expect(!make(defaults, clock).showsBanner)
        clock.advance(by: Self.day)
        #expect(make(defaults, clock).showsBanner)
    }

    @Test func turningOnWaitsNinetyDays() {
        let (prompt, clock, _) = shown()
        prompt.dontAskAgain()
        clock.advance(by: 365 * Self.day)
        prompt.save(true)
        #expect(prompt.isEnabled)
        #expect(!prompt.showsBanner)
        clock.advance(by: 89 * Self.day)
        prompt.refresh()
        #expect(!prompt.showsBanner)
        clock.advance(by: Self.day)
        prompt.refresh()
        #expect(prompt.showsBanner)
    }

    @Test func turningOffHidesTheBanner() {
        let (prompt, _, _) = shown()
        prompt.save(false)
        #expect(!prompt.isEnabled)
        #expect(!prompt.showsBanner)
    }

    @Test func saveUnchangedLeavesNextAsk() {
        let (prompt, clock, defaults) = shown()
        prompt.notNow()
        let before = defaults.object(forKey: FeedbackPrompt.nextAskKey) as? Date
        clock.advance(by: 10 * Self.day)
        prompt.save(true)
        #expect(defaults.object(forKey: FeedbackPrompt.nextAskKey) as? Date == before)
    }
}
