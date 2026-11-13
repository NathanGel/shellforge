import ShellforgeCore
import ShellforgeDesign
import SwiftUI

/// Settings › Agents' list: Add Agent…, then a row for each agent — its mark, its name, whether it is
/// installed and how its status is detected — with Edit… and a menu holding Duplicate, and Remove
/// for the person's own agent or Restore Default for an overridden one.
struct AgentsCard: View {
    @ObservedObject var model: AgentListModel
    /// Opens the form in the Settings panel.
    let open: (AgentFormModel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: Space.base) {
                HelpText("The agents a task can start: built in, ready-made, and your own. Changes to agents are saved at once.")
                Spacer(minLength: Space.base)
                Button("Add Agent…") { open(model.addForm()) }
                    .controlSize(SettingsCard<EmptyView, EmptyView, EmptyView, EmptyView>.actionControlSize)
            }
            .padding(Space.block)
            if let failure = model.failure {
                HelpText(failure, tone: .warning).padding(.horizontal, Space.block).padding(.bottom, Space.block)
            }
            ForEach(model.rows) { row in
                SettingsRowDivider()
                AgentRowCard(row: row, edit: { open(model.editForm(row.id)) }, duplicate: { model.duplicate(row.id) },
                             remove: { Task { await model.remove(row.id) } },
                             restore: { Task { await model.restoreDefault(row.id) } })
            }
        }
    }
}

/// One agent's row.
private struct AgentRowCard: View {
    let row: AgentListModel.Row
    let edit: () -> Void
    let duplicate: () -> Void
    let remove: () -> Void
    let restore: () -> Void

    private var status: SettingsStatus {
        SettingsStatus(row.installed ? .ready : .attention,
                       "\(row.installed ? "Installed" : "Not installed") · \(row.detection.label)")
    }

    var body: some View {
        SettingsCard(title: row.agent.name, status: status) {
            VendorMark(agent: SessionAgent(agentId: row.id), size: Size.control)
        } chips: {
            EmptyView()
        } actions: {
            Button("Edit…", action: edit)
            Menu {
                Button("Duplicate", action: duplicate)
                if row.origin == .own {
                    Button("Remove", action: remove)
                } else if row.overridden {
                    Button("Restore Default", action: restore)
                }
            } label: {
                Image(symbol: .ellipsis)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        } content: {
            EmptyView()
        }
    }
}
