import Foundation

/// Callers waiting on one answer that comes later, all handed it when it does. A single stored
/// continuation would be overwritten by a second caller, whose arrival strands the first forever.
@MainActor
public final class Waiters<Value: Sendable> {
    private var waiting: [CheckedContinuation<Value, Never>] = []

    public init() {}

    /// How many are waiting.
    public var count: Int { waiting.count }

    /// Waits for `resumeAll`, after `start` — what asks for the answer — has run.
    public func wait(start: () -> Void) async -> Value {
        await withCheckedContinuation { continuation in
            waiting.append(continuation)
            start()
        }
    }

    public func resumeAll(_ value: Value) {
        let all = waiting
        waiting = []
        for continuation in all { continuation.resume(returning: value) }
    }
}
