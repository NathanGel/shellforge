// Ported from AiTerm (app/Tests/AiTermCoreTests/StatusLineShimTests.swift), GPLv3, Laurens D'Hondt.
// The shims themselves are run by the daemon's tests (daemon/tests/test_*statusline_shim.py).
import Foundation
import Testing
@testable import ShellforgeCore

@Suite struct ShimPortTests {
    /// Not the app's own, so a port the shim fell back to would show.
    static let port = 50123

    /// Only what `record` writes is the port recorded. Anything else in the file — a host, a path,
    /// the port with space around it — the shims refuse, or might, so the driver's probe calls
    /// that install outdated and a Repair writes the file again.
    @Test func onlyWhatRecordWritesIsTheRecordedPort() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("sf-shim-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try ShimPort.record(Self.port, home: home)
        #expect(ShimPort.isRecorded(Self.port, home: home))
        for written in ["1@127.0.0.1:\(Self.port)\n", " \(Self.port)\n", "\(Self.port)", "\(Self.port)\n\n"] {
            try Data(written.utf8).write(to: ShellforgePaths.hookPortURL(home: home))
            #expect(!ShimPort.isRecorded(Self.port, home: home), "\(written.debugDescription) is not the recorded port")
        }
    }
}
