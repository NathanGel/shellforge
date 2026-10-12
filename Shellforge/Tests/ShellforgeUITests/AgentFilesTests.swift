import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI

/// The agents the app offers: the four presets, then each agent file in the agents folder (here a
/// temporary one) — so an agent written by hand appears in New Task with no editor yet.
@Suite struct AgentFilesTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shellforge-agents-\(UUID().uuidString)")

    private var registry: AgentRegistry { AgentRegistry(folder: folder, trash: { _ in }) }

    @Test func withNoFilesThePresetsAreOffered() {
        let loaded = AgentFiles.load(registry)
        #expect(loaded.agents.map(\.id) == AgentPresets.all.map(\.id))
        #expect(loaded.problem == nil)
    }

    @Test func anAgentFileIsOfferedAfterThePresets() throws {
        var mine = AgentPresets.claude
        mine.id = "mine"
        mine.name = "Mine"
        try registry.save(mine)
        let loaded = AgentFiles.load(registry)
        #expect(loaded.agents.map(\.id) == AgentPresets.all.map(\.id) + ["mine"])
        #expect(loaded.problem == nil)
    }

    @Test func aBrokenFileIsSaidAndTheRestStillLoad() throws {
        var mine = AgentPresets.claude
        mine.id = "mine"
        try registry.save(mine)
        try "{ not json".write(to: folder.appendingPathComponent("broken.json"), atomically: true, encoding: .utf8)
        let loaded = AgentFiles.load(registry)
        #expect(loaded.agents.map(\.id).contains("mine"))
        #expect(loaded.problem == "An agent file couldn’t be read: broken.json. The other agents loaded.")
    }
}
