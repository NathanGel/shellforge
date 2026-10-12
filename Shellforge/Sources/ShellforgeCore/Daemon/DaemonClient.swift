// Ported from AiTerm (app/Sources/AiTermCore/Daemon/DaemonClient.swift), GPLv3, Laurens D'Hondt.
import Foundation
import os

let daemonLog = Logger(subsystem: "io.github.nathangel.shellforge", category: "daemon")
#if canImport(Darwin)
import Darwin
#endif

/// Every mutable field is in `state`, so the compiler, not a convention, keeps each access under
/// its lock; the writer queue owns writes, and each reader exclusively closes its descriptor.
/// Streams are thread-safe.
public final class DaemonClient: Sendable {
    public let socketPath: String
    /// A request waiting for its reply. Its closures know the type the caller awaits, so the reader
    /// decodes the reply once, straight into that type, and resumes the caller with it.
    ///
    /// Its deadline is not held here or cancelled: a deadline that fires after its request has
    /// left `pending` finds nothing to time out, and ids are never reused.
    private struct Pending: Sendable {
        /// Decodes the reply line and resumes the caller. A reply that also stands for an event
        /// (`snapshot()`'s) hands it to `yield` first, so it takes its place in the stream in
        /// wire order, before the caller resumes.
        let answer: @Sendable (_ line: Data, _ decoder: JSONDecoder, _ yield: (DaemonEvent) -> Void) -> Void
        let fail: @Sendable (Error) -> Void
        let isLivenessCheck: Bool
    }
    /// The transport's mutable state, all of it under one lock. Whatever must happen because of a
    /// change (resuming a caller, finishing the stream, starting a reader) happens after the lock
    /// is released, with what `withLock` hands back.
    private struct State {
        var fd: Int32 = -1
        var nextId = 0
        /// Bumped by each `connect()` and `disconnect()`, so a reader can tell whether it is still
        /// the current connection's (see `readLoop`).
        var generation = 0
        var pending: [Int: Pending] = [:]
        /// Requests whose task was cancelled before they reached `pending`: `request` checks here
        /// before it registers one, and clears its id once the cancellation handler can no longer run.
        var cancelled: Set<Int> = []
        /// Requests that timed out since the last reply of any kind.
        var consecutiveTimeouts = 0
        /// Whether a liveness check is waiting for its reply, so a run of timeouts sends only one.
        /// Cleared by the check's reply, or by the disconnect that its silence leads to.
        var checkingLiveness = false
        var used = false
        /// `nil` once the stream has been finished: a stale reader's `yield` is then a no-op.
        var events: AsyncStream<DaemonEvent>.Continuation?
        /// Why the stream was finished: set by the disconnect that finished it, and never again.
        var ending: Ending?
    }
    private let state: Locked<State>
    /// A helper whose loop is stuck still has its process and its socket, so neither the supervisor
    /// nor the reader notices it. Timeouts alone do not show it: the helper answers each request on
    /// its own task, but window creation, placement and the snapshot each wait their turn on a lock
    /// held across iTerm2 calls, so with iTerm2 slow, requests queued behind one lock time out back
    /// to back from a helper that is fine. So two timeouts with no reply between them only prompt a
    /// liveness check (`livenessCheck`), and the connection is dropped only when that goes
    /// unanswered too.
    static let timeoutsBeforeLivenessCheck = 2
    /// `usage.get`: answered from what the helper holds, with no lock and no other process, so a
    /// helper whose loop runs answers it in one turn whatever else is waiting.
    static let livenessCheck = DaemonMethod.usageGet
    /// How long the liveness check is given. Its answer takes one turn of the helper's loop, so
    /// three seconds is a wide margin for a busy machine. The check goes out at the second timeout
    /// in a row, so a stuck helper is dropped this long after that: with requests overlapping, one
    /// request timeout and these few seconds after the first silence; with requests sent one after
    /// another, each waiting out its own timeout, about two request timeouts and these seconds.
    private let livenessTimeout: TimeInterval
    private let writer = DispatchQueue(label: "shellforge.socket-writer")
    private let requestTimeout: TimeInterval
    public let events: AsyncStream<DaemonEvent>
    /// Why `events` ended, once it has: its owner tells a helper this app cannot read from one
    /// that has gone away.
    public enum Ending: Equatable, Sendable {
        /// `disconnect()`: this app let it go.
        case closedHere
        /// The helper closed its end, or the socket failed under it.
        case closedByHelper
        /// A line this app could not read: no frame at all, one longer than a frame may be, or an
        /// event it knows in a shape it does not — what a helper of another version sends.
        case unreadable
        /// Events came faster than they were taken, and one was dropped.
        case dropped
        /// The helper went quiet and did not answer the liveness check.
        case unresponsive
        /// A request could not be written whole.
        case writeFailed
    }
    public var ending: Ending? { state.withLock { $0.ending } }

