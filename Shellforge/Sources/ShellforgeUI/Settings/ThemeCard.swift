import ShellforgeDesign
import SwiftUI

/// Settings › Core › Theme: whether Shellforge follows the Mac — a theme for light and one for dark
/// when it does, one theme when it doesn't — and, last, whether the terminal matches the theme.
struct ThemeCard: View {
    /// The sheet's own, unsaved choice.
    @Binding var choice: ThemeChoice
    /// The sheet's own, unsaved Match Terminal switch.
    @Binding var matchesTerminal: Bool

    static let followMacTitle = "Follow Mac Appearance"
    static let matchTitle = "Match Terminal"
    /// The switches' accessibility identifiers, which tests find them by.
    static let followMacIdentifier = "Settings.Core.Theme.FollowMac"
    static let matchIdentifier = "Settings.Core.Theme.MatchTerminal"

    private var status: SettingsStatus {
        guard choice.followsMac else { return SettingsStatus(.ready, ThemeCatalog.theme(id: choice.single).name) }
        let light = ThemeCatalog.theme(id: choice.light).name, dark = ThemeCatalog.theme(id: choice.dark).name
        return SettingsStatus(.ready, light == dark ? "\(light), following the Mac" : "\(light) and \(dark), following the Mac")
    }

    var body: some View {
        SettingsCard(title: "Theme", status: status) {
            SymbolMark(symbol: "paintpalette", size: Size.control, style: .paper)
        } chips: {
            EmptyView()
        } actions: {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: Space.gap) {
                switchRow(Self.followMacTitle, identifier: Self.followMacIdentifier, isOn: $choice.followsMac)
                if choice.followsMac {
                    HStack(alignment: .top, spacing: Space.gap) {
                        picker("Light", themes: ThemeCatalog.lightChoices, selection: $choice.light)
                        picker("Dark", themes: ThemeCatalog.darkChoices, selection: $choice.dark)
                    }
                } else {
                    picker("Theme", themes: ThemeCatalog.all, selection: $choice.single)
                }
                switchRow(Self.matchTitle, identifier: Self.matchIdentifier, isOn: $matchesTerminal)
                Text("Uses the theme’s colours in the terminal, with iTerm2’s Minimal theme. Your profiles are not changed.")
                    .font(Typography.help)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func switchRow(_ title: String, identifier: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: Space.gap) {
            Text(title).font(Typography.body).foregroundStyle(Palette.text)
            Spacer(minLength: Space.gap)
            SettingsSwitch(title: title, isOn: isOn, identifier: identifier)
        }
    }

    /// A theme id from `themes`, by name; an id not among them — gone from the catalogue, or a
    /// theme of the other appearance — reads as Shellforge, the first.
    private func picker(_ label: String, themes: [Theme], selection: Binding<String>) -> some View {
        FormField(label) {
            Select(values: themes.map(\.id),
                   selection: Binding(get: { ThemeCatalog.theme(id: selection.wrappedValue).id }, set: { selection.wrappedValue = $0 }),
                   label: { ThemeCatalog.theme(id: $0).name })
        }.frame(maxWidth: .infinity)
    }
}
