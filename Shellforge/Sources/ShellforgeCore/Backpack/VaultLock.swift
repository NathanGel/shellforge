import Foundation
import os

private let vaultLockLog = Logger(subsystem: "io.github.nathangel.shellforge", category: "keychain")

/// A lock across processes on one file, taken with `flock`. Every Shellforge process that writes
/// the vault (a release build and a dev build running together) holds it around reading, checking
/// and writing the item, so one waits for the other instead of both storing the whole item from
/// what each read before.
struct VaultLock: Sendable {
    let url: URL
    /// Called when another process holds the lock and this one is about to wait for it.
    let waiting: (@Sendable () -> Void)?

    init(url: URL, waiting: (@Sendable () -> Void)? = nil) {
        self.url = url
        self.waiting = waiting
    }

    /// In the installed app's support folder, not the running build's: a dev build has a folder of
    /// its own but shares the one Keychain item with the installed app.
    static var standard: VaultLock {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return VaultLock(url: ShellforgePaths.supportDirectory(home: home).appendingPathComponent("vault.lock"))
    }

    /// Runs `body` holding the lock. When the lock file cannot be opened or locked, `body` runs
    /// anyway: the read-back after a write still catches another writer, and refusing would leave a
    /// token unsaved over a lock file.
    func withLock<T>(_ body: () -> T) -> T {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            vaultLockLog.error("Opening the vault lock failed: \(errno, privacy: .public)")
            return body()
        }
        // Closing the file releases the lock.
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            waiting?()
            var result = flock(fd, LOCK_EX)
            while result != 0 && errno == EINTR { result = flock(fd, LOCK_EX) }
            if result != 0 { vaultLockLog.error("Taking the vault lock failed: \(errno, privacy: .public)") }
        }
        return body()
    }
}
