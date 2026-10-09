import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI

@MainActor @Suite struct AgentHooksModelTests {
    private func model() throws -> (AgentHooksModel, URL) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("sf-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let hooks = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("hooks")
        let integrations = HookIntegrations(home: home, resources: HookResources(folder: hooks, installationAllowed: true, unavailableReason: nil))
        return (AgentHooksModel(integrations: integrations, names: Dictionary(uniqueKeysWithValues: AgentPresets.all.map { ($0.id, $0.name) })), home)
    }

    @Test func rowsShowEachAgentsStateAndAnInstallTurnsItCurrent() async throws {
        let (model, _) = try model()
        await model.refresh()
        #expect(model.rows.map(\.name) == ["Claude Code", "Codex", "Grok Build", "PI"])
        #expect(model.rows.allSatisfy { $0.probe.state == .missing })
        await model.install("codex")
        #expect(model.rows.first { $0.id == "codex" }?.probe.state == .current)
        #expect(model.lastError == nil)
    }

    @Test func aRefusedInstallIsSaidAndTheRowKeepsItsState() async throws {
        let (model, home) = try model()
        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "[1, 2]".write(to: settings, atomically: true, encoding: .utf8)   // not an object: refused
        await model.refresh()
        await model.install("claude")
        #expect(model.lastError != nil)
        #expect(try String(contentsOf: settings, encoding: .utf8) == "[1, 2]")
    }

    /// AiTerm's rule for the footer: Claude's usage feed works only while Claude Code's status line
    /// is Shellforge's runnable shim — read from the status line itself, not from the hooks' state,
    /// so another tool taking the status line back while our hooks stay is a dead feed too.
    @Test func theClaudeFeedIsReadFromItsStatusLine() async throws {
        let (model, home) = try model()
        #expect(model.claudeStatusLineInstalled, "not checked yet counts as installed")
        await model.refresh()
        #expect(!model.claudeStatusLineInstalled, "nothing installed")
        await model.install("claude")
        #expect(model.claudeStatusLineInstalled)
        let settings = home.appendingPathComponent(".claude/settings.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        json["statusLine"] = ["type": "command", "command": "/usr/bin/true"]
        try JSONSerialization.data(withJSONObject: json).write(to: settings)
        await model.refresh()
        #expect(!model.claudeStatusLineInstalled, "our hooks stay, but the status line is another tool's")
    }
}
