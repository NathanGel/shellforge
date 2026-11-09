import Foundation
import Testing
@testable import ShellforgeTestSupport
@testable import ShellforgeCore

@Suite struct AgentRegistryTests {
    /// A fresh `agents/` folder, and a trash that records what was put in it instead of touching
    /// the user's real Trash.
    private final class Fixture: @unchecked Sendable {
        let folder = TestScratch.root.appendingPathComponent("shellforge-agents-\(UUID().uuidString)")
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

@Suite struct AgentRegistryOriginTests {
    private final class Fixture: @unchecked Sendable {
        let root = TestScratch.root.appendingPathComponent("shellforge-agents-\(UUID().uuidString)")
        var folder: URL { root.appendingPathComponent("own") }
        var readyMade: URL { root.appendingPathComponent("ready") }
        var trashed: [URL] = []
        lazy var registry = AgentRegistry(folder: folder, readyMade: readyMade, trash: { [unowned self] url in
            trashed.append(url)
            try FileManager.default.removeItem(at: url)
        })

        func write(_ json: String, _ name: String, in dir: URL) throws {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try json.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        func readyMadeAgent(_ id: String) throws {
            try write(#"{"id": "\#(id)", "name": "\#(id.capitalized)", "command": "\#(id)", "arguments": [], "prompt": "argument", "models": {"fixed": {"_0": []}}, "reasoningLevels": [], "environment": {}, "secrets": {}, "status": {"terminal": {}}, "x-sources": ["https://example.com/docs"]}"#,
                      "\(id).json", in: readyMade)
        }
    }

    @Test func readyMadeLoadsBetweenPresetsAndOwn() throws {
        let fixture = Fixture()
        try fixture.readyMadeAgent("gemini")
        try fixture.readyMadeAgent("aider")
        try fixture.registry.save(AgentDefinition(id: "mine", name: "Mine", command: "mine"))
        #expect(try fixture.registry.load().agents.map(\.id) == ["claude", "codex", "grok", "pi", "aider", "gemini", "mine"])
    }

    @Test func ownFileOverridesReadyMade() throws {
        let fixture = Fixture()
        try fixture.readyMadeAgent("gemini")
        var mine = AgentDefinition(id: "gemini", name: "My Gemini", command: "/opt/gemini")
        try fixture.registry.save(mine)
        mine.name = "My Gemini"
        let loaded = try fixture.registry.load()
        #expect(loaded.agents.filter { $0.id == "gemini" } == [mine])
        #expect(loaded.overridden == ["gemini"])
        var claude = AgentPresets.claude
        claude.name = "Mine"
        try fixture.registry.save(claude)
        #expect(try fixture.registry.load().overridden == ["gemini", "claude"])
    }

    @Test func originsAreRight() throws {
        let fixture = Fixture()
        try fixture.readyMadeAgent("gemini")
        try fixture.readyMadeAgent("aider")
        try fixture.registry.save(AgentDefinition(id: "mine", name: "Mine", command: "mine"))
        try fixture.registry.save(AgentDefinition(id: "aider", name: "My Aider", command: "aider"))
        var claude = AgentPresets.claude
        claude.name = "Mine"
        try fixture.registry.save(claude)
        let loaded = try fixture.registry.load()
        #expect(loaded.origins == ["claude": .builtIn, "codex": .builtIn, "grok": .builtIn, "pi": .builtIn,
                                   "gemini": .readyMade, "aider": .readyMade, "mine": .own])
        #expect(loaded.overridden == ["aider", "claude"])
    }

