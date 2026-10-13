import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

@MainActor @Suite struct DaemonLinkTests {
    private static let task = UUID(uuidString: "6F0E2C1A-9B3D-4E5F-8A7B-0C1D2E3F4A5B")!
    private static let session: [String: Any] = ["sessionId": "G", "windowId": "w", "tabIndex": 0,
                                                 "taskId": "6f0e2c1a-9b3d-4e5f-8a7b-0c1d2e3f4a5b", "projectId": NSNull(),
                                                 "agent": "claude", "state": "working", "title": "claude", "cwd": "/wt"]

    /// A folder that looks like the bundled daemon's: `shellforged/__main__.py`.
    private func daemonDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sf-daemon-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("shellforged"), withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("shellforged/__main__.py"))
        return dir
    }

    nonisolated private static func snapshotReply(_ req: [String: Any], version: Int = DaemonProtocol.version, sessions: [[String: Any]] = []) -> [String: Any] {
        ["id": req["id"]!, "result": ["protocolVersion": version, "connected": true, "sessions": sessions,
                                      "usage": ["claude": NSNull(), "codex": NSNull()]]]
    }

    private func report(_ id: String) -> SessionReport {
        SessionReport(sessionId: id, windowId: "w", tabIndex: 0, commandLine: nil, jobPid: nil, title: id, cwd: "/", active: true,
                      task: Self.task, project: nil)
    }

    /// A fake daemon answering the snapshot, `sessions.update` and `sessions.markSeen`.
    private func server(path: String = "/tmp/sf-link-\(UUID().uuidString.prefix(8)).sock", sessions: [[String: Any]] = []) -> FakeSocketServer {
        let server = FakeSocketServer(path: path)
        nonisolated(unsafe) let sessions = sessions
        server.handler = { req in
            switch req["method"] as? String {
            case "workspace.snapshot": Self.snapshotReply(req, sessions: sessions)
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
        // The "Python" is a script that leaves a mark: a supervisor that started would run it.
        let dir = try daemonDir(), mark = dir.appendingPathComponent("started")
        let python = dir.appendingPathComponent("python3")
        try "#!/bin/sh\ntouch '\(mark.path)'\n".write(to: python, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
        let gate = DispatchSemaphore(value: 0), asked = Locked(false)
        let link = DaemonLink(socketPath: "/tmp/sf-link-\(UUID().uuidString.prefix(8)).sock", daemonDir: dir, findPython: {
            asked.withLock { $0 = true }; gate.wait(); return python
        }, reports: { [] })
        link.start()
        #expect(await eventually { asked.withLock { $0 } })
        link.shutdown()
        gate.signal()
        try await Task.sleep(for: .milliseconds(500))
        #expect(!FileManager.default.fileExists(atPath: mark.path))
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
        let server = server(sessions: [Self.session])
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
        let first = server(sessions: [Self.session])
        let link = DaemonLink(socketPath: first.path, daemonDir: nil, findPython: { nil }, reports: { [report("A")] })
        defer { link.shutdown() }
        link.supervisorChanged(.listening(pid: 1))
        #expect(await eventually { updates(first) == [["A"]] && link.store.bootstrapped })
        first.stop()
        #expect(await eventually { link.store == SessionStore() && link.status == .helperUnreachable })
        let second = server(path: first.path)
        defer { second.stop() }
        #expect(await eventually(timeout: 30) { updates(second) == [["A"]] })
    }

    @Test func aMismatchedHelperFillsNoDots() async throws {
        let server = FakeSocketServer(path: "/tmp/sf-link-\(UUID().uuidString.prefix(8)).sock")
        nonisolated(unsafe) let session = Self.session
        server.handler = { req in Self.snapshotReply(req, version: 1, sessions: [session]) }
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

    /// A tunnel starts with the login shell's environment — the daemon has no `SSH_AUTH_SOCK` or
    /// `PATH` of its own — and stops by its alias.
    @Test func tunnelsStartWithTheLoginEnvironmentAndStopByAlias() async throws {
        let server = server()
        let link = DaemonLink(socketPath: server.path, daemonDir: nil, findPython: { nil }, reports: { [] },
                              environment: { ["PATH": "/opt/bin", "SSH_AUTH_SOCK": "/tmp/agent"] })
        defer { link.shutdown(); server.stop() }
        link.supervisorChanged(.listening(pid: 1))
        #expect(await eventually { link.status == .connected })
        link.startTunnel(alias: "db", keepRunning: false)
        link.stopTunnel(alias: "db")
        func sent(_ method: String) -> [String: Any]? {
            server.received.first { $0["method"] as? String == method }?["params"] as? [String: Any]
        }
        #expect(await eventually { sent("tunnels.start") != nil && sent("tunnels.stop") != nil })
        #expect(sent("tunnels.start")?["alias"] as? String == "db")
        #expect(sent("tunnels.start")?["environment"] as? [String: String] == ["PATH": "/opt/bin", "SSH_AUTH_SOCK": "/tmp/agent"])
        #expect(sent("tunnels.stop")?["alias"] as? String == "db")
    }

    /// The daemon's answer to `sessions.update`, as a fake server gives it.
    private func rejectingServer(code: String) -> FakeSocketServer {
        let server = FakeSocketServer(path: "/tmp/sf-link-\(UUID().uuidString.prefix(8)).sock")
        server.handler = { req in
            req["method"] as? String == "sessions.update"
                ? ["id": req["id"]!, "error": ["code": code, "message": "no"]]
                : Self.snapshotReply(req)
        }
        server.start()
        return server
    }

    /// A list the daemon refused is tried again on the next change or tick, not at once: refused
    /// every time, an immediate retry would spin the main actor for good.
    @Test func aRefusedListWaitsForTheNextTickToBeSentAgain() async throws {
        let server = rejectingServer(code: "bad_params")
        let link = DaemonLink(socketPath: server.path, daemonDir: nil, findPython: { nil }, reports: { [report("A")] })
        defer { link.shutdown(); server.stop() }
        link.supervisorChanged(.listening(pid: 1))
        #expect(await eventually { updates(server).count == 1 })
        try await Task.sleep(for: .milliseconds(300))
        #expect(updates(server).count == 1)
        link.reportsMayHaveChanged()
        #expect(await eventually { updates(server).count == 2 })
    }

    /// A daemon that does not know `sessions.update` is from another build: said so, and not sent
    /// to again.
    @Test func aDaemonWithoutSessionsUpdateIsAMismatch() async throws {
        let server = rejectingServer(code: "unknown_method")
        let link = DaemonLink(socketPath: server.path, daemonDir: nil, findPython: { nil }, reports: { [report("A")] })
        defer { link.shutdown(); server.stop() }
        link.supervisorChanged(.listening(pid: 1))
        #expect(await eventually { link.status == .helperMismatch })
        link.reportsMayHaveChanged()
        try await Task.sleep(for: .milliseconds(300))
        #expect(updates(server).count == 1)
    }

    /// A helper that keeps stopping says where its log is; the connection's "Reconnecting…" between
    /// its restarts does not replace that. Anything else the connection says does.
    @Test func aHelperThatKeepsStoppingIsNotHiddenByReconnecting() {
        let link = DaemonLink(daemonDir: nil, findPython: { nil }, reports: { [] })
        link.supervisorChanged(.failed(attempt: 2, message: "exited with status 1"))
        link.connectionSaid(.helperUnreachable)
        #expect(link.status == .helperFailing("exited with status 1"))
        link.connectionSaid(.connected)
        #expect(link.status == .connected)
        link.connectionSaid(.helperUnreachable)
        #expect(link.status == .helperUnreachable)
    }
}
