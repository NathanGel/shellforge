import ShellforgeDesign
import SwiftUI

/// Settings › Core › Terminal editor: the command that opens a file in a terminal tab.
struct TerminalEditorCard: View {
    let placeholder: String
    /// The sheet's own, unsaved command.
    @Binding var draft: String

    var body: some View {
        SettingsCard(title: "Terminal editor", status: SettingsStatus(.idle, draft.isEmpty ? "From $EDITOR" : "Your command")) {
            SymbolMark(symbol: "terminal", size: Size.control, style: .paper)
        } chips: {
            EmptyView()
        } actions: {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: Space.block) {
                Input(placeholder: placeholder, text: $draft, monospaced: true)
                Text("Files open in a terminal tab with this command. Leave it empty to use $EDITOR.")
                    .font(Typography.help)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
