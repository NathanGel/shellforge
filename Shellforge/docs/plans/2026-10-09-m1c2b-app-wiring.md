# M1c-2b App Wiring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Shellforge.app ships `shellforged`, starts it at launch and stops it at quit, sends it every tab, and shows each task's and tab's agent status in the sidebar — a dot that turns working, needs-input or done as the agent's hooks report, and clears when the user opens the task.

**Architecture:** One app-wide `DaemonLink` (ShellforgeUI, `ObservableObject`) owns the supervisor from M1c-2a, one `DaemonConnection` (a port of AiTerm's retry loop), the folded `SessionStore`, and the list of tabs last sent. iTerm2's side is thin: it bundles the daemon's package as a folder reference, starts and stops the link from the app delegate, and gives the link a closure that reads every session's variables. Every `SidebarModel` observes the link for its dots and tells it when a task is seen.

**Tech Stack:** Swift 6 language mode, macOS 13 (Combine `ObservableObject`, no `@Observable`), Swift Testing via `Shellforge/scripts/swift.sh`; iTerm2's Xcode project for the app side (ModernTests via `xcodebuild`).

**Spec:** Shellforge PRD (Claude Doc 89fd80a8-5fcf-4423-a8d6-c62f8512a481): W6 (status from the hook receiver), E1/E3 (login environment; one runner starts every child), "Architecture" (keep the daemon). `Shellforge/daemon/README.md` is the daemon's contract. M1c-2a's plan (`2026-10-09-m1c2a-daemon-client.md`) produced everything this one consumes.

## Global Constraints

- Source: AiTerm (`~/aiterm`, GPLv3, Laurens D'Hondt). Ported files start with a comment naming the AiTerm file they came from. Nothing in `~/aiterm` changes.
- macOS 13 and Swift 6: no `Mutex`, no `@Observable`, no macOS 14+ API. Package code builds and tests only with `Shellforge/scripts/swift.sh`; the app builds with `xcodebuild` on the `iTerm2` scheme, Development configuration, as M0/M1a did.
- Only `ChildProcess.swift` creates a `Process` (`SourceRulesTests`).
- Task and project ids go to the daemon only through `SessionReport(task:project:)` and `DaemonClient.markSeen(task:)`, which lowercase them; never build those strings by hand.
- AiTerm's daemon (`aitermd.sock`, port 47821) may run at the same time; nothing here touches it.
- Every iTerm2 file changed is listed in `Shellforge/docs/upstream-hook-points.md`.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Nothing is pushed without asking.

## Review Focus

1. **No Python 3.11+ on the login PATH** (a fresh Mac): the sidebar says so in words the user can act on, and the app otherwise works — no crash, no retry loop. (Task 2 test: `noPythonIsSaidOnceAndNothingStarts`.)
2. **The daemon restarting under a running app** (crash, or killed): the dots clear rather than lie while it is gone, the connection comes back, and the full tab list is sent again so the new daemon knows every tab. (Task 2 test: `aNewConnectionIsSentTheWholeListAgain`.)
3. **A daemon from another build on the socket** (an old one adopted inside its 60 s idle window): shown as a mismatch, its snapshot never fills the dots. (Task 1 test, ported: `aSnapshotDecodingFailureIsAMismatch`; Task 2 test: `aMismatchedHelperFillsNoDots`.)
4. **Split panes and tabs without a task**: every session is reported, the selected session of the selected tab is `active`, and untagged ones carry null ids — the daemon must not tag them. (Task 4 test: `reportsCoverEverySessionWithItsPlacement`.)
5. **Quitting while the daemon is still starting or Python is still being looked for**: no daemon is left behind, and a lookup that finishes after quit starts nothing. (Task 2 test: `shutdownBeforePythonIsFoundStartsNothing`.)

---

### Task 1: Helper status and the connection loop

**Files:**
- Create: `Shellforge/Sources/ShellforgeCore/Daemon/HelperStatus.swift`, `Shellforge/Sources/ShellforgeCore/BackgroundWork.swift` (ported from `~/aiterm/app/Sources/AiTermCore/BackgroundWork.swift`, unchanged but the origin comment)
- Create: `Shellforge/Sources/ShellforgeUI/DaemonConnection.swift` (ported from `~/aiterm/app/Sources/AiTerm/DaemonConnection.swift`)
- Test: `Shellforge/Tests/ShellforgeCoreTests/Daemon/HelperStatusTests.swift`, `Shellforge/Tests/ShellforgeUITests/DaemonConnectionTests.swift` (ported subset of `~/aiterm/app/Tests/AiTermTests/DaemonConnectionTests.swift`)

**Interfaces:**
- Consumes: `DaemonClient(socketPath:)`, `connect()`, `snapshot()`, `events`, `ending`, `disconnect()`; `DaemonError.isMismatch`; `Backoff.delay(attempt:)` (M1c-2a).
- Produces:
  - `public enum HelperStatus: Equatable, Sendable { case starting, helperMissing, pythonMissing, helperFailing(String), helperMismatch, helperUnreachable, connected }` with `public var text: String` and `public var isProblem: Bool`.
  - `public enum BackgroundWork { public static func run<Value: Sendable, Failure: Error>(on: DispatchQueue = .global(qos: .userInitiated), _ work: @escaping @Sendable () throws(Failure) -> Value) async throws(Failure) -> Value }`.
  - `@MainActor final class DaemonConnection { init(socketPath: String, onClient: @escaping @MainActor (DaemonClient?) -> Void, onStatus: @escaping @MainActor (HelperStatus) -> Void, onEvent: @escaping @MainActor (DaemonEvent) -> Void, backoff: @escaping @Sendable (Int) -> TimeInterval = { Backoff.delay(attempt: $0) }, steadyAfter: Duration = .seconds(5)); func start(); func stop() }` (internal; tests use `@testable import ShellforgeUI`).

- [ ] **Step 1: Write the status test.**

```swift
import Testing
@testable import ShellforgeCore

@Suite struct HelperStatusTests {
    @Test func everyProblemSaysWhatToDo() {
        #expect(HelperStatus.pythonMissing.text == "Shellforge needs Python 3.11 or newer on your login shell’s PATH.")
        #expect(HelperStatus.helperMissing.text == "Shellforge’s helper is missing from the app; reinstall Shellforge.")
        #expect(HelperStatus.helperFailing("exited with status 1").text == "Shellforge’s helper keeps stopping (exited with status 1). Its log is in ~/Library/Application Support/Shellforge/shellforged.log.")
        #expect(HelperStatus.helperMismatch.text == "Shellforge’s helper is from another version; quit Shellforge and open it again.")
        #expect(HelperStatus.helperUnreachable.text == "Reconnecting to Shellforge’s helper…")
    }

    @Test func onlyStartingAndConnectedAreNotProblems() {
        let all: [HelperStatus] = [.starting, .helperMissing, .pythonMissing, .helperFailing("x"), .helperMismatch, .helperUnreachable, .connected]
        #expect(all.filter { !$0.isProblem } == [.starting, .connected])
    }
}
```

- [ ] **Step 2:** Run `cd Shellforge && scripts/swift.sh test --filter HelperStatusTests`. Expected: build fails, `HelperStatus` does not exist.
- [ ] **Step 3: Write `HelperStatus.swift`.**

```swift
import Foundation

/// How far the chain to the helper reaches: the sidebar shows `text` while `isProblem`. A running
/// helper is not a connected one, so process, socket and version are told apart.
public enum HelperStatus: Equatable, Sendable {
    case starting
    /// The app was built without the daemon's package.
    case helperMissing
    case pythonMissing
    /// The helper has exited more than once; the message is its last exit.
    case helperFailing(String)
    /// The helper answers in a protocol this app cannot read.
    case helperMismatch
    /// The helper process is up but its socket is not answering.
    case helperUnreachable
    case connected

    public var text: String {
        switch self {
        case .starting: "Starting Shellforge’s helper…"
        case .helperMissing: "Shellforge’s helper is missing from the app; reinstall Shellforge."
        case .pythonMissing: "Shellforge needs Python 3.11 or newer on your login shell’s PATH."
        case .helperFailing(let message): "Shellforge’s helper keeps stopping (\(message)). Its log is in ~/Library/Application Support/Shellforge/shellforged.log."
        case .helperMismatch: "Shellforge’s helper is from another version; quit Shellforge and open it again."
        case .helperUnreachable: "Reconnecting to Shellforge’s helper…"
        case .connected: "Connected"
        }
    }

    public var isProblem: Bool { self != .starting && self != .connected }
}
```

- [ ] **Step 4:** Run the same filter. Expected: 2 tests pass.
- [ ] **Step 5: Port the connection tests first.** Copy AiTerm's `DaemonConnectionTests.swift` into `Tests/ShellforgeUITests/` as `@MainActor @Suite struct DaemonConnectionTests` (not an extension of `AppControllerTests`). Keep only these, with `ItermConnection` → `HelperStatus` and `.connected(version:)`/`.waitingForIterm` → `.connected`:
  - `socketLossReconnectsWhileServerStaysAliveAndStopEndsRetries`
  - `aSnapshotDecodingFailureIsAHelperMismatchNotAnUnreachableHelper` (rename `aSnapshotDecodingFailureIsAMismatch`)
  - `aHelperWhoseEventsCannotBeReadIsAMismatchAndItsRetriesBackOff`
  - `aConnectionThatHeldStartsTheBackoffOver`
  - `aMismatchedHelperIsNotShownConnectedAgainUntilAConnectionHolds`
  - `aConnectionThatHoldsAfterAMismatchIsShownOnceItHas`

  Drop the background-preference, iTerm2-reconnect, auth and cookie tests (no such events in app mode). Replace `import Synchronization`/`Mutex` with `Locked`; `AiTerm*` imports with `ShellforgeCore`, `ShellforgeUI`, `ShellforgeTestSupport`. Python fake servers' snapshots keep `'connected': True`.
  Add one new test:

```swift
    /// The loop delivers nothing that came before its own snapshot: a daemon may broadcast between
    /// accepting the socket and answering, and those events are older than the snapshot.
    @Test func eventsBeforeTheSnapshotAreNotDelivered() async throws {
        let path = "/tmp/sf-conn-\(UUID().uuidString.prefix(8)).sock"
        let server = FakeSocketServer(path: path)
        server.handler = { req in
            ["id": req["id"]!, "result": ["protocolVersion": 1, "connected": true, "sessions": [], "usage": ["claude": NSNull(), "codex": NSNull()]]]
        }
        server.start()
        var events: [DaemonEvent] = []
        let connection = DaemonConnection(socketPath: path, onClient: { _ in }, onStatus: { _ in }, onEvent: { events.append($0) })
        defer { connection.stop(); server.stop() }
        connection.start()
        #expect(server.waitForClient(timeout: 5))
        server.push(event: "session.closed", payload: ["sessionId": "early"])
        #expect(await eventually { events.contains { if case .snapshot = $0 { true } else { false } } })
        server.push(event: "session.closed", payload: ["sessionId": "late"])
        #expect(await eventually { events.count == 2 })
        guard case .snapshot = events[0], case .sessionClosed("late") = events[1] else { Issue.record("got \(events)"); return }
    }
```

  (If the fake answers the snapshot before the early push reaches the client, the early event arrives after the barrier and the test sees three events: run it 5 times; if it is flaky, push the early event from inside `handler` before returning the reply, and ledger the change.)
- [ ] **Step 6:** Run `scripts/swift.sh test --filter DaemonConnectionTests`. Expected: build fails, `DaemonConnection` does not exist.
- [ ] **Step 7: Port `DaemonConnection.swift` and `BackgroundWork.swift`.** In the connection: `ItermConnection` → `HelperStatus`; `ItermConnection.forSnapshot(_)` → `.connected`; delete `requestCookie`, the `answered`/`answer` cookie code, and the `.itermCookieRequested`, `.itermDisconnected`, `.itermAuthFailed`, `.itermConnected` branches; keep the bootstrap barrier, the `HeldStatus` hold-after-mismatch, `steadyAfter` and the backoff reset unchanged.
- [ ] **Step 8:** Run `scripts/swift.sh test --filter "DaemonConnectionTests|HelperStatusTests"`, then the full `scripts/swift.sh test`. Expected: all pass (record the counts).
- [ ] **Step 9:** Commit: `feat(ui): the connection loop to shellforged, from AiTerm, and the helper's status in words`.

### Task 2: DaemonLink — one helper for the whole app

**Files:**
- Create: `Shellforge/Sources/ShellforgeUI/DaemonLink.swift`
- Test: `Shellforge/Tests/ShellforgeUITests/DaemonLinkTests.swift`

**Interfaces:**
- Consumes: Task 1's `HelperStatus`, `BackgroundWork`, `DaemonConnection`; M1c-2a's `DaemonSupervisor(python:daemonDir:socketPath:hookPort:onStateChange:)`, `DaemonSupervisor.State`, `SessionStore.apply(_:)`, `SessionReport`, `DaemonClient.updateSessions(_:)`, `markSeen(task:)`.
- Produces:

```swift
@MainActor public final class DaemonLink: ObservableObject {
    @Published public private(set) var status: HelperStatus
    @Published public private(set) var store: SessionStore
    public init(socketPath: String = ShellforgePaths.socketPath, daemonDir: URL?,
                findPython: @escaping @Sendable () -> URL?, reports: @escaping @MainActor () -> [SessionReport])
    public func start()
    public func shutdown()
    /// Reads `reports()` and sends it when it differs from the last list the daemon took.
    public func reportsMayHaveChanged()
    public func markSeen(task: UUID)
    // internal, for tests and the supervisor callback:
    func supervisorChanged(_ state: DaemonSupervisor.State)
}
```

Behaviour, each pinned by a test below:
- `start()`: `daemonDir` nil, or without `shellforged/__main__.py` → `.helperMissing`, Python never looked for. Otherwise `findPython` runs through `BackgroundWork`; nil → `.pythonMissing`; else a `DaemonSupervisor` starts with that Python, and its states arrive on the main actor through `supervisorChanged`. A lookup that returns after `shutdown()` starts nothing.
- `supervisorChanged`: `.listening`/`.adopted` → make (once) and `start()` a `DaemonConnection`; `.failed(attempt, msg)` with `attempt >= 2` → `.helperFailing(msg)`; others leave `status` alone.
- Attach (`onClient` non-nil): forget the last list sent and send the current one. Detach (`onClient(nil)`): `store = SessionStore()` — dots clear rather than lie.
- Events go to `store.apply`. The connection delivers nothing before its own accepted snapshot, so a mismatched daemon's snapshot never reaches the store.
- Sending: one `updateSessions` in flight at a time; a change while one is in flight is sent when it returns; a failed send forgets the last list so the next change or attach resends.
- `markSeen(task:)` sends `markSeen(task:)` when attached, otherwise nothing.
- `shutdown()`: connection first, then supervisor (as AiTerm's `HelperLink.shutdown`).

- [ ] **Step 1: Write the tests.**

```swift
import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

@MainActor @Suite struct DaemonLinkTests {
    private static let task = UUID(uuidString: "6F0E2C1A-9B3D-4E5F-8A7B-0C1D2E3F4A5B")!

    /// A folder that looks like the bundled daemon's: `shellforged/__main__.py`.
    private func daemonDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sf-daemon-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("shellforged"), withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("shellforged/__main__.py"))
        return dir
    }

    private func snapshotReply(_ req: [String: Any], sessions: [[String: Any]] = []) -> [String: Any] {
        ["id": req["id"]!, "result": ["protocolVersion": 1, "connected": true, "sessions": sessions, "usage": ["claude": NSNull(), "codex": NSNull()]]]
    }

    private func report(_ id: String) -> SessionReport {
        SessionReport(sessionId: id, windowId: "w", tabIndex: 0, commandLine: nil, jobPid: nil, title: id, cwd: "/", active: true, task: Self.task, project: nil)
    }

    /// A fake daemon answering the snapshot, `sessions.update` and `sessions.markSeen`.
    private func server(sessions: [[String: Any]] = []) -> FakeSocketServer {
        let server = FakeSocketServer(path: "/tmp/sf-link-\(UUID().uuidString.prefix(8)).sock")
        server.handler = { [self] req in
            switch req["method"] as? String {
            case "workspace.snapshot": snapshotReply(req, sessions: sessions)
            case "sessions.markSeen": ["id": req["id"]!, "result": ["changed": 1]]
            default: ["id": req["id"]!, "result": ["ok": true]]
            }
        }
        server.start()
        return server
    }

    private func updates(_ server: FakeSocketServer) -> [[String]] {
        server.received.filter { $0["method"] as? String == "sessions.update" }.map {
            (($0["params"] as? [String: Any])?["sessions"] as? [[String: Any]] ?? []).compactMap { $0["sessionId"] as? String }
        }
    }

    @Test func aMissingHelperIsSaidWithoutLookingForPython() {
        let looked = Locked(false)
        let link = DaemonLink(daemonDir: nil, findPython: { looked.withLock { $0 = true }; return nil }, reports: { [] })
        link.start()
        #expect(link.status == .helperMissing)
        #expect(!looked.withLock { $0 })
    }

    @Test func noPythonIsSaidOnceAndNothingStarts() async throws {
        let link = DaemonLink(daemonDir: try daemonDir(), findPython: { nil }, reports: { [] })
        link.start()
        #expect(await eventually { link.status == .pythonMissing })
    }

    @Test func shutdownBeforePythonIsFoundStartsNothing() async throws {
        let gate = DispatchSemaphore(value: 0), asked = Locked(false)
        let link = DaemonLink(daemonDir: try daemonDir(), findPython: {
            asked.withLock { $0 = true }; gate.wait(); return URL(fileURLWithPath: "/usr/bin/false")
        }, reports: { [] })
        link.start()
        #expect(await eventually { asked.withLock { $0 } })
        link.shutdown()
        gate.signal()
        try await Task.sleep(for: .milliseconds(200))
        #expect(link.status == .starting)
    }

    @Test func aSecondFailureSaysTheHelperKeepsStopping() {
        let link = DaemonLink(daemonDir: nil, findPython: { nil }, reports: { [] })
        link.supervisorChanged(.failed(attempt: 1, message: "exited with status 1"))
        #expect(link.status == .starting)
        link.supervisorChanged(.failed(attempt: 2, message: "exited with status 1"))
        #expect(link.status == .helperFailing("exited with status 1"))
    }

    @Test func aListeningDaemonIsConnectedAndItsSnapshotFillsTheStore() async throws {
        let server = server(sessions: [["sessionId": "G", "windowId": "w", "tabIndex": 0, "taskId": "6f0e2c1a-9b3d-4e5f-8a7b-0c1d2e3f4a5b",
                                        "projectId": NSNull(), "agent": "claude", "state": "working", "title": "claude", "cwd": "/wt"]])
        let link = DaemonLink(socketPath: server.path, daemonDir: nil, findPython: { nil }, reports: { [] })
        defer { link.shutdown(); server.stop() }
        link.supervisorChanged(.listening(pid: 1))
        #expect(await eventually { link.status == .connected && link.store.status(ofTask: Self.task) == .working })
    }

    @Test func reportsAreSentOnAttachAndThenOnlyWhenTheyChange() async throws {
        let server = server()
        var tabs = ["A"]
        let link = DaemonLink(socketPath: server.path, daemonDir: nil, findPython: { nil }, reports: { tabs.map(report) })
        defer { link.shutdown(); server.stop() }
        link.supervisorChanged(.listening(pid: 1))
        #expect(await eventually { updates(server) == [["A"]] })
        link.reportsMayHaveChanged()
        try await Task.sleep(for: .milliseconds(200))
        #expect(updates(server) == [["A"]])
        tabs = ["A", "B"]
        link.reportsMayHaveChanged()
        #expect(await eventually { updates(server) == [["A"], ["A", "B"]] })
    }

    @Test func aNewConnectionIsSentTheWholeListAgain() async throws {
        let first = server()
        let link = DaemonLink(socketPath: first.path, daemonDir: nil, findPython: { nil }, reports: { [report("A")] })
        defer { link.shutdown() }
        link.supervisorChanged(.listening(pid: 1))
        #expect(await eventually { updates(first) == [["A"]] })
        first.stop()
        #expect(await eventually { link.store == SessionStore() && link.status == .helperUnreachable })
        let second = FakeSocketServer(path: first.path)
        second.handler = { [self] req in req["method"] as? String == "workspace.snapshot" ? snapshotReply(req) : ["id": req["id"]!, "result": ["ok": true]] }
        second.start()
        defer { second.stop() }
        #expect(await eventually(timeout: 30) { updates(second) == [["A"]] })
    }

    @Test func aMismatchedHelperFillsNoDots() async throws {
        let server = FakeSocketServer(path: "/tmp/sf-link-\(UUID().uuidString.prefix(8)).sock")
        server.handler = { req in
            ["id": req["id"]!, "result": ["protocolVersion": 2, "connected": true, "usage": ["claude": NSNull(), "codex": NSNull()],
                                          "sessions": [["sessionId": "G", "windowId": "w", "tabIndex": 0, "taskId": "6f0e2c1a-9b3d-4e5f-8a7b-0c1d2e3f4a5b",
                                                        "projectId": NSNull(), "agent": "claude", "state": "working", "title": "claude", "cwd": "/wt"]]]]
        }
        server.start()
        let link = DaemonLink(socketPath: server.path, daemonDir: nil, findPython: { nil }, reports: { [] })
        defer { link.shutdown(); server.stop() }
        link.supervisorChanged(.listening(pid: 1))
        #expect(await eventually { link.status == .helperMismatch })
        #expect(!link.store.bootstrapped)
    }

    @Test func markSeenGoesToTheAttachedDaemon() async throws {
        let server = server()
        let link = DaemonLink(socketPath: server.path, daemonDir: nil, findPython: { nil }, reports: { [] })
        defer { link.shutdown(); server.stop() }
        link.supervisorChanged(.listening(pid: 1))
        #expect(await eventually { link.status == .connected })
        link.markSeen(task: Self.task)
        #expect(await eventually {
            server.received.contains { ($0["params"] as? [String: Any])?["taskId"] as? String == "6f0e2c1a-9b3d-4e5f-8a7b-0c1d2e3f4a5b" }
        })
    }
}
```

  The fake sessions carry every key `SessionInfo` requires (`sessionId`, `windowId`, `tabIndex`, `agent`, `state`, `title`, `cwd`). `FakeSocketServer.path` is internal (`let path`), reachable through `@testable import ShellforgeTestSupport`. A second server on the same path must remove a leftover socket file before binding: check the fake's `start()`, and if it does not unlink, add `unlink(path)` there and ledger it.
- [ ] **Step 2:** Run `scripts/swift.sh test --filter DaemonLinkTests`. Expected: build fails, `DaemonLink` does not exist.
- [ ] **Step 3: Write `DaemonLink.swift`.**

```swift
import Combine
import Foundation
import ShellforgeCore

/// The app's one link to its helper: the daemon process, the socket to it, what it has said about
/// the sessions, and the tabs last sent to it. Every window's sidebar observes it.
@MainActor
public final class DaemonLink: ObservableObject {
    @Published public private(set) var status: HelperStatus = .starting
    @Published public private(set) var store = SessionStore()

    private let socketPath: String
    private let daemonDir: URL?
    private let findPython: @Sendable () -> URL?
    private let reports: @MainActor () -> [SessionReport]
    private var supervisor: DaemonSupervisor?
    private var connection: DaemonConnection?
    private var client: DaemonClient?
    private var startup: Task<Void, Never>?
    private var running = false
    /// The list the attached daemon last took; nil when it must be sent whatever it holds.
    private var lastSent: [SessionReport]?
    private var sending = false

    public init(socketPath: String = ShellforgePaths.socketPath, daemonDir: URL?,
                findPython: @escaping @Sendable () -> URL?, reports: @escaping @MainActor () -> [SessionReport]) {
        self.socketPath = socketPath
        self.daemonDir = daemonDir
        self.findPython = findPython
        self.reports = reports
    }

    /// Looks for Python off the main thread — a login shell and a check per candidate — then starts
    /// the helper with it; the connection follows once the helper listens.
    public func start() {
        guard !running else { return }
        running = true
        guard let daemonDir, FileManager.default.fileExists(atPath: daemonDir.appendingPathComponent("shellforged/__main__.py").path) else {
            status = .helperMissing
            return
        }
        let findPython = self.findPython
        startup = Task {
            let found = await BackgroundWork.run { findPython() }
            guard !Task.isCancelled, running else { return }
            guard let python = found else { status = .pythonMissing; return }
            supervisor = DaemonSupervisor(python: python, daemonDir: daemonDir, socketPath: socketPath) { [weak self] state in
                Task { @MainActor in self?.supervisorChanged(state) }
            }
            supervisor?.start()
        }
    }

    /// Closes the socket, then stops the helper this app started: an orphan holding the socket
    /// would be adopted by the next launch whatever version it is.
    public func shutdown() {
        running = false
        startup?.cancel()
        connection?.stop()
        connection = nil
        supervisor?.stop()
        supervisor = nil
    }

    public func reportsMayHaveChanged() {
        guard let client, !sending else { return }
        let current = reports()
        guard current != lastSent else { return }
        sending = true
        Task {
            do {
                try await client.updateSessions(current)
                if self.client === client { lastSent = current }
            } catch {
                lastSent = nil
            }
            sending = false
            // A change made while this one was in flight.
            reportsMayHaveChanged()
        }
    }

    public func markSeen(task: UUID) {
        guard let client else { return }
        Task { _ = try? await client.markSeen(task: task) }
    }

    func supervisorChanged(_ state: DaemonSupervisor.State) {
        switch state {
        case .listening, .adopted:
            if connection == nil {
                connection = DaemonConnection(socketPath: socketPath,
                    onClient: { [weak self] in self?.attached($0) },
                    onStatus: { [weak self] in self?.status = $0 },
                    onEvent: { [weak self] in self?.store.apply($0) })
            }
            connection?.start()
        // One failure is a restart in progress; from the second on the helper is stuck.
        case .failed(let attempt, let message): if attempt >= 2 { status = .helperFailing(message) }
        case .starting, .running, .stopped: break
        }
    }

    private func attached(_ client: DaemonClient?) {
        self.client = client
        lastSent = nil
        if client == nil { store = SessionStore() } else { reportsMayHaveChanged() }
    }
}
```

  Note: `supervisorChanged` is also driven directly by tests without `start()`, so it does not check `running`; `shutdown()` clears `supervisor` and the supervisor's own `stop()` ends its callbacks.
- [ ] **Step 4:** Run the filter 3 times. Expected: 9 tests pass each run. Then the full suite. Expected: all pass.
- [ ] **Step 5:** Commit: `feat(ui): one link to shellforged for the whole app — start, connect, send the tabs, fold the events`.

### Task 3: Status dots in the sidebar

**Files:**
- Modify: `Shellforge/Sources/ShellforgeUI/SidebarModel.swift`, `Shellforge/Sources/ShellforgeUI/ShellforgeSidebar.swift`
- Test: `Shellforge/Tests/ShellforgeUITests/SidebarModelTests.swift`

**Interfaces:**
- Consumes: Task 2's `DaemonLink` (`status`, `store`, `markSeen(task:)`) through a protocol so tests use a fake.
- Produces:

```swift
/// What the sidebar needs from the helper; `DaemonLink` is the app's.
@MainActor public protocol SessionFeed: AnyObject {
    var statusPublisher: AnyPublisher<HelperStatus, Never> { get }
    var storePublisher: AnyPublisher<SessionStore, Never> { get }
    func markSeen(task: UUID)
}
extension DaemonLink: SessionFeed  // $status.eraseToAnyPublisher(), $store.eraseToAnyPublisher()

// SidebarModel gains:
public init(host: TerminalHost, document: WorkspaceDocument, launcher: CommandLauncher, feed: SessionFeed? = nil)
@Published public private(set) var sessions: SessionStore
@Published public private(set) var helper: HelperStatus
public func status(ofTask id: UUID) -> SessionState
public func status(ofTab id: String) -> SessionState
```

Marking seen: when a task becomes the selected one — by `select(task:)` or by following iTerm2's selection in `refresh` — and its status is `.done`, call `feed.markSeen(task:)`. A done arriving for the task already selected is not marked seen: the window may not be in front (ruling candidate; AiTerm marks on selection only).

- [ ] **Step 1: Write the tests** (append to `SidebarModelTests.swift`).

```swift
@MainActor final class FakeFeed: SessionFeed {
    @Published var status: HelperStatus = .connected
    @Published var store = SessionStore()
    var seen: [UUID] = []
    var statusPublisher: AnyPublisher<HelperStatus, Never> { $status.eraseToAnyPublisher() }
    var storePublisher: AnyPublisher<SessionStore, Never> { $store.eraseToAnyPublisher() }
    func markSeen(task: UUID) { seen.append(task) }

    /// The daemon saying `state` for one session of `task`.
    func say(_ state: SessionState, session: String, task: UUID) {
        var next = SessionStore()
        next.apply(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true, sessions: [
            SessionInfo(sessionId: session, windowId: "w", tabIndex: 0, taskId: task.uuidString.lowercased(), projectId: nil,
                        agent: .claude, model: nil, state: state, title: "claude", cwd: "/wt")
        ], usage: .empty)))
        store = next
    }
}
```


```swift
    @Test func aTaskShowsItsMostUrgentTabAndATabItsOwn() async throws {
        let repo = try GitRepoForUI()
        let host = FakeTerminalHost(), feed = FakeFeed()
        let sidebar = SidebarModel(host: host, document: WorkspaceDocument(store: WorkspaceStore(folder: folder)), launcher: repo.launcher, feed: feed)
        await sidebar.addProject(folder: repo.path)
        await sidebar.newTask(title: "Fix login", in: try #require(sidebar.tree.projects.first).id)
        let task = try #require(sidebar.selectedTaskId), tab = try #require(host.tabs.first).id
        feed.say(.needsInput, session: tab, task: task)
        #expect(sidebar.status(ofTask: task) == .needsInput)
        #expect(sidebar.status(ofTab: tab) == .needsInput)
    }

    @Test func openingADoneTaskMarksItSeenAndOpeningAnotherDoesNot() async throws {
        let repo = try GitRepoForUI()
        let host = FakeTerminalHost(), feed = FakeFeed()
        let sidebar = SidebarModel(host: host, document: WorkspaceDocument(store: WorkspaceStore(folder: folder)), launcher: repo.launcher, feed: feed)
        await sidebar.addProject(folder: repo.path)
        let project = try #require(sidebar.tree.projects.first).id
        await sidebar.newTask(title: "One", in: project)
        let one = try #require(sidebar.selectedTaskId), oneTab = try #require(host.tabs.last).id
        await sidebar.newTask(title: "Two", in: project)
        let two = try #require(sidebar.selectedTaskId)
        feed.say(.done, session: oneTab, task: one)
        #expect(feed.seen.isEmpty)            // done while Two is shown: not seen yet
        sidebar.select(task: two)
        #expect(feed.seen.isEmpty)            // Two is not done
        sidebar.select(task: one)
        #expect(feed.seen == [one])
    }

    @Test func switchingToADoneTasksTabInITerm2MarksItSeen() async throws {
        let repo = try GitRepoForUI()
        let host = FakeTerminalHost(), feed = FakeFeed()
        let sidebar = SidebarModel(host: host, document: WorkspaceDocument(store: WorkspaceStore(folder: folder)), launcher: repo.launcher, feed: feed)
        await sidebar.addProject(folder: repo.path)
        let project = try #require(sidebar.tree.projects.first).id
        await sidebar.newTask(title: "One", in: project)
        let one = try #require(sidebar.selectedTaskId), oneTab = try #require(host.tabs.last).id
        await sidebar.newTask(title: "Two", in: project)
        feed.say(.done, session: oneTab, task: one)
        host.userSwitched(to: oneTab)
        #expect(feed.seen == [one])
    }

    @Test func theHelpersProblemIsShownAndClearedWhenItConnects() async throws {
        let repo = try GitRepoForUI()
        let feed = FakeFeed()
        let sidebar = SidebarModel(host: FakeTerminalHost(), document: WorkspaceDocument(store: WorkspaceStore(folder: folder)), launcher: repo.launcher, feed: feed)
        feed.status = .pythonMissing
        #expect(sidebar.helper == .pythonMissing)
        feed.status = .connected
        #expect(sidebar.helper == .connected)
    }
```

- [ ] **Step 2:** Run `scripts/swift.sh test --filter SidebarModelTests`. Expected: build fails (`SessionFeed`, `feed:` do not exist).
- [ ] **Step 3: Implement in `SidebarModel`.** Add `SessionFeed` and the `DaemonLink` conformance (in `DaemonLink.swift`). In `init`, when `feed` is given, subscribe both publishers with `.sink { value in MainActor.assumeIsolated { self?.sessions = value } }` (and `helper`), as the document subscription does. Add:

```swift
    public func status(ofTask id: UUID) -> SessionState { sessions.status(ofTask: id) }
    public func status(ofTab id: String) -> SessionState { sessions.status(ofTab: id) }

    /// The task the user is now looking at. A done one has been seen — when the user picked it
    /// (`explicit`) or the selection moved to it, not on every refresh while it stays selected.
    private func shown(_ id: UUID, explicit: Bool) {
        let changed = selectedTaskId != id
        selectedTaskId = id
        if explicit || changed, sessions.status(ofTask: id) == .done { feed?.markSeen(task: id) }
    }
```

  Store the feed as `private let feed: SessionFeed?` and keep the two subscriptions in `private var feedSubscriptions: [AnyCancellable]`. In `select(task:)` replace `selectedTaskId = id` with `shown(id, explicit: true)`; in `refresh` replace `selectedTaskId = task.id` with `shown(task.id, explicit: false)`. Leave `newTask`'s assignment alone: a new task has no done tab.
- [ ] **Step 4: The dots.** In `ShellforgeSidebar.swift` add a `StatusDot(state:)` view: nothing for `.idle`; an 8 pt circle — `.orange` needs input, `.blue` working, `.green` done — with `.accessibilityLabel` "Needs input" / "Working" / "Done" and `.help` the same. Put it before the task title in `taskRow` (`model.status(ofTask: node.id)`) and before the tab title in `tabRow` (`model.status(ofTab: tab.id)`). Under the list, when `model.helper.isProblem`, show `model.helper.text` like `lastError` (caption, `.secondary` for `.helperUnreachable`, `.orange` otherwise). Colours are placeholders for M1b's design system: ledger that.
- [ ] **Step 5:** Run `scripts/swift.sh test`. Expected: all pass, including `SidebarTests` (the view still builds headless).
- [ ] **Step 6:** Commit: `feat(ui): status dots for tasks and tabs, and the helper's problem in the sidebar`.

### Task 4: The app runs the helper and reports its tabs

**Files:**
- Modify: `iTerm2.xcodeproj/project.pbxproj` (folder reference `Shellforge/daemon/shellforged` in the iTerm2 app target's Resources phase `8742064A0564169600CFC3F1`, copied as `Contents/Resources/shellforged`)
- Modify: `sources/TerminalView/iTermShellforgeSidebar.swift` (the link, the report source, nudges)
- Modify: `sources/AppKit/iTermApplicationDelegate.m` (start in `applicationDidFinishLaunching:`, ~line 1507)
- Modify: `Shellforge/docs/upstream-hook-points.md`
- Test: `ModernTests/ShellforgeReportsTest.swift`

**Interfaces:**
- Consumes: Task 2's `DaemonLink`, Task 3's `SidebarModel(…, feed:)`, `PythonFinder.find(launcher:)`, `SessionReport`.
- Produces (iTerm2 side):

```swift
extension iTermShellforgeSidebar {
    /// The app's one helper link.
    static let link: DaemonLink
    /// Starts the helper and the one-second report tick; stops both at iTermApplicationWillTerminate.
    @objc static func startHelper()
    /// One session's report from its placement and a variable lookup — pure, for tests.
    nonisolated static func report(guid: String, windowId: String, tabIndex: Int, active: Bool,
                                   value: (String) -> Any?) -> SessionReport
}
```

- [ ] **Step 1: Write the ModernTests test.**

```swift
import XCTest
@testable import iTerm2SharedARC

final class ShellforgeReportsTest: XCTestCase {
    func testReportsCoverEverySessionWithItsPlacement() {
        let vars: [String: Any] = [
            iTermVariableKeySessionCommandLine: "claude --resume", iTermVariableKeySessionJobPid: NSNumber(value: 4242),
            iTermVariableKeySessionAutoName: "claude", iTermVariableKeySessionPath: "/wt/fix-login",
            "user.shellforge_task": "6f0e2c1a-9b3d-4e5f-8a7b-0c1d2e3f4a5b",
        ]
        let tagged = iTermShellforgeSidebar.report(guid: "G1", windowId: "W", tabIndex: 2, active: true) { vars[$0] }
        XCTAssertEqual(tagged, SessionReport(sessionId: "G1", windowId: "W", tabIndex: 2, commandLine: "claude --resume", jobPid: 4242,
                                             title: "claude", cwd: "/wt/fix-login", active: true,
                                             task: UUID(uuidString: "6f0e2c1a-9b3d-4e5f-8a7b-0c1d2e3f4a5b"), project: nil))
        let bare = iTermShellforgeSidebar.report(guid: "G2", windowId: "W", tabIndex: 0, active: false) { _ in nil }
        XCTAssertEqual(bare, SessionReport(sessionId: "G2", windowId: "W", tabIndex: 0, commandLine: nil, jobPid: nil,
                                           title: "", cwd: "", active: false, task: nil, project: nil))
    }

    func testAJunkTagIsNoTask() {
        let r = iTermShellforgeSidebar.report(guid: "G", windowId: "W", tabIndex: 0, active: true) { $0 == "user.shellforge_task" ? "not-a-uuid" : nil }
        XCTAssertNil(r.taskId)
    }
}
```

  Use the variable-name constants the iTerm2 code exposes (`iTermVariableKeySession…` from `iTermVariables.h`, through the bridging header) and `ShellforgeTags.task`/`.project` with the `user.` prefix as `scope.value(forVariableName:)` takes them — check how `iTermShellforgeHost.tabs` reads the tags and use the same names.
- [ ] **Step 2:** Run `xcodebuild test -project iTerm2.xcodeproj -scheme ModernTests -only-testing:ModernTests/ShellforgeReportsTest` (the scheme and flags M1a's `ShellforgeHostTest` used; copy them from `upstream-hook-points.md` "M1a verified"). Expected: build fails, `report(guid:…)` does not exist.
- [ ] **Step 3: Implement in `iTermShellforgeSidebar.swift`.**

```swift
extension iTermShellforgeSidebar {
    static let link = DaemonLink(daemonDir: Bundle.main.resourceURL,
                                 findPython: { PythonFinder.find(launcher: launcher).map(URL.init(fileURLWithPath:)) },
                                 reports: { allReports() })
    private static var tick: Timer?

    @objc static func startHelper() {
        link.start()
        // jobPid and commandLine change with no notification; a tick reads them, and only a changed
        // list is sent.
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { link.reportsMayHaveChanged() } }
        NotificationCenter.default.addObserver(forName: .init(iTermApplicationWillTerminate), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { tick?.invalidate(); link.shutdown() }
        }
    }

    /// Every session in every Shellforge window, the selected one of the selected tab active.
    static func allReports() -> [SessionReport] {
        (iTermController.sharedInstance()?.terminals() ?? []).flatMap { window -> [SessionReport] in
            let current = window.currentSession()?.guid
            return window.tabs().enumerated().flatMap { index, tab in
                tab.sessions().compactMap { $0 as? PTYSession }.map { session in
                    let scope = session.genericScope
                    return report(guid: session.guid, windowId: window.terminalGuid, tabIndex: index,
                                  active: session.guid == current) { scope.value(forVariableName: $0) }
                }
            }
        }
    }

    nonisolated static func report(guid: String, windowId: String, tabIndex: Int, active: Bool, value: (String) -> Any?) -> SessionReport {
        SessionReport(sessionId: guid, windowId: windowId, tabIndex: tabIndex,
                      commandLine: value(iTermVariableKeySessionCommandLine) as? String,
                      jobPid: (value(iTermVariableKeySessionJobPid) as? NSNumber)?.intValue,
                      title: value(iTermVariableKeySessionAutoName) as? String ?? "",
                      cwd: value(iTermVariableKeySessionPath) as? String ?? "",
                      active: active,
                      task: (value(ShellforgeTags.task) as? String).flatMap(UUID.init(uuidString:)),
                      project: (value(ShellforgeTags.project) as? String).flatMap(UUID.init(uuidString:)))
    }
}
```

  Adjust the Objective-C names to what the Swift importer gives (`terminals()`, `currentSession()`, `tabs()`, `sessions()`, `terminalGuid`); a `jobPid` of 0 or less is "none" (`nil`). Pass `feed: link` in `makeView(for:)`. In `iTermShellforgeHost`'s notification observer, after `onChange`, call `iTermShellforgeSidebar.link.reportsMayHaveChanged()` so a new or closed tab is sent at once, not on the next tick.
- [ ] **Step 4: Start it.** In `iTermApplicationDelegate.m` `applicationDidFinishLaunching:` (next to where M1a's code runs, ~line 1507) add `[iTermShellforgeSidebar startHelper];`.
- [ ] **Step 5: Bundle the daemon.** With a Python script (as in M1a), add to `project.pbxproj`: a `PBXFileReference` `{ lastKnownFileType = folder; path = Shellforge/daemon/shellforged; sourceTree = "<group>"; }` under the Shellforge group, a `PBXBuildFile` for it, and that build file in the Resources phase `8742064A0564169600CFC3F1`. `__pycache__` is never written into the bundle (`PYTHONDONTWRITEBYTECODE`, set by the supervisor).
- [ ] **Step 6:** Run the ModernTests filter. Expected: both pass. Then build the app: `xcodebuild -project iTerm2.xcodeproj -scheme iTerm2 -configuration Development build`. Expected: succeeds; `ls <app>/Contents/Resources/shellforged/__main__.py` exists; and nothing else at the top of `Contents/Resources` is importable Python that could shadow the standard library (`find <app>/Contents/Resources -maxdepth 1 \( -name '*.py' -o -name '__init__.py' \)` prints nothing; PYTHONPATH is that folder).
- [ ] **Step 7:** Add every iTerm2 file changed here to `upstream-hook-points.md` with one line each, then run the package suite once more. Commit: `feat(app): bundle shellforged, run it for the app's life, report every tab to it`.

### Task 5: Verify in the running app

No new code; evidence for the ledger.

- [ ] **Step 1:** Quit any running Shellforge build. Launch the Development build. Expected within 5 s: `~/Library/Application Support/Shellforge/shellforged.sock` and `daemon.json` exist; `ps -o pid,command -p <pid in daemon.json>` shows the Python found by `PythonFinder` running `-m shellforged run --socket … --hook-port 47831`. AiTerm's daemon (47821), if running, is untouched.
- [ ] **Step 2:** Open a task in the scratch repo (as M1a's verification did). Run `python3 -m shellforged ctl sessions.list` with `PYTHONPATH=Shellforge/daemon` and `--socket` the Shellforge socket. Expected: the task's tab, with its lowercase `taskId`, its `cwd` the worktree and `active: true`.
- [ ] **Step 3:** In that tab run `echo $ITERM_SESSION_ID`, then from another terminal post a Claude hook as that tab:
  `curl -s -X POST -H 'Content-Type: application/json' -H 'X-Shellforge-Hook: 1' -H "X-Shellforge-iTerm-Session: <that value>" --data '{"hook_event_name":"UserPromptSubmit","session_id":"verify-1","cwd":"<worktree>"}' http://127.0.0.1:47831/hook/claude`.
  Expected: the task's and tab's dots turn blue (working) within 2 s — screenshot. Then post `"hook_event_name":"Stop"`: green (done). Select another task, then this one: the green dot clears — screenshot.
- [ ] **Step 4:** `kill -9` the daemon's pid. Expected: the dots clear, the sidebar briefly says "Reconnecting…", the supervisor starts a new daemon, and within ~10 s `sessions.list` on the new one lists the task's tab again.
- [ ] **Step 5:** Quit Shellforge (Cmd-Q). Expected: the daemon's pid is gone and the socket file removed within 3 s.
- [ ] **Step 6:** Record each Expected against what was seen in the ledger and in `upstream-hook-points.md` under a new "M1c-2b verified" section; commit `docs: M1c-2b verified in the running app`.
