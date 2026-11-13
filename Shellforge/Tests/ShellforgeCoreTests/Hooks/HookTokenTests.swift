import Foundation
import Testing
@testable import ShellforgeTestSupport
@testable import ShellforgeCore

/// S-V6/S-V11: the helper's token file, which the app reads or makes as the helper does
/// (`shellforged/hook_token.py`), and the hooks that carry it.
@Suite struct HookTokenTests {
    private func home() throws -> URL {
        let dir = TestScratch.root.appendingPathComponent("sf-token-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var hooksFolder: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("hooks")
    }

    private func mode(_ url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    @Test func theTokenIsMadeOnceWholeAndPrivate() throws {
        let support = ShellforgeSupport(folder: try home().appendingPathComponent("support"))
        #expect(HookToken.read(in: support) == nil)
        let token = try HookToken.readOrCreate(in: support)
        let url = HookToken.url(in: support)
        #expect(token.count == 64 && token.allSatisfy(\.isHexDigit))
        #expect(try Data(contentsOf: url) == Data("X-Shellforge-Token: \(token)\n".utf8))
        #expect(try mode(url) == 0o600)
        #expect(try HookToken.readOrCreate(in: support) == token)
        #expect(try FileManager.default.contentsOfDirectory(atPath: support.folder.path) == ["hook-token"])
    }

    @Test func aLinkInItsPlaceIsReplacedNotFollowed() throws {
        let root = try home()
        let support = ShellforgeSupport(folder: root.appendingPathComponent("support"))
        try FileManager.default.createDirectory(at: support.folder, withIntermediateDirectories: true)
        let elsewhere = root.appendingPathComponent("elsewhere")
        let planted = Data("X-Shellforge-Token: \(String(repeating: "a", count: 64))\n".utf8)
        try planted.write(to: elsewhere)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: elsewhere.path)
        try FileManager.default.createSymbolicLink(at: HookToken.url(in: support), withDestinationURL: elsewhere)
        #expect(HookToken.read(in: support) == nil)
        let token = try HookToken.readOrCreate(in: support)
        #expect(token != String(repeating: "a", count: 64))
        #expect(try FileManager.default.attributesOfItem(atPath: HookToken.url(in: support).path)[.type] as? FileAttributeType == .typeRegular)
        #expect(try Data(contentsOf: elsewhere) == planted)
    }

    @Test(arguments: [0o644, 0o600]) func aFileOthersCanReadOrThatHoldsNoTokenIsReplaced(_ mode: Int) throws {
        let support = ShellforgeSupport(folder: try home().appendingPathComponent("support"))
        try FileManager.default.createDirectory(at: support.folder, withIntermediateDirectories: true)
        let url = HookToken.url(in: support)
        let contents = mode == 0o644 ? "X-Shellforge-Token: \(String(repeating: "b", count: 64))\n" : "not a token\n"
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        #expect(HookToken.read(in: support) == nil)
        let token = try HookToken.readOrCreate(in: support)
        #expect(token != String(repeating: "b", count: 64) && HookToken.read(in: support) == token)
        #expect(try self.mode(url) == 0o600)
    }

    @Test func claudesHooksCarryTheTokenInAFileOnlyItsOwnerReads() throws {
        let home = try home()
        let hooks = HookIntegrations(home: home, resources: HookResources(folder: hooksFolder, installationAllowed: true, unavailableReason: nil))
        try hooks.install("claude")
        let token = try #require(HookToken.read(in: .default(home: home)))
        let settings = home.appendingPathComponent(".claude/settings.json")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        let stop = try #require(((object["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])
        #expect((stop.first?["headers"] as? [String: String])?["X-Shellforge-Token"] == token)
        #expect(try mode(settings) == 0o600)
        #expect(hooks.probe("claude").state == .current)
        #expect(!hooks.upgradeTokenlessInstalls())
    }

    @Test func curlCommandsReadTheTokenFromItsFileAndNeverNameIt() throws {
        let home = try home()
        let hooks = HookIntegrations(home: home, resources: HookResources(folder: hooksFolder, installationAllowed: true, unavailableReason: nil))
        try hooks.install("codex")
        try hooks.install("grok")
        let support = ShellforgeSupport.default(home: home)
        let token = try #require(HookToken.read(in: support))
        let file = HookToken.url(in: support).path
        let codex = try String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8)
        #expect(codex.contains("-H \"@\(file)\" "))
        // Only the MCP server's header holds the token itself, in a file made private.
        #expect(codex.components(separatedBy: token).count == 2)
        #expect(codex.contains("X-Shellforge-Token = \"\(token)\""))
        #expect(try mode(home.appendingPathComponent(".codex/config.toml")) == 0o600)
        let grok = try String(contentsOf: GrokHooksFile.url(home: home), encoding: .utf8)
        #expect(grok.contains(file) && !grok.contains(token))
        #expect(hooks.probe("codex").state == .current)
    }

