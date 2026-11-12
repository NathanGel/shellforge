import Foundation

/// The ten themes, in the order the menus list them. Shellforge is adaptive and keeps today’s
/// values; every other theme is one appearance, its colours from its own published palette.
public enum ThemeCatalog {
    public static let shellforge = Theme(id: "shellforge", name: "Shellforge", appearance: .adaptive, colors: nil, terminal: nil)

    public static let all: [Theme] = [
        shellforge, darkModern, lightModern, oneDark, dracula,
        githubDark, githubLight, solarizedDark, solarizedLight, nord,
    ]

    /// The theme with `id`; Shellforge when there is none, or no such theme.
    public static func theme(id: String?) -> Theme {
        all.first { $0.id == id } ?? shellforge
    }

    // MARK: - VS Code

    /// VS Code’s built-in Dark Modern (`dark_modern.json`, over `dark_vs`/`dark_plus` defaults) and
    /// its default dark terminal colours (`terminalColorRegistry`). Raised is the input and
    /// dropdown fill; the terminal’s background is the panel’s, as VS Code draws it.
    static let darkModern = Theme(
        id: "dark-modern", name: "Dark Modern", appearance: .dark,
        colors: colors(background: 0x1F1F1F, raised: 0x313131, sidebar: 0x181818, text: 0xCCCCCC, muted: 0x9D9D9D,
                       border: 0x2B2B2B, accent: 0x0078D4, onAccent: 0xFFFFFF, selection: 0x04395E, hover: 0x2A2D2E,
                       link: 0x4DAAFC, green: 0x73C991, amber: 0xCCA700, red: 0xF14C4C),
        terminal: terminal(background: 0x181818, foreground: 0xCCCCCC, bold: 0xCCCCCC, cursor: 0xAEAFAD,
                           cursorText: 0x181818, selection: 0x264F78, selectedText: 0xCCCCCC,
                           ansi: [0x000000, 0xCD3131, 0x0DBC79, 0xE5E510, 0x2472C8, 0xBC3FBC, 0x11A8CD, 0xE5E5E5,
                                  0x666666, 0xF14C4C, 0x23D18B, 0xF5F543, 0x3B8EEA, 0xD670D6, 0x29B8DB, 0xE5E5E5]))

    /// VS Code’s built-in Light Modern (`light_modern.json`, over `light_vs`/`light_plus`
    /// defaults) and its default light terminal colours (`terminalColorRegistry`). Muted is the
    /// placeholder foreground; the terminal’s background is the panel’s.
    static let lightModern = Theme(
        id: "light-modern", name: "Light Modern", appearance: .light,
        colors: colors(background: 0xFFFFFF, raised: 0xFFFFFF, sidebar: 0xF8F8F8, text: 0x3B3B3B, muted: 0x767676,
                       border: 0xE5E5E5, accent: 0x005FB8, onAccent: 0xFFFFFF, selection: 0xE8E8E8, hover: 0xF2F2F2,
                       link: 0x005FB8, green: 0x388A34, amber: 0xBF8803, red: 0xE51400),
        terminal: terminal(background: 0xF8F8F8, foreground: 0x3B3B3B, bold: 0x3B3B3B, cursor: 0x000000,
                           cursorText: 0xF8F8F8, selection: 0xADD6FF, selectedText: 0x3B3B3B,
                           ansi: [0x000000, 0xCD3131, 0x107C10, 0x949800, 0x0451A5, 0xBC05BC, 0x0598BC, 0x555555,
                                  0x666666, 0xCD3131, 0x14CE14, 0xB5BA00, 0x0451A5, 0xBC05BC, 0x0598BC, 0xA5A5A5]))

    // MARK: - Atom

    /// Atom’s One Dark: the `one-dark-ui` surfaces and the `one-dark-syntax` colours (syntax-bg
    /// `#282C34`, mono-1 `#ABB2BF`, mono-3 `#5C6370`, hue-1…hue-6), the terminal’s ANSI colours
    /// being those hues.
    static let oneDark = Theme(
        id: "one-dark", name: "One Dark", appearance: .dark,
        colors: colors(background: 0x282C34, raised: 0x2C313A, sidebar: 0x21252B, text: 0xABB2BF, muted: 0x828997,
                       border: 0x181A1F, accent: 0x61AFEF, onAccent: 0x282C34, selection: 0x3A3F4B, hover: 0x2C313A,
                       link: 0x61AFEF, green: 0x98C379, amber: 0xE5C07B, red: 0xE06C75),
        terminal: terminal(background: 0x282C34, foreground: 0xABB2BF, bold: 0xABB2BF, cursor: 0x528BFF,
                           cursorText: 0x282C34, selection: 0x3E4451, selectedText: 0xABB2BF,
                           ansi: [0x21252B, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xABB2BF,
                                  0x5C6370, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xFFFFFF]))

