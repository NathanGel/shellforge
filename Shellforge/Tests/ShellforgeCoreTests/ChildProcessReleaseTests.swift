import Darwin
import Foundation
import Testing
@testable import ShellforgeCore

/// A finished call holds nothing: a background job that keeps the child's pipes open does not keep
/// its reader threads or their descriptors (PRD goal 7).
@Suite(.serialized) struct ChildProcessReleaseTests {
    private static func threads() -> Int {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return -1 }
        for i in 0..<Int(count) { mach_port_deallocate(mach_task_self_, list[i]) }
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        return Int(count)
    }

    private static func descriptors() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1 }

    @Test func aBackgroundedGrandchildLeavesNoReaders() async throws {
        let env = ["PATH": "/usr/bin:/bin"]
        // Let threads from earlier work settle before counting.
        try await Task.sleep(for: .milliseconds(300))
        let threadsBefore = Self.threads(), descriptorsBefore = Self.descriptors()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask { _ = try? ChildProcess.run("/bin/sh", ["-c", "sleep 6 & exit 0"], environment: env, timeout: 10) }
            }
        }
        // The background sleeps still hold the pipes for seconds yet; the readers must not wait for them.
        try await Task.sleep(for: .milliseconds(800))
        #expect(Self.threads() <= threadsBefore + 2, "reader threads outlived their calls")
        #expect(Self.descriptors() <= descriptorsBefore + 1, "pipe ends outlived their calls")
    }

    /// A child that has ended is let go: a helper in a crash loop does not pile up its Process and
    /// log handle once per restart.
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