    @Test func piReadsTheTokenFromTheFileOfThePortsFolder() throws {
        let home = try home()
        let hooks = HookIntegrations(home: home, resources: HookResources(folder: hooksFolder, installationAllowed: true, unavailableReason: nil))
        try hooks.install("pi")
        let text = try String(contentsOf: home.appendingPathComponent(PiHooks.path), encoding: .utf8)
        #expect(text.contains("const tokenFile = \(PiHooks.literal(HookToken.url(in: .default(home: home)).path));"))
        #expect(!text.contains("__SHELLFORGE_"))
        #expect(hooks.probe("pi").state == .current)
    }

    /// What an install wrote before hooks carried the token: Claude's and Codex's entries without
    /// it, schema 5 of the PI extension. Grok's hooks file without its status line is only partly
    /// Shellforge's install, so it is not rewritten unasked.
    private func writeTokenlessInstalls(home: URL, port: Int) throws {
        let shim = hooksFolder.appendingPathComponent("shellforge-claude-statusline.sh").path
        let support = ShellforgeSupport.default(home: home)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try ClaudeSettings.merge(nil, hookURL: "http://127.0.0.1:\(port)/hook/claude", shimPath: shim).0
            .write(to: home.appendingPathComponent(".claude/settings.json"))
        try ShimPort.record(port, in: support)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try CodexHookConfig.merge("model = \"gpt-5.6\"\n", hookURL: "http://127.0.0.1:\(port)")
            .write(to: home.appendingPathComponent(".codex/config.toml"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".pi/agent/extensions"), withIntermediateDirectories: true)
        try "// Shellforge PI extension schema: 5\nconst endpoint = \"http://127.0.0.1:\(port)/hook/pi\";\n"
            .write(to: home.appendingPathComponent(PiHooks.path), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: GrokHooksFile.url(home: home).deletingLastPathComponent(), withIntermediateDirectories: true)
        try GrokHooksFile.contents(port: port).write(to: GrokHooksFile.url(home: home))
    }

    @Test func launchRewritesTokenlessInstallsAndSaysWhileOneIsLeft() throws {
        let home = try home()
        try writeTokenlessInstalls(home: home, port: ShellforgeSupport.defaultHookPort)
        _ = try HookAuth.made(home: home)  // the helper made it at start
        let hooks = HookIntegrations(home: home, resources: HookResources(folder: hooksFolder, installationAllowed: true, unavailableReason: nil))
        #expect(hooks.agents.map { hooks.probe($0).state } == [.outdated, .outdated, .outdated, .outdated])
        let grokBefore = try Data(contentsOf: GrokHooksFile.url(home: home))

        #expect(hooks.upgradeTokenlessInstalls(), "Grok's hooks still post without the token")
        #expect(["claude", "codex", "pi"].map { hooks.probe($0).state } == [.current, .current, .current])
        #expect(try Data(contentsOf: GrokHooksFile.url(home: home)) == grokBefore)

        try hooks.install("grok")
        #expect(!hooks.upgradeTokenlessInstalls())
    }

    /// The agents' settings are global: a development build never rewrites the installed app's
    /// hooks, and those post to the installed app's port, not to its helper's.
    @Test func aDevelopmentBuildLeavesTheInstalledAppsHooksAlone() throws {
        let home = try home()
        try writeTokenlessInstalls(home: home, port: ShellforgeSupport.defaultHookPort)
        let settings = try Data(contentsOf: home.appendingPathComponent(".claude/settings.json"))
        let dev = ShellforgeSupport(folder: home.appendingPathComponent("Library/Application Support/shellforge-dev"), home: home)
        let hooks = HookIntegrations(home: home, support: dev,
                                     resources: HookResources(folder: hooksFolder, installationAllowed: true, unavailableReason: nil))
        #expect(!hooks.upgradeTokenlessInstalls())
        #expect(try Data(contentsOf: home.appendingPathComponent(".claude/settings.json")) == settings)
        #expect(HookToken.read(in: .default(home: home)) == nil, "nothing is made in the installed app's folder")
    }

    /// A port of another build, as a development build's install for itself leaves them, is that
    /// build's to rewrite: the installed app neither rewrites nor waits for it.
    @Test func hooksForAnotherPortAreNeitherRewrittenNorWaitedFor() throws {
        let home = try home()
        try writeTokenlessInstalls(home: home, port: 48_100)
        let codex = try String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8)
        let hooks = HookIntegrations(home: home, resources: HookResources(folder: hooksFolder, installationAllowed: true, unavailableReason: nil))
        #expect(!hooks.upgradeTokenlessInstalls())
        #expect(try String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8) == codex)
    }
}
