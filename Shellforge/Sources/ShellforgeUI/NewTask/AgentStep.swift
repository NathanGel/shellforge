// Ported from AiTerm (app/Sources/AiTerm/Views/Steps/AgentStep.swift), GPLv3, Laurens D'Hondt.
import ShellforgeCore
import ShellforgeDesign
import SwiftUI

/// Step 2. An agent whose CLI is not on the login shell's `PATH` cannot be picked, and the sheet
/// says which one and where to install it instead of letting the task open a tab that prints
/// "command not found". With none installed, Continue stays disabled.
struct AgentStep<Kind: CreationKind>: View {
    @ObservedObject var model: CreationModel<Kind>

    /// What stands where the model picker would, when an agent lists no models: AiTerm's per-agent
    /// sentence for a preset, the generic one for anyone else.
    static func noModelsExplanation(agentId: String) -> String {
        switch agentId {
        case AgentPresets.grok.id: return "No Grok models — run grok once to sign in and fetch them."
        case AgentPresets.pi.id: return "No PI providers are signed in — run /login in PI."
        default: return "No models are available."
        }
    }

    /// A catalogue that could not be read says why — "PI couldn’t be launched." — rather than
    /// suggesting a sign-in that would not help.
    static func modelPlaceholder(agentId: String, catalogueLoaded: Bool, failure: String? = nil) -> String {
        catalogueLoaded ? failure ?? noModelsExplanation(agentId: agentId) : "Loading models…"
    }

    var selectedModel: AgentModel? { model.models.first { $0.id == model.draft.model } }
    private var unselectedModel: AgentModel {
        AgentModel(id: "", label: "Choose a current model…", detail: nil, efforts: [], defaultEffort: nil)
    }
    var modelChoices: [AgentModel] { selectedModel == nil ? [unselectedModel] + model.models : model.models }
    var efforts: [String] { selectedModel?.efforts ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.block) {
            FormField("Agent") {
                AgentSegmented(agents: model.agents, available: model.availableAgents,
                               selection: Binding(get: { model.draft.agentId }, set: { model.selectAgent($0) }))
                if let note = CreationModel<Kind>.missingAgentNote(agents: model.agents, available: model.availableAgents) {
                    HelpText(note, tone: .warning)
                }
            }

            HStack(alignment: .top, spacing: Space.gap) {
                FormField("Model") {
                    if model.models.isEmpty {
                        HelpText(Self.modelPlaceholder(agentId: model.draft.agentId, catalogueLoaded: model.catalogueLoaded,
                                                       failure: model.catalogueFailure))
                            // A note where the dropdown will be, not an empty field: it only keeps the row's height.
                            .frame(maxWidth: .infinity, minHeight: Size.control, alignment: .leading)
                    } else {
                        Select(values: modelChoices, selection: Binding(get: { selectedModel ?? unselectedModel }, set: { model.setModel($0.id) }),
                               label: { $0.label }, detail: { $0.detail })
                    }
                }.frame(maxWidth: .infinity)
                // A model can publish no reasoning levels at all — Haiku's catalogue entry says
                // `thinking: none` — and then there is no flag to pass and nothing to pick.
                if !efforts.isEmpty {
                    FormField("Reasoning") {
                        Select(values: efforts, selection: Binding(get: { model.draft.reasoning ?? efforts.first ?? "" },
                                                                   set: { model.draft.reasoning = $0 }),
                               label: { $0.capitalized })
                    }.frame(maxWidth: .infinity)
                }
            }

            if let detail = selectedModel?.detail, !detail.isEmpty { HelpText(detail) }
        }
    }
}
