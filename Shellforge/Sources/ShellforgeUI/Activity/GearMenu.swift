import ShellforgeCore
import ShellforgeDesign
import SwiftUI

/// The activity bar's gear, VS Code's Manage menu: Settings…, the Theme submenu and the Customize
/// submenu. Built as a model, which `GearMenuContent` draws and the tests read. A choice applies
/// at once: unlike the Settings sheet, the menu has no Save.
public enum GearMenu {
    /// What choosing an item does.
    public enum Action: Equatable, Sendable {
        case openSettings
        /// Saves this as the theme choice.
        case chooseTheme(ThemeChoice)
        case matchTerminal(Bool)
        /// Shows (true) or hides (false) the panel in every window's bar.
        case showPanel(ActivityPanel, Bool)
    }

    public indirect enum Item: Equatable, Sendable {
        /// `checked` nil for an item that is never checked.
        case button(String, checked: Bool?, enabled: Bool, Action)
        case submenu(String, [Item])
        case divider

        public var title: String? {
            switch self {
            case .button(let title, _, _, _), .submenu(let title, _): return title
            case .divider: return nil
            }
        }

        /// The items of a submenu; none for anything else.
        public var children: [Item] {
            if case .submenu(_, let items) = self { return items }
            return []
        }
    }

    static let settingsTitle = "Settings…"
    static let themeTitle = "Theme"
    static let lightTitle = "Light Theme"
    static let darkTitle = "Dark Theme"
    static let followMacTitle = "Follow Mac Appearance"
    static let matchTitle = "Match Terminal"
    static let customizeTitle = "Customize"

    /// The menu for the theme `choice`, Match Terminal `match`, and the bar's `layout`.
    public static func items(choice: ThemeChoice, match: Bool, layout: ActivityLayout) -> [Item] {
        [
            .button(settingsTitle, checked: nil, enabled: true, .openSettings),
            .divider,
            .submenu(themeTitle, themeItems(choice: choice, match: match)),
            .submenu(customizeTitle, customizeItems(layout)),
        ]
    }

    /// Following the Mac, a Light Theme and a Dark Theme submenu, each with the themes that suit it;
    /// otherwise the ten. Then the Follow Mac and Match Terminal toggles.
    private static func themeItems(choice: ThemeChoice, match: Bool) -> [Item] {
        let themes: [Item]
        if choice.followsMac {
            let light = ThemeCatalog.lightChoices.map { pick($0, in: choice, \.light, among: ThemeCatalog.lightChoices) }
            let dark = ThemeCatalog.darkChoices.map { pick($0, in: choice, \.dark, among: ThemeCatalog.darkChoices) }
            themes = [.submenu(lightTitle, light), .submenu(darkTitle, dark)]
        } else {
            themes = ThemeCatalog.all.map { pick($0, in: choice, \.single, among: ThemeCatalog.all) }
        }
        var follow = choice
        follow.followsMac.toggle()
        return themes + [
            .divider,
            .button(followMacTitle, checked: choice.followsMac, enabled: true, .chooseTheme(follow)),
            .button(matchTitle, checked: match, enabled: true, .matchTerminal(!match)),
        ]
    }

    /// `theme` in the slot `slot` of `choice`: checked when it is the slot's theme (an id not among
    /// the slot's `themes` reads as Shellforge); choosing it puts it there.
    private static func pick(_ theme: Theme, in choice: ThemeChoice, _ slot: WritableKeyPath<ThemeChoice, String>, among themes: [Theme]) -> Item {
        var chosen = choice
        chosen[keyPath: slot] = theme.id
        let checked = ThemeCatalog.theme(id: choice[keyPath: slot], among: themes).id == theme.id
        return .button(theme.name, checked: checked, enabled: true, .chooseTheme(chosen))
    }

    /// One Show toggle per panel, in the bar's order; the last one shown cannot be turned off.
    private static func customizeItems(_ layout: ActivityLayout) -> [Item] {
        let visible = layout.visibleOrder
        return layout.order.map { panel in
            let shown = !layout.hidden.contains(panel)
            return .button("Show \(panel.title)", checked: shown, enabled: !(shown && visible.count == 1), .showPanel(panel, !shown))
        }
    }
}

extension GearMenu {
    /// Does what choosing an item with `action` does, at once.
    @MainActor
    static func perform(_ action: Action, theme: ThemeSettings, terminalMatch: TerminalMatchSettings,
                        activity: ActivityModel, openSettings: () -> Void) {
        switch action {
        case .openSettings: openSettings()
        case .chooseTheme(let choice): theme.save(choice)
        case .matchTerminal(let on): terminalMatch.save(on)
        case .showPanel(let panel, let show): activity.setHidden(panel, !show)
        }
    }
}

/// `GearMenu`'s items as a SwiftUI menu's content: a checkable item as a toggle, which the menu
/// draws with a check.
struct GearMenuContent: View {
    let items: [GearMenu.Item]
    let perform: (GearMenu.Action) -> Void

    var body: some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            switch item {
            case .divider:
                Divider()
            case .submenu(let title, let children):
                Menu(title) { AnyView(GearMenuContent(items: children, perform: perform)) }
            case .button(let title, let checked, let enabled, let action):
                if let checked {
                    Toggle(title, isOn: Binding(get: { checked }, set: { _ in perform(action) }))
                        .disabled(!enabled)
                } else {
                    Button(title) { perform(action) }.disabled(!enabled)
                }
            }
        }
    }
}
