import CoreServices
import Foundation

/// Tells when something under a folder changes. A protocol so tests fire the change themselves.
public protocol FolderWatching: AnyObject, Sendable {
    /// Calls `onChange`, on a queue of the watcher's own, when something under `path` that can
    /// change what the panel lists changes. It must not call `stop()` itself.
    func watch(_ path: String, onChange: @escaping @Sendable () -> Void)
    /// The same, with what changed: the relevant paths, relative to `path` ("" for the folder
    /// itself). An empty list says something changed but not what.
    func watch(_ path: String, onChanges: @escaping @Sendable ([String]) -> Void)
    func stop()
}

extension FolderWatching {
    public func watch(_ path: String, onChanges: @escaping @Sendable ([String]) -> Void) {
        watch(path) { onChanges([]) }
    }
}

/// An FSEvents stream over one folder. The stream coalesces bursts itself (0.3 s) and reports
/// individual files, so a save inside a nested folder counts.
public final class FolderWatcher: FolderWatching, @unchecked Sendable {
    private let queue = DispatchQueue(label: "shellforge.folder-watcher")
    private let onQueue = DispatchSpecificKey<Void>()
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var box: Box?
    private let filter: @Sendable (String, String) -> Bool

    private final class Box {
        let root: String
        let filter: @Sendable (String, String) -> Bool
        let onChanges: @Sendable ([String]) -> Void
        init(root: String, filter: @escaping @Sendable (String, String) -> Bool, onChanges: @escaping @Sendable ([String]) -> Void) {
            self.root = root
            self.filter = filter
            self.onChanges = onChanges
        }
    }

    /// `filter` says whether a changed path (as the stream reports it) under the watched folder
    /// counts: the Files panel's by default, `GitWatchPaths.isRelevant` for the Git panel.
    public init(filter: @escaping @Sendable (_ path: String, _ root: String) -> Bool = FolderWatcher.isRelevant) {
        self.filter = filter
        queue.setSpecific(key: onQueue, value: ())
    }

    deinit { stop() }

    /// Whether a change at `path` can change what the panel lists. Git's own folder is noise (its
    /// objects, logs and lock files change all the time) except the three files that decide what
    /// is tracked and what is ignored; task worktrees are not listed. `root` is the watched
    /// folder as the stream reports it (symlinks resolved).
    public static func isRelevant(_ path: String, root: String) -> Bool {
        let base = root.hasSuffix("/") ? String(root.dropLast()) : root
        guard path == base || path.hasPrefix(base + "/") else { return true }
        let parts = path.dropFirst(base.count).split(separator: "/").map(String.init)
        if parts.contains(".git") {
            return parts == [".git", "index"] || parts == [".git", "HEAD"] || parts == [".git", "info", "exclude"]
        }
        return parts.first != ".worktrees"
    }

    /// `path` as the stream reports paths under it: realpath's answer. Foundation's resolving
    /// drops `/private` (`/tmp/x` stays `/tmp/x`) while the stream says `/private/tmp/x/...`.
    static func resolvedRoot(_ path: String) -> String {
        guard let pointer = realpath(path, nil) else { return path }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    /// What a batch of the stream's paths reports: nil when none of them counts, else the ones
    /// that count, relative to `root` — or none at all when one of them is not under `root`.
    static func changes(_ paths: [String], root: String, filter: (String, String) -> Bool) -> [String]? {
        guard !paths.isEmpty else { return [] }
        let relevant = paths.filter { filter($0, root) }
        guard !relevant.isEmpty else { return nil }
        let base = root.hasSuffix("/") ? String(root.dropLast()) : root
        var relative: [String] = []
        for path in relevant {
            if path == base {
                relative.append("")
            } else if path.hasPrefix(base + "/") {
                relative.append(String(path.dropFirst(base.count + 1)))
            } else {
                return []
            }
        }
        return relative
    }

    public func watch(_ path: String, onChange: @escaping @Sendable () -> Void) {
        watch(path) { _ in onChange() }
    }

    public func watch(_ path: String, onChanges: @escaping @Sendable ([String]) -> Void) {
        stop()
        let box = Box(root: Self.resolvedRoot(path), filter: filter, onChanges: onChanges)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
            if let changes = FolderWatcher.changes(paths, root: box.root, filter: box.filter) { box.onChanges(changes) }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else {
            ErrorLogging.record("files", "Watching \(path) failed: the file event stream could not be created")
            return
        }
        lock.withLock {
            self.box = box
            self.stream = stream
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        if !FSEventStreamStart(stream) {
            ErrorLogging.record("files", "Watching \(path) failed: the file event stream did not start")
        }
    }

    public func stop() {
        let taken: FSEventStreamRef? = lock.withLock {
            defer { stream = nil }
            return stream
        }
        guard let taken else { return }
        FSEventStreamStop(taken)
        FSEventStreamInvalidate(taken)
        FSEventStreamRelease(taken)
        // A callback already running finishes before its box goes (not from the queue itself).
        if DispatchQueue.getSpecific(key: onQueue) == nil { queue.sync {} }
        lock.withLock { box = nil }
    }
}
