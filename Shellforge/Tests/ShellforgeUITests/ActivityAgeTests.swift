import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI

/// How long ago a task's agent last reported, as its row's trailing word says it.
@Suite struct ActivityAgeTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func theAgeReadsInTheLargestWholeUnit() {
        #expect(ActivityAge.text(since: now.addingTimeInterval(-30), now: now) == "now")
        #expect(ActivityAge.text(since: now.addingTimeInterval(-4 * 60), now: now) == "4m")
        #expect(ActivityAge.text(since: now.addingTimeInterval(-(3 * 3600 + 5 * 60)), now: now) == "3h")
        #expect(ActivityAge.text(since: now.addingTimeInterval(-49 * 3600), now: now) == "2d")
    }

    /// A report from a clock a little ahead reads as now, never as a negative age.
    @Test func aReportFromTheFutureIsNow() {
        #expect(ActivityAge.text(since: now.addingTimeInterval(90), now: now) == "now")
    }

    @Test func theNewestReportIsTheTasks() {
        func session(_ id: String, _ reportedAt: Double?) -> SessionInfo {
            var info = SessionInfo(sessionId: id, windowId: "w", tabIndex: 0, taskId: nil, projectId: nil, agent: .claude,
                                   model: nil, state: .idle, title: "", cwd: "/")
            info.reportedAt = reportedAt
            return info
        }
        #expect(ActivityAge.lastReport([session("a", nil)]) == nil)
        #expect(ActivityAge.lastReport([]) == nil)
        #expect(ActivityAge.lastReport([session("a", 10), session("b", nil), session("c", 30)]) == Date(timeIntervalSince1970: 30))
    }
}
