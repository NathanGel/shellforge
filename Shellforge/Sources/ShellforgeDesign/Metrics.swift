// Ported from AiTerm (app/Sources/AiTermUI/Metrics.swift), GPLv3, Laurens D'Hondt.
import SwiftUI

// The scales every AiTerm surface is drawn from.
//
// Where macOS publishes a scale, these are *its* numbers rather than a house set: the system text
// styles, AppKit's control sizes and AppKit's corner radii. That is the whole argument for them —
// a new control takes its height, radius and text size from here instead of from whatever looked
// right beside its neighbour.
//
// A consistency audit (17 Sep 2026) counted nine text sizes, five corner radii, seventeen padding
// values, two chip heights and three sheet footers across `Views/` before this file existed. This
// file is the source of truth; see `app/Sources/AiTermUI/README.md`.

/// Distance between things. Three named steps off the 4 pt rhythm (`hairline`, `snug`, `inset`)
/// earn their place inside chips, control tracks and field interiors, where the rhythm's own steps
/// are the wrong size.
public enum Space {
    /// Inside a segmented track, between it and its selected segment.
    public static let hairline: CGFloat = 2
    /// Icon to label inside a chip.
    public static let tight: CGFloat = 4
    /// A label to its control; a branch name to its `+n` chip.
    public static let snug: CGFloat = 6
    /// Related controls; a row's leading padding.
    public static let base: CGFloat = 8
    /// The one off-rhythm step at this width: a control's own interior padding (a text field and
    /// the command block, horizontally), and, at the same width, the gap between a row's avatar and
    /// its text (`SidebarView`) and between a footer row's vendor mark and its text
    /// (`SidebarFooter`). Also the sidebar `List`'s own inset, which the sidebar footer — below the
    /// list, not in it — adds back to line up with the rows. Off the 8 pt rhythm on purpose — at 8
    /// the text crowds the field's stroke, at 12 a short value looks lost.
    public static let inset: CGFloat = 10
    /// Two fields side by side; the quiet badges along a sidebar row's subtitle line, which have
    /// no box to separate them.
    public static let gap: CGFloat = 12
    /// Field to field, section to section, and a sheet footer's padding.
    public static let block: CGFloat = 16
    /// A task row's indent under its project; a sheet header's top.
    public static let section: CGFloat = 20
    /// The sheet gutter.
    public static let margin: CGFloat = 24
}

/// AppKit's control radii: 4 at the small control size, 6 at regular, 8 at large — and 10, which is
/// what a macOS popover uses, for anything that floats.
public enum Radius {
    /// Badges, the `+n` chip, a menu row's highlight, the provider tile.
    public static let chip: CGFloat = 4
    /// Fields, buttons, sidebar rows, the command block.
    public static let control: CGFloat = 6
    /// Segmented tracks and the boxed groups in Settings.
    public static let group: CGFloat = 8
    /// Menus, dropdowns, the completion popup.
    public static let panel: CGFloat = 10
}

