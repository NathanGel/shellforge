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

    /// The line comes as a closure, cleaned only when called: a receiver whose debug log is off
    /// never runs the cleaning.
    public typealias Receiver = @Sendable (Level, @escaping @Sendable () -> String) -> Void

    private static let receiver = Locked<Receiver?>(nil)

    /// Sends every later package line to `receiver` as well; nil stops that.
    public static func install(_ receiver: Receiver?) {
        Self.receiver.withLock { $0 = receiver }
    }

    /// The line as the error log would write it — tokens blanked, a URL's password left out, the
    /// home folder as `~` — since git's stderr, which some lines quote, can echo a token.
    static func send(_ level: Level, _ message: String) {
        guard let receiver = receiver.withLock({ $0 }) else { return }
        receiver(level, { ErrorLog.cleaned(message) })
    }
}

/// The package's one way to log: an os `Logger` line, every value public as the package always
/// wrote them, and the same text to `LogSink`. Debug, info and notice lines go to the sink's
/// `.debug`; errors and faults to its `.release`, at most once per `releaseSpacing` for the same
/// text, the repeats to `.debug`: a helper that is down fails the same way every few seconds, and
/// the host's release log keeps only its last few megabytes.
public struct PackageLogger: Sendable {
    static let releaseSpacing: TimeInterval = 5 * 60
    /// When each error text last went to `.release`. Capped, so varied texts cannot grow it for good.
    private static let lastReleased = Locked<[String: Date]>([:])
    private static let lastReleasedCap = 256

    /// Whether `text` goes to `.release` now: not when it went within `releaseSpacing`.
    static func releases(_ text: String, at now: Date = Date()) -> Bool {
        lastReleased.withLock { last in
            if let then = last[text], now.timeIntervalSince(then) < releaseSpacing { return false }
            if last.count >= lastReleasedCap {
                last = last.filter { now.timeIntervalSince($0.value) < releaseSpacing }
                if last.count >= lastReleasedCap { last.removeAll() }
            }
            last[text] = now
            return true
        }
    }

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
        let isError = level == .error || level == .fault
        LogSink.send(isError && Self.releases(text) ? .release : .debug, text)
    }
}
