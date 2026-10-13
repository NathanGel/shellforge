import Foundation
import Testing
@testable import ShellforgeTestSupport
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

/// A child that outlives the call that started it, as the daemon does.
@Suite struct LaunchedChildTests {
    private let env = ["PATH": "/usr/bin:/bin"]

    @Test func aLaunchedChildReportsItsExitStatus() async throws {
        let exited = Locked<Int32?>(nil)
        let child = try ChildProcess.launch("/bin/sh", ["-c", "exit 7"], environment: env, directory: nil, output: nil) { _, status in
            exited.withLock { $0 = status }
        }
        #expect(child.pid > 0)
        let deadline = Date().addingTimeInterval(2)
        while exited.withLock({ $0 }) == nil, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(exited.withLock { $0 } == 7)
        #expect(!child.isRunning)
    }

    @Test func aLaunchedChildWritesToTheGivenFile() async throws {
        let file = TestScratch.root.appendingPathComponent("sf-child-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        let done = Locked(false)
        _ = try ChildProcess.launch("/bin/sh", ["-c", "echo hi; echo oops >&2"], environment: env, directory: nil, output: handle) { _, _ in
            done.withLock { $0 = true }
        }
        let deadline = Date().addingTimeInterval(2)
        while !done.withLock({ $0 }), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        try handle.close()
        #expect(try String(contentsOf: file, encoding: .utf8) == "hi\noops\n")
    }

    @Test func terminateEndsALongRunningChild() async throws {
        let exited = Locked(false)
        let child = try ChildProcess.launch("/bin/sleep", ["30"], environment: env, directory: nil, output: nil) { _, _ in
            exited.withLock { $0 = true }
        }
        #expect(child.isRunning)
        child.terminate()
        let deadline = Date().addingTimeInterval(2)
        while !exited.withLock({ $0 }), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(exited.withLock { $0 })
    }
}
