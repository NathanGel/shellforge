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

    /// The Settings default when there is one, else the last model used with the agent while the
    /// catalogue still offers it, else the catalogue's first; nothing when the catalogue is empty.
    /// A saved default whose model the catalogue no longer offers resolves to nothing too, so the
    /// sheet asks for a current model rather than quietly starting a different one.
    public static func resolve(catalog: [AgentModel], remembered: String?, saved: ModelPreference? = nil) -> ModelPreference {
        switch resolution(catalog: catalog, remembered: remembered, saved: saved) {
        case .valid(let preference): return preference
        case .missing, .empty: return ModelPreference(model: "", reasoning: nil)
        }
    }

    /// As `resolve`, but saying why: Settings shows a missing default as such instead of as empty.
    public static func resolution(catalog: [AgentModel], remembered: String?, saved: ModelPreference?) -> ModelPreferenceResolution {
        if let saved {
            guard let model = catalog.first(where: { $0.id == saved.model }) else { return .missing(saved) }
            var preference = saved
            preference.select(model)
            return .valid(preference)
        }
        guard let model = catalog.first(where: { $0.id == remembered }) ?? catalog.first else { return .empty }
        var preference = ModelPreference(model: model.id, reasoning: nil)
        preference.select(model)
        return .valid(preference)
    }
}

public enum ModelPreferenceResolution: Equatable, Sendable {
    case valid(ModelPreference)
    /// A saved default whose model the catalogue no longer offers.
    case missing(ModelPreference)
    case empty
}

/// Settings › Agents: each agent's default model and reasoning level, app-wide. Kept apart from the
/// last-used models in the workspace, so a one-off task never replaces a deliberate default.
public enum ModelSettings {
    static func key(for agentId: String) -> String { "ShellforgeModelDefaults.\(agentId)" }

    public static func load(for agentId: String, defaults: UserDefaults = .standard) -> ModelPreference? {
        guard let value = defaults.dictionary(forKey: key(for: agentId)),
              let model = value["model"] as? String, !model.isEmpty else { return nil }
        return ModelPreference(model: model, reasoning: value["reasoning"] as? String)
    }

    /// Every saved default among `agentIds`, by agent id.
    public static func loadAll(for agentIds: [String], defaults: UserDefaults = .standard) -> [String: ModelPreference] {
        var all: [String: ModelPreference] = [:]
        for id in agentIds { all[id] = load(for: id, defaults: defaults) }
        return all
    }

    public static func save(_ preference: ModelPreference, for agentId: String, defaults: UserDefaults = .standard) {
        var value = ["model": preference.model]
        value["reasoning"] = preference.reasoning
        defaults.set(value, forKey: key(for: agentId))
    }
}
