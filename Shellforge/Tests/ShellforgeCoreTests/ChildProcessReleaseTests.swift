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
        #expect(await eventually(describing: "the background job's mark: it died writing to a closed pipe") {
            FileManager.default.fileExists(atPath: mark)
        })
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
        #expect(await eventually(describing: "the pipes to close: they outlived their background jobs") { Self.pipes() <= before })
    }

    /// A launch that fails lets go of its output when it returns, not when the calling thread's
    /// autorelease pool drains — which a busy dispatch queue's does only once its thread runs dry.
    /// A helper that could not be started was retried with a log handle of its own each time, and
    /// every one of them stayed open until the process ran out of descriptors.
    @Test func aFailedLaunchLetsGoOfItsOutput() throws {
        let released = Locked<Bool?>(nil)
        let done = DispatchSemaphore(value: 0)
        // A thread of its own, whose pool drains only as it ends: the check runs before that.
        Thread {
            weak var handle: FileHandle?
            do {
                // Made with `init`, so this test's own pool does not hold it.
                let output = FileHandle(fileDescriptor: open("/dev/null", O_WRONLY | O_CLOEXEC), closeOnDealloc: true)
                handle = output
                _ = try? ChildProcess.launch("/nonexistent/shellforge-helper", [], environment: [:], directory: nil,
                                             output: output) { _, _ in }
            }
            released.withLock { $0 = handle == nil }
            done.signal()
        }.start()
        // A bound for a hang only: the thread returns at once.
        try #require(done.wait(timeout: .now() + 60) == .success)
        #expect(released.withLock { $0 } == true, "the failed launch's output is still held")
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
        #expect(await eventually(describing: "the child's exit") { exited.withLock { $0 } })
        #expect(await eventually(describing: "the ended child let go") { released == nil })
    }
}
