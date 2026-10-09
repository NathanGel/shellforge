import Foundation
import Testing
@testable import ShellforgeCore

@Suite struct ChildProcessTests {
    /// A child that leaves a background job behind must not be handed the pipes of commands
    /// started at the same moment: they would wait for an end of output that only comes when the
    /// job exits, and lose what they printed. An SSH tunnel is such a job.
    @Test func backgroundJobsDoNotHoldOtherCommandsOutputOpen() async throws {
        let env = ["PATH": "/usr/bin:/bin"]
        let outputs = try await withThrowingTaskGroup(of: String?.self) { group in
            for i in 0..<40 {
                group.addTask {
                    if i.isMultiple(of: 2) {
                        _ = try ChildProcess.run("/bin/sh", ["-c", "sleep 5 & exit 0"], environment: env, timeout: 10)
                        return nil
                    }
                    return try ChildProcess.run("/bin/echo", ["done \(i)"], environment: env, timeout: 10).stdout
                }
            }
            return try await group.reduce(into: [String]()) { if let out = $1 { $0.append(out) } }
        }
        #expect(outputs.count == 20)
        #expect(outputs.filter { !$0.hasPrefix("done ") }.isEmpty, "lost output: \(outputs.filter { !$0.hasPrefix("done ") }.count) of 20")
    }
}
