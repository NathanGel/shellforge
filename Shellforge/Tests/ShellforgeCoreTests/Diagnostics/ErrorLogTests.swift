import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeTestSupport

/// The error log: one line per real problem, in the running app's data folder, with nothing private
/// in it and never more than two files.
@Suite struct ErrorLogTests {
    private func folder() -> URL {
        TestScratch.root.appendingPathComponent("error-log-\(UUID().uuidString)", isDirectory: true)
    }

    private func lines(_ url: URL) -> [String] {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    /// A fixed moment, so the line can be compared whole.
    private let moment = Date(timeIntervalSince1970: 1_794_298_451)

    private func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxxxx"
        return formatter.string(from: date)
    }

    /// Time, version, category and message, with the home folder written as `~`.
    @Test func aLineSaysWhenWhichVersionWhatAndHidesTheHomeFolder() throws {
        let moment = self.moment
        let log = ErrorLog(folder: folder(), version: "0.9.1", now: { moment })
        log.record("removal", "Couldn’t remove \(NSHomeDirectory())/code/app/.worktrees/fix")
        #expect(lines(log.fileURL) == ["\(timestamp(moment)) · 0.9.1 · removal · Couldn’t remove ~/code/app/.worktrees/fix"])
        #expect(log.fileURL.lastPathComponent == "errors.log")
    }

    /// The time always carries its offset, even in UTC, where ISO 8601 would allow a bare `Z`.
    @Test func theTimeCarriesItsOffset() throws {
        let log = ErrorLog(folder: folder(), version: "1.0.0")
        log.record("daemon", "lost")
        let line = try #require(lines(log.fileURL).first)
        #expect(line.range(of: #"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d\d:\d\d · 1\.0\.0 · daemon · lost$"#,
                           options: .regularExpression) != nil)
    }

    /// Only the home folder itself is hidden, not a longer name that starts like it.
    @Test func aFolderNamedLikeHomeIsNotMistakenForIt() {
        let log = ErrorLog(folder: folder(), version: "1", now: { Date(timeIntervalSince1970: 0) })
        let home = NSHomeDirectory()
        log.record("workspace", "\(home) and \(home)x/file")
        #expect(lines(log.fileURL).first?.hasSuffix(" · ~ and \(home)x/file") == true)
    }

    /// A password in a URL, as git can repeat one back, is left out.
    @Test func aURLsCredentialsAreLeftOut() {
        let log = ErrorLog(folder: folder(), version: "1", now: { Date(timeIntervalSince1970: 0) })
        log.record("removal", "fatal: unable to access 'https://me:s3cret@example.com/repo.git/'")
        #expect(lines(log.fileURL).first?.hasSuffix(" · fatal: unable to access 'https://…@example.com/repo.git/'") == true)
    }

    /// A message of several lines stays one line in the log, with ⏎ where each break was.
    @Test func newlinesBecomeOneLine() {
        let log = ErrorLog(folder: folder(), version: "1", now: { Date(timeIntervalSince1970: 0) })
        log.record("removal", "git failed\nerror: one\r\nerror: two\n")
        let written = lines(log.fileURL)
        #expect(written.count == 1)
        #expect(written.first?.hasSuffix(" · removal · git failed ⏎ error: one ⏎ error: two") == true)
    }

    /// Past `maxBytes` the file starts again, the older one kept as `errors.1.log`: only ever one
    /// older file.
    @Test func rotationKeepsExactlyOneOlderFile() throws {
        let dir = folder()
        // Each line is the same length: a timestamp, “ · 1 · c · ” and a two-digit message.
        let log = ErrorLog(folder: dir, version: "1", now: { Date(timeIntervalSince1970: 0) }, maxBytes: 200)
        log.record("c", "00")
        let lineBytes = try Data(contentsOf: log.fileURL).count
        let perFile = 200 / lineBytes
        for n in 1..<(perFile * 3 + 1) { log.record("c", String(format: "%02d", n)) }
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(names == ["errors.1.log", "errors.log"])
        let current = lines(log.fileURL), older = lines(dir.appendingPathComponent("errors.1.log"))
        #expect(current.count == 1)
        #expect(older.count == perFile)
        #expect(current.first?.hasSuffix(" · \(String(format: "%02d", perFile * 3))") == true)
        #expect(older.last?.hasSuffix(" · \(String(format: "%02d", perFile * 3 - 1))") == true)
        #expect(try Data(contentsOf: log.fileURL).count <= 200)
        #expect(try Data(contentsOf: dir.appendingPathComponent("errors.1.log")).count <= 200)
    }

    /// Records from many threads at once all land, each a whole line.
    @Test func concurrentRecordsAllLandAsWholeLines() {
        let log = ErrorLog(folder: folder(), version: "1")
        let count = 200
        DispatchQueue.concurrentPerform(iterations: count) { log.record("daemon", "message \($0)") }
        let written = lines(log.fileURL)
        #expect(written.count == count)
        let pattern = #"^\S+ · 1 · daemon · message \d+$"#
        #expect(written.allSatisfy { $0.range(of: pattern, options: .regularExpression) != nil })
        let numbers = Set(written.compactMap { $0.split(separator: " ").last.flatMap { Int($0) } })
        #expect(numbers == Set(0..<count))
    }

    /// Help › Show Error Log has a file to show before anything went wrong: an empty one, readable
    /// only by its owner, and an existing one is left as it is.
    @Test func anEmptyLogCanBeMadeToShow() throws {
        let log = ErrorLog(folder: folder(), version: "1")
        log.createIfMissing()
        let attributes = try FileManager.default.attributesOfItem(atPath: log.fileURL.path)
        #expect(attributes[.size] as? Int == 0)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        log.record("c", "kept")
        log.createIfMissing()
        #expect(lines(log.fileURL).count == 1)
    }

    /// A folder that can't be written to costs the caller nothing: no throw, no crash.
    @Test func aFailedWriteIsSwallowed() throws {
        let blocker = folder()
        try FileManager.default.createDirectory(at: blocker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("a file, not a folder".utf8).write(to: blocker)
        let log = ErrorLog(folder: blocker, version: "1")
        log.record("workspace", "nowhere to go")
        #expect(!FileManager.default.fileExists(atPath: log.fileURL.path))
    }

    /// Before the app configures it, the process-wide sink writes nothing; after, it writes to the
    /// configured log.
    @Test func theSinkIsANoOpUntilConfigured() {
        let sink = ErrorLogSink()
        let log = ErrorLog(folder: folder(), version: "1")
        sink.record("removal", "early")
        #expect(!FileManager.default.fileExists(atPath: log.fileURL.path))
        sink.configure(log)
        sink.record("removal", "late")
        #expect(lines(log.fileURL).count == 1)
        #expect(lines(log.fileURL).first?.hasSuffix(" · removal · late") == true)
    }

    /// A test's own log, for the task it runs in, takes the place of the configured one.
    @Test func aTaskLocalLogTakesPrecedence() {
        let sink = ErrorLogSink()
        let configured = ErrorLog(folder: folder(), version: "1"), local = ErrorLog(folder: folder(), version: "1")
        sink.configure(configured)
        ErrorLogging.$testLog.withValue(local) { sink.record("sidebar", "here") }
        #expect(lines(local.fileURL).count == 1)
        #expect(!FileManager.default.fileExists(atPath: configured.fileURL.path))
    }
}
