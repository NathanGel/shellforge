import AppKit
import SwiftUI
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

// MARK: - The active theme

/// Today’s colours, frozen: each `Palette` token’s expression as `Palette.swift` wrote it before
/// themes came, so the Shellforge theme is held to what Shellforge drew, not to the new code.
@MainActor private enum Today {
    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    static let surface = Color(nsColor: .windowBackgroundColor)
    static let surfaceRaised = Color(nsColor: .underPageBackgroundColor)
    static let groupFill = adaptive(light: NSColor(white: 0, alpha: 0.017), dark: NSColor(white: 1, alpha: 0.014))
    static let groupEdge = adaptive(light: NSColor(white: 0, alpha: 0.076), dark: NSColor(white: 1, alpha: 0.135))
    static let fieldFill = adaptive(light: .white, dark: NSColor(white: 1, alpha: 0.09))
    static let border = Color(nsColor: .separatorColor)
    static let controlActive = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
    static let codeBackground = adaptive(light: NSColor(srgbRed: 0.949, green: 0.949, blue: 0.957, alpha: 1),
                                         dark: NSColor(srgbRed: 0x14 / 255.0, green: 0x15 / 255.0, blue: 0x19 / 255.0, alpha: 1))
    static let text = Color(nsColor: .labelColor)
    static let muted = Color(nsColor: .secondaryLabelColor)
    static let accent = Color(nsColor: .controlAccentColor)
    static let link = Color(nsColor: .linkColor)
    static let green = Color(nsColor: .systemGreen)
    static let amber = Color(nsColor: .systemOrange)
    static let destructive = Color(nsColor: .systemRed)
    static let onAccent = Color.white
    static let markInk = Color.black
    static let badge = Color.primary.opacity(0.08)
    static let badgeSelected = Color.white.opacity(0.2)
    static let badgeHovered = adaptive(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.14))
    static let badgeSelectedHovered = Color.white.opacity(0.28)
    static let footerCard = adaptive(light: NSColor(white: 0, alpha: 0.04), dark: NSColor(white: 1, alpha: 0.05))
    static let rowHover = adaptive(light: NSColor(white: 0, alpha: 0.05), dark: NSColor(white: 1, alpha: 0.06))
    static let rowHoverSolid = Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        var base = NSColor.windowBackgroundColor
        appearance.performAsCurrentDrawingAppearance {
            base = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? NSColor.windowBackgroundColor
        }
        let (wash, alpha): (CGFloat, CGFloat) = dark ? (1, 0.06) : (0, 0.05)
        return NSColor(srgbRed: base.redComponent * (1 - alpha) + wash * alpha,
                       green: base.greenComponent * (1 - alpha) + wash * alpha,
                       blue: base.blueComponent * (1 - alpha) + wash * alpha,
                       alpha: 1)
    })
    static let selection = Color(nsColor: .selectedContentBackgroundColor)
    static let idleRing = Color(nsColor: .tertiaryLabelColor)
    static let spinnerTrack = Color(white: 0.56, opacity: 0.28)

    /// Every token, today’s next to the live one. The derived and aliased tokens are written from
    /// today’s roots exactly as `Palette` writes them from its own.
    static let tokens: [(name: String, live: Color, today: Color)] = [
        ("surface", Palette.surface, surface), ("surfaceRaised", Palette.surfaceRaised, surfaceRaised),
        ("groupFill", Palette.groupFill, groupFill), ("groupEdge", Palette.groupEdge, groupEdge),
        ("fieldFill", Palette.fieldFill, fieldFill), ("menu", Palette.menu, surfaceRaised),
        ("border", Palette.border, border), ("controlActive", Palette.controlActive, controlActive),
        ("codeBackground", Palette.codeBackground, codeBackground), ("text", Palette.text, text),
        ("muted", Palette.muted, muted), ("accent", Palette.accent, accent),
        ("focusRing", Palette.focusRing, accent.opacity(0.35)), ("tabActive", Palette.tabActive, accent),
        ("link", Palette.link, link), ("green", Palette.green, green), ("amber", Palette.amber, amber),
        ("destructive", Palette.destructive, destructive), ("badgeAmber", Palette.badgeAmber, amber),
        ("diffAdded", Palette.diffAdded, green), ("diffRemoved", Palette.diffRemoved, destructive),
        ("devBuild", Palette.devBuild, amber), ("devBuildInk", Palette.devBuildInk, onAccent),
        ("onAccent", Palette.onAccent, onAccent), ("onAccentSecondary", Palette.onAccentSecondary, onAccent.opacity(0.75)),
        ("spinnerTrackOnAccent", Palette.spinnerTrackOnAccent, onAccent.opacity(0.3)),
        ("keycapFill", Palette.keycapFill, onAccent.opacity(0.22)), ("keycapStroke", Palette.keycapStroke, onAccent.opacity(0.16)),
        ("accentPressed", Palette.accentPressed, accent.opacity(0.8)), ("placeholder", Palette.placeholder, idleRing),
        ("faint", Palette.faint, muted.opacity(0.8)), ("markPaper", Palette.markPaper, onAccent),
        ("markInk", Palette.markInk, markInk), ("badge", Palette.badge, badge),
        ("badgeSelected", Palette.badgeSelected, badgeSelected), ("badgeHovered", Palette.badgeHovered, badgeHovered),
        ("badgeSelectedHovered", Palette.badgeSelectedHovered, badgeSelectedHovered),
        ("noticeError", Palette.noticeError, destructive.opacity(0.12)), ("noticeWarning", Palette.noticeWarning, amber.opacity(0.14)),
        ("noticeInfo", Palette.noticeInfo, muted.opacity(0.10)), ("footerCard", Palette.footerCard, footerCard),
        ("sidebar", Palette.sidebar, surface), ("rowHover", Palette.rowHover, rowHover),
        ("rowHoverSolid", Palette.rowHoverSolid, rowHoverSolid),
        ("statusChipQuietFill", Palette.statusChipQuietFill, muted.opacity(0.14)),
        ("statusChipQuietStroke", Palette.statusChipQuietStroke, muted.opacity(0.30)),
        ("statusChipAttentionFill", Palette.statusChipAttentionFill, amber.opacity(0.16)),
        ("statusChipAttentionStroke", Palette.statusChipAttentionStroke, amber.opacity(0.38)),
        ("statusChipDoneFill", Palette.statusChipDoneFill, accent.opacity(0.17)),
        ("statusChipDoneStroke", Palette.statusChipDoneStroke, accent.opacity(0.42)),
        ("selection", Palette.selection, selection), ("idleRing", Palette.idleRing, idleRing),
        ("spinnerTrack", Palette.spinnerTrack, spinnerTrack), ("spinner", Palette.spinner, muted), ("done", Palette.done, accent),
    ]

    /// `ShellforgeTerminalPalette.colors(in:)` as it was before themes came.
    static func terminalColors(in appearance: NSAppearance?) -> [TerminalColorRole: SRGB] {
        var colors: [TerminalColorRole: SRGB] = [:]
        let draw = { (work: () -> Void) in
            if let appearance { appearance.performAsCurrentDrawingAppearance(work) } else { work() }
        }
        draw {
            let opaqueBlack = SRGB(red: 0, green: 0, blue: 0)
            let background = ShellforgeTerminalPalette.background(beside: SRGB(NSColor.windowBackgroundColor, over: opaqueBlack))
            func read(_ color: NSColor) -> SRGB { SRGB(color, over: background) }
            colors[.background] = background
            colors[.foreground] = read(.labelColor)
            colors[.bold] = read(.labelColor)
            colors[.cursor] = read(.controlAccentColor)
            colors[.cursorText] = background
            colors[.selection] = read(.selectedContentBackgroundColor)
            colors[.selectedText] = read(.labelColor)
            colors[.ansi(0)] = read(.underPageBackgroundColor)
            colors[.ansi(8)] = read(.tertiaryLabelColor)
            colors[.ansi(7)] = read(.secondaryLabelColor)
            colors[.ansi(15)] = read(.labelColor)
            let hues: [(Int, NSColor)] = [(1, .systemRed), (2, .systemGreen), (3, .systemYellow),
                                          (4, .systemBlue), (5, .systemPurple), (6, .systemTeal)]
            for (index, hue) in hues {
                colors[.ansi(index)] = read(hue)
                colors[.ansi(index + 8)] = read(hue).lightened(by: 0.2)
            }
            for role in TerminalColorRole.all where role.needsContrast {
                if let color = colors[role] { colors[role] = ShellforgeTerminalPalette.readable(color, on: background) }
            }
        }
        return colors
    }
}

