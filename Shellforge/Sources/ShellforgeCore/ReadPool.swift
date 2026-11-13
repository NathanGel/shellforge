import Foundation

/// A few reads at a time, the rest waiting their turn: the Files and Git panels read every
/// repository when they first show, and without a limit that is one `git status` per repository
/// at once. A read after the person's own action goes first, at their QoS; then projects, with a
/// task worktree's read let through after every `projectRun` project reads in a row, so tasks are
/// never starved; within each, first come first served.
public final class ReadPool: @unchecked Sendable {
    public enum Priority: Sendable {
        /// The read after something the person did (a stage, a commit): ahead of every other.
        case action
        /// A project's folder: what the panel lists first.
        case project
        /// A task's worktree.
        case task
    }

    /// The panels' pool: at most four reads at once, at utility QoS, as a background read is.
    public static let panels = ReadPool(limit: 4, queue: .global(qos: .utility))

    /// Project reads taken from the queue in a row before a waiting task's read goes.
    public static let projectRun = 4

    private let limit: Int
    private let queue: DispatchQueue
    private let actionQueue: DispatchQueue
    private let lock = NSLock()
    private var running = 0
    private var actions: [@Sendable () -> Void] = []
    private var projects: [@Sendable () -> Void] = []
    private var tasks: [@Sendable () -> Void] = []
    /// Project reads taken from the queue since the last task's.
    private var streak = 0

    /// `queue` runs the background reads; `actionQueue` the reads after an action.
    public init(limit: Int, queue: DispatchQueue, actionQueue: DispatchQueue = .global(qos: .userInitiated)) {
        precondition(limit > 0, "a pool runs at least one read")
        self.limit = limit
        self.queue = queue
        self.actionQueue = actionQueue
    }

    /// Runs `work` on the pool's queue once a place is free.
    public func submit(_ priority: Priority, _ work: @escaping @Sendable () -> Void) {
        let now: Bool = lock.withLock {
            guard running < limit else {
                switch priority {
                case .action: actions.append(work)
                case .project: projects.append(work)
                case .task: tasks.append(work)
                }
                return false
            }
            running += 1
            return true
        }
        if now { launch(work, priority) }
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
        lock.withLock { (running, actions.count + projects.count + tasks.count) }
    }

    private func launch(_ work: @escaping @Sendable () -> Void, _ priority: Priority) {
        (priority == .action ? actionQueue : queue).async {
            work()
            self.finished()
        }
    }

    /// A place came free: the next waiting read takes it.
    private func finished() {
        let next: (work: @Sendable () -> Void, priority: Priority)? = lock.withLock {
            if !actions.isEmpty { return (actions.removeFirst(), .action) }
            if !tasks.isEmpty, projects.isEmpty || streak >= Self.projectRun {
                streak = 0
                return (tasks.removeFirst(), .task)
            }
            if !projects.isEmpty {
                streak += 1
                return (projects.removeFirst(), .project)
            }
            running -= 1
            return nil
        }
        if let next { launch(next.work, next.priority) }
    }
}
