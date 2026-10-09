import ShellforgeCore
import SwiftUI

/// The Agent hooks sheet: each preset agent's hooks, and the one button that installs or repairs
/// them. Nothing changes a file until the user clicks.
public struct AgentHooksView: View {
    @ObservedObject var model: AgentHooksModel
    let dismiss: () -> Void

    public init(model: AgentHooksModel, dismiss: @escaping () -> Void) {
        self.model = model
        self.dismiss = dismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Agent hooks").font(.headline)
            Text("Shellforge changes an agent’s settings only when you click its button. Each file is backed up once before the first change.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(model.rows) { row in rowView(row) }
            if let error = model.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Done", action: dismiss).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .task { await model.refresh() }
    }

    private func rowView(_ row: AgentHooksModel.Row) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                Text(Self.words(row.probe.state)).font(.caption)
                if let explanation = row.probe.explanation, row.probe.state != .missing {
                    Text(explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if let title = Self.buttonTitle(row.probe.state) {
                Button(title) { Task { await model.install(row.id) } }
                    .disabled(row.working)
            }
        }
    }

    /// The state as the sheet says it.
    static func words(_ state: HookState) -> String {
        switch state {
        case .current: "Installed"
        case .missing: "Not installed"
        case .outdated: "Out of date"
        case .invalidOwned: "Needs repair"
        case .foreign: "Another file is in the way"
        case .unreadable: "Can’t be read"
        case .resourceUnavailable: "Unavailable"
        case .notChecked: "Checking…"
        }
    }

    /// The one action the state allows; none where an install would be refused anyway.
    static func buttonTitle(_ state: HookState) -> String? {
        switch state {
        case .missing: "Install"
        case .outdated, .invalidOwned: "Repair"
        case .current: "Reinstall"
        case .foreign, .unreadable, .resourceUnavailable, .notChecked: nil
        }
    }
}
