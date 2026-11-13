import Foundation
import os

/// Where the package's log lines go besides the unified log: the host's own logs, so a bug
/// report's iTerm2 debug log carries them. The package cannot call DLog or RLog, which are the host's;
/// the host installs them here at launch. Until then, and in the package's own tests, lines go to
/// the unified log only.
public enum LogSink {
    /// `.debug` lines are the host's DLog, kept only while debug logging is on; `.release` lines are
    /// its RLog, kept in memory always, so they are for errors only, never for secrets.
    public enum Level: Sendable, Equatable {
        case debug, release
    }

    public typealias Receiver = @Sendable (Level, String) -> Void

    private static let receiver = Locked<Receiver?>(nil)

    /// Sends every later package line to `receiver` as well; nil stops that.
    public static func install(_ receiver: Receiver?) {
        Self.receiver.withLock { $0 = receiver }
    }

    /// The line as the error log would write it — tokens blanked, a URL's password left out, the
    /// home folder as `~` — since git's stderr, which some lines quote, can echo a token.
    static func send(_ level: Level, _ message: String) {
        guard let receiver = receiver.withLock({ $0 }) else { return }
        receiver(level, ErrorLog.cleaned(message))
    }
}

/// The package's one way to log: an os `Logger` line, every value public as the package always
/// wrote them, and the same text to `LogSink`. Debug, info and notice lines go to the sink's
/// `.debug`; errors and faults to its `.release`.
public struct PackageLogger: Sendable {
    private let logger: Logger

    public init(category: String) {
        logger = Logger(subsystem: "io.github.nathangel.shellforge", category: category)
    }

    public func debug(_ message: @autoclosure () -> String) { log(level: .debug, message()) }
    public func info(_ message: @autoclosure () -> String) { log(level: .info, message()) }
    public func notice(_ message: @autoclosure () -> String) { log(level: .default, message()) }
    public func error(_ message: @autoclosure () -> String) { log(level: .error, message()) }

    public func log(level: OSLogType, _ message: @autoclosure () -> String) {
        let text = message()
        logger.log(level: level, "\(text, privacy: .public)")
        LogSink.send(level == .error || level == .fault ? .release : .debug, text)
    }
}
