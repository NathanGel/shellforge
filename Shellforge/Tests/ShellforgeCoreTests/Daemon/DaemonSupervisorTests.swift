// Ported from AiTerm (app/Tests/AiTermCoreTests/DaemonSupervisorTests.swift), GPLv3, Laurens D'Hondt.
import Testing
import Foundation
@testable import ShellforgeCore
@testable import ShellforgeTestSupport

/// Reference-type box so the process-exit callback (fired on the supervisor's private queue) can
/// safely append to a shared array the test polls with `eventually`.
///
/// Unchecked because its stored `var` is mutable: every access holds `lock`.
private final class StateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _states: [DaemonSupervisor.State] = []

    /// Lock-protected snapshot; safe to read from the test's task while `append` runs on the
    /// supervisor's private queue.
    var states: [DaemonSupervisor.State] {
        lock.lock(); defer { lock.unlock() }; return _states
    }

    var runningCount: Int { states.count { if case .running = $0 { return true } else { return false } } }

    func append(_ state: DaemonSupervisor.State) {
        lock.lock(); defer { lock.unlock() }
        _states.append(state)
    }
}

/// The attempt numbers a supervisor asked its backoff about, in order, answering each with `delay`.
/// A test passes `delay` to say how long each wait is, and reads `attempts` to see which waits the
/// supervisor chose, rather than timing them.
private final class RecordedBackoff: Sendable {
    private let asked = Locked<[Int]>([])
    let delay: @Sendable (Int) -> TimeInterval
    init(_ delay: @escaping @Sendable (Int) -> TimeInterval) { self.delay = delay }
    var attempts: [Int] { asked.withLock { $0 } }
    var backoff: @Sendable (Int) -> TimeInterval { { [self] attempt in asked.withLock { $0.append(attempt) }; return delay(attempt) } }
}

/// The bind deadline for a fake daemon that never opens its socket but must stay up for as long as
/// the test looks at it: under the parallel runner a test can outlast the real fifteen seconds.
private let neverAbandoned: TimeInterval = 3600

@Suite final class DaemonSupervisorTests {
    /// Every supervisor built here writes its daemon log into a throwaway directory: the default
    /// (`ShellforgePaths.daemonLogURL`) is the real `~/Library/Application Support/Shellforge`, which the
    /// tests must not touch.
    let logDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("aiterm-log-\(UUID().uuidString)")
    var logURL: URL { logDirectory.appendingPathComponent("shellforged.log") }
    deinit { try? FileManager.default.removeItem(at: logDirectory) }

