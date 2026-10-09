import Foundation
import Testing
@testable import ShellforgeCore

@Suite struct AgentRegistryTests {
    /// A fresh `agents/` folder, and a trash that records what was put in it instead of touching
    /// the user's real Trash.
    private final class Fixture: @unchecked Sendable {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shellforge-agents-\(UUID().uuidString)")
        var trashed: [URL] = []
        lazy var registry = AgentRegistry(folder: folder, trash: { [unowned self] url in
            trashed.append(url)
            try FileManager.default.removeItem(at: url)
        })
    }

    private let aider = AgentDefinition(id: "aider-local", name: "Aider (local)", command: "aider",
                                        arguments: [["--model", "ollama_chat/{model}"]], models: .fixed(["qwen3-coder"]))

    @Test func withNothingSavedTheFourPresetsAreOffered() throws {
        #expect(try Fixture().registry.load().agents.map(\.id) == ["claude", "codex", "grok", "pi"])
    }

    @Test func aSavedAgentIsOfferedAfterThePresetsAsItsOwnFile() throws {
        let fixture = Fixture()
        try fixture.registry.save(aider)
        #expect(FileManager.default.fileExists(atPath: fixture.folder.appendingPathComponent("aider-local.json").path))
        #expect(try fixture.registry.load().agents == AgentPresets.all + [aider])
    }

    @Test func savingWithAPresetsIdReplacesThatPreset() throws {
        let fixture = Fixture()
        var claude = AgentPresets.claude
        claude.command = "/opt/claude/bin/claude"
        try fixture.registry.save(claude)
        #expect(try fixture.registry.load().agents.first == claude)
    }

    @Test func removingAnAgentMovesItsFileToTheTrash() throws {
        let fixture = Fixture()
        try fixture.registry.save(aider)
        try fixture.registry.remove(id: "aider-local")
        #expect(fixture.trashed.map(\.lastPathComponent) == ["aider-local.json"])
        #expect(try fixture.registry.load().agents.map(\.id) == ["claude", "codex", "grok", "pi"])
    }

    @Test func removingAnOverrideBringsThePresetBack() throws {
        let fixture = Fixture()
        var claude = AgentPresets.claude
        claude.name = "My Claude"
        try fixture.registry.save(claude)
        try fixture.registry.remove(id: "claude")
        #expect(try fixture.registry.load().agents.first == AgentPresets.claude)
    }

    @Test func aPresetWithNoOverrideCannotBeRemoved() throws {
        #expect(throws: AgentRegistry.Refusal.isPreset("claude")) { try Fixture().registry.remove(id: "claude") }
    }

    @Test func duplicatingGivesACopyWithAFreshId() throws {
        let fixture = Fixture()
        let first = try fixture.registry.duplicate(id: "claude")
        let second = try fixture.registry.duplicate(id: "claude")
        #expect(first.id == "claude-copy" && first.name == "Claude Code copy" && first.command == "claude")
        #expect(second.id == "claude-copy-2")
        #expect(try fixture.registry.load().agents.map(\.id).suffix(2) == ["claude-copy", "claude-copy-2"])
    }

    @Test func aSecretTypedAsAPlainVariableIsRefused() throws {
        var leaky = aider
        leaky.environment = ["OPENAI_API_KEY": "sk-live-123"]
        #expect(throws: AgentRegistry.Refusal.secretInEnvironment("OPENAI_API_KEY")) { try Fixture().registry.save(leaky) }
    }

    @Test func aKeychainReferenceForASecretIsFine() throws {
        let fixture = Fixture()
        var keyed = aider
        keyed.secrets = ["OPENAI_API_KEY": "Shellforge OpenAI key"]
        try fixture.registry.save(keyed)
        #expect(try fixture.registry.load().agents.last?.secrets == ["OPENAI_API_KEY": "Shellforge OpenAI key"])
    }

    @Test func anUnreadableFileIsReportedAndTheRestStillLoad() throws {
        let fixture = Fixture()
        try fixture.registry.save(aider)
        try "{ not json".write(to: fixture.folder.appendingPathComponent("broken.json"), atomically: true, encoding: .utf8)
        let loaded = try fixture.registry.load()
        #expect(loaded.agents.last == aider)
        #expect(loaded.problems.map(\.file) == ["broken.json"])
    }

    @Test func anIdMustBeASafeFileName() throws {
        var bad = aider
        bad.id = "../escape"
        #expect(throws: AgentRegistry.Refusal.invalidId("../escape")) { try Fixture().registry.save(bad) }
    }
}
