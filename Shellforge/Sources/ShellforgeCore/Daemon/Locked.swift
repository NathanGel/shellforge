import Foundation

/// A value under a lock, with `Mutex`'s `withLock` shape: `Mutex` needs macOS 15, and Shellforge
/// runs on iTerm2's macOS 13. Unchecked, because every access goes through `withLock`.
public final class Locked<State>: @unchecked Sendable {
    private let lock = NSLock()
    private var state: State

    public init(_ state: State) { self.state = state }

    public func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }
}
