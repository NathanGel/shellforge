import Foundation
import Testing
@testable import ShellforgeCore

@Suite struct ReadyMadeAgentsTests {
    private static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("hooks/agents", isDirectory: true)
    private static let expected = [("gemini", "Gemini CLI"), ("opencode", "OpenCode"), ("aider", "Aider"),
                                   ("copilot", "GitHub Copilot CLI"), ("amp", "Amp"), ("goose", "Goose")]

    private func files() throws -> [(AgentDefinition, [String: Any])] {
        try FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url in
                let data = try Data(contentsOf: url)
                return (try JSONDecoder().decode(AgentDefinition.self, from: data),
                        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]))
            }
    }

    @Test func allSixDecodeWithTheirIdsAndNames() throws {
        let agents = try files().map(\.0)
        #expect(agents.map { "\($0.id)|\($0.name)" }.sorted() == Self.expected.map { "\($0.0)|\($0.1)" }.sorted())
    }

    @Test func noIdIsBuiltInAndEachIsValid() throws {
        for (agent, _) in try files() {
            #expect(!AgentPresets.reservedIds.contains(agent.id))
            #expect(AgentRegistry.isValidId(agent.id))
        }
    }

    @Test func noWordHoldsAControlCharacterOrBackslash() throws {
        for (agent, _) in try files() {
            let words = [agent.command] + agent.arguments.flatMap { $0 } + agent.reasoningLevels
            for word in words {
                #expect(!word.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F || $0 == "\\" })
            }
        }
    }

    @Test func everyArgumentAgentHasAPromptGroup() throws {
        for (agent, _) in try files() where agent.prompt == .argument {
            #expect(agent.arguments.contains { $0.contains { $0.contains("{prompt}") } })
        }
    }

    @Test func everySourceIsAnHttpsUrl() throws {
        for (_, raw) in try files() {
            let sources = try #require(raw["x-sources"] as? [String])
            #expect(!sources.isEmpty)
            for source in sources { #expect(URL(string: source)?.scheme == "https") }
        }
    }

    /// Each exact agent's snippet as JSON: hook event → the state it reports.
    private func states(of agent: AgentDefinition) throws -> [String: String] {
        let snippet = try #require(agent.statusSetup?.snippet)
        let root = try #require(JSONSerialization.jsonObject(with: Data(snippet.utf8)) as? [String: Any])
        let hooks = try #require(root["hooks"] as? [String: [[String: Any]]])
        let key = agent.id == "copilot" ? "bash" : "command"
        return try hooks.mapValues { entries in
            let entry = try #require(entries.first)
            let holder = agent.id == "copilot" ? entry : try #require((entry["hooks"] as? [[String: Any]])?.first)
            let raw = try #require(holder[key] as? String)
            #expect(raw.hasPrefix("{shellforge-status} "))
            return String(raw.dropFirst("{shellforge-status} ".count))
        }
    }

    @Test func exactAgentsReportEachStateOnItsOwnEvent() throws {
        let agents = try files().map(\.0)
        let gemini = try #require(agents.first { $0.id == "gemini" })
        let copilot = try #require(agents.first { $0.id == "copilot" })
        #expect(try states(of: gemini) == [
            "BeforeAgent": "working", "AfterTool": "working", "Notification": "needs-input", "AfterAgent": "done"])
        #expect(try states(of: copilot) == [
            "userPromptSubmitted": "working", "postToolUse": "working", "notification": "needs-input", "agentStop": "done"])
        for agent in agents {
            switch agent.status {
            case .eventProtocol: #expect(agent.statusSetup != nil)
            case .terminal: #expect(agent.statusSetup == nil)
            default: Issue.record("unexpected status for \(agent.id)")
            }
        }
    }

    @Test func copilotAsksOnlyForPermissionAndQuestions() throws {
        let agent = try #require(files().map(\.0).first { $0.id == "copilot" })
        let snippet = try #require(agent.statusSetup?.snippet)
        let root = try #require(JSONSerialization.jsonObject(with: Data(snippet.utf8)) as? [String: Any])
        let notification = try #require(((root["hooks"] as? [String: Any])?["notification"] as? [[String: Any]])?.first)
        #expect(notification["matcher"] as? String == "permission_prompt|elicitation_dialog")
    }

    @Test func registryLoadsThemAsReadyMade() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("rm-\(UUID().uuidString)")
        let loaded = try AgentRegistry(folder: scratch, readyMade: Self.folder).load()
        #expect(loaded.problems.isEmpty)
        for (id, _) in Self.expected { #expect(loaded.origins[id] == .readyMade) }
    }
}
