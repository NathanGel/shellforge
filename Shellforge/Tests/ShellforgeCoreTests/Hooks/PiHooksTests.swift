// Ported from AiTerm (app/Tests/AiTermCoreTests/PiDriverTests.swift), GPLv3, Laurens D'Hondt.
import Foundation
import Testing
@testable import ShellforgeTestSupport
@testable import ShellforgeCore

@Suite struct PiHooksTests {
    private func tempHome() throws -> URL {
        let home = TestScratch.root.appendingPathComponent("aiterm-pi-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func ownedSource(version: Int) -> String {
        "// Shellforge PI extension schema: \(version)\nexport default function shellforge() {}\n"
    }

    private var current: String { ownedSource(version: PiHooks.schemaVersion) }

    private let port = 47831

    private func driver(_ home: URL, port: Int? = nil, source: String? = nil) -> PiHooks {
        PiHooks(home: home, port: port ?? self.port, source: source ?? current)
    }

    private func url(_ home: URL) -> URL { home.appendingPathComponent(PiHooks.path) }

    @Test func piInstallerCreatesAndUpdatesOnlyOwnedFiles() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        #expect(driver(home).state == .missing)
        try driver(home).install()
        #expect(driver(home).state == .current)

        let url = url(home)
        try ownedSource(version: 0).write(to: url, atomically: true, encoding: .utf8)
        #expect(driver(home).state == .outdated)
        try driver(home).install()
        #expect(try String(contentsOf: url, encoding: .utf8) == current)
    }

    /// Schema 2 relays pi-subagents' background agents, so a schema-1 install reads as out of date
    /// and Settings offers to update it.
    @Test func aSchemaOneInstallIsOutdated() throws {
        #expect(PiHooks.state(of: ownedSource(version: 1), expected: nil) == .outdated)
    }

    /// Schema 5 sends the session's tokens with its subagents', so a schema-4 install reads as out of
    /// date and Settings offers to update it.
    @Test func aSchemaFourInstallIsOutdated() {
        #expect(PiHooks.state(of: ownedSource(version: 4), expected: nil) == .outdated)
    }

    /// Schema 3 forwards `session_start`'s reason and keeps the last ctx in `relay`, so a schema-2
    /// install reads as out of date and Repair (a plain reinstall) brings it to the current schema.
    @Test func aSchemaTwoInstallIsOutdatedAndRepairInstallsTheCurrentSchema() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = url(home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ownedSource(version: 2).write(to: url, atomically: true, encoding: .utf8)

        #expect(driver(home).state == .outdated)
        try driver(home).install()
        #expect(driver(home).state == .current)
        #expect(try String(contentsOf: url, encoding: .utf8) == current)
    }