    public init(socketPath: String, requestTimeout: TimeInterval = 15, livenessTimeout: TimeInterval = 3) {
        self.socketPath = socketPath
        self.requestTimeout = requestTimeout
        self.livenessTimeout = livenessTimeout
        let stream = AsyncStream<DaemonEvent>.makeStream(bufferingPolicy: .bufferingOldest(512))
        self.events = stream.stream
        self.state = Locked(State(events: stream.continuation))
    }

    public func connect() throws {
        let firstUse = state.withLock { state in
            let first = !state.used
            state.used = true
            return first
        }
        guard firstUse else { throw DaemonError(code: .connectionUsed, message: "Create a new client to reconnect") }
        let address = try UnixSocketAddress(path: socketPath)
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { throw DaemonError(code: .socket, message: String(cString: strerror(errno))) }
        // Without this, writing to a daemon that has gone away raises SIGPIPE, whose default
        // disposition kills the whole app. With it, `writeAll` simply sees EPIPE and reports it.
        var noSigPipe: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var sendTimeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
        let flags = fcntl(s, F_GETFL)
        _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)
        var rc = address.withSockaddr { Darwin.connect(s, $0, $1) }
        if rc != 0, errno == EINPROGRESS {
            var descriptor = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&descriptor, 1, 2_000)
            var error: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            if ready > 0, getsockopt(s, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 { rc = 0 }
            else { errno = ready == 0 ? ETIMEDOUT : (error == 0 ? errno : error) }
        }
        guard rc == 0 else { let e = errno; Darwin.close(s); throw DaemonError(code: .connect, message: String(cString: strerror(e))) }
        _ = fcntl(s, F_SETFL, flags)
        let generation: Int? = state.withLock { state in
            guard state.events != nil else { return nil }
            state.generation += 1; state.fd = s
            return state.generation
        }
        guard let generation else {
            Darwin.close(s)
            throw DaemonError(code: .disconnected, message: "Connection was canceled")
        }
        Thread(block: { self.readLoop(fd: s, generation: generation) }).start()
    }

    /// Tears the connection down and **ends** `events`: the continuation is taken out of `state`
    /// and finished exactly once, so a consumer's `for await` over `events` returns instead
    /// of hanging forever on a client that is never coming back. Taking it (rather than only
    /// finishing it) also makes later `yield`s from a stale `readLoop` no-ops, which is the same
    /// guarantee the `generation` bump gives the socket side. A client is single-use once
    /// disconnected: reconnecting it would not revive the stream, so callers make a new client.
    public func disconnect() { disconnect(because: .closedHere) }

    /// `disconnect()`, saying why: the first disconnect, the one that finishes the stream, is
    /// what `ending` says.
    private func disconnect(because reason: Ending) {
        let (waiting, continuation) = state.withLock { state in
            let f = state.fd; state.fd = -1; state.generation += 1
            let waiting = state.pending; state.pending = [:]; state.checkingLiveness = false
            let continuation = state.events; state.events = nil
            if continuation != nil { state.ending = reason }
            // The reader takes this lock before closing: shutdown must happen before
            // it can release the descriptor number for another socket to reuse.
            if f >= 0 { shutdown(f, SHUT_RDWR) }
            return (waiting, continuation)
        }
        // Shut the socket down but do NOT close it here: `readLoop` may be blocked in `read(f)`,
        // and closing the descriptor out from under it would free the number for immediate reuse
        // by another `connect()` in this process — the blocked reader would then consume bytes
        // belonging to a brand-new connection. `shutdown` makes the pending `read` return 0, and
        // the reader closes its own descriptor on the way out.
        waiting.values.forEach { $0.fail(DaemonError(code: .disconnected, message: "helper connection closed")) }
        continuation?.finish()
    }

    /// Reads newline-delimited JSON off `fd` until EOF/error. `generation` is the value captured
    /// at `connect()` time for this specific connection: once `fd` is closed, its integer can be
    /// reused immediately by a later `connect()`, so a blocked `read()` on the stale value could
    /// otherwise observe bytes from — and then tear down — a brand-new connection. Comparing
    /// against the live `state.generation` after the loop exits ensures this reader only tears
    /// things down when it is still the current connection; if a newer `connect()`/`disconnect()`
    /// has already superseded it, that call owns the cleanup.
    private func readLoop(fd: Int32, generation: Int) {
        let decoder = JSONDecoder()
        var buffer = Data(), chunk = [UInt8](repeating: 0, count: 65536)
        // The bytes at the front of `buffer` already searched for a newline: only what a read adds
        // is searched, so a large frame arriving in pieces is not rescanned from its start each time.
        var searched = 0
        var ending = Ending.closedByHelper
        reading: while true {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 {
                if errno == EINTR { continue }
                break
            }
            if n == 0 { break }
            buffer.append(chunk, count: n)
            var lineStart = buffer.startIndex
            var searchFrom = buffer.startIndex + searched
            while let nl = buffer[searchFrom...].firstIndex(of: 10) {
                let line = buffer[lineStart..<nl]
                let header: Header
                do {
                    guard line.count <= DaemonProtocol.maximumFrameBytes else { throw FrameTooLong() }
                    header = try decoder.decode(Header.self, from: line)
                } catch {
                    Self.logUnreadable("line", error)
                    ending = .unreadable
                    break reading
                }
                dispatch(header, line: line, decoder: decoder)
                lineStart = nl + 1; searchFrom = lineStart
            }
            // Once per read rather than per line: only an unfinished line is carried over.
            buffer.removeSubrange(buffer.startIndex..<lineStart)
            searched = buffer.count
            if buffer.count > DaemonProtocol.maximumFrameBytes {
                Self.logUnreadable("line", FrameTooLong())
                ending = .unreadable
                break
            }
        }
        // This thread is the sole owner of `fd` (the parameter): `connect()` handed it over and
        // `disconnect()` only shuts it down, so the close below is the one and only close. Clear
        // `state.fd` first, under the lock, so a `disconnect()` arriving after the close cannot
        // `shutdown()` a descriptor number the process has already handed to someone else.
        let stillCurrent = state.withLock { state in
            guard generation == state.generation else { return false }
            state.fd = -1
            return true
        }
        Darwin.close(fd)
        // The stream ending *is* the signal: yielding a synthetic `.itermDisconnected` here blamed
        // iTerm2 for the daemon itself having died (the banner read "Reconnecting to iTerm2…" for a
        // helper that was simply gone). `DaemonConnection` already treats an `events` stream that
        // ends without cancellation as `.helperUnreachable`.
        guard stillCurrent else { return }
        disconnect(because: ending)
    }

    private struct FrameTooLong: Error, CustomStringConvertible {
        var description: String { "longer than \(DaemonProtocol.maximumFrameBytes) bytes" }
    }

    private func dispatch(_ header: Header, line: Data, decoder: JSONDecoder) {
        if let id = header.id {
            let request = state.withLock { state in
                state.consecutiveTimeouts = 0 // even a late reply is a helper that answers
                let request = state.pending.removeValue(forKey: id)
                // Read by this thread before the check's caller resumes, so the next run of
                // timeouts can always send its own check.
                if request?.isLivenessCheck == true { state.checkingLiveness = false }
                return request
            }
            guard let request else { return }
            if let error = header.error { request.fail(DaemonError(code: error.code, message: error.message)); return }
            request.answer(line, decoder, yield)
            return
        }
        guard let name = header.event else { return }
        do { yield(try Self.decodeEvent(name, from: line, using: decoder)) }
        catch {
            // What the event was about is left as it was, and stays so until a snapshot, which
            // only a connection's start brings: drop this one, as for a dropped event, and let
            // its owner reconnect to a fresh snapshot.
            Self.logUnreadable("\(name) event", error)
            disconnect(because: .unreadable)
        }
    }

    /// Read under the lock, so a reader thread cannot see the continuation while `disconnect()` is
    /// taking it away.
    private func yield(_ event: DaemonEvent) {
        if case .dropped = state.withLock({ $0.events })?.yield(event) {
            // An incomplete event history is not trustworthy. Reconnect to a fresh snapshot.
            disconnect(because: .dropped)
        }
    }

    /// The event a line names, decoded from its bytes. An event this app does not know is a newer
    /// helper's and is passed on as `.unknown`; one it knows but cannot read throws.
    static func decodeEvent(_ name: String, from line: Data, using decoder: JSONDecoder = JSONDecoder()) throws -> DaemonEvent {
        struct SessionId: Decodable { var sessionId: String }
        func payload<P: Decodable>(_: P.Type) throws -> P {
            let event = try decoder.decode(EventPayload<P>.self, from: line)
            return event.payload
        }
        guard let known = DaemonEventName(rawValue: name) else { return .unknown(name) }
        switch known {
        case .sessionOpened: return .sessionOpened(try payload(SessionInfo.self))
        case .sessionChanged: return .sessionChanged(try payload(SessionInfo.self))
        case .sessionClosed: return .sessionClosed(try payload(SessionId.self).sessionId)
        case .usageChanged: return .usageChanged(try payload(UsageSnapshot.self))
        case .tunnelChanged: return .tunnelChanged(try payload(TunnelInfo.self))
        }
    }

    /// When each event, or a line that is none, was last logged as unreadable. A helper that sends
    /// a shape this app cannot read sends it every time it sends that event, and each time this
    /// client reconnects to it, so each one's failure is logged at most once a minute.
    private static let unreadableLogged = Locked<[String: ContinuousClock.Instant]>([:])

    private static func logUnreadable(_ name: String, _ error: Error) {
        let now = ContinuousClock.now
        let due = unreadableLogged.withLock { logged in
            if let last = logged[name], now - last < .seconds(60) { return false }
            logged[name] = now
            return true
        }
        guard due else { return }
        daemonLog.error("Unreadable \(name, privacy: .public) from the helper, so reconnecting to a fresh snapshot (logged at most once a minute): \(String(describing: error), privacy: .public)")
    }

    private func allocateID() -> Int {
        state.withLock { state in
            state.nextId += 1
            return state.nextId
        }
    }

    private func failRequest(_ id: Int, error: Error) {
        state.withLock { $0.pending.removeValue(forKey: id) }?.fail(error)
    }

    private func timedOut(_ id: Int, method: DaemonMethod, isLivenessCheck: Bool) {
        let (entry, check) = state.withLock { state in
            let entry = state.pending.removeValue(forKey: id)
            guard entry != nil, !isLivenessCheck else { return (entry, false) }
            state.consecutiveTimeouts += 1
            let check = state.consecutiveTimeouts >= Self.timeoutsBeforeLivenessCheck && !state.checkingLiveness
            if check { state.checkingLiveness = true }
            return (entry, check)
        }
        entry?.fail(DaemonError(code: .timeout, message: "\(method.rawValue) timed out; its outcome may need reconciliation"))
        if check { Task { await self.checkLiveness() } }
    }

    /// Asks a helper that has gone quiet whether its loop still runs, and drops the connection if
    /// it does not answer: its owner then reconnects to it, or reports it unreachable. Any answer,
    /// an error included, is a helper that is there; the reply itself resets `consecutiveTimeouts`
    /// and clears `checkingLiveness`, as the disconnect does otherwise. A check that never got as
    /// far as `pending` is on a client already disconnected.
    private func checkLiveness() async {
        do { _ = try await request(Self.livenessCheck, params: Optional<NoParams>.none, as: Empty.self, ordered: nil, isLivenessCheck: true) }
        catch let error as DaemonError where error.code == .timeout { disconnect(because: .unresponsive) }
        catch {}
    }

    /// A reply's `result`, decoded from its line. `Empty` asks for nothing, so nothing is read: a
    /// helper may answer it with `{}`, `null` or no result at all.
    static func result<R: Decodable>(_: R.Type, from line: Data, using decoder: JSONDecoder) throws -> R {
        if let empty = Empty() as? R { return empty }
        return try decoder.decode(Reply<R>.self, from: line).result
    }

    /// The wire shape of a request: `params` is only ever present for the concrete `P` a call site
    /// hands it, so it is encoded as that type, with no untyped value in between.
    private struct Envelope<P: Encodable>: Encodable {
        let id: Int, method: String, params: P?
        private enum CodingKeys: String, CodingKey { case id, method, params }
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(method, forKey: .method)
            try container.encodeIfPresent(params, forKey: .params) // omit the key entirely, not `null`
        }
    }
    private struct NoParams: Encodable {}

    public func request<R: Decodable & Sendable>(_ method: DaemonMethod, as type: R.Type) async throws -> R {
        try await request(method, params: Optional<NoParams>.none, as: type, ordered: nil, isLivenessCheck: false)
    }

    public func request<P: Encodable, R: Decodable & Sendable>(_ method: DaemonMethod, params: P, as type: R.Type) async throws -> R {
        try await request(method, params: Optional(params), as: type, ordered: nil, isLivenessCheck: false)
    }

    /// `ordered` makes the reply an event too, yielded from the reader thread in its place among
    /// the events around it. A liveness check has its own, shorter timeout, which is not counted
    /// as the helper going quiet again.
    private func request<P: Encodable, R: Decodable & Sendable>(_ method: DaemonMethod, params: P?, as type: R.Type,
                                                                ordered: (@Sendable (R) -> DaemonEvent)?,
                                                                isLivenessCheck: Bool) async throws -> R {
        try Task.checkCancellation()
        let id = allocateID()
        // Once `withTaskCancellationHandler` returns, its handler has run or never will.
        defer { state.withLock { _ = $0.cancelled.remove(id) } }
        var encoded = try JSONEncoder().encode(Envelope(id: id, method: method.rawValue, params: params))
        encoded.append(10)
        let data = encoded
        guard data.count <= DaemonProtocol.maximumFrameBytes else {
            throw Self.logged(DaemonError(code: .protocol, message: "Request exceeds frame limit"), method)
        }
        do { return try await exchange(id: id, method: method, data: data, as: type, ordered: ordered, isLivenessCheck: isLivenessCheck) }
        catch let error as DaemonError { throw Self.logged(error, method) }
        catch let error as DecodingError {
            // A reply this app cannot read: the caller says only that the request failed.
            daemonLog.error("\(method.rawValue, privacy: .public)'s reply could not be read: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// Every request that fails, with the helper's own words, which the person never reads
    /// (`DaemonError.userMessage`). A window or tab already gone is routine — closed since the
    /// last poll — and only an info line.
    private static func logged(_ error: DaemonError, _ method: DaemonMethod) -> DaemonError {
        daemonLog.log(level: error.isNotFound ? .info : .error,
                       "\(method.rawValue, privacy: .public) failed, \(error.code.rawValue, privacy: .public): \(error.message, privacy: .public)")
        return error
    }

    /// One request sent and its reply awaited: registered in `pending`, timed, written, and
    /// withdrawn if its task is cancelled.
    private func exchange<R: Decodable & Sendable>(id: Int, method: DaemonMethod, data: Data, as type: R.Type,
                                                   ordered: (@Sendable (R) -> DaemonEvent)?, isLivenessCheck: Bool) async throws -> R {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<R, Error>) in
                let request = Pending(answer: { line, decoder, yield in
                    do {
                        let value = try Self.result(R.self, from: line, using: decoder)
                        if let ordered { yield(ordered(value)) }
                        cont.resume(returning: value)
                    } catch { cont.resume(throwing: error) }
                }, fail: { cont.resume(throwing: $0) }, isLivenessCheck: isLivenessCheck)
                let refusal: Error? = state.withLock { state in
                    if state.cancelled.contains(id) { return CancellationError() }
                    guard state.fd >= 0 else { return DaemonError(code: .disconnected, message: "not connected") }
                    state.pending[id] = request
                    return nil
                }
                if let refusal { cont.resume(throwing: refusal); return }
                DispatchQueue.global().asyncAfter(deadline: .now() + (isLivenessCheck ? livenessTimeout : requestTimeout)) { [weak self] in
                    self?.timedOut(id, method: method, isLivenessCheck: isLivenessCheck)
                }
                writer.async { [self] in
                    // dup keeps this descriptor alive even if the reader exits during a write.
                    let socket = state.withLock { $0.pending[id] != nil && $0.fd >= 0 ? dup($0.fd) : -1 }
                    guard socket >= 0 else {
                        failRequest(id, error: DaemonError(code: .disconnected, message: "not connected")); return
                    }
                    defer { Darwin.close(socket) }
                    if let error = Self.writeAll(fd: socket, data: data) {
                        failRequest(id, error: error)
                        disconnect(because: .writeFailed) // a partial JSON frame cannot safely be followed by another
                    }
                }
            }
        } onCancel: {
            // Not yet in `pending` is not yet registered: the registration sees `cancelled` instead.
            self.state.withLock { _ = $0.cancelled.insert(id) }
            self.failRequest(id, error: CancellationError())
        }
    }

    /// Writes every byte of `data` to `fd`, retrying on `EINTR` and looping past short
    /// writes, so a partial `write(2)` never silently truncates a request line (which would leave
    /// the daemon waiting on a malformed frame and the caller awaiting forever). Returns the
    /// failure as a `DaemonError`, or `nil` once everything has been written.
    private static func writeAll(fd: Int32, data: Data) -> DaemonError? {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> DaemonError? in
            guard let base = raw.baseAddress else { return nil }
            var offset = 0
            while offset < data.count {
                let n = write(fd, base + offset, data.count - offset)
                if n > 0 { offset += n; continue }
                if n < 0, errno == EINTR { continue }
                return DaemonError(code: .write, message: n < 0 ? String(cString: strerror(errno)) : "short write")
            }
            return nil
        }
    }

    // -- typed helpers -----------------------------------------------------------------
    public struct Empty: Decodable, Sendable { public init() {} }
    struct ChangedResult: Decodable { var changed: Int }
    struct TaskParams: Encodable { var taskId: String }
    struct SessionsParams: Encodable { var sessions: [SessionReport] }
    struct TunnelStartParams: Encodable { var alias: String, environment: [String: String], keepRunning: Bool }
    struct TunnelParams: Encodable { var alias: String }
    struct TunnelHoldParams: Encodable { var alias: String, port: Int }
    struct OkResult: Decodable { var ok: Bool }

    /// The daemon's state, which is also yielded as `.snapshot` in the event stream: the daemon
    /// writes it with no pause after reading its state, so it is a barrier between the events
    /// before it and those after.
    public func snapshot() async throws -> DaemonSnapshot {
        let snapshot = try await request(.workspaceSnapshot, params: Optional<NoParams>.none, as: DaemonSnapshot.self,
                                         ordered: { .snapshot($0) }, isLivenessCheck: false)
        guard snapshot.protocolVersion == DaemonProtocol.version else {
            throw Self.logged(DaemonError(code: .incompatible, message: "The helper speaks protocol \(snapshot.protocolVersion), this app \(DaemonProtocol.version)"),
                              .workspaceSnapshot)
        }
        return snapshot
    }
    public func markSeen(task: UUID) async throws -> Int { try await request(.sessionsMarkSeen, params: TaskParams(taskId: Self.wireId(task)), as: ChangedResult.self).changed }

    /// A task or project id as the daemon matches it: lowercase, as the sidebar's session tags are.
    static func wireId(_ id: UUID) -> String { id.uuidString.lowercased() }
    /// The app's tabs, replacing the daemon's last list; returns once the daemon has read them.
    public func updateSessions(_ reports: [SessionReport]) async throws {
        _ = try await request(.sessionsUpdate, params: SessionsParams(sessions: reports), as: Empty.self)
    }

    /// Starts the `~/.ssh/config` host `alias` as a tunnel, run with `environment` — the app's login
    /// shell's, which the daemon, started from launchd's, does not have.
    public func startTunnel(alias: String, environment: [String: String], keepRunning: Bool = false) async throws {
        _ = try await request(.tunnelsStart, params: TunnelStartParams(alias: alias, environment: environment, keepRunning: keepRunning),
                              as: OkResult.self)
    }

    /// The app opened `alias` in a tab for the user to answer ssh: the daemon watches `port`, its
    /// first local forward, and hands it back to supervision when the tab's ssh ends.
    public func holdTunnel(alias: String, port: Int) async throws {
        _ = try await request(.tunnelsHold, params: TunnelHoldParams(alias: alias, port: port), as: OkResult.self)
    }

    public func stopTunnel(alias: String) async throws {
        _ = try await request(.tunnelsStop, params: TunnelParams(alias: alias), as: OkResult.self)
    }
}
