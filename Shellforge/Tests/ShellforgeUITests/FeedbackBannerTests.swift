import AppKit
import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

@MainActor @Suite struct FeedbackBannerTests {
    private func shown() -> FeedbackPrompt {
        let clock = TestClock(Date(timeIntervalSince1970: 1_000_000))
        let prompt = FeedbackPrompt(defaults: ScratchDefaults.make(), channel: .release, now: { clock.now })
        clock.advance(by: 15 * 86_400)
        prompt.refresh()
        return prompt
    }

    @Test func theTextAndTitlesAreExact() {
        #expect(FeedbackBanner.text == "How’s Shellforge working for you?")
        #expect(FeedbackBanner.why == "Feedback decides what gets added and fixed next.")
        #expect(FeedbackBanner.title(.give) == "Give Feedback…")
        #expect(FeedbackBanner.title(.notNow) == "Not Now")
        #expect(FeedbackBanner.title(.never) == "Don’t Ask Again")
    }

    @Test func giveOnlyAsksForTheForm() {
        let prompt = shown()
        #expect(prompt.showsBanner)
        var opened = 0
        FeedbackBanner(prompt: prompt, giveFeedback: { opened += 1 }).answer(.give)
        #expect(opened == 1)
        #expect(prompt.showsBanner)
    }

    @Test func theFormOpeningCountsTheAskOnce() {
        let clock = TestClock(Date(timeIntervalSince1970: 1_000_000))
        let defaults = ScratchDefaults.make()
        let prompt = FeedbackPrompt(defaults: defaults, channel: .release, now: { clock.now })
        clock.advance(by: 15 * 86_400)
        prompt.refresh()
        #expect(prompt.showsBanner)
        _ = FeedbackFormModel.live(prompt: prompt, dismiss: {})
        #expect(!prompt.showsBanner)
        let next = defaults.object(forKey: FeedbackPrompt.nextAskKey) as? Date
        #expect(next == clock.now.addingTimeInterval(FeedbackSchedule.notNowDelay))
    }

    @Test func theFormsMainButtonNamesWhereItGoes() {
        #expect(FeedbackFormPresentation.primaryTitle(viaRelay: true) == "Send")
        #expect(FeedbackFormPresentation.primaryTitle(viaRelay: false) == "Open in GitHub")
    }

    @Test func notNowHidesTheBanner() {
        let prompt = shown()
        FeedbackBanner(prompt: prompt, giveFeedback: {}).answer(.notNow)
        #expect(!prompt.showsBanner)
        #expect(prompt.isEnabled)
    }

    @Test func neverHidesTheBannerAndTurnsPromptsOff() {
        let prompt = shown()
        FeedbackBanner(prompt: prompt, giveFeedback: {}).answer(.never)
        #expect(!prompt.showsBanner)
        #expect(!prompt.isEnabled)
    }

    @Test func theSettingsSubtitleIsExact() {
        #expect(SettingsPanel.subtitle == "What Backpack Mode needs from this Mac, which agents Shellforge can start and the model and reasoning each starts with, Jira for New Task’s tickets, GitLab and GitHub for reviews, and whether Shellforge asks for feedback.")
    }

    @Test func closeWatchCallsBackOnceUntilStopped() {
        let window = NSWindow()
        let watch = CloseWatch()
        var calls = 0
        watch.start(on: [window]) { calls += 1 }
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        #expect(calls == 1)
        watch.start(on: [window]) { calls += 1 }
        watch.stop()
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        #expect(calls == 1)
    }
}
