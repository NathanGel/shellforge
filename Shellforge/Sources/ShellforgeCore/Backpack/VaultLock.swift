import Foundation
import os

private let vaultLockLog = Logger(subsystem: "io.github.nathangel.shellforge", category: "keychain")

/// A lock across processes on one file, taken with `flock`. Every Shellforge process that writes
/// the vault (a release build and a dev build running together) holds it around checking and
/// writing the item, so one waits for the other instead of both storing the whole item from what
/// each read before.
///
/// The wait is bounded: another process may hold the lock while it shows a Keychain prompt or sits
/// at a breakpoint, and the caller holds the vault's in-process lock, which every Keychain call in
/// this process waits on. Past the bound, or when the lock file cannot be used, `body` runs
/// without it; the read-back after each write still catches another writer.
struct VaultLock: Sendable {
    static let defaultTimeout: TimeInterval = 3

    let url: URL
    let timeout: TimeInterval
    /// Called when another process holds the lock and this one is about to wait for it.
    let waiting: (@Sendable () -> Void)?

    init(url: URL, timeout: TimeInterval = VaultLock.defaultTimeout, waiting: (@Sendable () -> Void)? = nil) {
        self.url = url
        self.timeout = timeout
        self.waiting = waiting
    }

    /// In the installed app's support folder, not the running build's: a dev build has a folder of
    /// its own but shares the one Keychain item with the installed app.
    static var standard: VaultLock {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return VaultLock(url: ShellforgePaths.supportDirectory(home: home).appendingPathComponent("vault.lock"))
    }

    /// Said once per process, so a lock that keeps timing out does not fill the log.
    private static let saidUnavailable = Locked(false)

    private static func unavailable(_ why: String) {
        let first = saidUnavailable.withLock { said in
            defer { said = true }
            return !said
        }
        if first { vaultLockLog.error("Writing the vault without the lock across processes: \(why, privacy: .public)") }
    }

    /// Runs `body` holding the lock, or without it when the lock is unavailable or another process
    /// held it past `timeout`.
    func withLock<T>(_ body: () -> T) -> T {
        guard let fd = openLockFile() else { return body() }
        guard acquire(fd) else { return body() }
        // Closing the file releases the lock.
        defer { close(fd) }
        return body()
    }

    /// The lock file, opened without following a symbolic link, and only when it is a regular file
    /// owned by this user.
    private func openLockFile() -> Int32? {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            Self.unavailable("opening the lock file failed (errno \(errno))")
            return nil
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
            close(fd)
            Self.unavailable("the lock file is not a regular file of this user")
            return nil
        }
        return fd
    }

    /// Takes the lock on `fd`. On `false`, `fd` is no longer the caller's: it is closed here, or by
    /// the waiting thread once its `flock` returns.
    private func acquire(_ fd: Int32) -> Bool {
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return true }
        waiting?()
        let wait = BlockingWait()
        let thread = Thread {
            var result = flock(fd, LOCK_EX)
            while result != 0 && errno == EINTR { result = flock(fd, LOCK_EX) }
            if !wait.finish(acquired: result == 0) { close(fd) }
        }
        thread.name = "vault lock wait"
        thread.start()
        switch wait.outcome(within: timeout) {
        case .acquired: return true
        case .failed:
            close(fd)
            Self.unavailable("taking the lock failed")
            return false
        case .abandoned:
            Self.unavailable("another process held the lock for more than \(timeout) seconds")
            return false
        }
    }
}

/// The hand-off between a thread blocked in `flock` and the caller waiting for it with a bound.
/// Whichever side comes second learns what the other did, so the descriptor is closed exactly once.
private final class BlockingWait: @unchecked Sendable {
    enum Outcome { case acquired, failed, abandoned }

    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var result: Bool?
    private var abandoned = false

    /// Called by the waiting thread. `false` when the caller gave up, so the thread closes the file.
    func finish(acquired: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !abandoned else { return false }
        result = acquired
        done.signal()
        return true
    }

    func outcome(within timeout: TimeInterval) -> Outcome {
        _ = done.wait(timeout: .now() + timeout)
        lock.lock()
        defer { lock.unlock() }
        guard let result else {
            abandoned = true
            return .abandoned
        }
        return result ? .acquired : .failed
    }
}
