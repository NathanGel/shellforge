// Ported from AiTerm (app/Sources/AiTermCore/BackgroundWork.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// Blocking filesystem/process work belongs on a Dispatch queue, not Swift's
/// cooperative executor. Callers retain ownership of cancellation and stale results.
public enum BackgroundWork {
    /// `queue` is a caller's own when its work must be serialised — `TaskWorkflow` keeps every git
    /// mutation on one queue — and the shared concurrent one otherwise. It throws what `work`
    /// throws and nothing else, so work that cannot fail is awaited without a `try`.
    public static func run<Value: Sendable, Failure: Error>(on queue: DispatchQueue = .global(qos: .userInitiated),
                                                            _ work: @escaping @Sendable () throws(Failure) -> Value) async throws(Failure) -> Value {
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result<Value, Failure>, Never>) in
            queue.async { continuation.resume(returning: Result { () throws(Failure) -> Value in try work() }) }
        }
        return try result.get()
    }
}
