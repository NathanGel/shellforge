import ShellforgeDesign
import SwiftUI

/// Settings › Core › Terminal editor: the command that opens a file in a terminal tab.
struct TerminalEditorCard: View {
    @ObservedObject var settings: TerminalEditorSettings
    /// The sheet's own, unsaved command.
    @Binding var draft: String

    var body: some View {
        SettingsCard(title: "Terminal editor", status: SettingsStatus(.idle, Self.status(draft: draft, settings: settings))) {
            SymbolMark(symbol: .terminal, size: Size.control, style: .paper)
        } chips: {
            EmptyView()
        } actions: {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: Space.block) {
                Input(placeholder: settings.placeholder, text: $draft, monospaced: true)
                Text("Files open in a terminal tab with this command. Leave it empty to use $EDITOR.")
                    .font(Typography.help)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await settings.load() }
    }

    /// The card's status: a draft of only spaces saves as empty, so it says what empty means.
    static func status(draft: String, settings: TerminalEditorSettings) -> String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? settings.emptyStatus : "Your command"
    }
}
