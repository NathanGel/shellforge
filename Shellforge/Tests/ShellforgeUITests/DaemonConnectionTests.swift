// Ported from AiTerm (app/Tests/AiTermTests/DaemonConnectionTests.swift), GPLv3, Laurens D'Hondt.
// Only the tests of the loop itself: iTerm2's background, reconnect, auth and cookie tests have no
// counterpart in app mode.
import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

@MainActor @Suite struct DaemonConnectionTests {
    @Test func socketLossReconnectsWhileServerStaysAliveAndStopEndsRetries() async throws {
        let server = try await PythonSocketServer.start(script: """
import socket,json,sys
s=socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1]);s.listen()
count=0
while True:
 c,_=s.accept();count+=1
 with c:
  f=c.makefile('rb')
  for line in f:
   m=json.loads(line)
   result={'protocolVersion':1,'connected':True,'sessions':[],'usage':{'claude':None,'codex':None}}
   c.sendall((json.dumps({'id':m['id'],'result':result})+'\\n').encode())
   if count==1: break
  f.close()
""")
        defer { server.stop() }
        var snapshots = 0, activeClients = 0
        // A 10 ms retry, so the reconnect is seen in a blink and the window below is several of them.
        let connection = DaemonConnection(socketPath: server.path, onClient: { if $0 != nil { activeClients += 1 } },
                                          onStatus: { _ in }, onEvent: { if case .snapshot = $0 { snapshots += 1 } },
                                          backoff: { _ in 0.01 })
        connection.start()
        connection.start() // idempotent: no second connection lifetime
        await eventually { snapshots >= 2 }
        #expect(snapshots >= 2)
        #expect(server.isRunning)
        connection.stop()
        let count = activeClients
        // Absence: ten retries' worth, in which a connection that outlived `stop()` would have reconnected.
        try await Task.sleep(for: .milliseconds(100))
        #expect(activeClients == count)
    }

    /// A snapshot this app's `Decodable`s cannot parse at all (as opposed to one carrying an
    /// unknown enum raw value, which decodes tolerantly) is a daemon this app cannot fully speak
    /// to — the same `.helperMismatch` as an explicit protocol-version refusal, not a retryable
    /// `.helperUnreachable`.
    @Test func aSnapshotDecodingFailureIsAMismatch() async throws {
        let server = try await PythonSocketServer.start(script: """
import json,socket,sys
s=socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1]);s.listen()
c,_=s.accept()
with c:
 f=c.makefile('rb')
 for line in f:
  m=json.loads(line)
  # No protocolVersion: a shape this app's Decodable cannot parse at all.
  result={'connected':True,'sessions':[],'usage':{'claude':None,'codex':None}}
  c.sendall((json.dumps({'id':m['id'],'result':result})+'\\n').encode())
""")
        defer { server.stop() }
        var states: [HelperStatus] = []
        let connection = DaemonConnection(socketPath: server.path, onClient: { _ in },
                                          onStatus: { if states.last != $0 { states.append($0) } }, onEvent: { _ in })
        connection.start()
        defer { connection.stop() }
        await eventually { !states.isEmpty }

        #expect(states.first == .helperMismatch, "a snapshot the app cannot decode must not be blamed on an unreachable helper, got \(states)")
    }

    /// A helper that sends an event this app knows but cannot read sends it again
    /// on every connection. That is a helper this app cannot speak to, as an unreadable snapshot
    /// is — not an unreachable one — and a connection that ends that soon after its snapshot does
    /// not earn a fresh backoff: the retries slow down rather than reconnecting once a second.
    @Test func aHelperWhoseEventsCannotBeReadIsAMismatchAndItsRetriesBackOff() async throws {
        let (attempts, states) = try await retries(steadyAfter: .seconds(5))
        #expect(Array(attempts.prefix(3)) == [0, 1, 2], "each short-lived connection climbs the backoff")
        #expect(states.contains(.helperMismatch), "got \(states)")
        #expect(!states.contains(.helperUnreachable), "a helper that answered is not unreachable, got \(states)")
    }

    /// A connection that held long enough is a helper that works: its end starts the backoff over.
    @Test func aConnectionThatHeldStartsTheBackoffOver() async throws {
        let (attempts, _) = try await retries(steadyAfter: .zero)
        #expect(Array(attempts.prefix(3)) == [0, 0, 0])
    }