    // MARK: - Dracula

    /// The Dracula spec (draculatheme.com/spec): its palette, its darker and lighter backgrounds
    /// for the sidebar and raised surfaces, and its ANSI terminal colours.
    static let dracula = Theme(
        id: "dracula", name: "Dracula", appearance: .dark,
        colors: colors(background: 0x282A36, raised: 0x343746, sidebar: 0x21222C, text: 0xF8F8F2, muted: 0x6272A4,
                       border: 0x191A21, accent: 0xBD93F9, onAccent: 0x282A36, selection: 0x44475A, hover: 0x424450,
                       link: 0x8BE9FD, green: 0x50FA7B, amber: 0xFFB86C, red: 0xFF5555),
        terminal: terminal(background: 0x282A36, foreground: 0xF8F8F2, bold: 0xF8F8F2, cursor: 0xF8F8F2,
                           cursorText: 0x282A36, selection: 0x44475A, selectedText: 0xF8F8F2,
                           ansi: [0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
                                  0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF]))

    // MARK: - GitHub

    /// GitHub Primer’s dark colours (`@primer/primitives`, dark): canvas, fg, border, accent,
    /// success, attention and danger, with the sidebar on canvas.inset as GitHub’s VS Code theme
    /// draws it, and Primer’s ANSI terminal colours. Selection and hover are Primer’s translucent
    /// neutral.muted and neutral.subtle, composited over canvas.default.
    static let githubDark = Theme(
        id: "github-dark", name: "GitHub Dark", appearance: .dark,
        colors: colors(background: 0x0D1117, raised: 0x161B22, sidebar: 0x010409, text: 0xE6EDF3, muted: 0x7D8590,
                       border: 0x30363D, accent: 0x1F6FEB, onAccent: 0xFFFFFF, selection: 0x343941, hover: 0x171B22,
                       link: 0x2F81F7, green: 0x3FB950, amber: 0xD29922, red: 0xF85149),
        terminal: terminal(background: 0x0D1117, foreground: 0xE6EDF3, bold: 0xE6EDF3, cursor: 0x2F81F7,
                           cursorText: 0x0D1117, selection: 0x1E4273, selectedText: 0xE6EDF3,
                           ansi: [0x484F58, 0xFF7B72, 0x3FB950, 0xD29922, 0x58A6FF, 0xBC8CFF, 0x39C5CF, 0xB1BAC4,
                                  0x6E7681, 0xFFA198, 0x56D364, 0xE3B341, 0x79C0FF, 0xD2A8FF, 0x56D4DD, 0xFFFFFF]))

    /// GitHub Primer’s light colours (`@primer/primitives`, light): canvas, fg, border, accent,
    /// success, attention and danger, the selection on accent.subtle, and Primer’s ANSI terminal
    /// colours. The terminal selection is accent.fg at 20 % over white, as GitHub’s VS Code theme.
    static let githubLight = Theme(
        id: "github-light", name: "GitHub Light", appearance: .light,
        colors: colors(background: 0xFFFFFF, raised: 0xFFFFFF, sidebar: 0xF6F8FA, text: 0x1F2328, muted: 0x656D76,
                       border: 0xD0D7DE, accent: 0x0969DA, onAccent: 0xFFFFFF, selection: 0xDDF4FF, hover: 0xEAEEF2,
                       link: 0x0969DA, green: 0x1A7F37, amber: 0x9A6700, red: 0xD1242F),
        terminal: terminal(background: 0xFFFFFF, foreground: 0x1F2328, bold: 0x1F2328, cursor: 0x0969DA,
                           cursorText: 0xFFFFFF, selection: 0xCEE1F8, selectedText: 0x1F2328,
                           ansi: [0x24292F, 0xCF222E, 0x116329, 0x4D2D00, 0x0969DA, 0x8250DF, 0x1B7C83, 0x6E7781,
                                  0x57606A, 0xA40E26, 0x1A7F37, 0x633C01, 0x218BFF, 0xA475F9, 0x3192AA, 0x8C959F]))

    // MARK: - Solarized

    /// Ethan Schoonover’s Solarized (ethanschoonover.com/solarized), dark: base03 background,
    /// base02 raised, base0 text, base01 muted, blue accent, and the canonical terminal mapping
    /// (bright colours on the base tones and orange/violet). The sidebar is VS Code’s Solarized
    /// Dark one, darker than base03: base0 text on base02 is under 4.5:1. Selection and hover are
    /// VS Code’s Solarized Dark list colours.
    static let solarizedDark = Theme(
        id: "solarized-dark", name: "Solarized Dark", appearance: .dark,
        colors: colors(background: 0x002B36, raised: 0x073642, sidebar: 0x00212B, text: 0x839496, muted: 0x586E75,
                       border: 0x073642, accent: 0x268BD2, onAccent: 0x002B36, selection: 0x005A6F, hover: 0x004454,
                       link: 0x268BD2, green: 0x859900, amber: 0xB58900, red: 0xDC322F),
        terminal: terminal(background: 0x002B36, foreground: 0x839496, bold: 0x93A1A1, cursor: 0x93A1A1,
                           cursorText: 0x002B36, selection: 0x073642, selectedText: 0x93A1A1,
                           ansi: solarizedANSI))

