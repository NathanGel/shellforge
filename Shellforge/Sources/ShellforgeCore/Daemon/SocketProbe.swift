// Ported from AiTerm (app/Sources/AiTermCore/Daemon/SocketProbe.swift), GPLv3, Laurens D'Hondt.
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Answers "is a daemon listening on this Unix socket right now?" — a bare `connect()`, with no
/// request sent and no reader thread started, so it is cheap enough to run on a timer.
public enum SocketProbe {
    public static func isLive(path: String) -> Bool {
        guard let address = try? UnixSocketAddress(path: path) else { return false }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        defer { Darwin.close(s) }
        return address.withSockaddr { Darwin.connect(s, $0, $1) } == 0
    }
}
