// Ported from AiTerm (app/Sources/AiTermUI/Palette.swift), GPLv3, Laurens D'Hondt.
import SwiftUI
import AppKit

/// The alpha of the white wash painted over a hovered sidebar row. A named top-level constant, not
/// an enum member, so it reads as what it is — a number, not a colour — rather than sitting among
/// `Palette`'s colour members.
private let rowHoverAlpha = 0.06
/// The black wash a hovered row takes in the light appearance: lighter than the dark's white one,
/// because black on a light grey reads stronger than white on a dark one.
private let rowHoverLightAlpha = 0.05

/// Semantic native colors resolve in the app's dark appearance and honor increased contrast.
/// Brand marks keep their vendor colors; terminal-background matching remains opt-in.
public enum Palette {
    /// `0xRRGGBB` as a colour. `Brand` reads it too, so a vendor's number is decoded one way.
    fileprivate static func hex(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    /// A colour with one value in the light appearance and another in the dark, resolved by AppKit
    /// wherever it is drawn.
    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    /// The window, the sidebar and any control drawn flush on them. Also covers the deleted
    /// `control` (`.controlBackgroundColor`) — the two resolved identically under `.darkAqua`.
    public static let surface = Color(nsColor: .windowBackgroundColor)
    /// The sheet footer that holds the primary action. Lighter than the surface.
    public static let surfaceRaised = Color(nsColor: .underPageBackgroundColor)
    /// The fill of anything that hangs over a sheet's content: the completion popup and a
    /// `SearchPicker`'s results. Raised, not `surface`: on the sheet's own colour a popup has only
    /// its hairline to tell it from the field and the text it covers. An alias, because a menu
    /// floating over the sheet and the footer standing off it are one step up from the surface.
    public static let menu = surfaceRaised
    /// The one hairline: a control's outline and a separator between rows. Previously
    /// `controlStroke` and `divider`, which were separate names for one value.
    public static let border = Color(nsColor: .separatorColor)
    /// The background of a secondary (unemphasized) selection — a selected row that is not first
    /// responder. Kept neutral; the accent is reserved for the current step and focus.
    public static let controlActive = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
    /// The command preview block in a sheet, kept visually distinct from the surrounding surface:
    /// AppKit's text background resolves too close to the window background in both appearances.
    public static let codeBackground = adaptive(light: NSColor(srgbRed: 0.949, green: 0.949, blue: 0.957, alpha: 1),
                                                dark: NSColor(srgbRed: 0x14 / 255.0, green: 0x15 / 255.0, blue: 0x19 / 255.0, alpha: 1))

    /// The default label colour: row titles, field values, button labels and most on-screen text.
    /// Also covers the deleted `textStrong` — both were `.labelColor`.
    public static let text = Color(nsColor: .labelColor)
    /// Secondary text: captions, help copy, timestamps and anything subordinate to the primary
    /// label. Also covers the deleted `label` and `chipDigit` — all three were `.secondaryLabelColor`.
    public static let muted = Color(nsColor: .secondaryLabelColor)

    /// The system accent colour: primary buttons, focus rings and the active step in a flow.
    public static let accent = Color(nsColor: .controlAccentColor)
    /// The house focus ring (`focusRing`): the accent at 35 % — a hint around a field, not a second
    /// border competing with a segmented track's own.
    public static let focusRing = accent.opacity(0.35)
    /// The active Settings tab and the primary sheet action are one accent family.
    public static let tabActive = accent
    /// A clickable link's text colour, e.g. a URL or cross-reference inside body copy.
    public static let link = Color(nsColor: .linkColor)
    /// The positive/success semantic: a passing check, a connected status, a completed state shown
    /// inline.
    public static let green = Color(nsColor: .systemGreen)
    /// The warning semantic: a status needing attention without being an outright error.
    public static let amber = Color(nsColor: .systemOrange)
    /// The destructive semantic: an irreversible, data-losing action. SwiftUI's `role: .destructive`
    /// already supplies this colour at every call site that needs it (the three "Remove…" menu items
    /// in `SidebarView.swift`) — this token exists so the design system can *express* that colour,
    /// not so Swift call sites start reaching for it explicitly.
    public static let destructive = Color(nsColor: .systemRed)
    /// The pip colour on a badge that needs to draw the eye, e.g. an unread or pending count. The
    /// badge pip and the general amber semantic are the same colour family. Previously written
    /// twice as the identical `Color(nsColor: .systemOrange)` — the same defect this task removes
    /// elsewhere, caught by `PaletteDistinctionTests` rather than listed in the 4b brief.
    public static let badgeAmber = amber
    /// Lines a checkout adds against the branch it started from — the `+12` on the VS Code badge.
    /// The positive semantic, declared as an alias because it is the same green, not a new one.
    public static let diffAdded = green
    /// Lines a checkout removes against the branch it started from — the `−3` beside `diffAdded`.
    public static let diffRemoved = destructive
    /// The DEV pill a local build draws over its Dock icon (`DevBuildIcon`), so it is never mistaken
    /// for the release in Applications. The warning family, declared as an alias of `amber`.
    public static let devBuild = amber
    /// The "DEV" lettering on `devBuild`. White, like everything on a saturated fill: the pill sits
    /// on the app icon, not on the window, so no appearance-resolving label colour applies. An alias
    /// of `onAccent`, the one solid white this file writes.
    public static let devBuildInk = onAccent

    // -- on the accent ------------------------------------------------------------------
    /// Ink on the accent: a selected row's title, marks and badges, a primary button's keycaps.
    /// Literal white, not `.labelColor`: the accent is as saturated in the dark appearance as in any
    /// other, and AppKit's own selected-row text is white on it. `Surface.accent.ink` is this.
    public static let onAccent = Color.white
    /// Subordinate ink on the accent — a selected row's branch, its subtitle, its quiet badges'
    /// labels: `onAccent` at 75 %, where `muted` would be a grey on blue. `Surface.accent.secondaryInk`
    /// is this.
    public static let onAccentSecondary = onAccent.opacity(0.75)
    /// A spinner's unfilled track on a selected row, where `spinnerTrack`'s grey would read as a
    /// smudge on the accent.
    public static let spinnerTrackOnAccent = onAccent.opacity(0.3)
    /// A keycap's fill on a primary button (`Kbd`): enough white to lift the cap off the accent.
    public static let keycapFill = onAccent.opacity(0.22)
    /// A keycap's edge, fainter than its fill, so the cap reads as one shape rather than a box.
    public static let keycapStroke = onAccent.opacity(0.16)
    /// A pressed row in a dropdown: the accent, dimmed while the pointer holds it down.
    public static let accentPressed = accent.opacity(0.8)

    // -- field text ---------------------------------------------------------------------
    /// A field's placeholder, where AppKit cannot draw it for us — the prompt editor's is an overlay
    /// on an `NSTextView`. It matches the `placeholderTextColor` AppKit draws every `Input` and
    /// `SearchField` placeholder in, so the editor's hint is no brighter than theirs. That colour is
    /// `tertiaryLabelColor` in dark, with or without increased contrast (both 24.7 % white), so it
    /// is declared as an alias of `idleRing`, which draws it.
    public static let placeholder = idleRing
    /// Text that sits back behind the secondary copy on its own line: a completion's source,
    /// after its detail. `muted` at 80 %.
    public static let faint = muted.opacity(0.8)

    // -- vendor marks -------------------------------------------------------------------
    /// The white of a round vendor mark: the Codex, GitLab and GitHub discs, and the logo on Claude's,
    /// Jira's, Pi's, Grok's and the shell's. A mark keeps its vendor's colours, not the appearance's;
    /// the same white as `onAccent`, declared as an alias.
    public static let markPaper = onAccent
    /// The black of a round vendor mark: the Pi, Grok and shell discs.
    public static let markInk = Color.black

    // Brand marks, not UI colours.
    /// Anthropic's vendor colour for the Claude logo/glyph — a brand mark, not a UI colour; never
    /// use it to colour a button or status.
    public static let claude = Brand("claude", 0xD97757, path: Logos.claudePath, fallbackSymbol: "asterisk")
    /// Atlassian's vendor colour for the Jira mark — a brand mark, not a UI colour; do not reach
    /// for it to colour general UI.
    public static let jira = Brand("jira", 0x2684FF, path: Logos.jiraPath, fallbackSymbol: "ticket")
    /// GitLab's vendor colour for its mark — a brand mark, not a UI colour; reserved for the
    /// GitLab logo/badge only.
    public static let gitlab = Brand("gitlab", 0xFC6D26, path: Logos.gitlabPath, fallbackSymbol: "triangle.fill")
    /// GitHub's mark, in white: GitHub's mark is monochrome, and the app is dark-only. A brand
    /// mark, not a UI colour; reserved for the GitHub logo/badge only. A light ground — the
    /// Integrations disc — tints it `markInk`.
    public static let github = Brand("github", 0xFFFFFF, path: Logos.githubPath, fallbackSymbol: "chevron.left.forwardslash.chevron.right", followsAppearance: true)
    /// Microsoft's vendor colour for the VS Code mark — a brand mark, not a UI colour; used only
    /// where the VS Code badge appears.
    public static let vscode = Brand("vscode", 0x23A9F2, path: Logos.vscodePath, fallbackSymbol: "chevron.left.forwardslash.chevron.right")
    /// OpenAI's mark, in its own black — drawn on `VendorMark`'s white Codex disc. A brand mark,
    /// not a UI colour.
    public static let openai = Brand("openai", 0x000000, path: Logos.openaiPath, fallbackSymbol: "hexagon")
    /// xAI's Grok mark, in black: Grok has no brand colour. A brand mark, not a UI colour.
    public static let grok = Brand("grok", 0x000000, path: Logos.grokPath, fallbackSymbol: "circle.slash", evenOdd: true)

    // -- sidebar ---------------------------------------------------------------------
    /// A neutral translucent wash behind an unselected count chip or badge. 8 % of `.primary`, which
    /// carries its own alpha (≈0.847, `.labelColor`'s) — so ≈6.8 % white on screen, the value this
    /// wash has always drawn at, not the 8 % its literal suggests.
    public static let badge = Color.primary.opacity(0.08)
    /// The same badge wash, brighter, drawn when its row is selected.
    public static let badgeSelected = Color.white.opacity(0.2)
    /// A badge under the pointer, on any ground but the accent: a white wash in dark, a black one
    /// in light.
    public static let badgeHovered = adaptive(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.14))
    /// A badge under the pointer on a selected row: stronger than `badgeSelected`, as
    /// `badgeHovered` is than `badge`.
    public static let badgeSelectedHovered = Color.white.opacity(0.28)
    /// The footer card's ground: a faint wash, black in light and white in dark, that sets the
    /// footer apart from the rows above it without a rule.
    public static let footerCard = adaptive(light: NSColor(white: 0, alpha: 0.04), dark: NSColor(white: 1, alpha: 0.05))
    /// The sidebar's own background; equal to `surface` but named separately so sidebar styling
    /// reads locally.
    public static let sidebar = surface
    /// The wash painted behind a sidebar row while the pointer is over it: literal white in dark,
    /// literal black in light. Not `.primary`, whose own alpha (≈0.847) compounds with an opacity.
    public static let rowHover = adaptive(light: NSColor(white: 0, alpha: rowHoverLightAlpha), dark: NSColor(white: 1, alpha: rowHoverAlpha))
    /// The opaque colour a hovered row's avatar ring is painted: `rowHover` composited over
    /// `sidebar`, in whichever appearance it is drawn. Derived, not hardcoded, so the two can never
    /// drift.
    ///
    /// Composited by hand in sRGB, not with `NSColor.blended(withFraction:of:)`: that method
    /// converts through `NSCalibratedRGBColorSpace`, whose gamma distorts a dark base colour.
    public static let rowHoverSolid = Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        var base = NSColor.windowBackgroundColor
        appearance.performAsCurrentDrawingAppearance {
            base = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? NSColor.windowBackgroundColor
        }
        let (wash, alpha): (CGFloat, CGFloat) = dark ? (1, rowHoverAlpha) : (0, rowHoverLightAlpha)
        return NSColor(srgbRed: base.redComponent * (1 - alpha) + wash * alpha,
                       green: base.greenComponent * (1 - alpha) + wash * alpha,
                       blue: base.blueComponent * (1 - alpha) + wash * alpha,
                       alpha: 1)
    })

    /// A collapsed project's status-count chips (`StatusCountChips`): a fill and a stroke per
    /// status family, each a wash of that family's colour. The three pairs strengthen with urgency —
    /// idle and working in `muted`, needs-input in `amber`, done in `accent` — a deliberate
    /// progression, so each is written out rather than derived from one opacity.
    public static let statusChipQuietFill = muted.opacity(0.14)
    /// The quiet chip's edge.
    public static let statusChipQuietStroke = muted.opacity(0.30)
    /// A needs-input chip's fill.
    public static let statusChipAttentionFill = amber.opacity(0.16)
    /// A needs-input chip's edge.
    public static let statusChipAttentionStroke = amber.opacity(0.38)
    /// A done chip's fill.
    public static let statusChipDoneFill = accent.opacity(0.17)
    /// A done chip's edge.
    public static let statusChipDoneStroke = accent.opacity(0.42)
    /// The system colour for an actively selected row or item, stronger than a hover.
    public static let selection = Color(nsColor: .selectedContentBackgroundColor)
    /// A faint ring drawn around an item that is idle or inactive, using the lowest-emphasis
    /// label colour.
    public static let idleRing = Color(nsColor: .tertiaryLabelColor)
    /// The background track behind an active spinner or progress indicator's stroke.
    public static let spinnerTrack = Color(white: 0.56, opacity: 0.28)
    /// The active stroke of a spinner or progress indicator; shares `muted` so it reads as
    /// secondary UI, not an alert.
    public static let spinner = muted
    /// Marks a completed task or step; shares the accent family since completion is a positive,
    /// current-state signal.
    public static let done = accent
}

