import Foundation
import os

/// ShellforgeDesign's log, which cannot use ShellforgeCore's `LogSink` (the design system imports
/// nothing else in the package): an os `Logger` line, and the same text to a receiver the host
/// installs at launch — its DLog, as every line here is a debug one.
public enum DesignLog {
    private static let logger = Logger(subsystem: "io.github.nathangel.shellforge", category: "theme")
    private static let lock = NSLock()
    nonisolated(unsafe) private static var receiver: (@Sendable (String) -> Void)?

    /// Sends every later design-system line to `receiver` as well; nil stops that.
    public static func install(_ receiver: (@Sendable (String) -> Void)?) {
        lock.withLock { Self.receiver = receiver }
    }

    static func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        lock.withLock { receiver }?(message)
    }
}
