// Ported from AiTerm (app/Tests/AiTermCoreTests/DaemonClientTests.swift), GPLv3, Laurens D'Hondt.
import Testing
import Foundation
@testable import ShellforgeCore
@testable import ShellforgeTestSupport

/// Wraps an `AsyncStream<DaemonEvent>.AsyncIterator` in a reference type so it can be shared with
/// the deadline-racing `Task` in `nextEvent(_:timeoutSeconds:)` below without re-deriving a fresh
/// iterator (which would drop events) on every call.
///
/// Unchecked because the iterator is mutable: `nextEvent` settles each `next()` before the next call.
private final class EventBox: @unchecked Sendable {
    private var iterator: AsyncStream<DaemonEvent>.AsyncIterator
    init(_ stream: AsyncStream<DaemonEvent>) { iterator = stream.makeAsyncIterator() }
    func next() async -> DaemonEvent? { await iterator.next() }
}

private enum NextEventResult { case event(DaemonEvent?), timedOut }

/// Races `box.next()` against a timeout so a dropped/never-sent event fails the test with a
/// recorded `Issue` instead of hanging the whole suite.
private func nextEvent(_ box: EventBox, timeoutSeconds: Double = 2) async -> NextEventResult {
    await withTaskGroup(of: NextEventResult.self) { group in
        group.addTask { .event(await box.next()) }
        group.addTask {
            try? await Task.sleep(for: .seconds(timeoutSeconds))
            return .timedOut
        }
        let result = await group.next() ?? .timedOut
        group.cancelAll()
        return result
    }
}

final class DaemonClientTests {
    var server: FakeSocketServer!
    var client: DaemonClient!
    /// `uuidString` spells these in capitals; the wire must not.
    static let task = UUID(uuidString: "6F0E2C1A-9B3D-4E5F-8A7B-0C1D2E3F4A5B")!
    static let project = UUID(uuidString: "A1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D")!

    init() {
        let path = "/tmp/sf-test-\(UUID().uuidString.prefix(8)).sock"
        server = FakeSocketServer(path: path); server.start()
        client = DaemonClient(socketPath: path)
    }
    deinit { client.disconnect(); server.stop() }

    @Test func updateSessionsSendsTheReportsAndWaitsForTheTick() async throws {
        server.handler = { req in
            #expect(req["method"] as? String == "sessions.update")
            return ["id": req["id"]!, "result": ["ok": true]]
        }
        try client.connect()
        #expect(server.waitForClient(timeout: 2))
        let report = SessionReport(sessionId: "G", windowId: "pty-1", tabIndex: 0, commandLine: "claude", jobPid: 42, title: "claude",
                                   cwd: "/wt", active: true, task: Self.task, project: Self.project)
        try await client.updateSessions([report])
        let sessions = try #require((server.received.first?["params"] as? [String: Any])?["sessions"] as? [[String: Any]])
        #expect(sessions.count == 1)
        #expect(sessions[0]["sessionId"] as? String == "G" && sessions[0]["jobPid"] as? Int == 42)
        // The daemon matches ids as strings; the sidebar's session tags are lowercase.
        #expect(sessions[0]["taskId"] as? String == "6f0e2c1a-9b3d-4e5f-8a7b-0c1d2e3f4a5b")
        #expect(sessions[0]["projectId"] as? String == "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d")
    }

    @Test func markSeenReturnsHowManySessionsChanged() async throws {
        server.handler = { req in
            #expect(req["method"] as? String == "sessions.markSeen")
            #expect((req["params"] as? [String: Any])?["taskId"] as? String == "6f0e2c1a-9b3d-4e5f-8a7b-0c1d2e3f4a5b")
            return ["id": req["id"]!, "result": ["changed": 2]]
        }
        try client.connect()
        #expect(server.waitForClient(timeout: 2))
        #expect(try await client.markSeen(task: Self.task) == 2)
    }

