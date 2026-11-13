import Foundation
import Testing
@testable import ShellforgeCore

/// The panels' reads wait their turn: a few at once, projects before task worktrees.
@Suite struct ReadPoolTests {
    /// Ten reads that hold until released: four start, six wait, and no more than four ever run.
    @Test func atMostFourReadsRunAtOnce() async {
        let pool = ReadPool(limit: 4, queue: .global(qos: .utility))
        let probe = Probe()
        let gate = DispatchSemaphore(value: 0)
        let done = DispatchGroup()
        for _ in 0..<10 {
            done.enter()
            pool.submit(.project) {
                probe.started()
                gate.wait()
                probe.finished()
                done.leave()
            }
        }
        // Submitting is synchronous: the pool has decided already, whatever has started yet.
        #expect(pool.load.running == 4)
        #expect(pool.load.waiting == 6)
        for _ in 0..<10 { gate.signal() }
        await withCheckedContinuation { continuation in done.notify(queue: .global()) { continuation.resume() } }
        #expect(probe.most <= 4)
        #expect(probe.count == 10)
    }

    /// With the one place taken, a task's read queued first still waits for a project's queued after.
    @Test func projectsGoBeforeTasks() async {
        let pool = ReadPool(limit: 1, queue: .global(qos: .utility))
        let gate = DispatchSemaphore(value: 0)
        let order = Probe()
        pool.submit(.project) { gate.wait() }
        async let task: Void = pool.run(.task) { order.record("task") }
        async let project: Void = pool.run(.project) { order.record("project") }
        // Both are queued before the first read lets go.
        while pool.load.waiting < 2 { await Task.yield() }
        gate.signal()
        _ = await (task, project)
        #expect(order.log == ["project", "task"])
    }

    /// Projects keep coming: after four of them in a row, a waiting task's read goes.
    @Test func tasksAreNotStarved() {
        let pool = ReadPool(limit: 1, queue: DispatchQueue(label: "pool-test"))
        let gate = DispatchSemaphore(value: 0)
        let order = Probe()
        let done = DispatchGroup()
        pool.submit(.project) { gate.wait() }
        func add(_ name: String, _ priority: ReadPool.Priority) {
            done.enter()
            pool.submit(priority) { order.record(name); done.leave() }
        }
        add("t1", .task)
        for n in 1...6 { add("p\(n)", .project) }
        gate.signal()
        done.wait()
        #expect(order.log == ["p1", "p2", "p3", "p4", "t1", "p5", "p6"])
    }

    /// The read after the person's own action goes ahead of every background read.
    @Test func aReadAfterAnActionGoesFirst() {
        let pool = ReadPool(limit: 1, queue: DispatchQueue(label: "pool-test"))
        let gate = DispatchSemaphore(value: 0)
        let order = Probe()
        let done = DispatchGroup()
        pool.submit(.project) { gate.wait() }
        for (name, priority) in [("task", ReadPool.Priority.task), ("project", .project), ("action", .action)] {
            done.enter()
            pool.submit(priority) { order.record(name); done.leave() }
        }
        gate.signal()
        done.wait()
        #expect(order.log == ["action", "project", "task"])
    }

    @Test func runReturnsWhatTheWorkReturns() async throws {
        struct Refused: Error {}
        let pool = ReadPool(limit: 2, queue: .global(qos: .utility))
        #expect(await pool.run(.task) { 42 } == 42)
        await #expect(throws: Refused.self) { try await pool.run(.project) { () throws(Refused) -> Int in throw Refused() } }
    }
}

private final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var now = 0, peak = 0, total = 0
    private var entries: [String] = []
    func started() { lock.withLock { now += 1; total += 1; peak = max(peak, now) } }
    func finished() { lock.withLock { now -= 1 } }
    func record(_ entry: String) { lock.withLock { entries.append(entry) } }
    var most: Int { lock.withLock { peak } }
    var count: Int { lock.withLock { total } }
    var log: [String] { lock.withLock { entries } }
}
