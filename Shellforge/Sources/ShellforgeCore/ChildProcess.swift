import Foundation

/// What a finished child said.
public struct ChildOutput: Sendable, Equatable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    /// The child outlived its deadline and was killed; `status` is then the signal's.
    public let timedOut: Bool
}

/// The only place in Shellforge that creates a `Process`. Everything else goes through
/// `CommandLauncher`, which gives the child the login environment; a source test keeps it that way.
enum ChildProcess {
    /// Runs `executable` with exactly `environment`, stdin closed, and waits up to `timeout` seconds.
    /// A child that outlives it — or that `cancellation` stops — is sent SIGTERM with everything it
    /// started, then SIGKILL a second later.
    static func run(_ executable: String, _ arguments: [String], environment: [String: String],
                    directory: String? = nil, timeout: TimeInterval,
                    cancellation: CreationCancellation? = nil) throws -> ChildOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let out = PipeReader(stdout.fileHandleForReading), err = PipeReader(stderr.fileHandleForReading)
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        // A create already cancelled starts nothing more.
        if cancellation?.isCancelled == true { throw CreationCancelled() }
        try process.run()
        var stopped: [pid_t] = []
        if let cancellation, !cancellation.begin(process) { stopped = terminateTree(process) }

        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            stopped += terminateTree(process)
            finished.wait()
        }
        cancellation?.end()
        // What was stopped is gone before the caller goes on — to clean up a worktree a hook was
        // still writing into, say.
        reap(stopped + (cancellation?.takeStopped() ?? []))
        // A grandchild that kept the pipes open (a shell's background job) must not hold us up.
        return ChildOutput(status: process.terminationStatus, stdout: out.text(waiting: 1),
                           stderr: err.text(waiting: 1), timedOut: timedOut)
    }
}

extension ChildProcess {
    /// Asks `process` and every process it started — a git hook and the `uv sync` it ran — to stop
    /// (SIGTERM), and returns who was asked, for `reap`. Enumerated once: a process forked after, or
    /// one already handed to launchd, is not reached.
    @discardableResult
    static func terminateTree(_ process: Process) -> [pid_t] {
        let pid = process.processIdentifier
        guard pid > 0 else { return [] }
        let all = [pid] + descendants(of: pid)
        for each in all { kill(each, SIGTERM) }
        return all
    }

    /// Waits up to a second for `pids` to end, SIGKILLs any that would not, and waits for those.
    static func reap(_ pids: [pid_t]) {
        guard !pids.isEmpty else { return }
        if waitGone(pids, timeout: 1) { return }
        for each in pids where kill(each, 0) == 0 { kill(each, SIGKILL) }
        _ = waitGone(pids, timeout: 1)
    }

    /// Whether every one of `pids` has ended within `timeout`, told by the kernel as each exits.
    private static func waitGone(_ pids: [pid_t], timeout: TimeInterval) -> Bool {
        let group = DispatchGroup()
        var sources: [DispatchSourceProcess] = []
        for pid in pids where kill(pid, 0) == 0 {
            group.enter()
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
            source.setEventHandler { source.cancel() }
            source.setCancelHandler { group.leave() }
            source.resume()
            // Gone between the check and the watch: nothing would ever tell.
            if kill(pid, 0) != 0 { source.cancel() }
            sources.append(source)
        }
        let gone = group.wait(timeout: .now() + timeout) == .success
        sources.forEach { $0.cancel() }
        return gone
    }

    /// Every process below `pid`, children first.
    static func descendants(of pid: pid_t) -> [pid_t] {
        var found: [pid_t] = []
        var pending = [pid]
        while let parent = pending.popLast() {
            let estimate = proc_listchildpids(parent, nil, 0)
            guard estimate > 0 else { continue }
            var buffer = [pid_t](repeating: 0, count: Int(estimate) + 16)
            let count = buffer.withUnsafeMutableBytes { bytes in
                proc_listchildpids(parent, bytes.baseAddress, Int32(bytes.count))
            }
            let children = buffer.prefix(max(0, Int(count))).filter { $0 > 0 }
            found += children
            pending += children
        }
        return found
    }

    /// Starts `executable` and returns at once: a child that outlives the call, as the daemon does.
    /// Its standard output and error go to `output` (nowhere when nil), stdin is closed, and
    /// `onExit` is called with it and its exit status when it ends.
    static func launch(_ executable: String, _ arguments: [String], environment: [String: String], directory: String?,
                       output: FileHandle?, onExit: @escaping @Sendable (RunningChild, Int32) -> Void) throws -> RunningChild {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output ?? FileHandle.nullDevice
        process.standardError = output ?? FileHandle.nullDevice
        let child = RunningChild(process)
        process.terminationHandler = { onExit(child, $0.terminationStatus) }
        try process.run()
        return child
    }

    /// Starts `executable` reading a pipe this process holds, and hands back the pipe's write end:
    /// when it closes — handed back, or this process gone however it went — the child reads end of
    /// file. Not waited for: it outlives us on purpose. Backpack Mode's sleep watchdog.
    static func holding(_ executable: String, _ arguments: [String], environment: [String: String]) throws -> FileHandle {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let pipe = Pipe()
        process.standardInput = pipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        try? pipe.fileHandleForReading.close()
        return pipe.fileHandleForWriting
    }

}

/// A child started by `ChildProcess.launch`, while it runs and after.
public final class RunningChild: @unchecked Sendable {
    private let process: Process

    init(_ process: Process) { self.process = process }

    /// Its process id; 0 before it has started.
    public var pid: Int32 { process.processIdentifier }

    public var isRunning: Bool { process.isRunning }

    /// SIGTERM: asks it to stop.
    public func terminate() { process.terminate() }

    /// SIGKILL: for a child that would not stop when asked.
    public func kill() { _ = Darwin.kill(pid, SIGKILL) }
}

/// Drains a pipe as its bytes arrive, on one dispatch queue every reader shares: no thread of its
/// own, and no polling. What has arrived is kept as it arrives, so an end of output that comes late
/// still leaves the output that came on time.
///
/// A command can leave a background job holding its pipe (an SSH tunnel, a hook's `&`). Once the
/// call has taken its text, whatever that job still writes is read and dropped — never met with a
/// closed pipe, whose SIGPIPE would kill it — and the pipe closes when the job lets go of it.
private final class PipeReader: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "ShellforgeCore.PipeReader")
    private let lock = NSLock()
    private var data = Data()
    private var taken = false
    private let done = DispatchSemaphore(value: 0)
    /// Read into on `queue` only.
    private var buffer = [UInt8](repeating: 0, count: 65_536)
    private let source: DispatchSourceRead

    init(_ handle: FileHandle) {
        let fd = handle.fileDescriptor
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: Self.queue)
        // The handlers hold the reader until the pipe's end: dispatch lets them go once cancelled.
        source.setEventHandler { [self] in
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                lock.withLock { if !taken { data.append(contentsOf: buffer[0..<count]) } }
            } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
                source.cancel()
            }
        }
        source.setCancelHandler { [self] in
            try? handle.close()
            done.signal()
        }
        source.resume()
    }

    /// What arrived, waiting up to `seconds` for the end of output; anything later is dropped.
    func text(waiting seconds: TimeInterval) -> String {
        _ = done.wait(timeout: .now() + seconds)
        return lock.withLock {
            taken = true
            defer { data = Data() }
            return String(decoding: data, as: UTF8.self)
        }
    }
}