    /// Ethan Schoonover’s Solarized, light: base3 background, base01 text (its emphasised tone:
    /// the body tone, base00, is under 4.5:1 on base3), base00 muted, blue accent, the canonical
    /// terminal mapping. The sidebar is halfway from base3 to base2: base01 on base2 is under
    /// 4.5:1. Selection is VS Code’s Solarized Light list selection.
    static let solarizedLight = Theme(
        id: "solarized-light", name: "Solarized Light", appearance: .light,
        colors: colors(background: 0xFDF6E3, raised: 0xFDF6E3, sidebar: 0xF6EFDC, text: 0x586E75, muted: 0x657B83,
                       border: 0xEEE8D5, accent: 0x268BD2, onAccent: 0xFDF6E3, selection: 0xDFCA88, hover: 0xEEE8D5,
                       link: 0x268BD2, green: 0x859900, amber: 0xB58900, red: 0xDC322F),
        terminal: terminal(background: 0xFDF6E3, foreground: 0x657B83, bold: 0x586E75, cursor: 0x586E75,
                           cursorText: 0xFDF6E3, selection: 0xEEE8D5, selectedText: 0x586E75,
                           ansi: solarizedANSI))

    /// Solarized’s 16 ANSI colours, the same for dark and light.
    private static let solarizedANSI: [UInt32] = [
        0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
        0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3,
    ]

    // MARK: - Nord

    /// Arctic Ice Studio’s Nord (nordtheme.com): Polar Night nord0–nord3 for the surfaces, Snow
    /// Storm nord4 for text, Frost nord8 for the accent, Aurora for status, and Nord’s own terminal
    /// mapping (nord-iterm2). Muted is nord4 at 60 % over nord0: Nord’s comment grey is under 3:1.
    static let nord = Theme(
        id: "nord", name: "Nord", appearance: .dark,
        colors: colors(background: 0x2E3440, raised: 0x3B4252, sidebar: 0x3B4252, text: 0xD8DEE9, muted: 0x949AA5,
                       border: 0x434C5E, accent: 0x88C0D0, onAccent: 0x2E3440, selection: 0x4C566A, hover: 0x434C5E,
                       link: 0x88C0D0, green: 0xA3BE8C, amber: 0xEBCB8B, red: 0xBF616A),
        terminal: terminal(background: 0x2E3440, foreground: 0xD8DEE9, bold: 0xECEFF4, cursor: 0xD8DEE9,
                           cursorText: 0x2E3440, selection: 0x434C5E, selectedText: 0xD8DEE9,
                           ansi: [0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0,
                                  0x4C566A, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4]))

    // MARK: - Building

    private static func colors(background: UInt32, raised: UInt32, sidebar: UInt32, text: UInt32, muted: UInt32,
                               border: UInt32, accent: UInt32, onAccent: UInt32, selection: UInt32, hover: UInt32,
                               link: UInt32, green: UInt32, amber: UInt32, red: UInt32) -> ThemeColors {
        ThemeColors(background: SRGB(hex: background), raised: SRGB(hex: raised), sidebar: SRGB(hex: sidebar),
                    text: SRGB(hex: text), muted: SRGB(hex: muted), border: SRGB(hex: border),
                    accent: SRGB(hex: accent), onAccent: SRGB(hex: onAccent), selection: SRGB(hex: selection),
                    hover: SRGB(hex: hover), link: SRGB(hex: link), green: SRGB(hex: green),
                    amber: SRGB(hex: amber), red: SRGB(hex: red))
    }

    /// The 23 terminal colours; `ansi` is colours 0–15 in order.
    private static func terminal(background: UInt32, foreground: UInt32, bold: UInt32, cursor: UInt32,
                                 cursorText: UInt32, selection: UInt32, selectedText: UInt32,
                                 ansi: [UInt32]) -> [TerminalColorRole: SRGB] {
        var colors: [TerminalColorRole: SRGB] = [
            .background: SRGB(hex: background), .foreground: SRGB(hex: foreground), .bold: SRGB(hex: bold),
            .cursor: SRGB(hex: cursor), .cursorText: SRGB(hex: cursorText), .selection: SRGB(hex: selection),
            .selectedText: SRGB(hex: selectedText),
        ]
        for (index, hex) in ansi.enumerated() {
            colors[.ansi(index)] = SRGB(hex: hex)
        }
        return colors
    }
}
