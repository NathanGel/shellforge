// Ported from AiTerm (app/Sources/AiTerm/Views/SettingsView.swift, the GitLab and GitHub cards), GPLv3, Laurens D'Hondt.
import ShellforgeCore
import ShellforgeDesign
import SwiftUI

/// AiTerm's GitLab card: the host — gitlab.com or a company's own — and a personal access token,
/// which Save keeps in the Keychain.
struct GitLabCard: View {
    let connection: ServiceConnection<GitLabFields>

    var body: some View {
        ServiceCard(title: "GitLab", service: .gitlab, connection: connection) { fields in
            VStack(alignment: .leading, spacing: Space.block) {
                HStack(alignment: .top, spacing: Space.gap) {
                    FormField("Host URL") { Input(placeholder: "https://gitlab.com", text: fields.host) }
                        .frame(maxWidth: .infinity)
                    FormField("Access token") { Input(placeholder: "Personal access token", text: fields.token, secure: true) }
                        .frame(maxWidth: .infinity)
                }
                if !fields.wrappedValue.token.isEmpty { HelpText("Save stores your token in Keychain.") }
            }
        }
    }
}

/// AiTerm's GitHub card: github.com only, so the token is the whole connection.
struct GitHubCard: View {
    let connection: ServiceConnection<GitHubFields>

    var body: some View {
        ServiceCard(title: "GitHub", service: .github, connection: connection) { fields in
            VStack(alignment: .leading, spacing: Space.block) {
                FormField("Access token") {
                    Input(placeholder: "Fine-grained or classic personal access token", text: fields.token, secure: true)
                }
                HelpText("Needs read access to pull requests.")
                if !fields.wrappedValue.token.isEmpty { HelpText("Save stores your token in Keychain.") }
            }
        }
    }
}
