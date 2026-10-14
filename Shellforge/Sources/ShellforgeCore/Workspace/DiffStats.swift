// Ported from AiTerm (app/Sources/AiTermCore/Git/DiffStatResolver.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// Lines a checkout adds and removes against the branch it started from.
public struct DiffStat: Equatable, Sendable {
    public var added: Int, removed: Int
    public init(added: Int, removed: Int) { self.added = added; self.removed = removed }
    public var isEmpty: Bool { added == 0 && removed == 0 }
}

/// Measures a task's worktree against its base branch: everything since the two diverged —
/// commits, uncommitted edits and untracked files alike, because an agent's work is on the branch
/// long before anyone commits it. Ignored and binary files do not count.
///
/// No one file changes when a diff does — any edit in the tree does — so an answer is kept for
/// `ttl` seconds, which is what stops every window's tick from running `git diff` over every
/// worktree each second. The merge-base the diff starts from is tied to the refs it joins, so it is
/// kept until one of them moves; an untracked file's lines are kept against its `lstat`, so an
/// expired answer reads only the files that changed.
///
/// A git that runs out of time is not an answer: the last known diff stands, and the worktree is
/// left alone for `failureBackoff` seconds. Thread-safe, and meant to be called off the main actor.
public final class DiffStats: Sendable {
    private struct Entry { var value: DiffStat?; var at: Date }
    /// What an untracked file counted as, and the `lstat` of the file it was counted from.
    private struct Counted { var stamp: Stamp; var lines: Int? }
    /// What a rewrite of a file changes: both times to the nanosecond, the size and the inode.
    private struct Stamp: Equatable {
        var modified: Int, changed: Int, size: Int, inode: UInt64
        init(_ info: stat) {
            modified = info.st_mtimespec.tv_sec * 1_000_000_000 + info.st_mtimespec.tv_nsec
            changed = info.st_ctimespec.tv_sec * 1_000_000_000 + info.st_ctimespec.tv_nsec
            size = Int(info.st_size); inode = UInt64(info.st_ino)
        }
    }
    /// A merge-base, nil when the base could not be found, and the refs it was computed from.
    private struct MergeBase { var refs: FileStamps; var commit: String? }

    /// How much of the untracked files is read to count their lines: past either limit the rest
    /// goes uncounted, so the badge is a floor rather than a stall over a stray `node_modules`.
    public struct UntrackedCap: Equatable, Sendable {
        public var files: Int, bytes: Int
        public init(files: Int, bytes: Int) { self.files = files; self.bytes = bytes }
        public static let standard = UntrackedCap(files: 2_000, bytes: 20 << 20)
    }

    private struct Kept {
        var entries: [String: Entry] = [:]
        var mergeBases: [String: MergeBase] = [:]
        var counted: [String: [String: Counted]] = [:]
        /// When git last ran out of time on a checkout.
        var timeouts: [String: Date] = [:]
        /// Checkouts being read now: every window asks on the same tick, and a second ask gets the
        /// last known answer rather than running git beside the first.
        var reading: Set<String> = []
    }

    /// Untracked files bigger than this are skipped rather than read.
    static let untrackedByteLimit = 1 << 20
    public static let failureBackoff: TimeInterval = 30
    /// Each git call's deadline: a worktree on a stalled mount holds up its pass this long at most.
    public static let gitDeadline: TimeInterval = 10

    private let git: any GitCommands
    private let now: @Sendable () -> Date
    private let ttl: TimeInterval
    private let cap: UntrackedCap
    private let kept = Locked(Kept())

    public init(git: any GitCommands, now: @escaping @Sendable () -> Date = Date.init, ttl: TimeInterval = 5,
                untrackedCap: UntrackedCap = .standard) {
        self.git = git; self.now = now; self.ttl = ttl; self.cap = untrackedCap
    }

    private static let sharedOne = Locked<DiffStats?>(nil)
    /// The one every window asks: an answer one window paid for is every window's.
    public static func shared(launcher: CommandLauncher) -> DiffStats {
        sharedOne.withLock { one in
            if let one { return one }
            let made = DiffStats(git: LauncherGit(launcher: launcher))
            one = made
            return made
        }
    }

