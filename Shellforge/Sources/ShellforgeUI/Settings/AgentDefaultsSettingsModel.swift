// Ported from AiTerm (app/Sources/AiTerm/HarnessSettingsModel.swift), GPLv3, Laurens D'Hondt.
// Its default model and reasoning pickers, without the harness install and test.
import Foundation
import ShellforgeCore

/// Settings › Agents: each installed agent's default model and reasoning level, which New Task and
/// New Review open with. Nothing is written until Settings is saved, and then only the agents whose
/// default was picked in this sheet: every other card shows the default it resolves to now (the
/// last model used, else the catalogue's first), and saving that would pin it.
@MainActor
final class AgentDefaultsSettingsModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        let agent: AgentDefinition
        var models: [AgentModel] = []
        var loaded = false
        var failure: String?
        var preference: ModelPreference?
        /// The saved default names a model the catalogue no longer offers.
        var missing = false
        var id: String { agent.id }
    }

    @Published private(set) var rows: [Row]
    private var picked: Set<String> = []
    private let catalogue: @Sendable (AgentDefinition) throws -> [AgentModel]
    private let remembered: [String: String]
    private let defaults: UserDefaults

    /// `agents` are the installed ones, in New Task's order.
    init(agents: [AgentDefinition], catalogue: @escaping @Sendable (AgentDefinition) throws -> [AgentModel],
         remembered: [String: String], defaults: UserDefaults = .standard) {
        rows = agents.map { Row(agent: $0) }
        self.catalogue = catalogue
        self.remembered = remembered
        self.defaults = defaults
    }

    /// Every agent's catalogue at once, off the main actor, so a slow one holds up only its card.
    func load() async {
        let read = catalogue
        await withTaskGroup(of: (String, Result<[AgentModel], Error>).self) { group in
            for row in rows {
                let agent = row.agent
                group.addTask {
                    let result = await BackgroundWork.run { () -> Result<[AgentModel], Error> in Result { try read(agent) } }
                    return (agent.id, result)
                }
            }
            for await (id, result) in group { accept(result, for: id) }
        }
    }

    private func accept(_ result: Result<[AgentModel], Error>, for id: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        var row = rows[index]
        row.loaded = true
        switch result {
        case .failure(let error):
            row.failure = error.localizedDescription
        case .success(let models):
            row.models = models
            switch ModelPreference.resolution(catalog: models, remembered: remembered[id],
                                              saved: ModelSettings.load(for: id, defaults: defaults)) {
            case .valid(let preference): row.preference = preference; row.missing = false
            case .missing(let preference): row.preference = preference; row.missing = true
            case .empty: row.preference = nil; row.missing = false
            }
        }
        rows[index] = row
    }

    func select(_ model: AgentModel, for id: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }), rows[index].models.contains(model) else { return }
        var preference = rows[index].preference ?? ModelPreference(model: model.id, reasoning: nil)
        preference.select(model)
        rows[index].preference = preference
        rows[index].missing = false
        picked.insert(id)
    }

    func selectReasoning(_ reasoning: String, for id: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }),
              let model = rows[index].models.first(where: { $0.id == rows[index].preference?.model }),
              model.efforts.contains(reasoning) else { return }
        rows[index].preference?.reasoning = reasoning
        picked.insert(id)
    }

    /// Whether `id`'s default is one saved in Settings, as opposed to the one it resolves to.
    func isSaved(_ id: String) -> Bool { picked.contains(id) || ModelSettings.load(for: id, defaults: defaults) != nil }

    /// Settings' Save: the defaults picked in this sheet, for models the catalogue still offers.
    func save() {
        for row in rows where picked.contains(row.id) {
            guard let preference = row.preference, row.models.contains(where: { $0.id == preference.model }) else { continue }
            ModelSettings.save(preference, for: row.id, defaults: defaults)
        }
        picked = []
    }
}

extension SidebarModel {
    /// Settings › Agents, over this sidebar's installed agents and the workspace's last-used models.
    func agentDefaultsModel() -> AgentDefaultsSettingsModel {
        let launcher = self.launcher
        return AgentDefaultsSettingsModel(agents: agents.filter { launcher.locate($0.command) != nil }, catalogue: catalogue,
                                          remembered: document.workspace.lastModelByAgent)
    }
}
