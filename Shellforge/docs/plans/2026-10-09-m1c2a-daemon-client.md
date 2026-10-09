# M1c-2a Daemon Client Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Shellforge package can start `shellforged`, keep it running, talk to it over its socket, send it the app's tabs, and fold its session events into per-task statuses — all tested with swiftly, ready for the app to wire up in M1c-2b.

**Architecture:** A port of AiTerm's daemon client (`~/aiterm/app/Sources/AiTermCore/Daemon`) into `ShellforgeCore/Daemon`, with its tests and test support, changed for Shellforge: macOS 13 (no `Mutex`, no `@Observable`), only the methods and events `shellforged` serves in app mode plus `sessions.update`, a liveness probe that exists without iTerm2, Shellforge's paths and port, and child processes started through `ChildProcess` (which gains long-lived children) so `SourceRulesTests` still holds. A pure `SessionStore` reducer and `TaskStatus.aggregate` turn the event stream into what the sidebar shows.

**Tech Stack:** Swift 6 language mode, swift-tools 6.0, macOS 13; Foundation sockets (`socket`/`connect`), `os.OSAllocatedUnfairLock`, `AsyncStream`; Swift Testing.

**Spec:** Shellforge PRD (Claude Doc 89fd80a8-5fcf-4423-a8d6-c62f8512a481): W6 (status from the hook receiver), E3 (one runner starts every child), "Architecture" (keep the daemon). `Shellforge/daemon/README.md` is the daemon's contract; its wire frames are `Shellforge/daemon/tests/wire/*.json`.

## Global Constraints

