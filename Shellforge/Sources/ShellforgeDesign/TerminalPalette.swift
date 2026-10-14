import AppKit

/// One of the 23 colours a terminal profile carries that the Shellforge match sets.
public enum TerminalColorRole: Hashable, Sendable {
    case background, foreground, bold, cursor, cursorText, selection, selectedText
    /// ANSI colour 0–15: 0–7 normal, 8–15 bright.
    case ansi(Int)

    public static let all: [TerminalColorRole] =
        [.background, .foreground, .bold, .cursor, .cursorText, .selection, .selectedText] + (0..<16).map { .ansi($0) }

    /// Held to `ShellforgeTerminalPalette.minimumContrast` against the background. Black and bright
    /// black are meant to be dim; the cursor and selection are fills, not text.
    public var needsContrast: Bool {
        switch self {
        case .foreground, .bold: true
        case .ansi(let index): index != 0 && index != 8
        case .background, .cursor, .cursorText, .selection, .selectedText: false
        }
    }
}

/// An opaque sRGB colour, components 0…1.
public struct SRGB: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// `color` in sRGB, its alpha composited over `background`: the label colours are white at
    /// less than full alpha, and a terminal colour cannot be translucent.
    init(_ color: NSColor, over background: SRGB) {
        guard let srgb = color.usingColorSpace(.sRGB) else {
            self = background
            return
        }
        let alpha = Double(srgb.alphaComponent)
        red = Double(srgb.redComponent) * alpha + background.red * (1 - alpha)
        green = Double(srgb.greenComponent) * alpha + background.green * (1 - alpha)
        blue = Double(srgb.blueComponent) * alpha + background.blue * (1 - alpha)
    }

    /// WCAG 2 relative luminance.
    private var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG 2 contrast ratio, 1…21.
    public func contrast(with other: SRGB) -> Double {
        let (a, b) = (luminance + 0.05, other.luminance + 0.05)
        return max(a, b) / min(a, b)
    }

    /// Mixed with `fraction` white.
    public func lightened(by fraction: Double) -> SRGB {
        SRGB(red: red + (1 - red) * fraction, green: green + (1 - green) * fraction, blue: blue + (1 - blue) * fraction)
    }

    /// Mixed with `fraction` black.
    public func darkened(by fraction: Double) -> SRGB {
        SRGB(red: red * (1 - fraction), green: green * (1 - fraction), blue: blue * (1 - fraction))
    }
}

/// The macOS colours Shellforge's terminal palette is read from: the sidebar's own, so a matched
/// terminal and the sidebar read as one surface. `NSColor`s, not `Palette`'s `Color`s, because the
/// palette resolves them under an appearance into iTerm2's sRGB values. Each line is a
/// `DesignRulesTests` exception: `Palette.swift` stays AiTerm's (TokenParityTests).
enum TerminalSource {
    static let surface = NSColor.windowBackgroundColor
    static let text = NSColor.labelColor
    static let cursor = NSColor.controlAccentColor
    static let selection = NSColor.selectedContentBackgroundColor
    static let black = NSColor.underPageBackgroundColor
    static let brightBlack = NSColor.tertiaryLabelColor
    static let white = NSColor.secondaryLabelColor
    /// ANSI 1–6; their bright versions (9–14) are these, lightened.
    static let hues: [(index: Int, color: NSColor)] = [(1, .systemRed), (2, .systemGreen), (3, .systemYellow),
                                                        (4, .systemBlue), (5, .systemPurple), (6, .systemTeal)]
}

/// Shellforge's terminal colours: the sidebar's own macOS colours, read under `appearance` (dark,
/// as the sidebar always is) each time they are asked for, so they follow the accent colour and
/// Increase Contrast.
public enum ShellforgeTerminalPalette {
    public static let minimumContrast = 4.5
    /// How much black the terminal's background mixes into the sidebar's surface: a step darker, so
    /// the sidebar reads as its own panel beside the terminal, still one family.
    public static let backgroundStep = 0.06

    public static func colors(in appearance: NSAppearance? = NSAppearance(named: .darkAqua)) -> [TerminalColorRole: SRGB] {
        var colors: [TerminalColorRole: SRGB] = [:]
        let draw = { (work: () -> Void) in
            if let appearance { appearance.performAsCurrentDrawingAppearance(work) } else { work() }
        }
        draw {
            let opaqueBlack = SRGB(red: 0, green: 0, blue: 0)
            let background = SRGB(TerminalSource.surface, over: opaqueBlack).darkened(by: backgroundStep)
            func read(_ color: NSColor) -> SRGB { SRGB(color, over: background) }
            colors[.background] = background
            colors[.foreground] = read(TerminalSource.text)
            colors[.bold] = read(TerminalSource.text)
            colors[.cursor] = read(TerminalSource.cursor)
            colors[.cursorText] = background
            colors[.selection] = read(TerminalSource.selection)
            colors[.selectedText] = read(TerminalSource.text)
            colors[.ansi(0)] = read(TerminalSource.black)
            colors[.ansi(8)] = read(TerminalSource.brightBlack)
            colors[.ansi(7)] = read(TerminalSource.white)
            colors[.ansi(15)] = read(TerminalSource.text)
            for (index, hue) in TerminalSource.hues {
                colors[.ansi(index)] = read(hue)
                colors[.ansi(index + 8)] = read(hue).lightened(by: 0.2)
            }
            for role in TerminalColorRole.all where role.needsContrast {
                if let color = colors[role] { colors[role] = readable(color, on: background) }
            }
        }
        return colors
    }

    /// `color`, lightened in 5 % steps until it reaches `minimumContrast` on `background`.
    public static func readable(_ color: SRGB, on background: SRGB) -> SRGB {
        var color = color
        for _ in 0..<100 where color.contrast(with: background) < minimumContrast {
            color = color.lightened(by: 0.05)
        }
        return color
    }
}
