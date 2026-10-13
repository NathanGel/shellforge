// Ported from AiTerm (app/Tests/AiTermCoreTests/GrokHooksFileTests.swift), GPLv3, Laurens D'Hondt.
import Foundation
import Testing
@testable import ShellforgeTestSupport
@testable import ShellforgeCore

@Suite struct GrokHooksFileTests {
    let port = 47831
    let shim = "/Applications/Shellforge.app/Contents/Resources/hooks/shellforge-grok-statusline.sh"

    func tempHome() throws -> URL {
        let home = TestScratch.root.appendingPathComponent("aiterm-grok-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    @Test func installWritesEveryEventAndIsCurrent() throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        #expect(GrokHooksFile.state(home: home, port: port) == .missing)
        try GrokHooks(home: home, port: port, shimPath: shim).install()
        #expect(GrokHooksFile.state(home: home, port: port) == .current)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: GrokHooksFile.url(home: home))) as? [String: Any])
        let hooks = try #require(object["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == ["SessionStart", "UserPromptSubmit", "Notification", "PostToolUse", "PostToolUseFailure",
                                    "Stop", "StopFailure", "StopCancelled"])
        let notification = try #require((hooks["Notification"] as? [[String: Any]])?.first)
        // A regular expression over the notification type (10-hooks.md): a waiting permission
        // prompt, and a finished turn gone idle.
        #expect(notification["matcher"] as? String == "permission_prompt|idle_prompt")
        let handler = try #require((notification["hooks"] as? [[String: Any]])?.first)
        #expect(handler["type"] as? String == "command" && handler["timeout"] as? Int == 5)
    }

    /// Current is what the file says, not how it is formatted: a change in Foundation's
    /// pretty-printing must not read every install as out of date, or make Install rewrite it.
    @Test func theSameHooksFormattedAnotherWayAreCurrent() throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let url = GrokHooksFile.url(home: home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let compact = try JSONSerialization.data(withJSONObject: GrokHooksFile.object(port: port))
        #expect(compact != GrokHooksFile.contents(port: port))
        try compact.write(to: url)

        #expect(GrokHooksFile.state(home: home, port: port) == .current)
        #expect(GrokHooksFile.state(home: home, port: 50000) == .outdated)
        try GrokHooks(home: home, port: port, shimPath: shim).install()
        #expect(try Data(contentsOf: url) == compact)
    }

    @Test func commandSilencesOutputAndAlwaysSucceeds() {
        // Grok reads Stop's stdout as a decision and exit 2 as "keep working".
        let command = GrokHooksFile.postCommand(port: port)
        #expect(command.hasSuffix(">/dev/null 2>&1; exit 0"))
        #expect(command.contains("http://127.0.0.1:47831/hook/grok"))
        #expect(command.contains("X-Shellforge-Hook: 1"))
    }

    @Test func commandNeverNamesABracedVariable() {
        // Grok refuses to run a hook whose `${VAR}` is unset; $ITERM_SESSION_ID is unset outside iTerm2.
        #expect(!GrokHooksFile.postCommand(port: port).contains("${"))
        #expect(GrokHooksFile.postCommand(port: port).contains("$ITERM_SESSION_ID"))
    }

    @Test func anotherPortIsOutdatedAndRepairs() throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        try GrokHooks(home: home, port: 50000, shimPath: shim).install()
        #expect(GrokHooksFile.state(home: home, port: port) == .outdated)
        try GrokHooks(home: home, port: port, shimPath: shim).install()
        #expect(GrokHooksFile.state(home: home, port: port) == .current)
    }

    @Test func refusesAForeignFile() throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let url = GrokHooksFile.url(home: home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let foreign = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#
        try foreign.write(to: url, atomically: true, encoding: .utf8)
        #expect(GrokHooksFile.state(home: home, port: port) == .foreign)
        #expect(throws: HookInstallError.foreign(path: "~/.grok/hooks/shellforge.json")) { try GrokHooks(home: home, port: port, shimPath: shim).install() }
        #expect(try String(contentsOf: url, encoding: .utf8) == foreign)
    }

    @Test func brokenOwnedFileIsInvalidOwnedAndRepairs() throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let url = GrokHooksFile.url(home: home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{ \"hooks\": X-Shellforge-Hook: 1 /hook/grok".write(to: url, atomically: true, encoding: .utf8)
        #expect(GrokHooksFile.state(home: home, port: port) == .invalidOwned)
        try GrokHooks(home: home, port: port, shimPath: shim).install()
        #expect(GrokHooksFile.state(home: home, port: port) == .current)
    }

    @Test func aDirectoryAtThePathIsUnreadable() throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: GrokHooksFile.url(home: home), withIntermediateDirectories: true)
        #expect(GrokHooksFile.state(home: home, port: port) == .unreadable)
    }

    @Test func symlinkedHooksFileWritesThroughAndTheLinkSurvives() throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let link = GrokHooksFile.url(home: home)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        let elsewhere = home.appendingPathComponent("dotfiles/grok-hooks.json")
        try FileManager.default.createDirectory(at: elsewhere.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A dotfiles-managed symlink whose target already exists — a previous, now-outdated
        // install — not a dangling link, so `install` must write through it.
        try GrokHooksFile.contents(port: 50000).write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)

        try GrokHooks(home: home, port: port, shimPath: shim).install()

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == elsewhere.path)
        #expect(try Data(contentsOf: elsewhere) == GrokHooksFile.contents(port: port))
        #expect(GrokHooksFile.state(home: home, port: port) == .current)
    }

    @Test func aDanglingSymlinkIsUnreadableNotReplaced() throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let link = GrokHooksFile.url(home: home)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        let missing = home.appendingPathComponent("nowhere/shellforge.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: missing)

        #expect(GrokHooksFile.state(home: home, port: port) == .unreadable)
        #expect(throws: HookInstallError.refused(path: "~/.grok/hooks/shellforge.json", reason: "links to \(missing.path), which does not exist")) { try GrokHooks(home: home, port: port, shimPath: shim).install() }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == missing.path)
    }
}
