import Foundation

/// Every agent's model list, for the New Task sheet: a preset's from the files its CLI keeps (PI's
/// from a launch of it), anyone else's from its definition. Blocking — call it off the main actor.
public struct ModelCatalogue: Sendable {
    public let home: URL
    private let launcher: CommandLauncher

    public init(home: URL, launcher: CommandLauncher) {
        self.home = home
        self.launcher = launcher
    }

    public func models(for agent: AgentDefinition) throws -> [AgentModel] {
        switch agent.id {
        case AgentPresets.claude.id: return ModelFiles.claudeModels(home: home)
        case AgentPresets.codex.id: return ModelFiles.codexModels(home: home)
        case AgentPresets.grok.id: return GrokModelCatalog.models(home: home)
        case AgentPresets.pi.id:
            guard let executable = launcher.locate(agent.command) else { throw PiModelCatalogError.unavailable }
            return try PiModelCatalog.discover(executable: executable, launcher: launcher)
        default:
            switch agent.models {
            case .fixed(let ids): return ids.map { model($0, of: agent) }
            case .command(let words):
                guard let command = words.first else { return [] }
                let out = try launcher.run(command, Array(words.dropFirst()), timeout: 5)
                guard out.status == 0, !out.timedOut else { return [] }
                return out.stdout.split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { model($0, of: agent) }
            }
        }
    }

    private func model(_ id: String, of agent: AgentDefinition) -> AgentModel {
        AgentModel(id: id, label: id, detail: nil, efforts: agent.reasoningLevels, defaultEffort: agent.defaultReasoning)
    }
}
