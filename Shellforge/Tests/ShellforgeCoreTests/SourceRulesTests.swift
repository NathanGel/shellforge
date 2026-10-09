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

    /// Code taken from AiTerm is GPLv3 and keeps its author: every file that says it was ported
    /// names AiTerm and the file it came from, the licence and Laurens D'Hondt.
    @Test func everyPortedFileCreditsAiTerm() throws {
        let root = sources.deletingLastPathComponent()
        let files = ["Sources", "Tests"].flatMap { folder in
            (FileManager.default.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL } ?? []).filter { $0.pathExtension == "swift" }
        }
        // The header comment, however many lines it runs to.
        let wrong = try files.filter { file in
            let header = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
                .prefix { $0.hasPrefix("//") }.joined(separator: " ")
            guard header.contains("Ported from") else { return false }
            return !(header.contains("Ported from AiTerm (") && header.contains("GPLv3, Laurens D'Hondt."))
        }
        #expect(wrong.isEmpty, "Credit AiTerm as the other ported files do: \(wrong.map(\.lastPathComponent))")
    }

    /// Shellforge's own code is GPLv3 (it carries AiTerm's), so the licence's text ships with it; and
    /// artwork taken under another licence — a logo "MIT-licensed" in its comment — has its notice.
    @Test func theLicencesTheCodeNamesShipWithIt() throws {
        let root = sources.deletingLastPathComponent()
        let licence = try String(contentsOf: root.appendingPathComponent("LICENSE"), encoding: .utf8)
        #expect(licence.contains("GNU GENERAL PUBLIC LICENSE") && licence.contains("Version 3, 29 June 2007"))
        let notices = try String(contentsOf: root.appendingPathComponent("THIRD_PARTY_NOTICES.md"), encoding: .utf8)
        let logos = try String(contentsOf: sources.appendingPathComponent("ShellforgeDesign/Logos.swift"), encoding: .utf8)
        for source in ["LobeHub"] where logos.contains(source) {
            #expect(notices.contains(source) && notices.contains("MIT License"), "\(source)'s MIT notice is missing")
        }
    }
}