    /// The diff of `worktree` against `base`; nil when there is no base, it cannot be found locally
    /// or as `origin/<base>`, or `worktree` is not a checkout.
    public func diff(for worktree: String, base: String) -> DiffStat? {
        // A folder gone from disk is no checkout: no git is run for it.
        guard !worktree.isEmpty, !base.isEmpty, FileManager.default.fileExists(atPath: worktree) else { return nil }
        let key = Self.key(worktree, base)
        let (known, stands): (Entry?, Bool) = kept.withLock { kept in
            let known = kept.entries[key], at = now()
            let fresh = known.map { at.timeIntervalSince($0.at) < ttl } ?? false
            let waiting = kept.timeouts[key].map { at.timeIntervalSince($0) < Self.failureBackoff } ?? false
            let stands = fresh || waiting || kept.reading.contains(key)
            if !stands { kept.reading.insert(key) }
            return (known, stands)
        }
        if stands { return known?.value }
        defer { kept.withLock { _ = $0.reading.remove(key) } }
        do {
            let value = try read(worktree, base: base, key: key)
            kept.withLock { $0.entries[key] = Entry(value: value, at: now()); $0.timeouts[key] = nil }
            return value
        } catch {
            kept.withLock { $0.timeouts[key] = now() }
            return known?.value
        }
    }

    /// One pass over the tasks; a task with no answer is absent. What is kept for a task no longer
    /// among `tasks` is dropped.
    public func diffs(for tasks: [TaskItem]) -> [UUID: DiffStat] {
        let live = Set(tasks.map { Self.key($0.worktreePath, $0.baseBranch) })
        kept.withLock { kept in
            kept.entries = kept.entries.filter { live.contains($0.key) }
            kept.mergeBases = kept.mergeBases.filter { live.contains($0.key) }
            kept.counted = kept.counted.filter { live.contains($0.key) }
            kept.timeouts = kept.timeouts.filter { live.contains($0.key) }
        }
        var out: [UUID: DiffStat] = [:]
        for task in tasks {
            if let diff = diff(for: task.worktreePath, base: task.baseBranch) { out[task.id] = diff }
        }
        return out
    }

    private static func key(_ worktree: String, _ base: String) -> String { worktree + "\u{0}" + base }

