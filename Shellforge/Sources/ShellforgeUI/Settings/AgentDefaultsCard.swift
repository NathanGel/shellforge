// Ported from AiTerm (app/Sources/AiTerm/Views/HarnessSettingsPane.swift), GPLv3, Laurens D'Hondt.
import ShellforgeCore
import ShellforgeDesign
import SwiftUI

/// Settings › Agents: one row per installed agent, with the default model and reasoning level New
/// Task and New Review open with.
struct AgentDefaultsCard: View {
    @ObservedObject var model: AgentDefaultsSettingsModel
    let row: AgentDefaultsSettingsModel.Row

    var body: some View {
        SettingsCard(title: row.agent.name, status: status) {
            VendorMark(agent: SessionAgent(rawValue: row.id) ?? .shell, size: Size.control)
        } chips: {
            EmptyView()
        } actions: {
            if !row.loaded { ProgressView().controlSize(.small) }
        } content: {
            pickers
        }
    }

    private var status: SettingsStatus {
        if !row.loaded { return SettingsStatus(.idle, "Reading its models…") }
        if let failure = row.failure { return SettingsStatus(.attention, failure) }
        if row.missing { return SettingsStatus(.attention, "The saved model is no longer offered") }
        if row.models.isEmpty { return SettingsStatus(.idle, "No models to choose from") }
        return model.isSaved(row.id) ? SettingsStatus(.ready, "Saved default")
                                     : SettingsStatus(.idle, "Last used model, until you pick one")
    }

    /// The saved model, when the catalogue no longer offers it, stays visible and first.
    private var choices: [AgentModel] {
        guard row.missing, let saved = row.preference else { return row.models }
        return [AgentModel(id: "", label: "Unavailable: \(saved.model)", detail: nil, efforts: [], defaultEffort: nil)] + row.models
    }

    private var selectedModel: AgentModel? { row.models.first { $0.id == row.preference?.model } }

    @ViewBuilder
    private var pickers: some View {
        if row.loaded, !row.models.isEmpty {
            HStack(alignment: .top, spacing: Space.gap) {
                FormField("Default model") {
                    Select(values: choices,
                           selection: Binding(get: { selectedModel ?? choices[0] },
                                              set: { model.select($0, for: row.id) }),
                           label: { $0.label }, detail: { $0.detail })
                }.frame(maxWidth: .infinity)
                if let selectedModel, !selectedModel.efforts.isEmpty {
                    let efforts = selectedModel.efforts
                    FormField("Default reasoning") {
                        Select(values: efforts,
                               selection: Binding(get: { row.preference?.reasoning.flatMap { efforts.contains($0) ? $0 : nil }
                                                         ?? selectedModel.defaultEffort ?? efforts[0] },
                                                  set: { model.selectReasoning($0, for: row.id) }),
                               label: { $0.capitalized })
                    }.frame(maxWidth: .infinity)
                }
            }
        }
    }
}
