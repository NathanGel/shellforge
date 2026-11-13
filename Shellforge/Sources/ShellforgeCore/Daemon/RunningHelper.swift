import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A helper already serving the socket, as the supervisor finds it before adopting it: its pid, as
/// the kernel gives it for the connection, and the protocol version its `workspace.snapshot` says.
public struct RunningHelper: Equatable, Sendable {
    public let pid: pid_t
    public let protocolVersion: Int

    public init(pid: pid_t, protocolVersion: Int) {
        self.pid = pid
        self.protocolVersion = protocolVersion
    }

    /// Whether this app should replace it: one older than this app's protocol has no pid check
    /// (protocol 2 and before), so a new app never adopts it.
    public var isOlder: Bool { protocolVersion < DaemonProtocol.version }

    /// Asks the helper at `socketPath` for its snapshot, once, with a short deadline. nil when
    /// nothing answers, the answer is not a snapshot, or the helper refuses it (one started by
    /// another app answers that app only): the caller then adopts it as before.
    public static func probe(socketPath: String, timeout: TimeInterval = 2) -> RunningHelper? {
        guard let address = try? UnixSocketAddress(path: socketPath) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var deadline = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - timeout.rounded(.down)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &deadline, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &deadline, socklen_t(MemoryLayout<timeval>.size))
        guard address.withSockaddr({ Darwin.connect(fd, $0, $1) }) == 0 else { return nil }
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid > 0 else { return nil }
        let request = Data("{\"id\":1,\"method\":\"workspace.snapshot\"}\n".utf8)
        let sent = request.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
        guard sent == request.count else { return nil }
        // The reply to request 1, skipping any event broadcast to this connection before it.
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let started = Date()
        while Date().timeIntervalSince(started) < timeout, buffer.count <= DaemonProtocol.maximumFrameBytes {
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<n])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = Data(buffer[buffer.index(after: newline)...])
                guard let reply = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      (reply["id"] as? Int) == 1 else { continue }
                guard let result = reply["result"] as? [String: Any],
                      let version = result["protocolVersion"] as? Int else { return nil }
                return RunningHelper(pid: pid, protocolVersion: version)
            }
        }
        return nil
    }
}
