// Ported from AiTerm (app/Sources/AiTermCore/Agents/AgentModel.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// One entry of an agent's model list. `id` is what goes on the command line; `label` and `detail`
/// are what the CLI itself shows for it, so the sheet reads like the agent's own `/model` picker.
public struct AgentModel: Equatable, Hashable, Identifiable, Sendable {
    public var id: String, label: String, detail: String?, efforts: [String], defaultEffort: String?
    public init(id: String, label: String, detail: String?, efforts: [String], defaultEffort: String?) {
        self.id = id; self.label = label; self.detail = detail; self.efforts = efforts; self.defaultEffort = defaultEffort
    }
}
