// Ported from AiTerm (app/Sources/AiTermCore/Tasks/AgentDraft.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// What New Task's and New Review's drafts share: a name, and the agent that runs, with its model,
/// reasoning level and first prompt. What the agent and prompt steps read and write.
public protocol AgentDraft: Equatable, Sendable {
    var title: String { get }
    var agentId: String { get set }
    var model: String { get set }
    var reasoning: String? { get set }
    var promptText: String { get set }
    mutating func setModel(_ id: String, catalog: [AgentModel], efforts: [String], defaultEffort: String?)
}

public extension AgentDraft {
    /// Switching model can change which reasoning levels exist, so a level the new model does not
    /// offer becomes that model's default. `efforts` and `defaultEffort` are the agent's own, for a
    /// model that publishes none (AiTerm's `Harness.efforts(for:)` and `defaultEffort(for:)`).
    mutating func setModel(_ id: String, catalog: [AgentModel], efforts: [String], defaultEffort: String?) {
        model = id
        let picked = catalog.first { $0.id == id }
        if let current = reasoning, (picked?.efforts ?? efforts).contains(current) { return }
        reasoning = picked.map(\.defaultEffort) ?? defaultEffort
    }
}

extension TaskDraft: AgentDraft {}
extension ReviewDraft: AgentDraft {}
