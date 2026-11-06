import ShellforgeCore
import ShellforgeDesign
import SwiftUI

/// Shellforge's Settings until it has AiTerm's window: AiTerm's Integrations tab — Core with the Mac
/// card, Agents with each agent's default model and reasoning, Services with Jira, GitLab and
/// GitHub — in a dark panel, Cancel or Save. Nothing is written until Save, and a
/// Save that cannot go through says why and keeps the panel open.
struct SettingsPanel: View {
    @ObservedObject var backpack: BackpackController
    let integrations: IntegrationSettingsModel
    var environment: EnvironmentModel?
    let terminalMatch: TerminalMatchSettings
    @ObservedObject var feedback: FeedbackPrompt
    @ObservedObject var agentDefaults: AgentDefaultsSettingsModel
    let close: @MainActor () -> Void
    @State private var failure: String?
    /// This sheet's own switch, from what is saved when it opens.
    @State private var matchDraft = false
    @State private var feedbackDraft = true

    static let subtitle = "What Backpack Mode needs from this Mac, the model and reasoning each agent starts with, Jira for New Task’s tickets, GitLab and GitHub for reviews, and whether Shellforge asks for feedback."

    var body: some View {
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
                }
                SettingsSection("Agents") {
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
        .task { integrations.testConfigured() }
        .task { await backpack.refreshSetup() }
        .task { await agentDefaults.load() }
        .onAppear { matchDraft = terminalMatch.isOn; feedbackDraft = feedback.isEnabled }
    }

    private func save() {
        failure = integrations.save()
        guard failure == nil else { return }
        terminalMatch.save(matchDraft)
        feedback.save(feedbackDraft)
        agentDefaults.save()
        Task { @MainActor in close() }
    }
}
