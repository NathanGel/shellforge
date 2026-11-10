import Foundation
import os

private let errorLogLog = Logger(subsystem: "io.github.nathangel.shellforge", category: "errorLog")

/// The error log: one line for each real problem — a failed removal, a lost helper, an update that
/// didn't install — in `errors.log`, for Help › Show Error Log and for whoever reports a bug. Local
/// only, and never sent anywhere. What callers record is never terminal contents, a typed command,
/// a prompt, a token, a password or an environment value; the log itself writes the home folder as
/// `~` and leaves out a URL's credentials.
///
/// Each line: `2026-11-10T09:14:11+01:00 · 0.9.1 · removal · <message>`, the message on one line.
/// When a line would take the file past `maxBytes`, the file becomes `errors.1.log`, replacing an
/// older one, and a new file starts. Writing never throws: a log that can't be written must not
/// cost the work that failed a second failure.
public final class ErrorLog: Sendable {
    public let fileURL: URL
    private let olderURL: URL
    private let folder: URL
    private let version: String
    private let now: @Sendable () -> Date
    private let maxBytes: Int
    /// The formatter, behind the lock that also orders the writes.
    private let state: Locked<DateFormatter>

    public init(folder: URL, version: String, now: @escaping @Sendable () -> Date = Date.init, maxBytes: Int = 1_000_000) {
        self.folder = folder
        self.fileURL = folder.appendingPathComponent("errors.log")
        self.olderURL = folder.appendingPathComponent("errors.1.log")
        self.version = version
        self.now = now
        self.maxBytes = maxBytes
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        // `xxxxx`: always `+hh:mm`, `+00:00` too, where `XXXXX` would write `Z`.
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxxxx"
        self.state = Locked(formatter)
    }

    public func record(_ category: String, _ message: String) {
        let text = Self.cleaned(message)
        state.withLock { formatter in
            let line = "\(formatter.string(from: now())) · \(version) · \(category) · \(text)\n"
            append(Data(line.utf8))
        }
    }

    /// An empty log, for Help › Show Error Log to show before anything has gone wrong; one that
    /// exists is left as it is.
    public func createIfMissing() {
        state.withLock { _ in
            do { try makeFile() } catch {
                errorLogLog.error("Making the error log failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Called under the lock.
    private func makeFile() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        guard !fm.fileExists(atPath: fileURL.path) else { return }
        // Only the person's own account reads it.
        guard fm.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// Called under the lock.
    private func append(_ line: Data) {
        let fm = FileManager.default
        do {
            let size = (try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? nil
            if let size, size > 0, size + line.count > maxBytes {
                if fm.fileExists(atPath: olderURL.path) { try fm.removeItem(at: olderURL) }
                try fm.moveItem(at: fileURL, to: olderURL)
            }
            try makeFile()
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            errorLogLog.error("Writing the error log failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// What stands in for a token left out.
    static let redacted = "‹redacted›"

    /// The message on one line, the home folder as `~`, a URL's `user:password@` left out, and a
    /// token blanked: a `token=`, `access_token=` or `private_token=` value, or a bare GitHub
    /// (`ghp_`, `gho_`, `ghs_`, `ghu_`, `ghr_`, `github_pat_`) or GitLab (`glpat-`) one — git's stderr can echo one.
    static func cleaned(_ message: String, home: String = NSHomeDirectory()) -> String {
        var text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: " ⏎ ")
        text = text.replacingOccurrences(of: #"(\w+://)[^/\s@]+@"#, with: "$1…@", options: .regularExpression)
        // `token=` also ends `access_token=` and `private_token=`.
        text = text.replacingOccurrences(of: ##"(?i)(token=)[^&\s'"#]+"##, with: "$1" + redacted, options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?<![A-Za-z0-9_])(?:gh[posur]_[A-Za-z0-9]+|github_pat_[A-Za-z0-9_]+|glpat-[A-Za-z0-9_-]+)"#,
                                         with: redacted, options: .regularExpression)
        if !home.isEmpty, home != "/" {
            // The home folder itself, not a longer name that only starts like it.
            let pattern = NSRegularExpression.escapedPattern(for: home) + #"(?![^/\s'"`)\],;:])"#
            text = text.replacingOccurrences(of: pattern, with: "~", options: .regularExpression)
        }
        return text
    }
}

/// Where `ErrorLogging.record` goes: nowhere until the app configures it, so tests stay hermetic.
final class ErrorLogSink: Sendable {
    private let log = Locked<ErrorLog?>(nil)

    func configure(_ log: ErrorLog) { self.log.withLock { $0 = log } }

    func record(_ category: String, _ message: String) {
        guard let target = ErrorLogging.testLog ?? log.withLock({ $0 }) else { return }
        target.record(category, message)
    }
}

/// The process-wide error log. The app configures it at launch with the log in its data folder;
/// until then — and in tests — recording is a no-op.
public enum ErrorLogging {
    private static let sink = ErrorLogSink()

    public static func configure(_ log: ErrorLog) { sink.configure(log) }

    /// `category` names the part of the app: `sidebar`, `removal`, `daemon`, `updates`, `workspace`,
    /// `projectFolder`, `backpack`.
    public static func record(_ category: String, _ message: String) { sink.record(category, message) }

    /// A test's own log, for the task it runs in: it takes the configured log's place there, so
    /// tests running side by side never share one.
    @TaskLocal public static var testLog: ErrorLog?
}
