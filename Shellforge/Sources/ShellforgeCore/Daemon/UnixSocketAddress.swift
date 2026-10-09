// Ported from AiTerm (Sources/AiTermCore/Daemon/UnixSocketAddress.swift), GPLv3, Laurens D'Hondt.
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A `sockaddr_un` built once, instead of the same zero-init-and-`strncpy` dance `DaemonClient`,
/// `SocketProbe` and the test harness's `FakeSocketServer` each used to repeat. `sun_path` is 104
/// bytes on Darwin, one of them the trailing NUL `strncpy` never writes itself, so a path of 104
/// bytes or more is rejected up front rather than silently truncated into some other socket's name.
struct UnixSocketAddress {
    private var raw = sockaddr_un()

    init(path: String) throws {
        guard path.utf8.count < 104 else { throw DaemonError(code: .socket, message: "Socket path is too long") }
        raw.sun_family = sa_family_t(AF_UNIX)
        _ = path.withCString { strncpy(&raw.sun_path.0, $0, 103) }
    }

    /// Hands `body` the `sockaddr *`/length pair `bind(2)` and `connect(2)` take, valid only for
    /// the call: the pointer is into a local copy that goes away when `body` returns.
    func withSockaddr<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) rethrows -> T {
        var copy = raw
        return try withUnsafePointer(to: &copy) {
            try body(UnsafeRawPointer($0).assumingMemoryBound(to: sockaddr.self), socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}