/// Heights, widths and diameters: the sidebar's own widths, every control and row height, and the
/// marks drawn inside them.
public enum Size {
    /// The edge of a Settings section's box: one device pixel at 2×, as the native grouped box draws it.
    public static let groupEdge: CGFloat = 0.5
    /// The width the sidebar opens at when there is no saved frame. It is sized to a task row rather
    /// than to the footer: at 360 a row carrying a Jira key, a diff and a `+n` squeezes its branch
    /// to `feat/f…t-side`; here the branch keeps its type, the ticket's prefix and its tail, and a
    /// branch without a ticket beside it nearly fits whole (proposal, 23 Sep 2026).
    public static let sidebarWidth: CGFloat = 420
    /// The sidebar cannot be narrowed past this. It has to fit a vendor usage row's common case:
    /// two windows under 100%, the 5-hour one resetting today and the weekly one on a later day.
    /// Everything at 100% costs a digit per segment and clips — the accepted price of showing clock
    /// times rather than a countdown.
    /// `SidebarFooterGeometryTests.theTwoWindowTelemetryFitsTheMinimumSidebarWidth` holds this honest.
    /// The context row's widest case — a full window and both token counts at `999k` — fits too, held
    /// by `SidebarFooterGeometryTests.theWidestContextRowFitsTheMinimumSidebarWidth`.
    ///
    /// Was 395 while each vendor row also carried its `ctx` segment; that moved to the footer's
    /// task row, which carries nothing else, so the minimum came back to 360.
    public static let sidebarMinWidth: CGFloat = 360
    /// Every chip: the Jira key, the VS Code badge, `+n`, a status count.
    public static let chip: CGFloat = 16
    /// The click target the sidebar's trailing column is built from.
    public static let slot: CGFloat = 20
    /// A row in a menu, a dropdown or the completion popup; the sidebar's `PROJECTS` header and a
    /// `DividerRow`; and a sidebar footer row and its SYSTEM and USAGE headings. Also the width a
    /// picker's list toggle answers to clicks in (`SearchPicker`).
    public static let menuRow: CGFloat = 24
    /// A field, a pop-up button, a segmented track, a footer button — `.controlSize(.large)`.
    public static let control: CGFloat = 28
    /// A project header.
    public static let projectRow: CGFloat = 28
    /// A task or terminal row: its two lines (a 16 pt title, `Space.tight`, a 16 pt chip line)
    /// inside `Space.base` above and below. Was 44, with 5 pt around the text and a 2 pt gap
    /// between the lines, which read as cramped (proposal A, 23 Sep 2026).
    public static let row: CGFloat = 52
    /// A vendor mark in an avatar group, and the provider tile beside a project name. Also an
    /// icon-only `Badge`'s width.
    public static let avatar: CGFloat = 18
    /// A vendor mark outside an avatar group: the sidebar footer, the agent picker.
    public static let vendorMark: CGFloat = 16
    /// A status mark on a row, and the sidebar footer's ring drawn to its recipe. A row's mark sits in
    /// the trailing column, so this is ``trailingGlyph``, declared as an alias; inside a count chip it
    /// is drawn at ``statusMarkSmall``.
    public static let statusMark = trailingGlyph
    /// The smaller status mark drawn inside a count chip, where ``statusMark``'s usual size would
    /// overflow it; and a tone's dot, leading a Settings card's status line and the footer's
    /// backpack line.
    public static let statusMarkSmall: CGFloat = 8
    /// The ink in the sidebar's trailing column, centred in a ``slot``.
    public static let trailingGlyph: CGFloat = 10
    /// The column a project row's disclosure chevron sits in, leading its provider tile. Its own
    /// name, not ``trailingGlyph``'s: that one feeds the trailing column's inset arithmetic, and a
    /// change there must not move this glyph.
    public static let chevron: CGFloat = 10
    /// A vendor mark beside a picked item in a picker's field: the ticket, the merge request, the
    /// Jira project.
    public static let pickerLogo: CGFloat = 13
    /// A vendor mark in a picker's result row — smaller than ``pickerLogo``, to sit inside a
    /// ``menuRow``.
    public static let pickerRowLogo: CGFloat = 11
}

/// A text style's parts, kept separate so `Typography` can declare size, weight and design
/// independently and `nsFont` below can consult all three rather than guessing at the ones a single
/// `Font` value would hide. `View.font(_:)` takes a `TypeStyle` directly, so call sites are unchanged.
public struct TypeStyle: Sendable, Equatable {
    public let size: CGFloat
    public let weight: Font.Weight
    public let design: Font.Design

    public init(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) {
        self.size = size
        self.weight = weight
        self.design = design
    }

    /// The same style at `scale`. Not rounded: text that grew faster than the whole-point layout
    /// around it would clip, and the system face sets cleanly at fractional sizes.
    public func scaled(by scale: InterfaceScale) -> TypeStyle {
        scale.factor == 1 ? self : TypeStyle(size: size * scale.factor, weight: weight, design: design)
    }

    public var font: Font { .system(size: size, weight: weight, design: design) }

