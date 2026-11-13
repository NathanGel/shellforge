import Foundation

/// A few reads at a time, the rest waiting their turn: the Files and Git panels read every
/// repository when they first show, and without a limit that is one `git status` per repository
/// at once. Projects go first, task worktrees after; within each, first come first served.
public final class ReadPool: @unchecked Sendable {
    public enum Priority: Sendable {
        /// A project's folder: what the panel lists first.
        case project
        /// A task's worktree.
        case task
    }

    /// The panels' pool: at most four reads at once, at utility QoS, as a background read is.
    public static let panels = ReadPool(limit: 4, queue: .global(qos: .utility))

    private let limit: Int
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var running = 0
    private var projects: [@Sendable () -> Void] = []
    private var tasks: [@Sendable () -> Void] = []

    public init(limit: Int, queue: DispatchQueue) {
        precondition(limit > 0, "a pool runs at least one read")
        self.limit = limit
        self.queue = queue
    }

    /// Runs `work` on the pool's queue once a place is free.
    public func submit(_ priority: Priority, _ work: @escaping @Sendable () -> Void) {
        let now: Bool = lock.withLock {
            guard running < limit else {
                if priority == .project { projects.append(work) } else { tasks.append(work) }
                return false
            }
            running += 1
            return true
        }
        if now { launch(work) }
    }

    /// `work` on the pool, awaited. It throws what `work` throws and nothing else.
    public func run<Value: Sendable, Failure: Error>(_ priority: Priority,
                                                     _ work: @escaping @Sendable () throws(Failure) -> Value) async throws(Failure) -> Value {
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result<Value, Failure>, Never>) in
            submit(priority) { continuation.resume(returning: Result { () throws(Failure) -> Value in try work() }) }
        }
        return try result.get()
    }

    /// How many reads run and how many wait. For tests.
    public var load: (running: Int, waiting: Int) {
        lock.withLock { (running, projects.count + tasks.count) }
    }

    private func launch(_ work: @escaping @Sendable () -> Void) {
        queue.async {
            work()
            self.finished()
        }
    }

    /// A place came free: the next waiting read takes it.
    private func finished() {
        let next: (@Sendable () -> Void)? = lock.withLock {
            if !projects.isEmpty { return projects.removeFirst() }
            if !tasks.isEmpty { return tasks.removeFirst() }
            running -= 1
            return nil
        }
        if let next { launch(next) }
    }
}
