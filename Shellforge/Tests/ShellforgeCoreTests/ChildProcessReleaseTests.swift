import Darwin
import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeTestSupport

/// A finished call holds nothing for good: a background job that keeps the child's pipes open keeps
/// no thread, its pipes close when it ends, and it is never killed for writing late (PRD goal 7).
@Suite(.serialized) struct ChildProcessReleaseTests {
    /// The pipes this process holds open.
    private static func pipes() -> Int {
        let fds = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")) ?? []
        return fds.compactMap(Int32.init).filter { fd in
            var info = stat()
            return fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFIFO
        }.count
    }

    /// A background job that writes after the call has returned is not killed for it: its output
    /// is drained and dropped, not met with a closed pipe and SIGPIPE.
    @Test func aLateWriterIsNotKilled() async throws {
        try FileManager.default.createDirectory(at: TestScratch.root, withIntermediateDirectories: true)
        let mark = TestScratch.root.appendingPathComponent("late-\(UUID().uuidString)").path
        let script = "(sleep 3; echo late; echo late >&2; touch '\(mark)') & exit 0"
        _ = try ChildProcess.run("/bin/sh", ["-c", script], environment: ["PATH": "/usr/bin:/bin"], timeout: 10)
        let deadline = Date().addingTimeInterval(8)
        while !FileManager.default.fileExists(atPath: mark), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(FileManager.default.fileExists(atPath: mark), "the background job died writing to a closed pipe")
    }

    /// Once the background jobs end, their pipes close: nothing waits on them for good.
    @Test func pipesCloseWhenTheBackgroundJobEnds() async throws {
        let before = Self.pipes()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    _ = try? ChildProcess.run("/bin/sh", ["-c", "sleep 3 & exit 0"], environment: ["PATH": "/usr/bin:/bin"], timeout: 10)
                }
            }
        }
        // Other suites start commands too: wait for the count to come back, rather than read it once.
        let deadline = Date().addingTimeInterval(10)
        while Self.pipes() > before, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        #expect(Self.pipes() <= before, "pipes outlived their background jobs")
    }

    @Test func aFinishedChildIsReleased() async throws {
        let exited = Locked(false)
        weak var released: RunningChild?
        do {
            let child = try ChildProcess.launch("/usr/bin/true", [], environment: [:], directory: nil, output: nil) { _, _ in
                exited.withLock { $0 = true }
            }
            released = child
        }
        let deadline = Date().addingTimeInterval(5)
        while !exited.withLock({ $0 }), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(exited.withLock { $0 })
        while released != nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(released == nil, "the ended child is still held")
    }
}
