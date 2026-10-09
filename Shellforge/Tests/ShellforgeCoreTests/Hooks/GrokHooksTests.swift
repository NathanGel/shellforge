// Ported from AiTerm (app/Tests/AiTermCoreTests/GrokDriverTests.swift), GPLv3, Laurens D'Hondt.
import Foundation
import Testing
@testable import ShellforgeCore

@Suite struct GrokHooksTests {
    let port = 47831
    let shim = "/Applications/Shellforge.app/Contents/Resources/hooks/shellforge-grok-statusline.sh"

    func tempHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-grok-drv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    func driver(_ home: URL) -> GrokHooks { GrokHooks(home: home, port: port, shimPath: shim) }

    @Test func installMakesItCurrent() throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        #expect(driver(home).state == .missing)
        try driver(home).install()
        let probe = driver(home).probe()
        #expect(probe.state == .current && probe.explanation == nil)
    }

    /// The shim posts to the port in `hook-port`: a status line that points at it is outdated until
    /// Install has recorded the daemon's, and a Repair of an otherwise current install does it.
    @Test func theShimsPortIsRecordedByInstallAndMissingOnesAreOutdated() throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        try driver(home).install()
        #expect(try String(contentsOf: ShellforgePaths.hookPortURL(home: home), encoding: .utf8) == "\(port)\n")

        try FileManager.default.removeItem(at: ShellforgePaths.hookPortURL(home: home))
        #expect(driver(home).state == .outdated)
        try driver(home).install()
        #expect(driver(home).state == .current)
        #expect(ShimPort.isRecorded(port, home: home))
    }

    @Test func hooksWithoutTheStatusLineAreOutdated() throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let url = GrokHooksFile.url(home: home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try GrokHooksFile.contents(port: port).write(to: url)
        #expect(driver(home).state == .outdated)
    }

    @Test func aBuiltinStatusLineIsCurrentWithAContextWarning() throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent(".grok/config.toml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "[ui.status_line]\ntype = \"builtin\"\n".write(to: config, atomically: true, encoding: .utf8)
        try driver(home).install()
        #expect(try String(contentsOf: config, encoding: .utf8) == "[ui.status_line]\ntype = \"builtin\"\n")
        let probe = driver(home).probe()
        #expect(probe.state == .current)
        #expect(probe.explanation == "Grok’s built-in status line is on, so Shellforge cannot read context.")
    }

    @Test func unreadableConfigLeavesHooksFileUnwritten() throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent(".grok/config.toml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0xFF, 0xFE, 0x00, 0x41]).write(to: config)
        #expect(throws: HookInstallError.refused(path: "~/.grok/config.toml", reason: "cannot be read as text")) {
            try driver(home).install()
        }
        #expect(!FileManager.default.fileExists(atPath: GrokHooksFile.url(home: home).path))
    }

    /// Install would only refuse, so a config it cannot read is the driver's state even while
    /// the hooks file still needs writing.
    @Test func anUnreadableConfigIsNotOfferedEvenWithTheHooksMissing() throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent(".grok/config.toml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0xFF, 0xFE, 0x00, 0x41]).write(to: config)
        #expect(driver(home).probe() == HookProbe(state: .unreadable, explanation: "~/.grok/config.toml cannot be read as text."))
    }

    @Test func aForeignHooksFileIsForeign() throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let url = GrokHooksFile.url(home: home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"hooks":{}}"#.write(to: url, atomically: true, encoding: .utf8)
        #expect(driver(home).probe() == HookProbe(state: .foreign, explanation: "A different file occupies ~/.grok/hooks/shellforge.json."))
        #expect(throws: HookInstallError.foreign(path: "~/.grok/hooks/shellforge.json")) { try driver(home).install() }
    }

    /// A link to nothing is not a missing config: an atomic write to it would replace the link
    /// with a regular file, cutting the config off from wherever the link was meant to lead.
    @Test func aDanglingConfigLinkIsUnreadableNotReplaced() throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let link = home.appendingPathComponent(".grok/config.toml")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        let missing = home.appendingPathComponent("dotfiles/grok.toml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: missing)

        let reason = "links to \(missing.path), which does not exist"
        #expect(driver(home).probe() == HookProbe(state: .unreadable, explanation: "~/.grok/config.toml \(reason)."))
        #expect(throws: HookInstallError.refused(path: "~/.grok/config.toml", reason: reason)) { try driver(home).install() }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == missing.path)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        #expect(!FileManager.default.fileExists(atPath: GrokHooksFile.url(home: home).path))
    }

    @Test func installSavesTheOriginalAndBacksUp() throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent(".grok/config.toml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "[ui.status_line]\ntype = \"command\"\ncommand = \"~/line.sh\"\n".write(to: config, atomically: true, encoding: .utf8)
        try driver(home).install()
        let original = ShellforgePaths.grokStatusLineOriginalURL(home: home)
        #expect(try String(contentsOf: original, encoding: .utf8) == "~/line.sh")
        #expect(FileManager.default.fileExists(atPath: config.path + ".shellforge-backup"))
        #expect(driver(home).state == .current)
    }

    @Test func repairDoesNotReviveARemovedStatusLine() throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent(".grok/config.toml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "[ui.status_line]\ntype = \"command\"\ncommand = \"~/line.sh\"\n".write(to: config, atomically: true, encoding: .utf8)
        try driver(home).install()
        let original = ShellforgePaths.grokStatusLineOriginalURL(home: home)
        #expect(try String(contentsOf: original, encoding: .utf8) == "~/line.sh")

        // The user turns the status line off (or deletes the table); repairing must not bring
        // the stale saved command back to life.
        try "[ui.status_line]\ntype = \"disabled\"\n".write(to: config, atomically: true, encoding: .utf8)
        try driver(home).install()
        #expect(!FileManager.default.fileExists(atPath: original.path))
    }

    @Test func repairOverAMovedBundleKeepsTheSavedOriginal() throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent(".grok/config.toml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "[ui.status_line]\ntype = \"command\"\ncommand = \"~/line.sh\"\n".write(to: config, atomically: true, encoding: .utf8)
        try driver(home).install()
        let original = ShellforgePaths.grokStatusLineOriginalURL(home: home)
        #expect(try String(contentsOf: original, encoding: .utf8) == "~/line.sh")

        // The bundle moved: config still names the old shim path, so the state is `.outdated`,
        // not `.missing` — the saved original must survive a repair of that.
        let movedShim = "/Users/me/Downloads/Shellforge.app/Contents/Resources/hooks/shellforge-grok-statusline.sh"
        try "[ui.status_line]\ntype = \"command\"\ncommand = \"\(movedShim)\"\n".write(to: config, atomically: true, encoding: .utf8)
        #expect(driver(home).state == .outdated)
        try driver(home).install()
        #expect(try String(contentsOf: original, encoding: .utf8) == "~/line.sh")
        #expect(driver(home).state == .current)
    }

    @Test func nonUTF8ConfigIsUnreadableAndNeverWritten() throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent(".grok/config.toml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data([0xFF, 0xFE, 0x00, 0x41])
        try bytes.write(to: config)
        #expect(driver(home).state == .unreadable)
        #expect(throws: HookInstallError.self) { try driver(home).install() }
        #expect(try Data(contentsOf: config) == bytes)
    }

    /// AiTerm's hooks file and its status-line shim stay; Shellforge's file goes beside them and its
    /// shim keeps AiTerm's as the original.
    @Test func aitermsHooksStayBesideShellforges() throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let aitermHooks = home.appendingPathComponent(".grok/hooks/aiterm.json")
        try FileManager.default.createDirectory(at: aitermHooks.deletingLastPathComponent(), withIntermediateDirectories: true)
        let aitermText = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"curl -H 'X-AiTerm-Hook: 1' http://127.0.0.1:47821/hook/grok"}]}]}}"#
        try aitermText.write(to: aitermHooks, atomically: true, encoding: .utf8)
        let aitermShim = "/Applications/AiTerm.app/Contents/Resources/hooks/grok-statusline-shim.sh"
        let config = home.appendingPathComponent(".grok/config.toml")
        try "[ui.status_line]\ntype = \"command\"\ncommand = \"\(aitermShim)\"\n".write(to: config, atomically: true, encoding: .utf8)
        let aitermRecord = home.appendingPathComponent("Library/Application Support/AiTerm/grok-statusline-original.cmd")
        try FileManager.default.createDirectory(at: aitermRecord.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "my-grok-line".write(to: aitermRecord, atomically: true, encoding: .utf8)
        let hooks = driver(home)
        try hooks.install()
        #expect(hooks.probe() == HookProbe(state: .current, explanation: nil))
        #expect(try String(contentsOf: aitermHooks, encoding: .utf8) == aitermText)
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".grok/hooks/shellforge.json").path))
        // The user's command, carried over from AiTerm's record; AiTerm's shim is not kept.
        #expect(try String(contentsOf: ShellforgePaths.grokStatusLineOriginalURL(home: home), encoding: .utf8) == "my-grok-line")
    }
}
