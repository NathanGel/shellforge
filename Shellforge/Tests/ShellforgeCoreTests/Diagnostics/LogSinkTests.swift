import Foundation
import Testing
@testable import ShellforgeCore

/// The package's lines reach the host's logs through `LogSink`: debug lines to its DLog, errors to
/// its RLog, and never a token. Serialized: the sink is the process's one, and only this suite sets it.
@Suite(.serialized) struct LogSinkTests {
    private final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [(LogSink.Level, String)] = []
        func append(_ level: LogSink.Level, _ line: String) { lock.withLock { lines.append((level, line)) } }
        /// The lines naming `marker`: other suites' lines can arrive meanwhile.
        func lines(with marker: String) -> [(LogSink.Level, String)] { lock.withLock { lines.filter { $0.1.contains(marker) } } }
    }

    private func listening(_ body: (Heard) throws -> Void) rethrows {
        let heard = Heard()
        LogSink.install { heard.append($0, $1) }
        defer { LogSink.install(nil) }
        try body(heard)
    }

    @Test func aNoticeGoesToTheDebugLog() {
        let marker = UUID().uuidString
        listening { heard in
            TaskRemoval.log("removing \(marker)")
            let lines = heard.lines(with: marker)
            #expect(lines.count == 1)
            #expect(lines.first?.0 == .debug && lines.first?.1 == "removing \(marker)")
        }
    }

    @Test func anErrorGoesToTheReleaseLog() {
        let marker = UUID().uuidString
        listening { heard in
            HTTPLog.failed("Reading /rest/\(marker)", CocoaError(.fileReadCorruptFile))
            let lines = heard.lines(with: marker)
            #expect(lines.count == 1)
            #expect(lines.first?.0 == .release && lines.first?.1.hasPrefix("Reading /rest/\(marker) failed: ") == true)
        }
    }

    @Test func aLevelPassedByTypeIsSortedTheSameWay() {
        let marker = UUID().uuidString
        let logger = PackageLogger(category: "test")
        listening { heard in
            logger.log(level: .info, "info \(marker)")
            logger.log(level: .fault, "fault \(marker)")
            logger.debug("debug \(marker)")
            #expect(heard.lines(with: marker).map(\.0) == [.debug, .release, .debug])
        }
    }

    @Test func aTokenNeverReachesTheHost() {
        let marker = UUID().uuidString
        listening { heard in
            PackageLogger(category: "test").error("\(marker) git said https://example.com/x?private_token=abc123 and glpat-abcdef")
            let line = heard.lines(with: marker).first?.1 ?? ""
            #expect(!line.contains("abc123") && !line.contains("glpat-abcdef"), "\(line)")
            #expect(line.contains(ErrorLog.redacted))
        }
    }

    @Test func nothingIsSentOnceTheSinkIsRemoved() {
        let marker = UUID().uuidString
        let heard = Heard()
        LogSink.install { heard.append($0, $1) }
        LogSink.install(nil)
        TaskRemoval.log("after \(marker)")
        #expect(heard.lines(with: marker).isEmpty)
    }
}
