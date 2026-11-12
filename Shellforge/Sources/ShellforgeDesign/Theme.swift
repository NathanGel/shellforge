import Foundation

/// A look for everything Shellforge draws and, with Match Terminal on, for the terminal: its 14
/// base colours and its 23 terminal colours. Every other `Palette` token is derived from the base
/// colours; brand colours never change.
public struct Theme: Identifiable, Equatable, Sendable {
    /// Whether a theme is light, dark, or both — following the window, as Shellforge’s own does.
    public enum Appearance: Sendable {
        case light, dark, adaptive
    }

    public let id: String
    public let name: String
    public let appearance: Appearance
    /// Nil only for the adaptive Shellforge theme, meaning today’s values.
    public let colors: ThemeColors?
    /// Nil only for the adaptive Shellforge theme, meaning today’s values.
    public let terminal: [TerminalColorRole: SRGB]?

    public init(id: String, name: String, appearance: Appearance, colors: ThemeColors?, terminal: [TerminalColorRole: SRGB]?) {
        self.id = id
        self.name = name
        self.appearance = appearance
        self.colors = colors
        self.terminal = terminal
    }
}

/// A theme’s 14 base colours.
public struct ThemeColors: Equatable, Sendable {
    /// The main surface: the editor, the panels’ content.
    public var background: SRGB
    /// Cards, sheets and fields that sit on the background.
    public var raised: SRGB
    /// The activity bar and the side panels.
    public var sidebar: SRGB
    public var text: SRGB
    public var muted: SRGB
    public var border: SRGB
    public var accent: SRGB
    /// Text and glyphs on an accent fill.
    public var onAccent: SRGB
    /// A selected row.
    public var selection: SRGB
    /// A hovered row.
    public var hover: SRGB
    public var link: SRGB
    public var green: SRGB
    public var amber: SRGB
    public var red: SRGB

    public init(background: SRGB, raised: SRGB, sidebar: SRGB, text: SRGB, muted: SRGB, border: SRGB,
                accent: SRGB, onAccent: SRGB, selection: SRGB, hover: SRGB, link: SRGB,
                green: SRGB, amber: SRGB, red: SRGB) {
        self.background = background
        self.raised = raised
        self.sidebar = sidebar
        self.text = text
        self.muted = muted
        self.border = border
        self.accent = accent
        self.onAccent = onAccent
        self.selection = selection
        self.hover = hover
        self.link = link
        self.green = green
        self.amber = amber
        self.red = red
    }
}

/// Which theme applies: one for each Mac appearance while following the Mac, otherwise one for
/// both. Each is a theme id; an unknown one is Shellforge.
public struct ThemeChoice: Equatable, Sendable {
    public var followsMac: Bool
    public var light: String
    public var dark: String
    public var single: String

    public init(followsMac: Bool = true, light: String = ThemeCatalog.shellforge.id,
                dark: String = ThemeCatalog.shellforge.id, single: String = ThemeCatalog.shellforge.id) {
        self.followsMac = followsMac
        self.light = light
        self.dark = dark
        self.single = single
    }

    /// The theme for a Mac that is dark or light: its slot’s while following the Mac, the single
    /// theme otherwise.
    public func active(isDark: Bool) -> Theme {
        guard followsMac else { return ThemeCatalog.theme(id: single) }
        return ThemeCatalog.theme(id: isDark ? dark : light)
    }

    /// The appearance the app is held to: the single theme’s, unless following the Mac or the
    /// single theme is adaptive (Shellforge), when the Mac decides.
    public func forcedAppearance() -> Theme.Appearance? {
        guard !followsMac else { return nil }
        let appearance = ThemeCatalog.theme(id: single).appearance
        return appearance == .adaptive ? nil : appearance
    }
}

extension SRGB {
    /// From a 24-bit `0xRRGGBB` value, as the themes publish their colours.
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
