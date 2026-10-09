// Ported from AiTerm (app/Tests/AiTermTestSupport/PythonSocketServer.swift), GPLv3, Laurens D'Hondt.
// Debug only: these record issues through swift-testing, whose macros a plain release build of the
// package (the library is built with it, though only tests use it) does not have.
#if DEBUG
import Testing
import Foundation
import ShellforgeCore

/// A Unix-socket server a test writes in Python, for one that must behave differently from one
/// connection to the next, send events on its own, or hold a socket open while the test looks away:
/// what `FakeSocketServer`, which serves a single client from a handler, does not do.
///
/// The script is handed the socket path as `sys.argv[1]` and `arguments` after it, and binds and
/// listens itself. `start` returns once it listens, so a client that connects first does not have
/// to retry. The socket file is no sign of that: it appears at `bind`, and a connect between that
/// and `listen` is refused. So the script runs after ``listenSays``, and the helper waits for the
/// line it prints.
///
/// On the main actor because `Process` reports its end through the run loop of the thread that
/// launched it: `waitUntilExit` in `stop()` waits on the thread it is called from, and one launched
/// from a pool thread's run loop, which nobody turns, never wakes it.
@MainActor
final class PythonSocketServer {
    let path: String
    private let process = Process()
    private let output = Pipe()
    /// What the reader has heard: the line ``listenSays`` prints, and the end of the output.
    private let heard = Locked((listening: false, ended: false))

    private init(script: String, arguments: [String]) {
        // Short and in /tmp: a socket path is limited to about a hundred bytes.
        path = "/tmp/at-\(UUID().uuidString.prefix(8)).sock"
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", Self.listenSays + script, path] + arguments
        process.standardError = FileHandle.nullDevice
        process.standardOutput = output
    }

    static func start(script: String, arguments: [String] = []) async throws -> PythonSocketServer {
        let server = PythonSocketServer(script: script, arguments: arguments)
        try server.process.run()
        server.readUntilListening()
        // Not `process.isRunning`: a script that listened and then ended at once can be gone before
        // its line is read. The output ends after the script does, so its end settles it.
        guard await eventually(describing: "the Python server to listen on \(server.path)", {
            server.heard.withLock { $0.listening || $0.ended }
        }), server.heard.withLock({ $0.listening }) else {
            server.stop()
            throw DidNotListen(path: server.path)
        }
        return server
    }

    struct DidNotListen: Error { let path: String }

    /// Run before the script: its sockets print ``listeningLine`` once they listen, which the
    /// script then need not do itself.
    private static let listenSays = """
import socket as _socket
class _SaysWhenListening(_socket.socket):
    def listen(self, *args):
        super().listen(*args)
        print('\(listeningLine)', flush=True)
_socket.socket = _SaysWhenListening

"""
    private nonisolated static let listeningLine = "aiterm-test-server-listening"

    /// Reads the script's output on a thread of its own until ``listenSays`` speaks, and then
    /// drains the rest until the script ends, so no later print fills the pipe.
    private func readUntilListening() {
        let reader = output.fileHandleForReading
        Thread { [self] in
            let line = Data((Self.listeningLine + "\n").utf8)
            var read = Data()
            while case let chunk = reader.availableData, !chunk.isEmpty {
                guard read.range(of: line) == nil else { continue }
                read.append(chunk)
                if read.range(of: line) != nil { heard.withLock { $0.listening = true } }
            }
            heard.withLock { $0.ended = true }
        }.start()
    }

    var isRunning: Bool { process.isRunning }

    /// Ends the script and removes its socket. Safe to call twice.
    func stop() {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        try? FileManager.default.removeItem(atPath: path)
    }
}
#endif
