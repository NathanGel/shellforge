import Foundation
import ShellforgeCore

/// The feedback banner's state, once for the app. It reads and writes only the defaults it is given.
@MainActor public final class FeedbackPrompt: ObservableObject {
    nonisolated public static let firstSeenKey = "NoSyncShellforgeFeedbackFirstSeen"
    nonisolated public static let nextAskKey = "NoSyncShellforgeFeedbackNextAsk"
    nonisolated public static let enabledKey = "ShellforgeFeedbackPromptsEnabled"

    @Published public private(set) var showsBanner = false
    @Published public private(set) var isEnabled: Bool

    private let defaults: UserDefaults
    private let channel: BuildChannel
    private let now: @Sendable () -> Date
    private let firstSeen: Date
    /// Kept for as long as the prompt lives: the app's one lives as long as the app.
    private var observers: [any NSObjectProtocol] = []

    public init(defaults: UserDefaults, channel: BuildChannel, now: @escaping @Sendable () -> Date = Date.init) {
        self.defaults = defaults; self.channel = channel; self.now = now
        if let seen = defaults.object(forKey: Self.firstSeenKey) as? Date {
            firstSeen = seen
        } else {
            firstSeen = now()
            defaults.set(firstSeen, forKey: Self.firstSeenKey)
        }
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        refresh()
    }

    public func refresh() {
        showsBanner = FeedbackSchedule.isDue(firstSeen: firstSeen, nextAsk: defaults.object(forKey: Self.nextAskKey) as? Date,
                                             enabled: isEnabled, channel: channel, now: now())
    }

    /// Checks again each time one of `names` is posted on `center`: someone who keeps one window open
    /// for weeks, and never relaunches, sees the banner when they come back to the app.
    public func refresh(on names: [Notification.Name], from center: NotificationCenter) {
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                guard Thread.isMainThread else {
                    Task { @MainActor in self?.refresh() }
                    return
                }
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    public func notNow() { wait(FeedbackSchedule.notNowDelay) }

    public func dontAskAgain() {
        isEnabled = false
        defaults.set(false, forKey: Self.enabledKey)
        showsBanner = false
    }

    /// A form left open, or a crash, counts as Not Now.
    public func beginFeedback() { wait(FeedbackSchedule.notNowDelay) }

    public func finished(sent: Bool) { wait(sent ? FeedbackSchedule.afterSendDelay : FeedbackSchedule.notNowDelay) }

    public func save(_ on: Bool) {
        guard on != isEnabled else { return }
        isEnabled = on
        defaults.set(on, forKey: Self.enabledKey)
        if on { defaults.set(now().addingTimeInterval(FeedbackSchedule.notNowDelay), forKey: Self.nextAskKey) }
        showsBanner = false
    }

    private func wait(_ delay: TimeInterval) {
        defaults.set(now().addingTimeInterval(delay), forKey: Self.nextAskKey)
        showsBanner = false
    }
}
