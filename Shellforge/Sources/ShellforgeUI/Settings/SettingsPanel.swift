import ShellforgeCore
import ShellforgeDesign
import SwiftUI

/// Shellforge's Settings until it has AiTerm's window: AiTerm's Integrations tab — Core with the Mac
/// card, Services with Jira, GitLab and GitHub — in a dark panel, Cancel or Save. Nothing is written until Save, and a
/// Save that cannot go through says why and keeps the panel open.
struct SettingsPanel: View {
    @ObservedObject var backpack: BackpackController
    let integrations: IntegrationSettingsModel
    var environment: EnvironmentModel?
    let close: @MainActor () -> Void
    @State private var failure: String?

    var body: some View {
        SheetLayout(title: "Settings", height: Sheet.settingsHeight) {
            SheetSubtitle("Jira for New Task's tickets, GitLab and GitHub for reviews, and what Backpack Mode needs from this Mac.")
        } content: {
            VStack(alignment: .leading, spacing: Space.section) {
                SettingsSection("Core") {
                    MacSettingsCard(backpack: backpack)
                    if let environment { EnvironmentCard(model: environment) }
                }
                SettingsSection("Services") {
                    JiraCard(connection: integrations.jira)
                    GitLabCard(connection: integrations.gitLab)
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
    }

    private func save() {
        failure = integrations.save()
        if failure == nil { Task { @MainActor in close() } }
    }
}