    @Test func saveKeepsUnknownFields() throws {
        let fixture = Fixture()
        let written = #"""
        {"id": "hand", "name": "Hand", "command": "hand", "arguments": [], "prompt": "argument", "models": {"fixed": {"_0": []}},
         "reasoningLevels": ["low"], "defaultReasoning": "low", "environment": {}, "secrets": {}, "status": {"terminal": {}},
         "x-note": "keep", "x-nested": {"b": [1, 2.5, true, null, {"c": "d"}], "a": "https://example.com/a b"}, "x-number": 12345678901234}
        """#
        try fixture.write(written, "hand.json", in: fixture.folder)
        var agent = try #require(try fixture.registry.load().agents.first { $0.id == "hand" })
        agent.name = "Renamed"
        agent.defaultReasoning = nil
        try fixture.registry.save(agent)
        let after = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.folder.appendingPathComponent("hand.json"))) as? [String: Any])
        let before = try #require(JSONSerialization.jsonObject(with: Data(written.utf8)) as? [String: Any])
        #expect(after["name"] as? String == "Renamed")
        #expect(after["defaultReasoning"] == nil)
        #expect(after["x-note"] as? String == "keep")
        #expect(NSDictionary(dictionary: after["x-nested"] as? [String: Any] ?? [:]).isEqual(to: before["x-nested"] as? [String: Any] ?? [:]))
        #expect(after["x-number"] as? Int == 12345678901234)
        // Anything a person wrote outside the form's fields survives untouched, and the file still decodes.
        for key in before.keys where !AgentDefinition.CodingKeys.allCases.map(\.rawValue).contains(key) {
            #expect(NSDictionary(dictionary: [key: after[key] as Any]).isEqual(to: [key: before[key] as Any]), "\(key)")
        }
        #expect(try fixture.registry.load().agents.last?.name == "Renamed")
        let text = try String(contentsOf: fixture.folder.appendingPathComponent("hand.json"), encoding: .utf8)
        #expect(text.contains("https://example.com/a b"))
    }

    @Test func removingReadyMadeWithoutFileIsRefused() throws {
        let fixture = Fixture()
        try fixture.readyMadeAgent("gemini")
        #expect(throws: AgentRegistry.Refusal.isReadyMade("gemini")) { try fixture.registry.remove(id: "gemini") }
        #expect(throws: AgentRegistry.Refusal.notFound("nope")) { try fixture.registry.remove(id: "nope") }
        try fixture.registry.save(AgentDefinition(id: "gemini", name: "Mine", command: "g"))
        try fixture.registry.remove(id: "gemini")
        #expect(try fixture.registry.load().agents.first { $0.id == "gemini" }?.name == "Gemini")
    }

    @Test func duplicateOfBuiltInIsAutomatic() throws {
        let fixture = Fixture()
        let copy = try fixture.registry.duplicate(id: "claude")
        #expect(copy.status == .terminal)
        #expect(try fixture.registry.load().origins[copy.id] == .own)
    }

    @Test func freshId() {
        #expect(AgentRegistry.freshId(for: "Gemini CLI", taken: []) == "gemini-cli")
        #expect(AgentRegistry.freshId(for: "Gemini CLI", taken: ["gemini-cli"]) == "gemini-cli-2")
        #expect(AgentRegistry.freshId(for: "Gemini CLI", taken: ["gemini-cli", "gemini-cli-2"]) == "gemini-cli-3")
        #expect(AgentRegistry.freshId(for: "!!!", taken: []) == "agent")
        #expect(AgentRegistry.freshId(for: "  My  Agent!! ", taken: []) == "my-agent")
        #expect(AgentRegistry.freshId(for: "Claude", taken: []) == "claude-2")
    }

    @Test func aNewOwnAgentCannotTakeAReservedId() throws {
        let fixture = Fixture()
        for id in ["claude", "codex", "grok", "pi", "shell"] {
            let error = #expect(throws: AgentRegistry.Refusal.reservedId(id)) {
                try fixture.registry.create(AgentDefinition(id: id, name: "X", command: "x"))
            }
            #expect(error?.localizedDescription.contains("reserved") == true)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.folder.path))
        // Editing a built-in is an override under its own id, and stays possible.
        var claude = AgentPresets.claude
        claude.command = "/opt/claude"
        try fixture.registry.save(claude)
        #expect(try fixture.registry.load().overridden == ["claude"])
        // `shell` is no agent to override.
        #expect(throws: AgentRegistry.Refusal.reservedId("shell")) { try fixture.registry.save(AgentDefinition(id: "shell", name: "S", command: "s")) }
        try fixture.registry.create(AgentDefinition(id: "gemini", name: "G", command: "g"))
    }

    @Test func removingAnAgentDeletesItsKeychainItemsAndRestoreDefaultTheOverrides() throws {
        let fixture = Fixture()
        let store = MemorySecretStore()
        var mine = AgentDefinition(id: "mine", name: "Mine", command: "m", secrets: ["TOKEN_X": "ref"])
        try fixture.registry.save(mine)
        store.set("agent.mine.TOKEN_X", "v")
        store.set("agent.other.TOKEN_X", "w")
        try fixture.registry.remove(id: "mine", secrets: store)
        #expect(store.get("agent.mine.TOKEN_X") == nil && store.get("agent.other.TOKEN_X") == "w")
        mine = AgentPresets.claude
        mine.secrets = ["ANTHROPIC_KEY": "ref"]
        try fixture.registry.save(mine)
        store.set("agent.claude.ANTHROPIC_KEY", "v")
        try fixture.registry.remove(id: "claude", secrets: store)
        #expect(store.get("agent.claude.ANTHROPIC_KEY") == nil)
    }
}

@Suite struct AgentRegistrySecretsTests {
    private let folder = TestScratch.root.appendingPathComponent("shellforge-agents-\(UUID().uuidString)")
    private var registry: AgentRegistry { AgentRegistry(folder: folder, trash: { try FileManager.default.removeItem(at: $0) }) }

    @Test func aSecretDroppedOnEditIsDeleted() throws {
        let store = MemorySecretStore()
        var agent = AgentDefinition(id: "mine", name: "Mine", command: "m", secrets: ["A_TOKEN": "ref", "B_TOKEN": "ref"])
        try registry.save(agent, secrets: store)
        store.set("agent.mine.A_TOKEN", "a"); store.set("agent.mine.B_TOKEN", "b"); store.set("agent.other.A_TOKEN", "o")
        agent.secrets = ["A_TOKEN": "ref"]
        try registry.save(agent, secrets: store)
        #expect(store.get("agent.mine.B_TOKEN") == nil)
        #expect(store.get("agent.mine.A_TOKEN") == "a" && store.get("agent.other.A_TOKEN") == "o")
    }

    @Test func removeDeletesWhatTheFileNamesEvenIfItNoLongerDecodes() throws {
        let store = MemorySecretStore()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Valid JSON, but not an agent: no `command`.
        try #"{"id": "mine", "secrets": {"X_TOKEN": "ref"}}"#.write(to: folder.appendingPathComponent("mine.json"), atomically: true, encoding: .utf8)
        store.set("agent.mine.X_TOKEN", "v")
        try registry.remove(id: "mine", secrets: store)
        #expect(store.get("agent.mine.X_TOKEN") == nil)
    }

    @Test func createRefusesATakenIdAndASaveNeverWritesOverBrokenJSON() throws {
        let store = MemorySecretStore()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "{ not json".write(to: folder.appendingPathComponent("broken.json"), atomically: true, encoding: .utf8)
        #expect(throws: AgentRegistry.Refusal.idTaken("broken")) { try registry.create(AgentDefinition(id: "broken", name: "B", command: "b"), secrets: store) }
        #expect(throws: AgentRegistry.Refusal.unreadableFile("broken")) { try registry.save(AgentDefinition(id: "broken", name: "B", command: "b"), secrets: store) }
        #expect(try String(contentsOf: folder.appendingPathComponent("broken.json"), encoding: .utf8) == "{ not json")
        try registry.create(AgentDefinition(id: "fresh", name: "F", command: "f"), secrets: store)
        #expect(throws: AgentRegistry.Refusal.idTaken("fresh")) { try registry.create(AgentDefinition(id: "fresh", name: "F", command: "f"), secrets: store) }
    }

    @Test func createRefusesAReadyMadeId() throws {
        let ready = TestScratch.root.appendingPathComponent("ready-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ready, withIntermediateDirectories: true)
        let json = try JSONEncoder().encode(AgentDefinition(id: "gemini", name: "Gemini CLI", command: "gemini"))
        try json.write(to: ready.appendingPathComponent("gemini.json"))
        try json.write(to: ready.appendingPathComponent("zz-again.json"))
        let registry = AgentRegistry(folder: folder, readyMade: ready, trash: { _ in })
        #expect(throws: AgentRegistry.Refusal.idTaken("gemini")) { try registry.create(AgentDefinition(id: "gemini", name: "G", command: "g")) }
        // Two ready-made files with one id are no override.
        #expect(try registry.load().overridden.isEmpty)
    }

    @Test func aFileClaimingShellIsLeftOut() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(AgentDefinition(id: "shell", name: "S", command: "s")).write(to: folder.appendingPathComponent("shell.json"))
        let loaded = try registry.load()
        #expect(!loaded.agents.contains { $0.id == "shell" })
    }
}