    @Test func piInstallerRefusesForeignFileWithoutChangingIt() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = url(home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let foreign = "export default function mine() {}"
        try foreign.write(to: url, atomically: true, encoding: .utf8)

        #expect(driver(home).probe() == HookProbe(state: .foreign,
                                                    explanation: "A different file occupies ~/.pi/agent/extensions/shellforge-status.ts."))
        #expect(throws: HookInstallError.foreign(path: "~/.pi/agent/extensions/shellforge-status.ts")) { try driver(home).install() }
        #expect(try String(contentsOf: url, encoding: .utf8) == foreign)
    }

    @Test func malformedOwnedMarkerCanBeRepairedButUnreadableTargetCannot() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = url(home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "// Shellforge PI extension schema: broken\n".write(to: url, atomically: true, encoding: .utf8)

        #expect(driver(home).state == .invalidOwned)
        try driver(home).install()
        #expect(driver(home).state == .current)

        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        #expect(driver(home).state == .unreadable)
        #expect(throws: HookInstallError.refused(path: "~/.pi/agent/extensions/shellforge-status.ts", reason: "cannot be read")) {
            try driver(home).install()
        }
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func installerRejectsASourceWithoutTheCurrentOwnershipMarker() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        #expect(throws: HookInstallError.invalidSource) { try driver(home, source: ownedSource(version: 0)).install() }
        #expect(driver(home).state == .missing)
    }

    @Test func currentMarkerWithCorruptedBodyIsInvalidAgainstTheBundledSource() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = url(home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "// Shellforge PI extension schema: \(PiHooks.schemaVersion)\ntruncated\n".write(to: url, atomically: true, encoding: .utf8)

        #expect(driver(home).state == .invalidOwned)
    }

    /// A dotfiles-managed extension stays a link; the file it names is what gets written.
    @Test func aSymlinkedExtensionIsWrittenThroughAndStaysALink() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let link = url(home), elsewhere = home.appendingPathComponent("dotfiles/shellforge-status.ts")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: elsewhere.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ownedSource(version: 2).write(to: elsewhere, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)

        try driver(home).install()

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == elsewhere.path)
        #expect(try String(contentsOf: elsewhere, encoding: .utf8) == current)
        #expect(driver(home).state == .current)
    }

    @Test func aDanglingExtensionLinkIsUnreadableNotReplaced() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let link = url(home), missing = home.appendingPathComponent("dotfiles/gone.ts")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: missing)

        #expect(driver(home).state == .unreadable)
        #expect(throws: HookInstallError.self) { try driver(home).install() }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == missing.path)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    /// Schema 4 is written with the daemon's port, where the schema-3 file had it spelled out, so
    /// a schema-3 install reads as out of date: it still posts to the port it was written with,
    /// until Repair writes the daemon's.
    @Test func aSchemaThreeInstallIsOutdated() throws {
        #expect(PiHooks.state(of: ownedSource(version: 3), expected: nil) == .outdated)
    }

    /// The extension is installed with the daemon's port in place of its placeholder, and a file
    /// written for another port is outdated: Repair writes the daemon's, as for an older schema,
    /// where a file whose body was changed is broken.
    @Test func theExtensionIsWrittenWithTheDaemonsPort() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let source = "// Shellforge PI extension schema: \(PiHooks.schemaVersion)\nconst endpoint = \"http://127.0.0.1:\(PiHooks.portPlaceholder)/hook/pi\";\n"

        try driver(home, port: 50123, source: source).install()

        #expect(try String(contentsOf: url(home), encoding: .utf8)
                == "// Shellforge PI extension schema: \(PiHooks.schemaVersion)\nconst endpoint = \"http://127.0.0.1:50123/hook/pi\";\n")
        #expect(driver(home, port: 50123, source: source).state == .current)
        // The daemon moved to another port: the file no longer matches what Install writes.
        #expect(driver(home, port: 50124, source: source).state == .outdated)
        try Data("// Shellforge PI extension schema: \(PiHooks.schemaVersion)\nconst endpoint = \"http://evil:50123/hook/pi\";\n".utf8)
            .write(to: url(home))
        #expect(driver(home, port: 50124, source: source).state == .invalidOwned, "not a port but another host in its place")
        try driver(home, port: 50124, source: source).install()
        #expect(driver(home, port: 50124, source: source).state == .current)
        #expect(try String(contentsOf: url(home), encoding: .utf8).contains("127.0.0.1:50124/hook/pi"))
    }

    /// AiTerm's extension stays byte for byte; Shellforge's goes beside it.
    @Test func aitermsExtensionStaysBesideShellforges() throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let aiterm = home.appendingPathComponent(".pi/agent/extensions/aiterm-status.ts")
        try FileManager.default.createDirectory(at: aiterm.deletingLastPathComponent(), withIntermediateDirectories: true)
        let aitermText = "// AiTerm PI extension schema: 5\nexport default function aiterm() {}\n"
        try aitermText.write(to: aiterm, atomically: true, encoding: .utf8)
        try driver(home).install()
        #expect(driver(home).probe().state == .current)
        #expect(try String(contentsOf: aiterm, encoding: .utf8) == aitermText)
        #expect(FileManager.default.fileExists(atPath: url(home).path))
    }
}
