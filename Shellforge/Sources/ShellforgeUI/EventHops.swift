import Foundation

/// Events handed from a watcher's queue to the main actor, kept so tests can await them. Each hop
/// leaves once it has run, so a long session keeps none.
final class EventHops: @unchecked Sendable {
    private let lock = NSLock()
    private var next = 0
    private var tasks: [Int: Task<Void, Never>] = [:]
    /// Hops that finished before they were added: `add` then keeps nothing.
    private var finished: Set<Int> = []

    /// Runs `body` on the main actor, kept until it has run.
    func hop(_ body: @escaping @MainActor @Sendable () -> Void) {
        // The id is taken before the task is made, so a task that finishes first is not kept.
        let id = lock.withLock { next += 1; return next }
        let task = Task { @MainActor [self] in
            body()
            finish(id)
        }
        lock.withLock { if finished.remove(id) == nil { tasks[id] = task } }
    }

    private func finish(_ id: Int) {
        lock.withLock { if tasks.removeValue(forKey: id) == nil { finished.insert(id) } }
    }

    /// Waits until every hop made so far has run.
    func delivered() async {
        for hop in lock.withLock({ Array(tasks.values) }) { await hop.value }
    }

    /// The hops still kept.
    var count: Int { lock.withLock { tasks.count } }
}
