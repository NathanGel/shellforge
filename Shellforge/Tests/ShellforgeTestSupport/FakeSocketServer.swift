// Ported from AiTerm (Tests/AiTermTestSupport/FakeSocketServer.swift), GPLv3, Laurens D'Hondt.
import Foundation
#if canImport(Darwin)
import Darwin
#endif
import ShellforgeCore

/// Minimal Unix-socket JSON-lines server for tests. Replies to requests via `handler`; `push` sends an event.
///
/// Unchecked because what the accept loop shares with the test's thread is guarded by `lock`. The
/// listener is the loop's alone: it closes it, and until then the number cannot be handed to
/// another test's socket. `stop()` never touches it; it wakes the loop through a pipe instead.
final class FakeSocketServer: @unchecked Sendable {
    let path: String
    private let lock = NSLock()
    /// Set by `stop()`; a client the loop accepts after it is turned away.
    private var stopped = false
    /// The write end of the pipe that wakes the loop out of waiting for a client, by being closed.
    private var wake: Int32 = -1
    private var _client: Int32 = -1
    private var _received: [[String: Any]] = []
    private var _handler: @Sendable ([String: Any]) -> [String: Any]? = { req in ["id": req["id"]!, "result": ["echo": req["params"] ?? NSNull()]] }
    private let clientReady = DispatchSemaphore(value: 0)
    private let queue = DispatchQueue(label: "fake-server")
    /// Set from the test's own thread while the loop in `start()` reads it on the server's
    /// background thread; guarded by `lock` like every other property shared between the two.
    var handler: @Sendable ([String: Any]) -> [String: Any]? {
        get { lock.lock(); defer { lock.unlock() }; return _handler }
        set { lock.lock(); _handler = newValue; lock.unlock() }
    }
    var received: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return _received }

    init(path: String) { self.path = path }

    func start() {
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        unlink(path)
        // Core's `UnixSocketAddress` is not public. A test's socket path is always a short,
        // fixed-format temp path, so it needs none of the length check that type enforces.
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = path.withCString { strncpy(&address.sun_path.0, $0, 103) }
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        listen(listener, 1)
        var ends: [Int32] = [-1, -1]
        // Without the pipe `stop()` could not wake a loop still waiting for a client.
        precondition(pipe(&ends) == 0, "FakeSocketServer could not make its wake pipe")
        let readEnd = ends[0]
        lock.lock(); wake = ends[1]; lock.unlock()
        queue.async { [self] in
            // Waits for a client or for `stop()`, whichever comes first — even when `stop()` ran
            // before this block did — and only then lets the listener go. Closed by `stop()`, its
            // number could be another server's listener by the time this block calls `accept`.
            var waiting = [pollfd(fd: listener, events: Int16(POLLIN), revents: 0),
                           pollfd(fd: readEnd, events: Int16(POLLIN), revents: 0)]
            while poll(&waiting, 2, -1) < 0, errno == EINTR {}
            let c = waiting[1].revents == 0 && waiting[0].revents & Int16(POLLIN) != 0 ? accept(listener, nil, nil) : -1
            close(listener); close(readEnd)
            lock.lock()
            let accepted = c >= 0 && !stopped
            if accepted { _client = c }
            lock.unlock()
            guard accepted else { if c >= 0 { close(c) }; return }
            var noSigPipe: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            clientReady.signal()
            var buffer = Data(), chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(c, &chunk, chunk.count)
                if n <= 0 { break }
                buffer.append(chunk, count: n)
                while let nl = buffer.firstIndex(of: 10) {
                    let line = buffer[..<nl]; buffer.removeSubrange(...nl)
                    guard let req = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                    lock.lock(); _received.append(req); lock.unlock()
                    if let reply = handler(req) { send(reply) }
                }
            }
            // This thread owns the accepted descriptor: `stop()` only shuts it down, so closing it
            // here is the single close and no other test can be handed the recycled number while
            // this `read` is still blocked on it. Forget it before closing so a later `stop()`
            // cannot `shutdown()` a number the process has already reused.
            lock.lock(); if _client == c { _client = -1 }; lock.unlock()
            close(c)
        }
    }

    /// Blocks (up to `timeout`) until the background `accept()` has returned a connected client.
    /// Unix-domain `connect(2)` on the caller's side completes as soon as the kernel accepts the
    /// connection into the listen backlog — it does not wait for this server's `accept()` call to
    /// actually run. `push`/`send` can only write once `_client` exists, so a test that calls
    /// `push` immediately after `DaemonClient.connect()` races this thread's `accept()`; without
    /// this wait, that race can silently drop the event (see `send`'s `client >= 0` guard) and
    /// hang a test awaiting it forever. Tests must call this after `connect()` and before the
    /// first `push`.
    func waitForClient(timeout: TimeInterval) -> Bool {
        clientReady.wait(timeout: .now() + timeout) == .success
    }

    func push(event: String, payload: Any) { send(["event": event, "payload": payload]) }

    private func send(_ obj: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        data.append(10)
        lock.lock()
        let c = _client >= 0 ? dup(_client) : -1
        lock.unlock()
        guard c >= 0 else { return }
        defer { close(c) }
        data.withUnsafeBytes { raw in
            var sent = 0
            while sent < data.count {
                let count = write(c, raw.baseAddress! + sent, data.count - sent)
                if count <= 0 { break }
                sent += count
            }
        }
    }

    /// Idempotent: tests may stop the server explicitly and again from `deinit`. Neither socket
    /// is closed here — each is the loop's, which closes it (see `start`): a number freed while
    /// that loop can still `accept` or `read` on it would be another test's socket next, and the
    /// stale loop would take that test's client or swallow its bytes. The accepted client is shut
    /// down, and a loop still waiting for one is woken.
    func stop() {
        lock.lock()
        stopped = true
        let w = wake
        // Under the lock: the loop clears `_client` under it before it closes the client, so the
        // number is still this server's. Shut down after unlocking, it could be another test's.
        if _client >= 0 { shutdown(_client, SHUT_RDWR) }
        _client = -1; wake = -1
        lock.unlock()
        // Closing the write end is the wake: the loop's `poll` sees its read end hang up. A byte
        // written instead would raise SIGPIPE once the loop had closed that end after a client.
        if w >= 0 { close(w) }
        unlink(path)
    }
}
