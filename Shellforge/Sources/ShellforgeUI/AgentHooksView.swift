import ShellforgeCore
import ShellforgeDesign
import SwiftUI

/// The Agent hooks sheet: each preset agent's hooks, and the one button that installs or repairs
/// them. Nothing changes a file until the user clicks. Drawn from AiTerm's design system: a sheet's
/// title, help text, each agent's mark and its state as a quiet badge.
public struct AgentHooksView: View {
    @ObservedObject var model: AgentHooksModel
    let dismiss: () -> Void

    public init(model: AgentHooksModel, dismiss: @escaping () -> Void) {
        self.model = model
        self.dismiss = dismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.block) {
            Text("Agent hooks").font(Typography.title).foregroundStyle(Palette.text)
            HelpText("Shellforge changes an agent’s settings only when you click its button. Each file is backed up once before the first change.")
            VStack(alignment: .leading, spacing: Space.gap) {
                ForEach(model.rows) { row in rowView(row) }
            }
            if let error = model.lastError { HelpText(error, tone: .warning) }
            // Every sheet's keys: ⌘↩ is Done, ⎋ closes, and a plain ↩ does neither.
            HStack {
                Spacer()
                SheetPrimaryButton(title: "Done", action: dismiss)
            }
            .controlSize(.large)
            .overlay { Button("Close", action: dismiss).keyboardShortcut(.cancelAction).hidden() }
        }
        .padding(Space.margin)
        .frame(width: Sheet.width, alignment: .leading)
        .background(Palette.surface)
        .task { await model.refresh() }
    }

    private func rowView(_ row: AgentHooksModel.Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.gap) {
            VendorMark(agent: Self.agent(row.id), size: Size.vendorMark)
            VStack(alignment: .leading, spacing: Space.tight) {
                HStack(spacing: Space.base) {
                    Text(row.name).font(Typography.bodyEmphasis).foregroundStyle(Palette.text)
                    Badge(Self.words(row.probe.state), style: .quiet)
                }
                if let explanation = row.probe.explanation, row.probe.state != .missing {
                    HelpText(explanation)
                }
            }
            Spacer()
            if let title = Self.buttonTitle(row.probe.state) {
                Button(title) { Task { await model.install(row.id) } }
                    .disabled(row.working)
            }
        }
    }

    /// The preset's agent, for its mark.
    static func agent(_ id: String) -> SessionAgent { SessionAgent(rawValue: id) ?? .shell }

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
