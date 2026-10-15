import ShellforgeDesign
import SwiftUI

/// Settings › Core › Terminal: one row, its setting the trailing switch that matches every terminal
/// to Shellforge, as System Settings draws a setting.
struct TerminalMatchCard: View {
    /// The sheet's own, unsaved switch.
    @Binding var isOn: Bool

    private var status: SettingsStatus {
        isOn ? SettingsStatus(.ready, "Matched to Shellforge") : SettingsStatus(.idle, "Your profiles’ colours")
    }

    var body: some View {
        SettingsCard(title: "Match the terminal to Shellforge", status: status) {
            SymbolMark(symbol: "paintpalette", size: Size.control, style: .paper)
        } chips: {
            EmptyView()
        } actions: {
            SettingsSwitch(title: "Match the terminal to Shellforge", isOn: $isOn)
        } content: {
            Text("Uses Shellforge’s colours and iTerm2’s Minimal theme. Your profiles are not changed.")
                .font(Typography.help)
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
