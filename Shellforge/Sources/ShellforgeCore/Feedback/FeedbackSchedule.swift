import Foundation

/// When to ask for feedback. Pure: the clock and the stored dates are passed in.
public enum FeedbackSchedule {
    public static let firstAskDelay: TimeInterval = 14 * 86_400
    public static let notNowDelay: TimeInterval = 90 * 86_400
    public static let afterSendDelay: TimeInterval = 180 * 86_400

    /// Release builds only, and only while the person has not switched the prompts off.
    public static func isDue(firstSeen: Date, nextAsk: Date?, enabled: Bool, channel: BuildChannel, now: Date) -> Bool {
        guard enabled, channel == .release else { return false }
        guard now >= firstSeen.addingTimeInterval(firstAskDelay) else { return false }
        if let nextAsk, nextAsk > now { return false }
        return true
    }
}
