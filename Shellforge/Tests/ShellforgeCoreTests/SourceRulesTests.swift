import Foundation
import Testing

/// Rules about the package's own source that a review would miss.
@Suite struct SourceRulesTests {
    private var sources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    /// A child started anywhere else would get the app's launchd environment, and the "uv not found"
    /// bug would be back. Every command goes through `CommandLauncher`, which ends in `ChildProcess`.
    @Test func onlyChildProcessCreatesAProcess() throws {
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        // `Process`, not `ChildProcess`: the name alone, followed by a call.
        let spawn = try Regex(#"(^|[^A-Za-z_])(Process\(\)|Process\.run\(|NSTask\b|posix_spawn)"#).anchorsMatchLineEndings()
        let offenders = try files.filter { $0.lastPathComponent != "ChildProcess.swift" }.filter { file in
            try String(contentsOf: file, encoding: .utf8).contains(spawn)
        }
        #expect(offenders.isEmpty, "Start children through CommandLauncher: \(offenders.map(\.lastPathComponent))")
    }
}
