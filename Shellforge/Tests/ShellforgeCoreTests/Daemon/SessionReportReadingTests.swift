import Foundation
import Testing
@testable import ShellforgeCore

/// Each session goes to shellforged as its placement and the variables iTerm2 keeps for it.
@Suite struct SessionReportReadingTests {
    @Test func aSessionIsReportedWithItsPlacementAndVariables() {
        let vars: [String: Any] = [
            SessionReport.Variable.commandLine: "claude --resume", SessionReport.Variable.jobPid: NSNumber(value: 4242),
            SessionReport.Variable.title: "claude", SessionReport.Variable.path: "/wt/fix-login",
            ShellforgeTags.task: "6f0e2c1a-9b3d-4e5f-8a7b-0c1d2e3f4a5b",
        ]
        let tagged = SessionReport.reading(sessionId: "G1", windowId: "W", tabIndex: 2, active: true) { vars[$0] }
        #expect(tagged == SessionReport(sessionId: "G1", windowId: "W", tabIndex: 2, commandLine: "claude --resume", jobPid: 4242,
                                        title: "claude", cwd: "/wt/fix-login", active: true,
                                        task: UUID(uuidString: "6f0e2c1a-9b3d-4e5f-8a7b-0c1d2e3f4a5b"), project: nil))
        let bare = SessionReport.reading(sessionId: "G2", windowId: "W", tabIndex: 0, active: false) { _ in nil }
        #expect(bare == SessionReport(sessionId: "G2", windowId: "W", tabIndex: 0, commandLine: nil, jobPid: nil,
                                      title: "", cwd: "", active: false, task: nil, project: nil))
    }

    @Test func aJunkTagIsNoTaskAndNoJobIsNoPid() {
        let r = SessionReport.reading(sessionId: "G", windowId: "W", tabIndex: 0, active: true) {
            switch $0 {
            case ShellforgeTags.task: "not-a-uuid"
            case SessionReport.Variable.jobPid: NSNumber(value: 0)
            default: nil
            }
        }
        #expect(r.taskId == nil && r.jobPid == nil)
    }

    /// The names shellforged's own iTerm2 bridge reads (`iterm_bridge.VARIABLES`).
    @Test func theVariablesAreTheOnesTheBridgeReads() {
        #expect([SessionReport.Variable.commandLine, SessionReport.Variable.jobPid, SessionReport.Variable.title, SessionReport.Variable.path]
                == ["commandLine", "jobPid", "autoName", "path"])
    }
}
