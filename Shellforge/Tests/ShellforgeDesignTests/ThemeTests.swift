import Testing
@testable import ShellforgeDesign

/// The ten themes, which one applies for a choice, and that every theme reads.
@Suite struct ThemeTests {
    @Test func theCatalogIsTheTenThemesInOrder() {
        #expect(ThemeCatalog.all.map(\.name) == [
            "Shellforge", "Dark Modern", "Light Modern", "One Dark", "Dracula",
            "GitHub Dark", "GitHub Light", "Solarized Dark", "Solarized Light", "Nord",
        ])
        #expect(ThemeCatalog.all.map(\.id) == [
            "shellforge", "dark-modern", "light-modern", "one-dark", "dracula",
            "github-dark", "github-light", "solarized-dark", "solarized-light", "nord",
        ])
        #expect(ThemeCatalog.shellforge.appearance == .adaptive)
        #expect(ThemeCatalog.shellforge.colors == nil)
        #expect(ThemeCatalog.shellforge.terminal == nil)
        #expect(ThemeCatalog.all.dropFirst().allSatisfy { $0.appearance != .adaptive })
    }

    @Test func unknownIdsAreShellforge() {
        #expect(ThemeCatalog.theme(id: nil) == ThemeCatalog.shellforge)
        #expect(ThemeCatalog.theme(id: "no-such-theme") == ThemeCatalog.shellforge)
        #expect(ThemeCatalog.theme(id: "").id == "shellforge")
        #expect(ThemeCatalog.theme(id: "nord").name == "Nord")
    }

    @Test func followMacPicksTheSlotForTheAppearance() {
        let choice = ThemeChoice(followsMac: true, light: "github-light", dark: "dracula", single: "nord")
        #expect(choice.active(isDark: true).id == "dracula")
        #expect(choice.active(isDark: false).id == "github-light")
        #expect(ThemeChoice().active(isDark: true) == ThemeCatalog.shellforge)
        #expect(ThemeChoice().active(isDark: false) == ThemeCatalog.shellforge)
    }

    @Test func aSingleThemeIgnoresTheMac() {
        let choice = ThemeChoice(followsMac: false, light: "github-light", dark: "dracula", single: "nord")
        #expect(choice.active(isDark: true).id == "nord")
        #expect(choice.active(isDark: false).id == "nord")
    }

    @Test func forcedAppearanceIsTheSingleThemes() {
        func forced(_ single: String, followsMac: Bool = false) -> Theme.Appearance? {
            ThemeChoice(followsMac: followsMac, single: single).forcedAppearance()
        }
        #expect(forced("dracula") == .dark)
        #expect(forced("light-modern") == .light)
        #expect(forced("shellforge") == nil)
        #expect(forced("no-such-theme") == nil)
        #expect(forced("dracula", followsMac: true) == nil)
    }

    /// Text on the background and on the sidebar at least 4.5:1, the accent on the background at
    /// least 3:1 (WCAG 2, from relative luminance).
    @Test(arguments: ThemeCatalog.all.filter { $0.colors != nil })
    func everyThemeIsReadable(theme: Theme) throws {
        let colors = try #require(theme.colors)
        #expect(colors.text.contrast(with: colors.background) >= 4.5, "\(theme.name): text on background")
        #expect(colors.text.contrast(with: colors.sidebar) >= 4.5, "\(theme.name): text on sidebar")
        #expect(colors.accent.contrast(with: colors.background) >= 3, "\(theme.name): accent on background")
    }

    @Test(arguments: ThemeCatalog.all.filter { $0.appearance != .adaptive })
    func everyFixedThemeHasAllTerminalColours(theme: Theme) throws {
        let terminal = try #require(theme.terminal)
        #expect(terminal.count == 23, "\(theme.name)")
        #expect(TerminalColorRole.all.allSatisfy { terminal[$0] != nil }, "\(theme.name)")
    }

    @Test func aHexIsItsComponents() {
        #expect(SRGB(hex: 0xFF8000) == SRGB(red: 1, green: 128.0 / 255, blue: 0))
    }

    @Test func theContrastIsWCAGs() {
        let black = SRGB(hex: 0x000000), white = SRGB(hex: 0xFFFFFF)
        #expect(abs(black.contrast(with: white) - 21) < 0.0001)
        #expect(abs(SRGB(hex: 0x767676).contrast(with: white) - 4.54) < 0.01)
    }
}

extension Theme: CustomTestStringConvertible {
    public var testDescription: String { name }
}