/// A vendor's single-colour mark: its colour, its path, and what to draw if the path will not
/// decode.
///
/// The marks are SVG documents built at runtime, so `Icon` wants the colour as text while SwiftUI
/// wants a `Color`. Deriving both from one number is what stops them drifting — `#2684FF` used to be
/// written twice, once as `Palette.jira` and once as a literal in `JiraChip`.
public struct Brand: Sendable, Hashable {
    /// What the brand is called, and the whole of its identity: two brands are equal when their names
    /// are, so an image cache keys on a few characters, not on the path's kilobytes.
    public let name: String
    public let color: Color
    /// `color` as `#RRGGBB`, for the SVG fill. Internal: only `Icon` builds the document.
    let hex: String
    /// The vendor mark as an SVG path string in a 24 × 24 viewBox. `NSImage(data:)` rasterises SVG
    /// on macOS, so the mark is path data rather than a hand-ported `Path`.
    public let path: String
    /// Drawn instead when the SVG will not decode, so a mark never silently vanishes.
    public let fallbackSymbol: String
    /// Whether `path` needs `fill-rule="evenodd"` to render its cut-outs as holes rather than fill:
    /// opt-in, since most vendor marks are already correct under SVG's default nonzero winding rule.
    /// Only Grok's mark sets this.
    public let evenOdd: Bool
    /// Whether the mark is drawn in the text colour rather than its own: GitHub's mark is white on
    /// dark and black on light, by GitHub's own rules, so on a light sheet it is not lost.
    public let followsAppearance: Bool

    /// The brand's colour as a faint wash, behind a label in the brand's own ink: a ticket's or a
    /// merge request's lane in a picker — neutral information in the vendor's colour, not a warning.
    public var wash: Color { color.opacity(0.18) }

    public static func == (lhs: Brand, rhs: Brand) -> Bool { lhs.name == rhs.name }
    public func hash(into hasher: inout Hasher) { hasher.combine(name) }

    public init(_ name: String, _ value: UInt32, path: String, fallbackSymbol: String, evenOdd: Bool = false,
                followsAppearance: Bool = false) {
        self.name = name
        color = followsAppearance ? Palette.text : Palette.hex(value)
        self.followsAppearance = followsAppearance
        hex = String(format: "#%06X", value)
        self.path = path
        self.fallbackSymbol = fallbackSymbol
        self.evenOdd = evenOdd
    }
}
