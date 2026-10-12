// Ported from AiTerm (app/Sources/AiTerm/Views/SettingsView.swift `ServiceCard` and the Jira card), GPLv3, Laurens D'Hondt.
import ShellforgeCore
import ShellforgeDesign
import SwiftUI

/// A service's Settings card: its mark, its connection's status line, a trailing Disconnect while
/// it holds saved credentials, and the fields `content` lays out from the connection's own binding.
/// It alone observes the connection, so an edit or a test answer redraws this card and not the panel.
struct ServiceCard<Fields: ServiceFields, Content: View>: View {
    let title: String
    let service: IntegrationMark.Service
    @ObservedObject var connection: ServiceConnection<Fields>
    @ViewBuilder let content: (Binding<Fields>) -> Content

    var body: some View {
        SettingsCard(title: title, status: connection.status) {
            IntegrationMark(service: service, size: Size.control)
        } chips: {
            EmptyView()
        } actions: {
            if connection.canDisconnect {
                Button("Disconnect") { connection.disconnect() }
            }
        } content: {
            content($connection.fields)
        }
    }
}

/// AiTerm's Jira card: the site, the account's email and its API token, which Save keeps in the
/// Keychain.
struct JiraCard: View {
    let connection: ServiceConnection<JiraFields>

    var body: some View {
        ServiceCard(title: "Jira", service: .jira, connection: connection) { fields in
            VStack(alignment: .leading, spacing: Space.block) {
                FormField("Site URL") { Input(placeholder: "https://yourcompany.atlassian.net", text: fields.site) }
                HStack(alignment: .top, spacing: Space.gap) {
                    FormField("Email") { Input(placeholder: "you@company.com", text: fields.email) }
                        .frame(maxWidth: .infinity)
                    FormField("API token") { Input(placeholder: "Atlassian API token", text: fields.token, secure: true) }
                        .frame(maxWidth: .infinity)
                }
                if !fields.wrappedValue.token.isEmpty { HelpText("Save stores your token in Keychain.") }
            }
        }
    }
}
