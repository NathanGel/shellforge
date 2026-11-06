import Foundation

/// What a project's repository says that its row draws — who hosts it, and the default branch its
/// Pull names — read once for the app rather than once per window: every new window's sidebar asks
/// for every project. An answer stands for `ttl` seconds, and not past a change to the files it
/// came from: `.git/config` (where the remote URL lives), the refs that name origin's HEAD, and
/// the files that mark a GitLab checkout. Thread-safe, and meant to be called off the main actor.
public final class RepositoryFacts<Facts: Sendable>: Sendable {
    private struct Kept { let facts: Facts; let stamps: FileStamps; let at: Date }
    private let kept = Locked<[String: Kept]>([:])
    private let reads = Locked(0)
    private let read: @Sendable (String) -> Facts
    private let now: @Sendable () -> Date
    private let ttl: TimeInterval

    public init(ttl: TimeInterval = 60, now: @escaping @Sendable () -> Date = Date.init, read: @escaping @Sendable (String) -> Facts) {
        self.ttl = ttl; self.now = now; self.read = read
    }

    /// How many times a repository was read, for tests.
    public var readCount: Int { reads.withLock { $0 } }

    /// `path`'s facts, read again when the kept ones are older than `ttl` or a file they came from
    /// changed.
    public func facts(of path: String) -> Facts {
        let at = now()
        if let known = kept.withLock({ $0[path] }), at.timeIntervalSince(known.at) < ttl, known.stamps.areCurrent {
            return known.facts
        }
        // Stamped before the read: a change while git answers is caught on the next ask.
        let stamps = FileStamps(Self.sources(of: path))
        let facts = read(path)
        reads.withLock { $0 += 1 }
        kept.withLock { $0[path] = Kept(facts: facts, stamps: stamps, at: at) }
        return facts
    }

    /// Drops what is kept for `path`: the next ask reads it.
    public func forget(_ path: String) {
        kept.withLock { _ = $0.removeValue(forKey: path) }
    }

    /// The files whose change can change the answer, in an ordinary checkout. A linked worktree's
    /// `.git` is a file and its config lives elsewhere: `ttl` covers it.
    static func sources(of path: String) -> [String] {
        let git = path + "/.git"
        return [git, git + "/config", git + "/packed-refs", git + "/refs/remotes/origin/HEAD",
                path + "/.gitlab-ci.yml", path + "/.gitlab"]
    }
}