    /// A tunnel is started with the app's login environment: the daemon has none of its own.
    @Test func startingATunnelSendsItsAliasAndTheEnvironment() async throws {
        server.handler = { req in
            #expect(req["method"] as? String == "tunnels.start")
            let params = req["params"] as? [String: Any]
            #expect(params?["alias"] as? String == "db-staging")
            #expect((params?["environment"] as? [String: String])?["SSH_AUTH_SOCK"] == "/tmp/agent.sock")
            return ["id": req["id"]!, "result": ["ok": true]]
        }
        try client.connect()
        #expect(server.waitForClient(timeout: 2))
        try await client.startTunnel(alias: "db-staging", environment: ["SSH_AUTH_SOCK": "/tmp/agent.sock", "PATH": "/usr/bin"])
    }

    @Test func aTunnelThatKeepsRunningSaysSoWithItsStart() async throws {
        server.handler = { req in
            #expect((req["params"] as? [String: Any])?["keepRunning"] as? Bool == true)
            return ["id": req["id"]!, "result": ["ok": true]]
        }
        try client.connect()
        #expect(server.waitForClient(timeout: 2))
        try await client.startTunnel(alias: "db-staging", environment: [:], keepRunning: true)
    }

    /// A tunnel's traffic, who holds it and whether it needs an answer are read when the daemon
    /// sends them, and absent from an older daemon.
    @Test func aTunnelsNewFieldsAreReadAndOptional() throws {
        let full = #"{"alias":"db","state":"up","error":null,"since":1,"bytesIn":2749,"bytesOut":2594,"heldBy":"tab","needsInput":false}"#
        let info = try JSONDecoder().decode(TunnelInfo.self, from: Data(full.utf8))
        #expect(info.bytesIn == 2749 && info.bytesOut == 2594 && info.heldBy == .tab && info.needsInput == false)
        let old = try JSONDecoder().decode(TunnelInfo.self, from: Data(#"{"alias":"db","state":"up","error":null,"since":1}"#.utf8))
        #expect(old.bytesIn == nil && old.heldBy == nil && old.needsInput == nil)
    }

    @Test func stoppingATunnelSendsItsAlias() async throws {
        server.handler = { req in
            #expect(req["method"] as? String == "tunnels.stop")
            #expect((req["params"] as? [String: Any])?["alias"] as? String == "db-staging")
            return ["id": req["id"]!, "result": ["ok": true]]
        }
        try client.connect()
        #expect(server.waitForClient(timeout: 2))
        try await client.stopTunnel(alias: "db-staging")
    }

    @Test func aDaemonOfAnotherProtocolVersionIsAMismatch() async throws {
        server.handler = { req in
            ["id": req["id"]!, "result": ["protocolVersion": 2, "connected": true, "sessions": [], "usage": ["claude": NSNull(), "codex": NSNull()]]]
        }
        try client.connect()
        #expect(server.waitForClient(timeout: 2))
        do { _ = try await client.snapshot(); Issue.record("expected a mismatch") }
        catch let error as DaemonError { #expect(error.code == .incompatible && error.isMismatch) }
    }

    @Test func testErrorResponseThrowsDaemonError() async throws {
        server.handler = { req in ["id": req["id"]!, "error": ["code": "not_found", "message": "no such task"]] }
        try client.connect()
        #expect(server.waitForClient(timeout: 2))
        do { _ = try await client.markSeen(task: Self.task); Issue.record("expected throw") }
        catch let e as DaemonError { #expect(e == DaemonError(code: .notFound, message: "no such task")) }
    }

    @Test func testEventsAreDecoded() async throws {
        try client.connect()
        #expect(server.waitForClient(timeout: 2))
        let box = EventBox(client.events)
        server.push(event: "iterm.connected", payload: ["version": "3.7.2"])
        server.push(event: "window.activated", payload: ["windowId": "w1"])
        server.push(event: "session.changed", payload: ["sessionId": "s1", "windowId": "w1", "tabIndex": 0, "taskId": "t1", "projectId": NSNull(), "agent": "claude", "model": "claude-opus-5", "state": "working", "title": "✳", "cwd": "/wt"])
        server.push(event: "usage.changed", payload: ["claude": ["fiveHour": ["usedPercent": 23, "resetsAt": 99], "sevenDay": NSNull(), "spend": NSNull(), "plan": NSNull(), "updatedAt": 1], "codex": NSNull()])

        guard case .event(let e1) = await nextEvent(box) else { Issue.record("timed out waiting for iterm.connected event"); return }
        #expect(e1 == .unknown("iterm.connected"))

        guard case .event(let e2) = await nextEvent(box) else { Issue.record("timed out waiting for session.changed event"); return }
        #expect(e2 == .unknown("window.activated"))

        guard case .event(let e5) = await nextEvent(box) else { Issue.record("timed out waiting for session.changed event"); return }
        guard case .sessionChanged(let s)? = e5 else { Issue.record("expected .sessionChanged"); return }
        #expect(s.state == .working); #expect(s.model == "claude-opus-5")

        guard case .event(let e6) = await nextEvent(box) else { Issue.record("timed out waiting for usage.changed event"); return }
        guard case .usageChanged(let u)? = e6 else { Issue.record("expected .usageChanged"); return }
        #expect(u.claude?.fiveHour?.usedPercent == 23); #expect(u.codex == nil)

        // A later snapshot replaces the first wholesale: the vendor that went quiet is nil again.
        server.push(event: "usage.changed", payload: ["claude": NSNull(), "codex": ["fiveHour": NSNull(), "sevenDay": ["usedPercent": 12, "resetsAt": 88], "spend": NSNull(), "plan": "pro", "updatedAt": 2]])
        guard case .event(let e7) = await nextEvent(box) else { Issue.record("timed out waiting for second usage.changed event"); return }
        guard case .usageChanged(let u2)? = e7 else { Issue.record("expected .usageChanged"); return }
        #expect(u2.codex?.sevenDay?.usedPercent == 12)
        #expect(u2.claude == nil)
    }

    /// A known event this app cannot read leaves what it was about stale until the next
    /// snapshot, which only a reconnect brings, so the client drops the connection and its owner
    /// reconnects to a fresh one. An event it does not know is a newer helper's: it passes as
    /// `.unknown`, and the connection stays.
    @Test func anUnreadableKnownEventEndsTheConnectionAndAnUnknownOneDoesNot() async throws {
        try client.connect()
        #expect(server.waitForClient(timeout: 2))
        let box = EventBox(client.events)
        server.push(event: "session.renamed", payload: ["sessionId": "s1"])
        guard case .event(let unknown) = await nextEvent(box) else { Issue.record("timed out waiting for the unknown event"); return }
        #expect(unknown == .unknown("session.renamed"))

        server.push(event: "session.changed", payload: ["sessionId": "s1"])
        server.push(event: "window.closed", payload: ["windowId": "w1"])
        guard case .event(let end) = await nextEvent(box) else { Issue.record("timed out waiting for the stream to end"); return }
        #expect(end == nil, "neither the unreadable event nor any after it is passed on")
        #expect(client.ending == .unreadable, "its owner can tell a helper it cannot read from one that went away")
    }

    /// The branch a row shows is resolved from `effectiveCwd`, never from `cwd`: iTerm2 only ever
    /// reports the shell's directory, which does not follow an agent into a worktree.
    @Test func testSessionInfoPrefersTheAgentsCwd() throws {
        let moved = #"{"sessionId":"s1","windowId":"w1","tabIndex":0,"taskId":null,"projectId":null,"agent":"claude","model":null,"state":"idle","title":"","cwd":"/repo","agentCwd":"/repo/.worktrees/feat","active":true}"#
        let a = try JSONDecoder().decode(SessionInfo.self, from: Data(moved.utf8))
        #expect(a.effectiveCwd == "/repo/.worktrees/feat")
        #expect(a.active)

        // An older daemon, or a plain shell tab: no agentCwd, and no active flag, which reads as not active.
        let plain = #"{"sessionId":"s2","windowId":"w1","tabIndex":1,"taskId":null,"projectId":null,"agent":"shell","model":null,"state":"idle","title":"","cwd":"/repo"}"#
        let b = try JSONDecoder().decode(SessionInfo.self, from: Data(plain.utf8))
        #expect(b.effectiveCwd == "/repo")
        #expect(!b.active)
    }

    /// No synthetic `.itermDisconnected` here: the daemon dying is not the same fact as iTerm2
    /// going away, and yielding it blamed iTerm2 for a helper that had simply exited. The stream
    /// ending, with no event, is the whole signal — `DaemonConnection` reads it as `.helperUnreachable`.
    @Test func testEventStreamEndsWhenTheConnectionCloses() async throws {
        try client.connect()
        #expect(server.waitForClient(timeout: 2))
        let box = EventBox(client.events)
        server.stop()

        guard case .event(let end) = await nextEvent(box) else { Issue.record("the event stream never ended after the connection closed"); return }
        #expect(end == nil)
        #expect(client.ending == .closedByHelper)
    }

    @Test func testDisconnectEndsTheEventStream() async throws {
        try client.connect()
        #expect(server.waitForClient(timeout: 2))
        let box = EventBox(client.events)
        #expect(client.ending == nil, "a stream still running has not ended")
        client.disconnect()

        guard case .event(let end) = await nextEvent(box) else { Issue.record("the event stream never ended after disconnect()"); return }
        #expect(end == nil)
        #expect(client.ending == .closedHere)
    }

    @Test func silentRequestTimesOutAndDoesNotPoisonSubsequentRequests() async throws {
        client = DaemonClient(socketPath: server.path, requestTimeout: 0.08)
        server.handler = { _ in nil }
        try client.connect()
        #expect(server.waitForClient(timeout: 2))
                do { _ = try await client.request(.usageGet, as: UsageSnapshot.self); Issue.record("Expected deadline") }
        catch let error as DaemonError { #expect(error.code == .timeout) }
        // A timeout does not corrupt framing or poison subsequent requests.
        server.handler = { req in ["id": req["id"]!, "result": ["claude": NSNull(), "codex": NSNull()]] }
        #expect(try await client.request(.usageGet, as: UsageSnapshot.self) == .empty)
    }

    /// A separate, long-timeout client: racing cancellation against an 80ms request timeout (as a
    /// single client covering both halves used to) is flaky under load, where a slow scheduler can
    /// let the 20ms cancel arrive after the deadline already fired.
    @Test func cancellingARequestFinishesPromptlyWithoutWaitingForItsTimeout() async throws {
        let path = "/tmp/sf-test-\(UUID().uuidString.prefix(8)).sock"
        let longWaitServer = FakeSocketServer(path: path); longWaitServer.start()
        defer { longWaitServer.stop() }
        longWaitServer.handler = { _ in nil }
        let longWaitClient = DaemonClient(socketPath: path, requestTimeout: 30)
        defer { longWaitClient.disconnect() }
        try longWaitClient.connect()
        #expect(longWaitServer.waitForClient(timeout: 2))
                let waiting = Task { try await longWaitClient.request(.usageGet, as: UsageSnapshot.self) }
        await eventually { !longWaitServer.received.isEmpty }
        waiting.cancel()
        do { _ = try await waiting.value; Issue.record("Expected cancellation") }
        catch is CancellationError { }
    }

    @Test func concurrentRequestsKeepTheirFramesAndResponses() async throws {
        server.handler = { req in ["id": req["id"]!, "result": req["params"]!] }
        try client.connect()
        #expect(server.waitForClient(timeout: 2))
        let client: DaemonClient = self.client
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                group.addTask {
                    let value = String(repeating: "payload-\(index)", count: 2000)
                    // The server echoes any request's params: the method is not what is under test.
                    let reply = try await client.request(.sessionsMarkSeen, params: value, as: String.self)
                    #expect(reply == value)
                }
            }
            try await group.waitForAll()
        }
        #expect(server.received.count == 40)
    }

    @Test func aKnownEventWithoutItsPayloadIsUnreadableNotACrash() throws {
        for name in ["session.opened", "session.changed", "session.closed", "usage.changed"] {
            #expect(throws: DecodingError.self) { try DaemonClient.decodeEvent(name, from: Data(#"{"event":"\#(name)"}"#.utf8)) }
        }
        #expect(try DaemonClient.decodeEvent("iterm.disconnected", from: Data(#"{"event":"iterm.disconnected"}"#.utf8)) == .unknown("iterm.disconnected"))
    }

    /// The reader searches only the bytes each read adds and carries an unfinished line over: a line
    /// that arrives a few bytes at a time, and a read holding one line and the start of the next,
    /// each come out whole and in order.
    @MainActor @Test func linesSplitAcrossReadsArriveWholeAndInOrder() async throws {
        let server = try await PythonSocketServer.start(script: """
import json,socket,sys,time
s=socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1]);s.listen()
c,_=s.accept()
line=lambda w:(json.dumps({'event':'session.closed','payload':{'sessionId':w}})+'\\n').encode()
a,b,d=line('a'),line('b'),line('c')
for i in range(0,len(a),3):
 c.sendall(a[i:i+3]);time.sleep(0.002)
c.sendall(b+d[:10]);time.sleep(0.02);c.sendall(d[10:])
time.sleep(5)
""")
        defer { server.stop() }
        let client = DaemonClient(socketPath: server.path)
        defer { client.disconnect() }
        try client.connect()
        let box = EventBox(client.events)
        for windowId in ["a", "b", "c"] {
            guard case .event(let event) = await nextEvent(box) else { Issue.record("timed out waiting for window \(windowId)"); return }
            #expect(event == .sessionClosed(windowId))
        }
    }

    /// A payload is decoded straight into its type from the line's bytes: no number passes through
    /// `Double` on the way, which could not hold an integer above 2^53 exactly.
    @Test func eventIntegersArriveExactly() async throws {
        try client.connect()
        #expect(server.waitForClient(timeout: 2))
        let box = EventBox(client.events)
        let large = (1 << 53) + 1
        server.push(event: "usage.changed", payload: ["claude": ["fiveHour": NSNull(), "sevenDay": NSNull(), "spend": NSNull(), "plan": NSNull(), "updatedAt": large], "codex": NSNull()])
        guard case .event(let event) = await nextEvent(box) else { Issue.record("timed out waiting for the event"); return }
        guard case .usageChanged(let usage)? = event else { Issue.record("expected .usageChanged"); return }
        #expect(usage.claude?.updatedAt == large)
    }

    private func timeOut(_ client: DaemonClient, sourceLocation: SourceLocation = #_sourceLocation) async {
        do { _ = try await client.request(.sessionsMarkSeen, as: DaemonClient.Empty.self); Issue.record("Expected a timeout", sourceLocation: sourceLocation) }
        catch { #expect((error as? DaemonError)?.code == .timeout, sourceLocation: sourceLocation) }
    }

    /// A daemon whose loop is stuck keeps its socket open and its process alive, so neither
    /// the reader nor the supervisor notices. Two timeouts in a row prompt a liveness check, and a
    /// check that goes unanswered as well drops the connection so its owner reconnects.
    @Test func aHelperThatAnswersNothingIsDropped() async throws {
        client = DaemonClient(socketPath: server.path, requestTimeout: 0.05, livenessTimeout: 0.1)
        server.handler = { _ in nil }
        try client.connect()
        #expect(server.waitForClient(timeout: 2))
        let box = EventBox(client.events)
        await timeOut(client)
        await timeOut(client)
        guard case .event(let end) = await nextEvent(box) else { Issue.record("a wedged helper kept its connection"); return }
        #expect(end == nil)
        #expect(client.ending == .unresponsive)
        #expect(server.received.contains { $0["method"] as? String == DaemonClient.livenessCheck.rawValue })
    }

    /// Requests queued behind one of the helper's locks while iTerm2 is slow time out back to back
    /// from a helper whose loop is fine: it answers the liveness check, and the connection stays.
    @Test func timeoutsFromAHelperThatStillAnswersKeepTheConnection() async throws {
        client = DaemonClient(socketPath: server.path, requestTimeout: 0.05, livenessTimeout: 2)
        server.handler = { req in req["method"] as? String == DaemonClient.livenessCheck.rawValue ? ["id": req["id"]!, "result": ["claude": NSNull(), "codex": NSNull()]] : nil }
        try client.connect()
        #expect(server.waitForClient(timeout: 2))
        func checks() -> Int { server.received.count { $0["method"] as? String == DaemonClient.livenessCheck.rawValue } }
        for round in 1...2 {
            await timeOut(client)
            await timeOut(client)
            try #require(await eventually(describing: "round \(round)'s check") { checks() == 2 * round - 1 })
            // Sent once the server holds the check, so answered after it in wire order: the check's
            // reply has been read, ending this run of timeouts, before the next round's first one.
            _ = try await client.request(DaemonClient.livenessCheck, as: DaemonClient.Empty.self)
        }
        #expect(checks() == 4, "one check per run of timeouts, and one request per round after it")
    }

    /// One reply between two timeouts is a helper that is answering: only an unbroken run counts.
    /// Long enough a timeout that an answered request is never mistaken for one under load.
    @Test func aReplyBetweenTimeoutsKeepsTheConnection() async throws {
        client = DaemonClient(socketPath: server.path, requestTimeout: 0.5, livenessTimeout: 0.1)
        let answering = Locked(false)
        server.handler = { req in answering.withLock { $0 } ? ["id": req["id"]!, "result": [:]] : nil }
        try client.connect()
        #expect(server.waitForClient(timeout: 2))
        await timeOut(client)
        answering.withLock { $0 = true }
        _ = try await client.request(.sessionsMarkSeen, as: DaemonClient.Empty.self)
        answering.withLock { $0 = false }
        await timeOut(client)
        answering.withLock { $0 = true }
        _ = try await client.request(.sessionsMarkSeen, as: DaemonClient.Empty.self)
        #expect(!server.received.contains { $0["method"] as? String == DaemonClient.livenessCheck.rawValue })
    }

    @Test func snapshotAppearsInWireOrderAsAnEventBarrier() async throws {
        server.handler = { req in
            ["id": req["id"]!, "result": ["protocolVersion": 1, "connected": true, "sessions": [], "usage": ["claude": NSNull(), "codex": NSNull()]]]
        }
        try client.connect()
        #expect(server.waitForClient(timeout: 2))
        server.push(event: "session.closed", payload: ["sessionId": "old"])
        let snapshot = try await client.snapshot()
        server.push(event: "session.closed", payload: ["sessionId": "new"])
        let box = EventBox(client.events)
        guard case .event(let old) = await nextEvent(box) else { Issue.record("missing old event"); return }
        guard case .event(let barrier) = await nextEvent(box) else { Issue.record("missing barrier"); return }
        guard case .event(let new) = await nextEvent(box) else { Issue.record("missing new event"); return }
        #expect(old == .sessionClosed("old"))
        #expect(barrier == .snapshot(snapshot))
        #expect(new == .sessionClosed("new"))
    }

    @Test func eventOverflowEndsTheStreamSoTheOwnerCanResynchronize() async throws {
        try client.connect()
        #expect(server.waitForClient(timeout: 2))
        for index in 0..<600 { server.push(event: "session.closed", payload: ["sessionId": "s\(index)"]) }
        // Do not consume while the reader is still filling the bounded queue.
        // A request behind those frames provides a deterministic processing barrier.
        do { _ = try await client.request(.usageGet, as: DaemonClient.Empty.self); Issue.record("Expected overflow disconnect") }
        catch let error as DaemonError { #expect(error.code == .disconnected) }
        let box = EventBox(client.events)
        var received = 0
        while case .event(let event) = await nextEvent(box) {
            guard event != nil else { #expect(received == 512); #expect(client.ending == .dropped); return }
            received += 1
        }
        Issue.record("Overflow must finish the stream")
    }

    @Test func oversizedIncomingFrameDisconnects() async throws {
        try client.connect()
        #expect(server.waitForClient(timeout: 2))
        server.push(event: "unknown", payload: String(repeating: "x", count: (1 << 20) + 1))
        let box = EventBox(client.events)
        guard case .event(let end) = await nextEvent(box) else { Issue.record("Stream remained open"); return }
        #expect(end == nil)
        #expect(client.ending == .unreadable)
    }

    @Test func testConnectToMissingSocketThrows() {
        #expect(throws: (any Error).self) { try DaemonClient(socketPath: "/tmp/does-not-exist.sock").connect() }
    }
}
