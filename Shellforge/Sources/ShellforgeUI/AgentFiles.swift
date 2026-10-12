import Foundation
import ShellforgeCore

/// The agents the app offers: the presets, then each agent file in the agents folder
/// (`AgentRegistry`), one JSON file each — so an agent written by hand appears in New Task and New
/// Review before Shellforge has an editor for them. A file that cannot be read is said, once, and
/// the others load regardless.
public enum AgentFiles {
    public static func load(_ registry: AgentRegistry) -> (agents: [AgentDefinition], problem: String?) {
        guard let loaded = try? registry.load() else { return (AgentPresets.all, nil) }
        let files = loaded.problems.map(\.file)
        guard !files.isEmpty else { return (loaded.agents, nil) }
        let lead = files.count == 1 ? "An agent file couldn’t be read" : "\(files.count) agent files couldn’t be read"
        return (loaded.agents, "\(lead): \(files.joined(separator: ", ")). The other agents loaded.")
    }
}
