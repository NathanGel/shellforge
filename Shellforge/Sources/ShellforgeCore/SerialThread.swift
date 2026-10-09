// Ported from AiTerm (app/Sources/AiTermCore/SerialThread.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// A serial queue on a thread of its own, for blocking work that must run one job at a time — a
/// Wi-Fi join, `sudo pmset`. Not a `DispatchQueue`: a serial Dispatch queue still borrows the global
/// workers Swift concurrency's cooperative pool shares, and work that blocks for seconds (or a test
/// that holds a job in flight) parks them past other callers' deadlines (see `ProcessRunner`).
///
/// The thread lives as long as this object; it ends once the object goes and its queue is empty.
public final class SerialThread: Sendable {
    private let worker: Worker

    public init(name: String) {
        let worker = Worker()
        self.worker = worker
        let thread = Thread { worker.loop() }
        thread.name = name
        thread.stackSize = 512 * 1024
        thread.start()
    }

    deinit { worker.stop() }

    /// Queues `job` behind whatever is already queued.
    public func enqueue(_ job: @escaping @Sendable () -> Void) { worker.add(job) }

    /// Runs `work` on the thread, after what is already queued, and hands back its answer.
    public func run<Value: Sendable>(_ work: @escaping @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            worker.add { continuation.resume(returning: work()) }
        }
    }

    /// Blocks the caller until `work` has run on the thread, after what is already queued.
    public func sync<Value: Sendable>(_ work: @escaping @Sendable () -> Value) -> Value {
        let done = DispatchSemaphore(value: 0)
        let box = Box<Value>()
        worker.add { box.value = work(); done.signal() }
        done.wait()
        return box.value!
    }

    /// The queue and its condition, shared by the owner and the thread, so the thread does not keep
    /// the owner alive.
    private final class Worker: @unchecked Sendable {
        private let condition = NSCondition()
        private var jobs: [@Sendable () -> Void] = []
        private var stopped = false

        func add(_ job: @escaping @Sendable () -> Void) {
            condition.lock()
            jobs.append(job)
            condition.signal()
            condition.unlock()
        }

        func stop() {
            condition.lock()
            stopped = true
            condition.signal()
            condition.unlock()
        }

        func loop() {
            while true {
                condition.lock()
                while jobs.isEmpty && !stopped { condition.wait() }
                if jobs.isEmpty { condition.unlock(); return }
                let job = jobs.removeFirst()
                condition.unlock()
                job()
            }
        }
    }

    /// Written once by the job, read once after the semaphore: the semaphore orders the two.
    private final class Box<Value>: @unchecked Sendable { var value: Value? }
}

/// One blocking call on a fresh `Thread` of its own, awaited: an admin prompt that waits on the
/// person, a `networksetup` listing, a Keychain read. For the same reason as `SerialThread`.
public enum ThreadWork {
    public static func run<Value: Sendable>(_ work: @escaping @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            let thread = Thread { continuation.resume(returning: work()) }
            thread.name = "aiterm.blocking"
            thread.stackSize = 512 * 1024
            thread.start()
        }
    }
}
