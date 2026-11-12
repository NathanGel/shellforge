import Foundation
import ShellforgeDesign
import Testing
@testable import ShellforgeTestSupport
@testable import ShellforgeUI

/// Settings › Core › Theme: Shellforge everywhere until saved otherwise; saving writes the four
/// synced keys; Match Terminal keeps its own key.
@MainActor @Suite struct ThemeSettingsTests {
    @Test func noSettingsMeansShellforgeEverywhere() {
        let choice = ThemeSettings(defaults: ScratchDefaults.make()).choice
        #expect(choice == ThemeChoice(followsMac: true, light: "shellforge", dark: "shellforge", single: "shellforge"))
        #expect(choice.active(isDark: false) == ThemeCatalog.shellforge)
        #expect(choice.active(isDark: true) == ThemeCatalog.shellforge)
        #expect(choice.forcedAppearance() == nil)
    }

    @Test func savingWritesTheKeys() {
        let store = ScratchDefaults.make()
        let settings = ThemeSettings(defaults: store)
        let chosen = ThemeChoice(followsMac: false, light: "github-light", dark: "dracula", single: "nord")
        settings.save(chosen)
        #expect(store.object(forKey: "ShellforgeThemeFollowsMac") as? Bool == false)
        #expect(store.string(forKey: "ShellforgeThemeLight") == "github-light")
        #expect(store.string(forKey: "ShellforgeThemeDark") == "dracula")
        #expect(store.string(forKey: "ShellforgeTheme") == "nord")
        #expect(settings.choice == chosen)
        #expect(ThemeSettings(defaults: store).choice == chosen, "read back")
    }

    @Test func onChangeIsCalledOnlyWhenTheChoiceChanges() {
        let settings = ThemeSettings(defaults: ScratchDefaults.make())
        var calls = 0
        settings.onChange = { calls += 1 }
        settings.save(ThemeChoice())
        settings.save(ThemeChoice(followsMac: false))
        settings.save(ThemeChoice(followsMac: false))
        #expect(calls == 1)
    }

    @Test func matchTerminalKeepsItsKey() {
        #expect(TerminalMatchSettings.defaultsKey == "ShellforgeMatchTerminal")
        let store = ScratchDefaults.make()
        store.set(true, forKey: "ShellforgeMatchTerminal")
        #expect(TerminalMatchSettings(defaults: store).isOn, "an upgrade keeps its choice")
        ThemeSettings(defaults: store).save(ThemeChoice(followsMac: false, single: "dracula"))
        #expect(store.bool(forKey: "ShellforgeMatchTerminal"), "a theme leaves it be")
    }
}
