import CoreServices
import Foundation

/// Tells when something under a folder changes. A protocol so tests fire the change themselves.
public protocol FolderWatching: AnyObject, Sendable {
    /// Calls `onChange`, on a queue of the watcher's own, when anything under `path` changes.
    func watch(_ path: String, onChange: @escaping @Sendable () -> Void)
    func stop()
}

/// An FSEvents stream over one folder. The stream coalesces bursts itself (0.3 s) and reports
/// individual files, so a save inside a nested folder counts.
public final class FolderWatcher: FolderWatching, @unchecked Sendable {
    private let queue = DispatchQueue(label: "shellforge.folder-watcher")
    private var stream: FSEventStreamRef?
    private var box: Box?

    private final class Box {
        let onChange: @Sendable () -> Void
        init(_ onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }
    }

    public init() {}

    deinit { stop() }

    public func watch(_ path: String, onChange: @escaping @Sendable () -> Void) {
        stop()
        let box = Box(onChange)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<Box>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else { return }
        self.box = box
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        queue.sync {}   // a callback already running finishes before the box goes
        box = nil
    }
}
