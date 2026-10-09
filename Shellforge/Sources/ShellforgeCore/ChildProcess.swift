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
    /// A child that outlives it is sent SIGTERM, then SIGKILL a second later.
    static func run(_ executable: String, _ arguments: [String], environment: [String: String],
                    directory: String? = nil, timeout: TimeInterval) throws -> ChildOutput {
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
        try process.run()

        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                finished.wait()
            }
        }
        // A grandchild that kept the pipes open (a shell's background job) must not hold us up.
        return ChildOutput(status: process.terminationStatus, stdout: out.text(waiting: 1),
                           stderr: err.text(waiting: 1), timedOut: timedOut)
    }
}

extension ChildProcess {
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

/// Drains a pipe on a thread of its own, so a child that fills one pipe while we read the other
/// never stalls. Its own thread, not a slot on a shared queue: a reader blocks until end of output,
/// and a command that leaves a background job holding its pipe (an SSH tunnel) would otherwise tie
/// up shared threads until other commands' readers never got to run. What has arrived is kept as it
/// arrives, so an end of output that comes late still leaves the output that came on time.
private final class PipeReader: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let done = DispatchSemaphore(value: 0)

    init(_ handle: FileHandle) {
        let thread = Thread { [self] in
            while case let chunk = handle.availableData, !chunk.isEmpty {
                lock.withLock { data.append(chunk) }
            }
            done.signal()
        }
        thread.name = "ShellforgeCore.PipeReader"
        thread.start()
    }

    func text(waiting seconds: TimeInterval) -> String {
        _ = done.wait(timeout: .now() + seconds)
        return lock.withLock { String(decoding: data, as: UTF8.self) }
    }

}