    /// Throws when git ran out of time; any other failure is nil, no answer.
    private func read(_ worktree: String, base: String, key: String) throws -> DiffStat? {
        guard let from = try mergeBase(worktree, base: base, key: key),
              let numstat = try ask(["diff", "--numstat", from], in: worktree) else { return nil }
        var stat = DiffStat(added: 0, removed: 0)
        for line in numstat.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 2)
            // A binary file reports `-` for both counts; `Int` refuses it, which is the skip.
            guard fields.count == 3, let added = Int(fields[0]), let removed = Int(fields[1]) else { continue }
            stat.added += added; stat.removed += removed
        }
        stat.added += try untrackedLines(worktree, key: key)
        return stat
    }

    /// git's trimmed answer; nil for a command git refused or that could not be run, a throw only
    /// for one that ran out of time — the one failure that backs off.
    private func ask(_ args: [String], in directory: String) throws -> String? {
        guard let out = try? git.git(args, in: directory, remote: false, timeout: Self.gitDeadline) else { return nil }
        if out.timedOut { throw GitTimedOut(command: "git " + args.joined(separator: " ")) }
        guard out.status == 0 else { return nil }
        return out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The cached merge-base while its refs are unchanged, else a fresh one. The refs are stamped
    /// before git is asked, so a ref that moves while it answers is caught on the next pass.
    private func mergeBase(_ worktree: String, base: String, key: String) throws -> String? {
        let cached = kept.withLock { $0.mergeBases[key] }
        if let cached, cached.refs.areCurrent { return cached.commit }
        guard let files = try refFiles(worktree, base: base) else { return nil }
        let refs = FileStamps(files)
        let commit = try findMergeBase(worktree, base: base)
        kept.withLock { $0.mergeBases[key] = MergeBase(refs: refs, commit: commit) }
        return commit
    }

    /// Every file whose change can move the merge-base: `HEAD`, the branch it is on, `<base>` and
    /// `origin/<base>`, `packed-refs`, and both reftable stacks. nil when `worktree` is not a
    /// checkout with a commit.
    private func refFiles(_ worktree: String, base: String) throws -> [String]? {
        let names = ["HEAD", "packed-refs", "refs/heads/" + base, "refs/remotes/origin/" + base, "reftable/tables.list"]
        guard let answer = try ask(["rev-parse", "--symbolic-full-name", "HEAD"] + names.flatMap { ["--git-path", $0] },
                                   in: worktree) else { return nil }
        var lines = answer.split(separator: "\n").map(String.init)
        guard lines.count == names.count + 1 else { return nil }
        let head = lines.removeFirst()
        var files = lines.map { FileStamps.absolute($0, in: worktree) }
        let shared = (files[1] as NSString).deletingLastPathComponent
        files.append(shared + "/reftable/tables.list")
        if head.hasPrefix("refs/") { files.append(shared + "/" + head) }
        return files
    }

    /// Where the checkout left `base`, locally or on origin: when both exist the later of the two
    /// merge-bases wins, so a local base not pulled in weeks does not count upstream's work.
    private func findMergeBase(_ worktree: String, base: String) throws -> String? {
        var found: [String] = []
        for ref in [base, "origin/" + base] {
            if let commit = try ask(["merge-base", ref, "HEAD"], in: worktree), !commit.isEmpty { found.append(commit) }
        }
        guard let first = found.first else { return nil }
        guard found.count == 2, found[0] != found[1] else { return first }
        let localIsOlder = try ask(["merge-base", "--is-ancestor", found[0], found[1]], in: worktree) != nil
        return localIsOlder ? found[1] : found[0]
    }

    /// Lines in the untracked, non-ignored files, counted as `git diff` would once added. A file
    /// whose `lstat` is unchanged is not read again; files no longer listed are forgotten.
    private func untrackedLines(_ worktree: String, key: String) throws -> Int {
        guard let listing = try ask(["ls-files", "--others", "--exclude-standard", "-z"], in: worktree) else { return 0 }
        let before = kept.withLock { $0.counted[key] ?? [:] }
        var after: [String: Counted] = [:]
        var total = 0, bytes = 0
        defer { kept.withLock { $0.counted[key] = after } }
        for name in listing.split(separator: "\0", maxSplits: cap.files).prefix(cap.files) {
            let path = String(name), file = worktree + "/" + path
            var info = stat()
            guard lstat(file, &info) == 0 else { continue }
            // git counts a symlink as one line, its target's path, and never follows it.
            if info.st_mode & S_IFMT == S_IFLNK { total += 1; continue }
            let size = Int(info.st_size)
            guard info.st_mode & S_IFMT == S_IFREG, size <= Self.untrackedByteLimit else { continue }
            guard bytes + size <= cap.bytes else { break }
            bytes += size
            let stamp = Stamp(info)
            let result = before[path].flatMap { $0.stamp == stamp ? $0 : nil }
                ?? Counted(stamp: stamp, lines: Self.contents(of: file, size: size).flatMap(Self.lineCount))
            after[path] = result
            total += result.lines ?? 0
        }
        return total
    }

    /// What a regular file of `size` bytes holds, read without following a link or waiting on a
    /// pipe; nil for a file that grew since `lstat` measured it.
    static func contents(of path: String, size: Int) -> Data? {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              let data = try? file.read(upToCount: size + 1), data.count <= size else { return nil }
        return data
    }

    /// Newlines, plus one for a last line without its own; nil for an empty or binary file.
    static func lineCount(_ data: Data) -> Int? {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int? in
            guard let start = raw.baseAddress, raw.count > 0, memchr(start, 0, raw.count) == nil else { return nil }
            let end = start + raw.count
            var cursor = start, newlines = 0
            while cursor < end, let hit = memchr(cursor, 0x0A, end - cursor) {
                newlines += 1
                cursor = UnsafeRawPointer(hit) + 1
            }
            return newlines + (raw[raw.count - 1] == 0x0A ? 0 : 1)
        }
    }
}