- Source: AiTerm (`~/aiterm`, GPLv3, Laurens D'Hondt). Ported files start with a comment naming the AiTerm file they came from. Nothing in `~/aiterm` changes.
- macOS 13 and Swift 6: no `import Synchronization`/`Mutex` (use `OSAllocatedUnfairLock<State>`, or `NSLock` with `@unchecked Sendable`), no `@Observable`, no macOS 14+ API. Build and test only with `Shellforge/scripts/swift.sh`.
- Only `ChildProcess.swift` creates a `Process` (`SourceRulesTests`).
- Paths: socket `~/Library/Application Support/Shellforge/shellforged.sock`, log `~/Library/Application Support/Shellforge/shellforged.log`, hook port 47831. Daemon arguments: `-m shellforged run --socket <sock> --hook-port <port>` — never `--cookies-from-app`.
- The client names only what Shellforge uses: methods `workspace.snapshot`, `sessions.list`, `sessions.markSeen`, `sessions.update`, `usage.get`; events `session.opened`, `session.changed`, `session.closed`, `usage.changed`; any other event decodes as `.unknown(name)`.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Nothing is pushed without asking.

## Review Focus

1. **The daemon not running yet when the client connects** (first launch, or a crash): the client fails fast with a connect error and the caller retries with backoff; no hang. (Task 3 test: missing socket.)
2. **Events that arrive before the bootstrap snapshot**: they must not overwrite it — the snapshot is the barrier. (Task 3 test, ported.)
3. **A daemon from another build answering** (protocol version or unknown method): reported as a mismatch, not a crash. (Task 3 test.)
4. **AiTerm's daemon already running**: Shellforge's supervisor never adopts or kills it — different socket, different port. (Task 4 test: socket path.)
5. **The app quitting while the daemon starts**: `stop()` ends the child (SIGTERM, then SIGKILL) and leaves no orphan. (Task 4 test, ported.)

---

### Task 1: Test support

**Files:**
- Modify: `Shellforge/Package.swift` (add a `ShellforgeTestSupport` library target that the test targets depend on)
- Create: `Shellforge/Tests/ShellforgeTestSupport/FakeSocketServer.swift`, `Eventually.swift`, `TestDeadline.swift` (ported from `~/aiterm/app/Tests/AiTermTestSupport/`)
- Test: `Shellforge/Tests/ShellforgeCoreTests/FakeSocketServerTests.swift` (ported from `~/aiterm/app/Tests/AiTermCoreTests/FakeSocketServerTests.swift`)

- [ ] **Step 1:** Add to `Package.swift`: `.target(name: "ShellforgeTestSupport", dependencies: ["ShellforgeCore"], path: "Tests/ShellforgeTestSupport")`, and add `"ShellforgeTestSupport"` to both test targets' dependencies.
- [ ] **Step 2:** Copy the three support files and the fake server's tests. Replace `AiTermCore`/`AiTermTestSupport` imports with `ShellforgeCore`/`ShellforgeTestSupport`; replace any `Mutex` with `OSAllocatedUnfairLock`; keep their behaviour. Add the origin comment at the top of each.
- [ ] **Step 3:** Run `cd Shellforge && scripts/swift.sh test --filter FakeSocketServerTests`. Expected: every ported test passes (record the count).
- [ ] **Step 4:** Commit: `test(core): fake daemon socket and waiting helpers, from AiTerm`.

### Task 2: Wire types, checked against shellforged's frames

**Files:**
- Create: `Shellforge/Sources/ShellforgeCore/Daemon/DaemonProtocol.swift`, `DaemonTypes.swift`, `UnixSocketAddress.swift`, `SocketProbe.swift`, `Backoff.swift` (ported)
- Test: `Shellforge/Tests/ShellforgeCoreTests/Daemon/DaemonTypesTests.swift`, `WireContractTests.swift` (ported)

**Interfaces:**
- Produces: `DaemonProtocol.version = 1`, `maximumFrameBytes = 1 << 20`; `enum DaemonMethod: String, CaseIterable { case snapshot = "workspace.snapshot", listSessions = "sessions.list", markSeen = "sessions.markSeen", updateSessions = "sessions.update", usage = "usage.get" }`; `enum DaemonEventName: String, CaseIterable { case sessionOpened = "session.opened", sessionChanged = "session.changed", sessionClosed = "session.closed", usageChanged = "usage.changed" }`; `SessionInfo`, `SessionAgent`, `SessionState`, `TokenTally`, `UsageWindow`, `Usage`, `UsageSnapshot`, `DaemonSnapshot { protocolVersion, connected, sessions, usage }`, `DaemonError { code: Code; message: String }`, `DaemonEvent { snapshot, sessionOpened, sessionChanged, sessionClosed, usageChanged, unknown }`; and new `struct SessionReport: Codable, Equatable, Sendable { sessionId, windowId: String; tabIndex: Int; commandLine: String?; jobPid: Int?; title, cwd: String; active: Bool; taskId, projectId: String? }`.

- [ ] **Step 1: Port the tests first.** Copy `DaemonTypesTests.swift` and `WireContractTests.swift`, then change them:
  - drop every case for `Frame`, `SessionTitle`, `ItermCookieAnswer`, `iterm.*`, `window.*`, `tab.create`, `interface.*` and the `itermUnavailable` code;
  - point the fixture directory at `Shellforge/daemon/tests/wire` (resolve from `#filePath`: `Tests/ShellforgeCoreTests/Daemon/` is four levels below `Shellforge/`);
  - change `theAppNamesWhatTheDaemonNames` to require that every `DaemonMethod`/`DaemonEventName` raw value is in the manifest (the app names a subset; the daemon still serves the bridge's methods for `--session-source iterm`);
  - add `@Test func aSessionReportEncodesAsSessionsUpdateTakesIt()`: encode `SessionReport(sessionId: "G", windowId: "pty-1", tabIndex: 0, commandLine: nil, jobPid: nil, title: "t", cwd: "/r", active: true, taskId: nil, projectId: nil)` with `JSONEncoder` and assert the keys are exactly `["active", "commandLine", "cwd", "jobPid", "projectId", "sessionId", "tabIndex", "taskId", "title", "windowId"]` with `null` for the nils (encode optionals explicitly, not omitted — `parse_sessions` reads them by key).
- [ ] **Step 2:** Run `scripts/swift.sh test --filter "DaemonTypesTests|WireContractTests"`. Expected: build fails, the types do not exist.
- [ ] **Step 3: Port the types.** Copy the five source files; delete what the tests no longer name; move `SessionAgent`/`SessionState` (from AiTerm's `Models.swift:24–38`) into `DaemonTypes.swift`; reword `DaemonError.userMessage` without iTerm2 ("Shellforge's helper did not answer" etc.); add `SessionReport` with a hand-written `encode(to:)` that writes every key, nil as null.
- [ ] **Step 4:** Run the same filter. Expected: all pass, including every reply fixture for the five methods and every event fixture for the four events.
- [ ] **Step 5:** Commit: `feat(core): the daemon's wire types, checked against shellforged's frames`.

### Task 3: The socket client

**Files:**
- Create: `Shellforge/Sources/ShellforgeCore/Daemon/DaemonClient.swift` (ported, 538 lines in AiTerm)
- Test: `Shellforge/Tests/ShellforgeCoreTests/Daemon/DaemonClientTests.swift` (ported, 25 tests in AiTerm)

**Interfaces:**
- Consumes: Task 2's types; `FakeSocketServer` (Task 1).
- Produces: `public final class DaemonClient: Sendable` with `init(socketPath:requestTimeout:livenessTimeout:)`, `events: AsyncStream<DaemonEvent>`, `ending: Ending?`, `connect() throws`, `disconnect()`, `request(_:as:)`, `request(_:params:as:)`, `snapshot() async throws -> DaemonSnapshot`, `markSeen(taskId:) async throws -> Int`, and new `updateSessions(_ reports: [SessionReport]) async throws`.

- [ ] **Step 1: Port the tests first.** Copy `DaemonClientTests.swift`; replace every `iterm.status` liveness expectation with `usage.get` (the new liveness probe: it exists in app mode and costs nothing); drop tests of iTerm2-only methods; add:
  - `updateSessionsSendsTheReportsAndWaitsForTheTick`: the fake server answers `sessions.update` with `{"ok": true}`; assert the received params equal `{"sessions": [<the report as JSON>]}`.
  - `aDaemonOfAnotherProtocolVersionIsAMismatch`: the fake answers `workspace.snapshot` with `protocolVersion: 2`; assert `snapshot()` throws `DaemonError` with `.incompatible`.
- [ ] **Step 2:** Run `scripts/swift.sh test --filter DaemonClientTests`. Expected: build fails, `DaemonClient` missing.
- [ ] **Step 3: Port the client.** Copy `DaemonClient.swift`. Change:
  - state in `OSAllocatedUnfairLock<State>` (make `State` a copyable struct; replace `withLock` call sites accordingly), and the static `unreadableLogged` likewise;
  - liveness probe method `.usage` instead of `iterm.status`;
  - `decodeEvent` maps only the four events; everything else `.unknown(name)`;
  - remove the iTerm2 command wrappers; add `updateSessions` (`request(.updateSessions, params: ["sessions": reports], as: Empty.self)`, with the params type a small `Encodable` struct);
  - logging through `os.Logger(subsystem: "io.github.nathangel.shellforge", category: "daemon")` instead of AiTerm's `Log.daemon`.
- [ ] **Step 4:** Run the filter. Expected: every ported test passes, plus the two new ones.
- [ ] **Step 5:** Run the whole package (`scripts/swift.sh test`), then commit: `feat(core): a socket client for shellforged, from AiTerm's`.

### Task 4: Long-lived children and the supervisor

**Files:**
- Modify: `Shellforge/Sources/ShellforgeCore/ChildProcess.swift` (add a long-lived launch)
- Create: `Shellforge/Sources/ShellforgeCore/Daemon/DaemonSupervisor.swift` (ported, 260 lines), `Shellforge/Sources/ShellforgeCore/Daemon/PythonFinder.swift`, `Shellforge/Sources/ShellforgeCore/Daemon/ShellforgePaths.swift`
- Test: `Shellforge/Tests/ShellforgeCoreTests/Daemon/DaemonSupervisorTests.swift` (ported, 18 tests), `Shellforge/Tests/ShellforgeCoreTests/Daemon/PythonFinderTests.swift`, `ChildProcessTests.swift` (extend)

**Interfaces:**
- Produces:
  - `ChildProcess.launch(_ executable: String, _ arguments: [String], environment: [String: String], directory: String?, output: FileHandle?, onExit: @escaping @Sendable (Int32) -> Void) throws -> RunningChild`, where `public final class RunningChild: Sendable { let pid: Int32; func terminate(); func kill(); var isRunning: Bool }`.
  - `public enum ShellforgePaths { static var supportDirectory: URL; static var socketPath: String; static var daemonLogURL: URL; static let hookPort = 47831 }`.
  - `public enum PythonFinder { static func find(launcher: CommandLauncher) -> String? }` — the first of `python3`, `python3.14`…`python3.11` on the launcher's `PATH` whose `sys.version_info >= (3, 11)`, run through the launcher.
  - `DaemonSupervisor` as AiTerm's, with `init(python: URL, daemonDir: URL, socketPath: String = ShellforgePaths.socketPath, hookPort: Int = ShellforgePaths.hookPort, arguments: [String]? = nil, logURL: URL = ShellforgePaths.daemonLogURL, …)` and arguments `["-m", "shellforged", "run", "--socket", socketPath, "--hook-port", String(hookPort)]`.

- [ ] **Step 1: Tests first.**
  - `ChildProcessTests`: `aLaunchedChildReportsItsExit` (launch `/bin/sh -c "exit 7"`, `onExit` gets 7), `aLaunchedChildWritesToTheGivenFile` (output handle receives `echo hi`), `terminateEndsALongRunningChild` (`sleep 30`, `terminate()`, `onExit` within 2 s).
  - `PythonFinderTests`: with a launcher whose `PATH` holds a fake `python3` script printing `True` for the version check, `find` returns its path; with one printing `False` and a fake `python3.11` printing `True`, it returns `python3.11`'s; with neither, nil.
  - Port `DaemonSupervisorTests.swift`: same fakes (`/bin/sh -c …` as "python"), `RecordedBackoff`, temp `logURL`; drop the PythonLocator tests (replaced above); assert the default arguments are `-m shellforged run --socket … --hook-port 47831` and contain no `--cookies-from-app`; add `theDefaultSocketIsShellforgesNotAiTerms` (`ShellforgePaths.socketPath` ends with `/Application Support/Shellforge/shellforged.sock`).
- [ ] **Step 2:** Run the three filters. Expected: build fails, the APIs do not exist.
- [ ] **Step 3: `ChildProcess.launch` and `RunningChild`.** In `ChildProcess.swift` (the only file allowed to create a `Process`): configure a `Process` as `run` does, set `standardOutput`/`standardError` to `output` (or `FileHandle.nullDevice`), `terminationHandler = { onExit($0.terminationStatus) }`, `run()`, and return a `RunningChild` holding it (`terminate()` → `process.terminate()`, `kill()` → `Darwin.kill(pid, SIGKILL)`).
- [ ] **Step 4: Paths, finder, supervisor.** Write `ShellforgePaths` and `PythonFinder`; port `DaemonSupervisor.swift`, replacing `Mutex` as in Task 3, `Process` creation with `ChildProcess.launch`, `ProcessRunner.withoutLaunchIdentity` with `LoginEnvironment.forChildren(ProcessInfo.processInfo.environment)`, `AiTermPaths` with `ShellforgePaths`, and the module name `aitermd` with `shellforged`.
- [ ] **Step 5:** Run the filters, then the whole package including `SourceRulesTests`. Expected: all pass.
- [ ] **Step 6:** Commit: `feat(core): keep shellforged running, from AiTerm's supervisor`.

### Task 5: Session store and task status

**Files:**
- Create: `Shellforge/Sources/ShellforgeCore/Daemon/SessionStore.swift`
- Test: `Shellforge/Tests/ShellforgeCoreTests/Daemon/SessionStoreTests.swift`

**Interfaces:**
- Produces: `public struct SessionStore: Equatable, Sendable { public private(set) var sessions: [String: SessionInfo]; public private(set) var usage: UsageSnapshot; public private(set) var bootstrapped: Bool; public mutating func apply(_ event: DaemonEvent); public func status(ofTask id: UUID) -> SessionState; public func status(ofTab sessionId: String) -> SessionState }` and `public enum TaskStatus { public static func aggregate(_ states: [SessionState]) -> SessionState }`.

- [ ] **Step 1: Write the failing tests.**

```swift
import Foundation
import Testing
@testable import ShellforgeCore

@Suite struct SessionStoreTests {
    private func session(_ id: String, task: UUID?, _ state: SessionState) -> SessionInfo {
        SessionInfo(sessionId: id, windowId: "pty-1", tabIndex: 0, taskId: task?.uuidString, projectId: nil,
                    agent: .claude, model: nil, state: state, title: id, cwd: "/r")
    }

    @Test func eventsBeforeTheSnapshotAreIgnored() {
        var store = SessionStore()
        store.apply(.sessionOpened(session("a", task: nil, .working)))
        store.apply(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true, sessions: [], usage: .empty)))
        #expect(store.sessions.isEmpty && store.bootstrapped)
    }

    @Test func openedChangedAndClosedKeepTheSessionsCurrent() {
        var store = SessionStore()
        store.apply(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true, sessions: [session("a", task: nil, .idle)], usage: .empty)))
        store.apply(.sessionChanged(session("a", task: nil, .working)))
        store.apply(.sessionOpened(session("b", task: nil, .idle)))
        store.apply(.sessionClosed("a"))
        #expect(store.sessions.keys.sorted() == ["b"])
    }

    @Test func aTaskShowsItsMostUrgentTab() {
        let task = UUID()
        var store = SessionStore()
        store.apply(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true, sessions: [
            session("a", task: task, .done), session("b", task: task, .needsInput), session("c", task: nil, .working)],
            usage: .empty)))
        #expect(store.status(ofTask: task) == .needsInput)
        #expect(store.status(ofTab: "c") == .working)
        #expect(store.status(ofTask: UUID()) == .idle)
    }

    @Test(arguments: [([SessionState.idle, .done], SessionState.done), ([.done, .working], .working),
                      ([.working, .needsInput, .done], .needsInput), ([], .idle)])
    func urgencyOrder(states: [SessionState], expected: SessionState) {
        #expect(TaskStatus.aggregate(states) == expected)
    }
}
```

(Adjust the `SessionInfo`/`DaemonSnapshot` initialisers to the ported types' memberwise or explicit initialisers; add public initialisers if Task 2's types lack them.)
- [ ] **Step 2:** Run `scripts/swift.sh test --filter SessionStoreTests`. Expected: build fails, `SessionStore` missing.
- [ ] **Step 3: Write it.** `apply`: before the first `.snapshot`, ignore everything; `.snapshot` replaces `sessions` (keyed by `sessionId`) and `usage` and sets `bootstrapped`; `.sessionOpened`/`.sessionChanged` upsert; `.sessionClosed` removes; `.usageChanged` sets `usage`; `.unknown` does nothing. `status(ofTask:)` aggregates the states of sessions whose `taskId` parses to that UUID; `status(ofTab:)` is that session's state or `.idle`. `TaskStatus.aggregate`: needsInput > working > done > idle.
- [ ] **Step 4:** Run the filter and the whole package. Expected: all pass.
- [ ] **Step 5:** Commit: `feat(core): per-task status from the daemon's events`.