    /// The same style, for the handful of AppKit views (`NSPopUpButton`, `NSTextView`) that take an
    /// `NSFont` rather than a SwiftUI `Font`. Consults size and weight rather than narrowing to just
    /// the size; `design` only distinguishes `.monospaced` from everything else, since no token uses
    /// `.rounded` or `.serif` — both fall through to the system default.
    public var nsFont: NSFont {
        let nsWeight: NSFont.Weight
        switch weight {
        case .ultraLight: nsWeight = .ultraLight
        case .thin: nsWeight = .thin
        case .light: nsWeight = .light
        case .medium: nsWeight = .medium
        case .semibold: nsWeight = .semibold
        case .bold: nsWeight = .bold
        case .heavy: nsWeight = .heavy
        case .black: nsWeight = .black
        default: nsWeight = .regular
        }
        return design == .monospaced
            ? .monospacedSystemFont(ofSize: size, weight: nsWeight)
            : .systemFont(ofSize: size, weight: nsWeight)
    }
}

public extension View {
    /// Sets `style` at the environment's `InterfaceScale`, so text in a scaled subtree grows without
    /// the call site knowing.
    func font(_ style: TypeStyle) -> some View { modifier(ScaledFont(style: style)) }
}

private struct ScaledFont: ViewModifier {
    let style: TypeStyle
    @Environment(\.interfaceScale) private var scale

    func body(content: Content) -> some View { content.font(style.scaled(by: scale).font) }
}

/// The macOS system text scale. AiTerm draws with `.system(size:)` rather than a text style, so the
/// comment on each line is the style it is the size of.
public enum Typography {
    /// `.title3` — a sheet's own title.
    public static let title = TypeStyle(size: 15, weight: .semibold)
    /// `.callout` — a heading inside a boxed group.
    public static let card = TypeStyle(size: 12, weight: .semibold)
    /// `.body` — row titles, field values, buttons, menu rows.
    public static let body = TypeStyle(size: 13)
    /// `.body` at medium weight — more presence than plain body text, short of semibold: a project
    /// name, a settings row's own title, a selected segment's label.
    public static let bodyEmphasis = TypeStyle(size: 13, weight: .medium)
    /// `.callout` — a field's label. Also the sidebar's own `+` add glyph.
    public static let label = TypeStyle(size: 12, weight: .medium)
    /// `.callout` — a sheet's subtitle, an error, a step's name.
    public static let caption = TypeStyle(size: 12)
    /// `.subheadline` — help text, banners, a completion's detail and source.
    public static let help = TypeStyle(size: 11)
    /// `.footnote`, semibold — "Projects", a row's disclosure chevron, the `+n` overflow, a step
    /// number, and a ticket row's small icon buttons (clear, toggle).
    public static let micro = TypeStyle(size: 10, weight: .semibold)
    /// A sidebar section header (“Projects”): macOS 26's sidebar header, sentence case.
    public static let sectionHeader = TypeStyle(size: 11, weight: .semibold)
    /// A branch name, a usage line.
    public static let mono = TypeStyle(size: 11, design: .monospaced)
    /// The command block, a ticket key in a sheet.
    public static let monoCode = TypeStyle(size: 12, design: .monospaced)
    /// The first-prompt editor's own size, monospaced — has to match `PromptEditor`'s real
    /// `NSTextView` font exactly, or its placeholder sits where typed text will not.
    public static let promptMono = TypeStyle(size: 13, design: .monospaced)
    /// A ticket key on a sidebar row, the `+n` chip.
    public static let monoChip = TypeStyle(size: 10, weight: .medium, design: .monospaced)
}

/// A sheet's footprint: its width, its preferred heights, and the height it actually gets on a
/// short screen. Everything inside it measures in ``Space``, ``Radius`` and ``Size``.
public enum Sheet {
    /// `preferred`, or less on a screen too short for it: the main screen's visible height less
    /// `screenMargin`, but never under `minimumHeight`. With no screen, `preferred`.
    @MainActor public static func fittingHeight(_ preferred: CGFloat) -> CGFloat {
        guard let visible = NSScreen.main?.visibleFrame.height else { return preferred }
        return min(preferred, max(minimumHeight, visible - screenMargin))
    }
    /// The shortest a sheet is drawn however short the screen — its header, a field and its footer
    /// — below which it scrolls rather than shrinks.
    private static let minimumHeight: CGFloat = 320
    /// What a sheet leaves free of the screen's visible height, so it never meets the menu bar or
    /// the Dock.
    private static let screenMargin: CGFloat = 100
    public static let width: CGFloat = 560
    public static let height: CGFloat = 560
    /// Settings has a slightly taller preferred viewport for its forms.
    public static let settingsHeight: CGFloat = 580
}