    /// Sessions come from the app, so the daemon is never told to ask it for iTerm2 cookies.
    @Test func theHelperRunsAsShellforgedWithoutCookies() {
        #expect(DaemonSupervisor.arguments(socketPath: "/tmp/s.sock", hookPort: 47831)
                == ["-m", "shellforged", "run", "--socket", "/tmp/s.sock", "--hook-port", "47831"])
    }

    @Test func theDefaultSocketAndLogAreShellforgesNotAiTerms() {
        #expect(ShellforgePaths.socketPath.hasSuffix("/Application Support/Shellforge/shellforged.sock"))
        #expect(ShellforgePaths.daemonLogURL.path.hasSuffix("/Application Support/Shellforge/shellforged.log"))
        #expect(ShellforgePaths.hookPort == 47831)
    }

    @Test func testBackoffSequence() {
        #expect((0..<6).map(Backoff.delay) == [1, 2, 5, 10, 10, 10])
    }

    @Test func testSupervisorRestartsAfterExit() async {
        // Use /bin/sh as the "python": the module name is ignored, the process exits immediately with 0.
        let box = StateBox()
        let sup = DaemonSupervisor(python: URL(fileURLWithPath: "/bin/sh"), daemonDir: URL(fileURLWithPath: "/tmp"), socketPath: "/tmp/x.sock", arguments: ["-c", "exit 0"], logURL: logURL,
                                   backoff: { _ in 0.01 }) { state in
            box.append(state)
        }
        sup.start()
        await eventually { box.runningCount >= 2 }
        sup.stop()

        #expect(box.runningCount >= 2, "a daemon that exits must be relaunched, got \(box.states)")
        #expect(box.states.contains { if case .failed(let attempt, _) = $0 { return attempt == 1 } else { return false } })
    }

    // C8: `exited(_:status:)` used to act on any child its exit callback was ever given, not
    // just the one it currently supervises. A stale child's callback firing after a restart or an
    // adoption would then treat the process that replaced it as itself having exited.
    @Test func testAStaleChildsExitIsIgnored() async {
        let box = StateBox()
        let sup = DaemonSupervisor(python: URL(fileURLWithPath: "/bin/sh"), daemonDir: URL(fileURLWithPath: "/tmp"), socketPath: "/tmp/stale-\(UUID().uuidString).sock", arguments: ["-c", "sleep 30"], logURL: logURL, bindDeadline: neverAbandoned) { state in
            box.append(state)
        }
        sup.start()
        await eventually { box.states.contains { if case .running = $0 { return true } else { return false } } }

        // A foreign, already-exited `Process` standing in for a stale `terminationHandler` — one
        // whose callback fires after `sup` has already moved on to a different child.
        let ended = Locked(false)
        let stale = try? ChildProcess.launch("/bin/sh", ["-c", "exit 1"], environment: ["PATH": "/usr/bin:/bin"], directory: nil,
                                             output: nil) { _, _ in ended.withLock { $0 = true } }
        await eventually { ended.withLock { $0 } }

        if let stale { sup.exited(stale, status: 1) }
        sup.stop()

        #expect(!box.states.contains { if case .failed = $0 { return true } else { return false } },
                "a stale child's exit must not be treated as the supervised process crashing, got \(box.states)")
    }

    // stop() must not return until the daemon process is actually gone. Enqueuing
    // `terminate()` on the supervisor's queue is not enough: `applicationWillTerminate` returns,
    // the app exits, and the daemon is orphaned holding the socket the next launch needs.
    @Test func testStopTerminatesTheProcessBeforeReturning() async {
        let box = StateBox()
        // A "python" that stays alive, so the process is still running when stop() is called.
        let sup = DaemonSupervisor(python: URL(fileURLWithPath: "/bin/sh"), daemonDir: URL(fileURLWithPath: "/tmp"), socketPath: "/tmp/z.sock", arguments: ["-c", "sleep 30"], logURL: logURL, bindDeadline: neverAbandoned) { state in
            box.append(state)
        }
        sup.start()

        func runningPid() -> Int32? {
            for state in box.states { if case .running(let pid) = state { return pid } }
            return nil
        }
        await eventually { runningPid() != nil }
        guard let pid = runningPid() else { Issue.record("supervisor never reported .running"); return }
        #expect(kill(pid, 0) == 0, "the fake daemon should be running before stop()")

        sup.stop()
        #expect(kill(pid, 0) != 0, "stop() returned while the daemon process was still alive")
    }

    // The daemon runs from inside the signed app bundle (PYTHONPATH), so it must not be
    // allowed to write `__pycache__` there — that breaks `codesign --verify --deep --strict`.
    @Test func testSupervisorDisablesBytecodeWritingInTheDaemonEnvironment() async throws {
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("aiterm-env-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: out) }
        let box = StateBox()
        // A "python" that dumps the two variables we care about and then stays alive. (BSD
        // `printenv` takes a single name, hence the shell expansion.)
        let sup = DaemonSupervisor(python: URL(fileURLWithPath: "/bin/sh"), daemonDir: URL(fileURLWithPath: "/tmp"), socketPath: "/tmp/env.sock",
                                   arguments: ["-c", "echo \"nobytecode=$PYTHONDONTWRITEBYTECODE pythonpath=$PYTHONPATH\" > '\(out.path)'; sleep 30"],
                                   logURL: logURL, bindDeadline: neverAbandoned) { state in
            box.append(state)
        }
        sup.start()

        func dumped() -> String {
            (try? String(contentsOf: out, encoding: .utf8))?.trimmingCharacters(in: .newlines) ?? ""
        }
        await eventually { dumped().contains("pythonpath=") }
        sup.stop()

        #expect(dumped() == "nobytecode=1 pythonpath=/tmp",
                "the daemon environment must disable bytecode writing, got \(dumped())")
    }

    // 2026-09-22: every osascript the daemon's `iterm2` library ran to ask for a cookie inherited
    // the app's launch identity, and LaunchServices showed each one in the Dock as AiTerm — 18
    // icons in 17 seconds while iTerm2 kept refusing.
    @Test func testDaemonEnvironmentDropsTheAppsLaunchIdentity() {
        let inherited = [
            "__CFBundleIdentifier": "com.laurensdhondt.aiterm",
            "XPC_SERVICE_NAME": "application.com.laurensdhondt.aiterm.333546733.333546738",
            "XPC_FLAGS": "0x0",
            "__CF_USER_TEXT_ENCODING": "0x1F5:0x0:0x0",
            "HOME": "/Users/someone", "PATH": "/usr/bin:/bin", "PYTHONPATH": "/elsewhere",
        ]
        let env = DaemonSupervisor.daemonEnvironment(inheriting: inherited, daemonDir: URL(fileURLWithPath: "/bundle/daemon"))

        #expect(env["__CFBundleIdentifier"] == nil)
        #expect(env["XPC_SERVICE_NAME"] == nil)
        #expect(env["XPC_FLAGS"] == nil)
        // The user's text encoding is not an identity, and osascript reads its output through it.
        #expect(env["__CF_USER_TEXT_ENCODING"] == "0x1F5:0x0:0x0")
        #expect(env["HOME"] == "/Users/someone" && env["PATH"] == "/usr/bin:/bin")
        #expect(env["PYTHONPATH"] == "/bundle/daemon")
        #expect(env["PYTHONUNBUFFERED"] == "1" && env["PYTHONDONTWRITEBYTECODE"] == "1")
    }

    // A `python` that can never be launched (Process.run() throws every attempt) must still
    // escalate the backoff counter (1, 2, ...) instead of retrying forever at
    // Backoff.delay(attempt: -1) == 1s. And stop() must leave no later .starting/.running/.failed callback once it has
    // reported .stopped, i.e. a pending scheduled restart must not fire after stop().
    @Test func testSupervisorEscalatesBackoffOnLaunchFailureAndStopsCleanly() async {
        let box = StateBox()
        // The first retry is quick; the second is the pending one `stop()` must cancel.
        let waits = RecordedBackoff { $0 == 0 ? 0.01 : 0.1 }
        let sup = DaemonSupervisor(python: URL(fileURLWithPath: "/nonexistent/python3"), daemonDir: URL(fileURLWithPath: "/tmp"), socketPath: "/tmp/y.sock", logURL: logURL,
                                   backoff: waits.backoff) { state in
            box.append(state)
        }
        sup.start()

        func failedAttempts() -> [Int] {
            box.states.compactMap { if case .failed(let attempt, _) = $0 { return attempt } else { return nil } }
        }

        await eventually { failedAttempts().count >= 2 }
        #expect(Array(failedAttempts().prefix(2)) == [1, 2])

        sup.stop()
        #expect(box.states.last == .stopped)
        // Each failure asks for the wait one attempt behind it: the first retry is attempt 0's. Read
        // after `stop()`, which waits for the queue: a failure is reported before its wait is asked for.
        #expect(Array(waits.attempts.prefix(2)) == [0, 1])

        // The second failure scheduled a restart 0.1s out. Waiting three times that confirms
        // stop() cancelled it rather than merely racing it; `stop()` is serialised with the
        // restart, so a restart that fired first still leaves `.stopped` last.
        let countAfterStop = box.states.count
        try? await Task.sleep(for: .milliseconds(300))
        #expect(box.states.count == countAfterStop, "no further state changes should arrive after stop()")
    }

    // The bug this fixes: an app that died without a graceful quit leaves a healthy daemon
    // holding the socket. The next launch's daemon refuses to start (exit
    // `alreadyRunningExitStatus`), and treating that as a crash restart-looped forever behind a
    // "Daemon keeps exiting" banner. The right answer is to use the daemon that is already there.
    @Test func testSupervisorAdoptsARunningDaemonInsteadOfRestarting() async {
        let box = StateBox()
        let sup = DaemonSupervisor(python: URL(fileURLWithPath: "/bin/sh"), daemonDir: URL(fileURLWithPath: "/tmp"), socketPath: "/tmp/adopt-\(UUID().uuidString).sock",
                                   arguments: ["-c", "exit \(DaemonSupervisor.alreadyRunningExitStatus)"], logURL: logURL, adoptedProbeInterval: 30) { state in
            box.append(state)
        }
        sup.start()

        await eventually { box.states.contains(.adopted) }
        sup.stop()

        #expect(box.states.contains(.adopted), "exit status \(DaemonSupervisor.alreadyRunningExitStatus) must report .adopted, got \(box.states)")
        #expect(!box.states.contains { if case .failed = $0 { return true } else { return false } },
                "adopting a running daemon is not a failure, so no backoff/restart may be scheduled: \(box.states)")
    }

    // Adoption gives up ownership of the process, so the supervisor no longer gets a termination
    // callback if that daemon dies. Without this probe the app would sit with no daemon and no
    // recovery — a regression against the owned-process path, which restarts.
    @Test func testSupervisorTakesOverWhenTheAdoptedDaemonGoesAway() async {
        let box = StateBox()
        // The socket path never has a listener, so the first probe after .adopted finds the
        // daemon gone and the supervisor launches its own.
        let sup = DaemonSupervisor(python: URL(fileURLWithPath: "/bin/sh"), daemonDir: URL(fileURLWithPath: "/tmp"), socketPath: "/tmp/gone-\(UUID().uuidString).sock",
                                   arguments: ["-c", "exit \(DaemonSupervisor.alreadyRunningExitStatus)"], logURL: logURL, adoptedProbeInterval: 0.05) { state in
            box.append(state)
        }
        sup.start()

        func startsAfterFirstAdoption() -> Int {
            guard let i = box.states.firstIndex(of: .adopted) else { return 0 }
            return box.states[i...].filter { $0 == .starting }.count
        }
        await eventually { startsAfterFirstAdoption() >= 1 }
        sup.stop()

        #expect(startsAfterFirstAdoption() >= 1, "a vanished adopted daemon must be replaced, got \(box.states)")
    }

    // The app connects when the supervisor says the daemon is there. A daemon binds its
    // socket only after Python has imported its modules and started asyncio, so reporting it on spawn
    // sent the first connect into a missing socket: a "Reconnecting to AiTerm's helper…" banner on
    // every cold launch, and the first snapshot a full backoff step late.
    @Test func testTheDaemonIsReportedListeningOnlyOnceItsSocketAcceptsConnections() async {
        let box = StateBox()
        let socketPath = "/tmp/ready-\(UUID().uuidString.prefix(8)).sock"
        let listening = Locked<[Bool]>([])
        let script = "import socket,sys,time\ntime.sleep(0.3)\ns=socket.socket(socket.AF_UNIX)\ns.bind(sys.argv[1]);s.listen()\ntime.sleep(30)"
        let sup = DaemonSupervisor(python: URL(fileURLWithPath: "/usr/bin/python3"), daemonDir: URL(fileURLWithPath: "/tmp"), socketPath: socketPath,
                                   arguments: ["-c", script, socketPath], logURL: logURL) { state in
            if case .listening = state { listening.withLock { $0.append(SocketProbe.isLive(path: socketPath)) } }
            box.append(state)
        }
        defer { try? FileManager.default.removeItem(atPath: socketPath) }
        sup.start()
        await eventually { !listening.withLock { $0.isEmpty } }
        sup.stop()

        #expect(listening.withLock { $0 } == [true], "the app must be told to connect only to a socket that accepts, got \(box.states)")
        let order = box.states.compactMap { state -> String? in
            switch state { case .running: "running"; case .listening: "listening"; default: nil }
        }
        #expect(order == ["running", "listening"])
    }

    // A child that never opens its socket — stuck in an import — is a failed launch, not one that
    // is still starting: it is ended and restarted through the same backoff as one that exits, so
    // the banner says what it says for a helper that keeps stopping rather than "Starting…" forever.
    @Test func testADaemonThatNeverListensIsAFailedLaunchAndIsRestarted() async {
        let box = StateBox()
        let sup = DaemonSupervisor(python: URL(fileURLWithPath: "/bin/sh"), daemonDir: URL(fileURLWithPath: "/tmp"), socketPath: "/tmp/mute-\(UUID().uuidString.prefix(8)).sock",
                                   arguments: ["-c", "sleep 30"], logURL: logURL, bindDeadline: 0.2, backoff: { _ in 0.01 }) { state in
            box.append(state)
        }
        sup.start()
        func firstPid() -> Int32? { box.states.lazy.compactMap { if case .running(let pid) = $0 { pid } else { nil } }.first }
        await eventually { box.runningCount >= 2 }
        sup.stop()

        #expect(box.states.contains { if case .failed(1, let message) = $0 { message.contains("socket") } else { false } },
                "a child that never listens must be a failed launch, got \(box.states)")
        #expect(!box.states.contains { if case .listening = $0 { true } else { false } })
        // Ended, then reaped by `Process` a moment later: until then `kill` still finds its zombie.
        if let pid = firstPid() { await eventually(describing: "the child that never listened to be ended") { kill(pid, 0) != 0 } }
    }

    // So it does for a child given up on: `stop()` returns only once it is gone, though it
    // is no longer the supervised process and is waiting out its own grace before SIGKILL.
    @Test func testStopEndsAChildGivenUpOnThatIgnoresSIGTERM() async {
        let box = StateBox()
        let sup = DaemonSupervisor(python: URL(fileURLWithPath: "/bin/sh"), daemonDir: URL(fileURLWithPath: "/tmp"), socketPath: "/tmp/deaf-\(UUID().uuidString.prefix(8)).sock",
                                   arguments: ["-c", "trap '' TERM; while :; do sleep 0.05; done"], logURL: logURL, bindDeadline: 0.1, backoff: { _ in 30 }) { state in
            box.append(state)
        }
        sup.start()
        await eventually { box.states.contains { if case .failed = $0 { true } else { false } } }
        let pid = box.states.lazy.compactMap { if case .running(let pid) = $0 { pid } else { nil } }.first
        sup.stop()

        guard let pid else { Issue.record("supervisor never reported .running"); return }
        #expect(kill(pid, 0) != 0, "stop() returned while the child it gave up on was still alive")
    }

    // Final review item A: a daemon that keeps exiting is only diagnosable if its stdout and stderr
    // land somewhere the banner can point at, so the child's output must reach the log file.
    @Test func testDaemonOutputIsWrittenToTheLogFile() async {
        let box = StateBox()
        let sup = DaemonSupervisor(python: URL(fileURLWithPath: "/bin/sh"), daemonDir: URL(fileURLWithPath: "/tmp"), socketPath: "/tmp/log.sock",
                                   arguments: ["-c", "echo hello-from-daemon"], logURL: logURL) { state in
            box.append(state)
        }
        sup.start()

        func logText() -> String { (try? String(contentsOf: logURL, encoding: .utf8)) ?? "" }
        await eventually { logText().contains("hello-from-daemon") }
        sup.stop()

        #expect(logText().contains("hello-from-daemon"), "the daemon's output must reach \(logURL.path), got “\(logText())”")
    }

    // A daemon that still has the old file open (an orphan about to be adopted, or one
    // still exiting) must keep writing into the file the banner points at, so the log is emptied
    // in place rather than replaced.
    //
    // An orphan that opened the file for append (as `openLog` does) lands its lines right after the
    // child's. One built before that did not, and writes at the offset it had: the emptied file
    // grows a gap of NULs before its line, which a reader of the log sees as junk but which does
    // not hide it, so only a writer that appends is held to a clean file.
    @Test(arguments: [true, false])
    func testRestartEmptiesTheLogInPlaceSoAnOpenWriterStillReachesIt(orphanAppends: Bool) async throws {
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        try Data("stale-line-from-the-run-before\n".utf8).write(to: logURL)
        let before = try FileManager.default.attributesOfItem(atPath: logURL.path)[.systemFileNumber] as? Int
        let orphan: FileHandle
        if orphanAppends {
            let fd = open(logURL.path, O_WRONLY | O_APPEND)
            try #require(fd >= 0)
            orphan = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        } else {
            orphan = try FileHandle(forWritingTo: logURL)
            _ = try orphan.seekToEnd()
        }
        defer { try? orphan.close() }

        let box = StateBox()
        // `exec`, so no shell is left waiting on the sleep: `stop()`'s SIGTERM reaches the whole
        // process group, and a shell that outlived its sleep wrote "Terminated" into the log.
        let sup = DaemonSupervisor(python: URL(fileURLWithPath: "/bin/sh"), daemonDir: URL(fileURLWithPath: "/tmp"), socketPath: "/tmp/inode.sock",
                                   arguments: ["-c", "echo new-daemon; exec sleep 30"], logURL: logURL, bindDeadline: neverAbandoned) { state in
            box.append(state)
        }
        sup.start()
        func logText() -> String { (try? String(contentsOf: logURL, encoding: .utf8)) ?? "" }
        await eventually { logText().contains("new-daemon") }
        try orphan.write(contentsOf: Data("orphan-line\n".utf8))
        await eventually { logText().contains("orphan-line") }
        sup.stop()

        let after = try FileManager.default.attributesOfItem(atPath: logURL.path)[.systemFileNumber] as? Int
        #expect(after == before, "truncating must not swap the file under a running writer")
        #expect(!logText().contains("stale-line"))
        if orphanAppends {
            #expect(logText() == "new-daemon\norphan-line\n", "got “\(logText())”")
        } else {
            #expect(logText().replacing("\0", with: "") == "new-daemon\norphan-line\n", "got “\(logText())”")
        }
    }
}