    /// After a connection that ended as a mismatch, the next one's snapshot is not
    /// shown until that connection has held — each retry at a helper that will end the same way
    /// would otherwise flash "Connected" between two "from another version"s.
    @Test func aMismatchedHelperIsNotShownConnectedAgainUntilAConnectionHolds() async throws {
        let (_, states) = try await retries(steadyAfter: .seconds(5))
        #expect(states == [.connected, .helperMismatch], "got \(states)")
    }

    /// The connection after a mismatch that does hold is shown, once it has held.
    @Test func aConnectionThatHoldsAfterAMismatchIsShownOnceItHas() async throws {
        let (_, states) = try await retries(steadyAfter: .milliseconds(200), unreadableConnections: 1) { states in
            states.count >= 3
        }
        #expect(states == [.connected, .helperMismatch, .connected], "got \(states)")
    }

    /// The backoff's first attempts, and every status said, against a helper that answers each
    /// connection's snapshot and then, on the first `unreadableConnections` of them, sends a
    /// `session.changed` this app cannot read; by default every one does, and the wait is for
    /// three attempts.
    private func retries(steadyAfter: Duration, unreadableConnections: Int = .max,
                         until done: (_ states: [HelperStatus]) -> Bool = { _ in false })
        async throws -> (attempts: [Int], states: [HelperStatus]) {
        let server = try await PythonSocketServer.start(script: """
import json,socket,sys
s=socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1]);s.listen()
unreadable=int(sys.argv[2])
count=0
while True:
 c,_=s.accept();count+=1
 with c:
  f=c.makefile('rb')
  for line in f:
   m=json.loads(line)
   result={'protocolVersion':1,'connected':True,'sessions':[],'usage':{'claude':None,'codex':None}}
   c.sendall((json.dumps({'id':m['id'],'result':result})+'\\n').encode())
   # session.changed without the session it is about: a shape this app cannot read.
   if count<=unreadable: c.sendall((json.dumps({'event':'session.changed','payload':{'sessionId':'s1'}})+'\\n').encode())
  f.close()
""", arguments: [String(min(unreadableConnections, Int(Int32.max)))])
        defer { server.stop() }
        var states: [HelperStatus] = []
        let attempts = Attempts()
        let connection = DaemonConnection(socketPath: server.path, onClient: { _ in },
                                          onStatus: { if states.last != $0 { states.append($0) } }, onEvent: { _ in },
                                          backoff: { attempts.record($0); return 0.01 }, steadyAfter: steadyAfter)
        connection.start()
        defer { connection.stop() }
        await eventually { attempts.all.count >= 3 || done(states) }
        return (attempts.all, states)
    }

    /// The loop delivers nothing that came before its own snapshot: a daemon may broadcast between
    /// accepting the socket and answering, and those events are older than the snapshot. The fake
    /// writes its early event before the reply, so the order on the wire is fixed.
    @Test func eventsBeforeTheSnapshotAreNotDelivered() async throws {
        let server = try await PythonSocketServer.start(script: """
import json,socket,sys
s=socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1]);s.listen()
c,_=s.accept()
with c:
 f=c.makefile('rb')
 for line in f:
  m=json.loads(line)
  c.sendall((json.dumps({'event':'session.closed','payload':{'sessionId':'early'}})+'\\n').encode())
  result={'protocolVersion':1,'connected':True,'sessions':[],'usage':{'claude':None,'codex':None}}
  c.sendall((json.dumps({'id':m['id'],'result':result})+'\\n').encode())
  c.sendall((json.dumps({'event':'session.closed','payload':{'sessionId':'late'}})+'\\n').encode())
""")
        defer { server.stop() }
        var events: [DaemonEvent] = []
        let connection = DaemonConnection(socketPath: server.path, onClient: { _ in }, onStatus: { _ in }, onEvent: { events.append($0) })
        defer { connection.stop() }
        connection.start()
        #expect(await eventually { events.count >= 2 })
        try await Task.sleep(for: .milliseconds(100))
        guard events.count == 2, case .snapshot = events[0], case .sessionClosed("late") = events[1] else { Issue.record("got \(events)"); return }
    }
}

/// The backoff's attempts, as the connection asks for them from its retry loop.
private final class Attempts: Sendable {
    private let asked = Locked<[Int]>([])
    var all: [Int] { asked.withLock { $0 } }
    func record(_ attempt: Int) { asked.withLock { $0.append(attempt) } }
}
