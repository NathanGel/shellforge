// Ported from AiTerm (Tests/AiTermCoreTests/FakeSocketServerTests.swift), GPLv3, Laurens D'Hondt.
import Foundation
#if canImport(Darwin)
import Darwin
#endif
import Testing
@testable import ShellforgeCore
@testable import ShellforgeTestSupport

/// The helper every daemon-client test talks to. Tests run in parallel, and a descriptor a stopped
/// server let go is the next `socket()` anyone makes: its accept loop must never accept on it.
struct FakeSocketServerTests {
    /// One request over a plain socket: the reply's line, or why there was none.
    private func roundTrip(_ path: String, timeout: Int = 2) -> Result<String, Failure> {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(Failure("socket", errno)) }
        defer { close(fd) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var wait = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        let address = try! UnixSocketAddress(path: path)
        guard address.withSockaddr({ connect(fd, $0, $1) }) == 0 else { return .failure(Failure("connect", errno)) }
        let request = Array(#"{"id":1,"method":"m","params":{}}"#.utf8) + [10]
        guard write(fd, request, request.count) == request.count else { return .failure(Failure("write", errno)) }
        var reply = [UInt8](), byte: UInt8 = 0
        while true {
            let n = read(fd, &byte, 1)
            if n < 0 { return .failure(Failure("read", errno)) }
            if n == 0 || byte == 10 { break }
            reply.append(byte)
        }
        return .success(String(decoding: reply, as: UTF8.self))
    }

    struct Failure: Error, CustomStringConvertible {
        let step: String, code: Int32
        init(_ step: String, _ code: Int32) { self.step = step; self.code = code }
        var description: String { "\(step): \(String(cString: strerror(code)))" }
    }

    /// Two ways a stopped server reached a descriptor number it had let go, which by then was
    /// another server's: its loop, not yet at `accept`, took the next server's listener and
    /// answered that server's client with its own handler; and `stop()` shut down, after its lock,
    /// a client number its loop had just closed, ending another server's connection unanswered.
    @Test func aStoppedServerNeverReachesAnotherServersSockets() async {
        let rounds = 150, width = 8
        let failures = await withTaskGroup(of: [String].self) { group in
            for _ in 0..<width {
                group.addTask {
                    var failed: [String] = []
                    for _ in 0..<rounds {
                        let stale = FakeSocketServer(path: "/tmp/aiterm-fss-\(UUID().uuidString.prefix(8)).sock")
                        stale.start()
                        stale.stop()
                        let live = FakeSocketServer(path: "/tmp/aiterm-fss-\(UUID().uuidString.prefix(8)).sock")
                        live.handler = { req in ["id": req["id"]!, "result": ["from": "live"]] }
                        live.start()
                        let reply = roundTrip(live.path)
                        if (try? reply.get())?.contains(#""from":"live""#) != true || !live.waitForClient(timeout: 0) {
                            failed.append("\(reply)")
                        }
                        live.stop()
                    }
                    return failed
                }
            }
            return await group.reduce([], +)
        }
        #expect(failures.isEmpty, "\(failures.count) of \(rounds * width) clients were not answered by their own server: \(failures.prefix(3))")
    }
}
