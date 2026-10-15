import Foundation

/// A create the user can stop: the sheet's Cancel while a worktree is being made. Cancelling ends the
/// command running for it — and everything that command started, such as a repository's checkout
/// hook and its `uv sync` — and the create then undoes what it made.
public final class CreationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var running: Process?
    /// What the cancel stopped, for the run to see off before anything is cleaned up.
    private var stopped: [pid_t] = []

    public init() {}

    public var isCancelled: Bool { lock.withLock { cancelled } }

    /// Asks the running command and what it started to stop, and returns at once: the run waits
    /// for them to be gone, off the main thread.
    public func cancel() {
        let process: Process? = lock.withLock {
            cancelled = true
            return running
        }
        guard let process, process.isRunning else { return }
        let pids = ChildProcess.terminateTree(process)
        lock.withLock { stopped += pids }
    }

    /// The processes the cancel stopped, taken once.
    func takeStopped() -> [pid_t] {
        lock.withLock {
            defer { stopped = [] }
            return stopped
        }
    }

    /// Holds `process` while it runs, so a cancel reaches it; false when already cancelled.
    func begin(_ process: Process) -> Bool {
        lock.withLock {
            guard !cancelled else { return false }
            running = process
            return true
        }
    }

    func end() { lock.withLock { running = nil } }
}

/// The create was stopped by its user.
public struct CreationCancelled: Error, Equatable {
    public init() {}
}

/// What a create is doing, for the sheet to say while it waits.
public enum CreationStep: Equatable, Sendable {
    /// Fetching the base branch from origin.
    case fetching(base: String)
    /// Making the worktree; `runsHook` when the repository's own post-checkout hook runs in it.
    case creatingWorktree(runsHook: Bool)
}
