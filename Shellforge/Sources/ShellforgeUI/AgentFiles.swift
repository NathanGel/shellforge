import Foundation
import ShellforgeCore

/// The agents the app offers: the presets, then each agent file in the agents folder
/// (`AgentRegistry`), one JSON file each — so an agent written by hand appears in New Task and New
/// Review before Shellforge has an editor for them. A file that cannot be read is said, once, and
/// the others load regardless.
public enum AgentFiles {
    /// `readyMade` names the ready-made agents among them, for `SidebarModel.reloadAgents`.
    public static func load(_ registry: AgentRegistry) -> (agents: [AgentDefinition], problem: String?, readyMade: Set<String>) {
        guard let loaded = try? registry.load() else { return (AgentPresets.all, nil, []) }
        return (loaded.agents, problemSentence(files: loaded.problems.map(\.file)),
                Set(loaded.origins.filter { $0.value == .readyMade }.keys))
    }

    /// Names the agent files that couldn’t be read; nil when every one could.
    static func problemSentence(files: [String]) -> String? {
        guard !files.isEmpty else { return nil }
        let lead = files.count == 1 ? "An agent file couldn’t be read" : "\(files.count) agent files couldn’t be read"
        return "\(lead): \(files.joined(separator: ", ")). The other agents loaded."
    }
}
