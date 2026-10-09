// Ported from AiTerm (app/Sources/AiTermCore/Agents/ModelSettings.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// The model and reasoning level a draft opens with.
public struct ModelPreference: Equatable, Sendable {
    public var model: String
    public var reasoning: String?

    public init(model: String, reasoning: String?) {
        self.model = model
        self.reasoning = reasoning
    }

    /// Keep a supported effort when changing models; otherwise use the new model's default.
    public mutating func select(_ model: AgentModel) {
        self.model = model.id
        if let reasoning, model.efforts.contains(reasoning) { return }
        reasoning = model.defaultEffort.flatMap { model.efforts.contains($0) ? $0 : nil } ?? model.efforts.first
    }

    /// The last model used with the agent while the catalogue still offers it, else the catalogue's
    /// first; nothing when the catalogue is empty. (AiTerm's Settings default comes first; it arrives
    /// with Settings › Models.)
    public static func resolve(catalog: [AgentModel], remembered: String?) -> ModelPreference {
        guard let model = catalog.first(where: { $0.id == remembered }) ?? catalog.first else {
            return ModelPreference(model: "", reasoning: nil)
        }
        var preference = ModelPreference(model: model.id, reasoning: nil)
        preference.select(model)
        return preference
    }
}
