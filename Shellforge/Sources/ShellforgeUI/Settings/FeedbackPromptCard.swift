import ShellforgeDesign
import SwiftUI

/// Settings › Core › Feedback: one row, its setting the trailing switch for the sidebar’s note.
struct FeedbackPromptCard: View {
    /// The sheet's own, unsaved switch.
    @Binding var isOn: Bool

    /// The switch's accessibility identifier, which tests find it by.
    static let switchIdentifier = "Settings.Core.Feedback.AskForFeedback"

    private var status: SettingsStatus {
        isOn ? SettingsStatus(.ready, "On") : SettingsStatus(.idle, "Off")
    }

    var body: some View {
        SettingsCard(title: "Ask for feedback now and then", status: status) {
            SymbolMark(symbol: "bubble.left", size: Size.control, style: .paper)
        } chips: {
            EmptyView()
        } actions: {
            SettingsSwitch(title: "Ask for feedback now and then", isOn: $isOn, identifier: Self.switchIdentifier)
        } content: {
            Text("A note in the sidebar every few months, asking what to add or fix. Help › Send Feedback… works any time, once a day.")
                .font(Typography.help)
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
