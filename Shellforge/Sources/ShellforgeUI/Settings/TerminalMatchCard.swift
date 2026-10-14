import ShellforgeDesign
import SwiftUI

/// Settings › Core › Terminal: the switch that matches every terminal to Shellforge.
struct TerminalMatchCard: View {
    @ObservedObject var settings: TerminalMatchSettings

    private var status: SettingsStatus {
        settings.draft ? SettingsStatus(.ready, "Matched to Shellforge") : SettingsStatus(.idle, "Your profiles’ colours")
    }

    var body: some View {
        SettingsCard(title: "Terminal", status: status) {
            SymbolMark(symbol: "paintpalette", size: Size.control, style: .paper)
        } chips: {
            EmptyView()
        } actions: {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: Space.snug) {
                Toggle("Match the terminal to Shellforge", isOn: $settings.draft)
                Text("Uses Shellforge’s colours and iTerm2’s Minimal theme. Your profiles are not changed.")
                    .font(Typography.help)
                    .foregroundStyle(Palette.muted)
            }
        }
    }
}
