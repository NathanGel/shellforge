import Foundation

/// What a tab's terminal says about its agent: how much it has printed, and how often it has rung
/// the bell. Output that follows the user's own typing closely is the terminal echoing it, not the agent.
public struct TerminalSignals: Equatable, Sendable {
    public static let echoWindow: TimeInterval = 0.5
    public private(set) var outputBytes = 0
    public private(set) var attention = 0

    public init() {}

    public mutating func output(_ bytes: Int, sinceInput: TimeInterval) {
        guard sinceInput > Self.echoWindow, bytes > 0 else { return }
        outputBytes += bytes
    }

    public mutating func attentionRequested() { attention += 1 }
}