/// `color` resolved under the appearance `name`, as sRGB components with alpha.
@MainActor private func components(_ color: Color, in name: NSAppearance.Name) -> [CGFloat] {
    var out: [CGFloat] = []
    let appearance = NSAppearance(named: name) ?? NSAppearance.currentDrawing()
    appearance.performAsCurrentDrawingAppearance {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return }
        out = [srgb.redComponent, srgb.greenComponent, srgb.blueComponent, srgb.alphaComponent]
    }
    return out
}

@MainActor private func resolves(_ color: Color, to srgb: SRGB, in name: NSAppearance.Name) -> Bool {
    let c = components(color, in: name)
    return c.count == 4 && abs(c[0] - srgb.red) < 0.0001 && abs(c[1] - srgb.green) < 0.0001
        && abs(c[2] - srgb.blue) < 0.0001 && abs(c[3] - 1) < 0.0001
}

/// How far two resolutions of one colour may differ: a 32-bit float’s rounding, which SwiftUI’s
/// `opacity` stores an alpha in once the colour behind it is an `NSColor` — a millionth of the
/// 1⁄255 step a screen can show.
private let floatPrecision: CGFloat = 0.000001

/// The appearances today’s colours are held in: light and dark, each with Increase Contrast.
private let appearances: [NSAppearance.Name] = [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]

