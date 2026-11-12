import ShellforgeCore
import ShellforgeDesign
import SwiftUI

/// Shellforge's Settings until it has AiTerm's window: AiTerm's Integrations tab — Core with the Mac
/// card, Agents with the agents a task can start and each one's default model and reasoning,
/// Services with Jira, GitLab and GitHub — in a dark panel, Cancel or Save. Nothing is written until
/// Save, and a Save that cannot go through says why and keeps the panel open. The agents themselves
/// are the exception: an agent's form opens in the panel in place of the sections, with its own
/// Cancel and Save, and what it, Duplicate, Remove and Restore Default change is saved at once —
/// the panel's Cancel doesn't undo it. The defaults list follows those changes.
struct SettingsPanel: View {
    @ObservedObject var backpack: BackpackController
    let integrations: IntegrationSettingsModel
    var environment: EnvironmentModel?
    var terminalEditor: TerminalEditorSettings?
    let terminalMatch: TerminalMatchSettings
    @ObservedObject var feedback: FeedbackPrompt
    @ObservedObject var agentDefaults: AgentDefaultsSettingsModel
    let agents: AgentListModel
    let close: @MainActor () -> Void
    @State private var failure: String?
    /// This sheet's own switch, from what is saved when it opens.
    @State private var matchDraft = false
    @State private var feedbackDraft = true
    @State private var editorDraft = ""
    /// The agent form open in the panel, if one is.
    @State private var agentForm: AgentFormModel?

    static let subtitle = "What Backpack Mode needs from this Mac, which agents Shellforge can start and the model and reasoning each starts with, Jira for New Task’s tickets, GitLab and GitHub for reviews, and whether Shellforge asks for feedback."

    /// In a `ZStack`, not a `Group`: the panel's `onAppear` and tasks run once, when it opens, rather
    /// than again each time an agent form closes, which would reset the unsaved switches.
    var body: some View {
        ZStack {
            if let agentForm {
                AgentFormView(model: agentForm, close: { self.agentForm = nil })
            } else {
                sections
            }
        }
        .task { integrations.testConfigured() }
        .task { await backpack.refreshSetup() }
        .task { await agentDefaults.load() }
        .onAppear { matchDraft = terminalMatch.isOn; feedbackDraft = feedback.isEnabled; editorDraft = terminalEditor?.saved ?? "" }
        // An agent added, changed or removed here shows in the defaults list at once.
        .onReceive(agents.$rows.dropFirst()) { rows in
            agentDefaults.update(agents: rows.filter(\.installed).map(\.agent))
            Task { await agentDefaults.load(onlyUnloaded: true) }
        }
    }

    private var sections: some View {
        SheetLayout(title: "Settings", height: Sheet.settingsHeight) {
            SheetSubtitle(Self.subtitle)
        } content: {
            VStack(alignment: .leading, spacing: Space.section) {
                SettingsSection("Core") {
                    MacSettingsCard(backpack: backpack)
                    if let environment { SettingsRowDivider(); EnvironmentCard(model: environment) }
                    SettingsRowDivider()
                    TerminalMatchCard(isOn: $matchDraft)
                    SettingsRowDivider()
                    FeedbackPromptCard(isOn: $feedbackDraft)
                    if let terminalEditor { SettingsRowDivider(); TerminalEditorCard(placeholder: terminalEditor.placeholder, draft: $editorDraft) }
                }
                SettingsSection("Agents") {
                    AgentsCard(model: agents, open: { agentForm = $0 })
                    SettingsRowDivider()
                    if agentDefaults.rows.isEmpty {
                        HelpText("No agent is installed. Install Claude Code, Codex, Grok or PI to choose its defaults.")
                            .padding(Space.block)
                    }
                    ForEach(Array(agentDefaults.rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { SettingsRowDivider() }
                        AgentDefaultsCard(model: agentDefaults, row: row)
                    }
                }
                SettingsSection("Services") {
                    JiraCard(connection: integrations.jira)
                    SettingsRowDivider()
                    GitLabCard(connection: integrations.gitLab)
                    SettingsRowDivider()
                    GitHubCard(connection: integrations.gitHub)
                }
            }
        } footer: {
            SheetFooter(primary: "Save", cancel: { Task { @MainActor in close() } }, submit: save) {
                if let failure { Text(failure).font(Typography.caption).foregroundStyle(Palette.amber) }
            }
        }
    }

    private func save() {
        failure = integrations.save()
        guard failure == nil else { return }
        terminalMatch.save(matchDraft)
        feedback.save(feedbackDraft)
        terminalEditor?.save(editorDraft)
        agentDefaults.save()
        Task { @MainActor in close() }
    }
}