/// Counts how often a view appears, so a test can see `.themed()` rebuild its content.
@MainActor private final class AppearCount {
    var count = 0
}

private struct AppearCounter: View {
    let counter: AppearCount
    var body: some View {
        Color.clear.frame(width: 10, height: 10).onAppear { counter.count += 1 }
    }
}

/// How many times a store posted, counted wherever it posts from.
private final class PostCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    private(set) var offMain = false
    var count: Int { lock.withLock { value } }
    func add() { lock.withLock { value += 1; if !Thread.isMainThread { offMain = true } } }
}

extension ThemeTests {
    @MainActor @Test func theShellforgeThemeIsTodaysPalette() {
        ThemeRuntime.$override.withValue(ThemeCatalog.shellforge) {
            for token in Today.tokens {
                for name in appearances {
                    let live = components(token.live, in: name), today = components(token.today, in: name)
                    #expect(live.count == 4 && today.count == 4 && zip(live, today).allSatisfy { abs($0 - $1) < floatPrecision },
                            "\(token.name) in \(name.rawValue): \(live) is not today’s \(today)")
                }
            }
        }
    }

    @MainActor @Test func everyTokenIsHeldToToday() {
        // The frozen list covers every token the manifest in PaletteDistinctionTests names.
        #expect(Today.tokens.count == 55)
        #expect(Set(Today.tokens.map(\.name)).count == Today.tokens.count)
    }

    @MainActor @Test("The Shellforge terminal colours are today’s") func theShellforgeTerminalColoursAreTodays() {
        ThemeRuntime.$override.withValue(ThemeCatalog.shellforge) {
            for name in appearances {
                #expect(ShellforgeTerminalPalette.colors(in: NSAppearance(named: name)) == Today.terminalColors(in: NSAppearance(named: name)),
                        "\(name.rawValue)")
            }
        }
    }

    @Test func aFixedThemeHasItsOwnTerminalColours() throws {
        let dracula = ThemeCatalog.theme(id: "dracula")
        let terminal = try #require(dracula.terminal)
        ThemeRuntime.$override.withValue(dracula) {
            #expect(ShellforgeTerminalPalette.colors(in: NSAppearance(named: .aqua)) == terminal)
            #expect(ShellforgeTerminalPalette.colors(in: NSAppearance(named: .darkAqua)) == terminal)
        }
    }

    @MainActor @Test func aFixedThemeColoursTheTokens() throws {
        let dracula = ThemeCatalog.theme(id: "dracula")
        let colors = try #require(dracula.colors)
        ThemeRuntime.$override.withValue(dracula) {
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                #expect(resolves(Palette.surface, to: colors.background, in: name), "surface in \(name.rawValue)")
                #expect(resolves(Palette.sidebar, to: colors.background, in: name), "sidebar in \(name.rawValue)")
                #expect(resolves(Palette.surfaceRaised, to: colors.raised, in: name), "surfaceRaised in \(name.rawValue)")
                #expect(resolves(Palette.text, to: colors.text, in: name), "text in \(name.rawValue)")
                #expect(resolves(Palette.muted, to: colors.muted, in: name), "muted in \(name.rawValue)")
                #expect(resolves(Palette.border, to: colors.border, in: name), "border in \(name.rawValue)")
                #expect(resolves(Palette.onAccent, to: colors.onAccent, in: name), "onAccent in \(name.rawValue)")
                #expect(resolves(Palette.selection, to: colors.selection, in: name), "selection in \(name.rawValue)")
                #expect(resolves(Palette.rowHover, to: colors.hover, in: name), "rowHover in \(name.rawValue)")
                #expect(resolves(Palette.rowHoverSolid, to: colors.hover, in: name), "rowHoverSolid in \(name.rawValue)")
                #expect(resolves(Palette.link, to: colors.link, in: name), "link in \(name.rawValue)")
                #expect(resolves(Palette.green, to: colors.green, in: name), "green in \(name.rawValue)")
                #expect(resolves(Palette.amber, to: colors.amber, in: name), "amber in \(name.rawValue)")
                #expect(resolves(Palette.destructive, to: colors.red, in: name), "destructive in \(name.rawValue)")
            }
        }
    }

    /// Every token takes a fixed theme’s colours: none still shows a macOS colour that would differ
    /// between light and dark.
    @MainActor @Test(arguments: ThemeCatalog.all.filter { $0.colors != nil })
    func aFixedThemeLooksTheSameInLightAndDark(theme: Theme) {
        ThemeRuntime.$override.withValue(theme) {
            for token in Today.tokens where token.name != "markInk" {
                #expect(components(token.live, in: .aqua) == components(token.live, in: .darkAqua), "\(theme.name): \(token.name)")
            }
        }
    }

    @MainActor @Test func theAccentFollowsTheTheme() throws {
        for id in ["dracula", "nord", "github-light"] {
            let theme = ThemeCatalog.theme(id: id)
            let colors = try #require(theme.colors)
            ThemeRuntime.$override.withValue(theme) {
                #expect(resolves(Palette.accent, to: colors.accent, in: .darkAqua), "\(id)")
                #expect(resolves(Palette.tabActive, to: colors.accent, in: .aqua), "\(id)")
                #expect(components(Palette.focusRing, in: .darkAqua).last.map { abs($0 - 0.35) < 0.0001 } == true, "\(id)")
            }
        }
        ThemeRuntime.$override.withValue(ThemeCatalog.shellforge) {
            #expect(components(Palette.accent, in: .darkAqua) == components(Color(nsColor: .controlAccentColor), in: .darkAqua))
        }
    }

    @MainActor @Test func brandColoursNeverChange() {
        let brands = [Palette.claude, Palette.jira, Palette.gitlab, Palette.vscode, Palette.openai, Palette.grok]
        func resolved() -> [[CGFloat]] {
            brands.map { components($0.color, in: .darkAqua) } + [components(Palette.markInk, in: .darkAqua)]
        }
        let shellforge = ThemeRuntime.$override.withValue(ThemeCatalog.shellforge) { resolved() }
        for theme in ThemeCatalog.all {
            ThemeRuntime.$override.withValue(theme) {
                #expect(resolved() == shellforge, "\(theme.name)")
                #expect(brands.map(\.hex) == ["#D97757", "#2684FF", "#FC6D26", "#23A9F2", "#000000", "#000000"])
            }
        }
    }

    @MainActor @Test func settingTheThemePostsOnce() {
        let store = ThemeStore()
        let posts = PostCount()
        let observer = NotificationCenter.default.addObserver(forName: ThemeRuntime.didChange, object: store, queue: nil) { _ in
            posts.add()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let dracula = ThemeCatalog.theme(id: "dracula")

        #expect(store.current == ThemeCatalog.shellforge)
        store.set(ThemeCatalog.shellforge)
        #expect(posts.count == 0, "setting the theme already set posts nothing")
        store.set(dracula)
        #expect(posts.count == 1)
        #expect(store.current == dracula)
        store.set(dracula)
        #expect(posts.count == 1)
        store.set(ThemeCatalog.shellforge)
        #expect(posts.count == 2)
        #expect(!posts.offMain)
    }

    @Test func theAppStartsInShellforge() {
        #expect(ThemeStore().current == ThemeCatalog.shellforge)
        #expect(ThemeRuntime.$override.withValue(nil) { ThemeRuntime.current } == ThemeRuntime.shared.current)
    }

    @MainActor @Test func themedRebuildsItsContentOnAThemeChange() {
        let counter = AppearCount()
        let host = NSHostingView(rootView: AppearCounter(counter: counter).themed())
        host.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
        let window = window(hosting: host, orderFront: false)
        defer { window.close() }
        settle(host)
        let before = counter.count
        #expect(before >= 1)
        NotificationCenter.default.post(name: ThemeRuntime.didChange, object: nil)
        settle(host)
        #expect(counter.count > before)
    }
}
