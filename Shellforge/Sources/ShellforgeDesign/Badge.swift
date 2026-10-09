// Ported from AiTerm (app/Sources/AiTermUI/Badge.swift), GPLv3, Laurens D'Hondt.
import SwiftUI

/// The 16 pt neutral-wash chip a sidebar row draws for a ticket key, a vendor mark or a `+n`
/// overflow count — one shape in place of the three types (`EditorBadge`, `JiraChip`,
/// `BranchLabelView`'s `+n` chip) that each redrew it. `action` carries whether the badge is a
/// button, so a badge with no action draws its shape only; `menu` makes it open a menu instead — a
/// project header's count of Jira projects — the same chip, hovered the same way.
///
/// A `diff` extends the badge with signed line counts after its icon and label — `[mark] +12 −3`,
/// the VS Code badge on a row whose checkout has moved from the branch it started at. An empty diff
/// draws nothing extra, so a caller can pass one unconditionally.
///
/// A `.quiet` badge drops the box at rest: its mark and text sit on the row in secondary ink, and
/// the wash only appears under the pointer, outset by `Space.tight` so the text does not move. The
/// sidebar's project headers and task and terminal rows draw their badges this way, where four
/// boxes in a row read as clutter; everywhere else a badge keeps its box.
///
/// What this is *not*: a status count. `StatusCountChip` varies its tint, its ink and both its
/// fill and stroke opacity by status — a deliberate three-dimensional progression keyed to
/// urgency (muted/0.14/0.30 idle and working, amber/0.16/0.38 needs-input, accent/0.17/0.42 done),
/// not a single colour a caller could hand in. Carrying that into `Badge` would either need two
/// more parameters `Badge`'s only other shape has no use for, or flatten three real opacity pairs
/// into one and silently change two of the three statuses' pixels. Neither is acceptable, so
/// `StatusCountChip` stays its own component: a status chip that happens to be chip-shaped, not a
/// `Badge`.
public struct Badge: View {
    private let label: String?
    private let icon: IconSource?
    private let help: String?
    private let action: (() -> Void)?
    private let menu: AnyView?
    /// What VoiceOver reads in place of the label, when the label alone says too little — a count.
    private let accessibilityText: String?
    /// Exists for the Settings check chips, whose checkmark is green and whose warning is amber.
    /// Off the accent it replaces the icon's own ink; on the accent it yields to white like
    /// everything else on a selected row.
    private let iconTint: Color?
    private let diff: Diff?
    private let style: Style

    /// Whether the badge draws its box at rest.
    public enum Style: Equatable, Sendable {
        /// The wash is always there. The default.
        case boxed
        /// No wash until the pointer is over it; the label in the surface's secondary ink.
        case quiet
    }

    /// Lines added and removed, drawn after the label as `+added −removed`. A standard shape, not an
    /// AiTerm type: the badge does not know what the counts are measured against.
    public struct Diff: Equatable, Sendable {
        enum Side: Equatable, Sendable { case added, removed }
        struct Segment: Equatable, Sendable { var side: Side, text: String }

        public var added: Int, removed: Int
        public init(added: Int, removed: Int) { self.added = added; self.removed = removed }

        var isEmpty: Bool { added <= 0 && removed <= 0 }

        /// What is drawn, in order. A side with nothing to count is left out rather than drawn as
        /// `+0`; the removal sign is a true minus (U+2212), which sets at the width of the plus.
        var segments: [Segment] {
            (added > 0 ? [Segment(side: .added, text: "+\(added)")] : [])
                + (removed > 0 ? [Segment(side: .removed, text: "\u{2212}\(removed)")] : [])
        }
    }

    @Environment(\.surface) private var surface
    @Environment(\.interfaceScale) private var scale

    // `@State` is a macro shipping only with Xcode, which this machine lacks. This is the storage
    // the macro would generate — the same pattern `EditorBadge` and `JiraChip` hand-expand today.
    var _hovered = State(initialValue: false)
    private var hovered: Bool {
        get { _hovered.wrappedValue }
        nonmutating set { _hovered.wrappedValue = newValue }
    }

    public init(_ label: String? = nil,
                icon: IconSource? = nil,
                help: String? = nil,
                iconTint: Color? = nil,
                diff: Diff? = nil,
                style: Style = .boxed,
                accessibilityLabel: String? = nil,
                action: (() -> Void)? = nil) {
        self.init(label, icon: icon, help: help, iconTint: iconTint, diff: diff, style: style,
                  accessibilityLabel: accessibilityLabel, action: action, menu: nil)
    }

    /// A badge that opens a menu of `items` when clicked.
    public init<Items: View>(_ label: String? = nil,
                             icon: IconSource? = nil,
                             help: String? = nil,
                             style: Style = .boxed,
                             accessibilityLabel: String? = nil,
                             @ViewBuilder menu items: () -> Items) {
        self.init(label, icon: icon, help: help, iconTint: nil, diff: nil, style: style,
                  accessibilityLabel: accessibilityLabel, action: nil, menu: AnyView(items()))
    }

    private init(_ label: String?, icon: IconSource?, help: String?, iconTint: Color?, diff: Diff?, style: Style,
                 accessibilityLabel: String?, action: (() -> Void)?, menu: AnyView?) {
        self.label = label
        self.icon = icon
        self.help = help
        self.iconTint = iconTint
        self.diff = diff.flatMap { $0.isEmpty ? nil : $0 }
        self.style = style
        self.accessibilityText = accessibilityLabel
        self.action = action
        self.menu = menu
    }

    /// The wash a badge draws, isolated as a pure function so the colour rule is testable without
    /// rendering a view. A quiet badge draws none at rest and the ordinary hovered wash under the
    /// pointer.
    static func fill(surface: Surface, hovered: Bool, style: Style = .boxed) -> Color {
        if hovered { return surface.badgeWashHovered }
        return style == .quiet ? .clear : surface.badgeWash
    }

    /// The label's ink, isolated the same way `fill` is: the surface's ink in a box. A quiet badge
    /// inks its label in the surface's secondary ink instead: with no box to hold it, the text has
    /// to sit back from the row's title on its own.
    static func labelInk(surface: Surface, style: Style = .boxed) -> Color {
        style == .quiet ? surface.secondaryInk : surface.ink
    }

    public var body: some View {
        // `fixedSize` on all three: a badge is a chip at its own width, never squeezed or stretched
        // by the row around it, whether or not it is a button.
        if let menu {
            // `AddMenu`'s recipe: a menu with no bezel and no indicator, so the label is the chip.
            Menu { menu } label: { shape }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .onHover { hovered = $0 }
                .ifHelp(help)
                .ifAccessibilityLabel(accessibilityText ?? label ?? help)
        } else if let action {
            Button(action: action) { shape }
                .buttonStyle(.plain)
                .fixedSize()
                .onHover { hovered = $0 }
                .ifHelp(help)
                .ifAccessibilityLabel(accessibilityText ?? label ?? help)
        } else {
            shape.fixedSize().ifHelp(help).ifAccessibilityLabel(accessibilityText ?? label ?? help)
        }
    }

    private var shape: some View {
        // A quiet badge has no padding of its own, so its text lines up with the row's title; its
        // hover wash is drawn `Space.tight` outside it, where a boxed badge's padding would be.
        // The content shape makes a quiet badge's gaps clickable, where its clear wash would not be.
        content
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: scale(Radius.chip))
                .fill(Self.fill(surface: surface, hovered: hovered, style: style))
                .padding(.horizontal, style == .quiet ? -scale(Space.tight) : 0))
    }

    /// A diff count's ink, isolated the same way `labelInk` is: green and red off the accent, and
    /// on it the surface's own white, like everything else on a selected row.
    static func diffInk(surface: Surface, side: Diff.Side) -> Color {
        if surface.isOnAccent { return surface.ink }
        return side == .added ? Palette.diffAdded : Palette.diffRemoved
    }

    // Icon-only: `EditorBadge`'s `Size.avatar` width. Anything with text — a label, a diff, or
    // both, after an icon or not: `Space.tight` throughout — leading, trailing, and between icon,
    // label and diff. All of them: `Size.chip` tall. Quiet: the same, less the outer padding, which
    // its hover wash draws into instead.
    // Every token below is read through `scale`; the badge is a chip at whatever scale it sits in.
    @ViewBuilder
    private var content: some View {
        let inset = style == .quiet ? 0 : scale(Space.tight)
        if let icon, label == nil, diff == nil {
            iconView(icon)
                .frame(width: style == .quiet ? scale(Self.iconSize) : scale(Size.avatar), height: scale(Size.chip))
        } else if icon != nil || label != nil || diff != nil {
            HStack(spacing: scale(Space.tight)) {
                if let icon { iconView(icon) }
                if let label { labelView(label) }
                if let diff { diffView(diff) }
            }
            .padding(.horizontal, inset)
            .frame(height: scale(Size.chip))
        }
    }

    /// The icon's tint, isolated the same way `labelInk` is. Off the accent it is the caller's
    /// `override`, and `nil` lets `Icon` fall back to the brand's own colour; on it, the surface's
    /// ink — the same "everything on it turns white" rule the label follows.
    static func iconTint(surface: Surface, override: Color? = nil) -> Color? {
        surface.isOnAccent ? surface.ink : override
    }

    /// The icon's own drawn size inside the badge — smaller than `Size.chip` so it sits inside the
    /// chip's own padding rather than filling it edge to edge.
    private static let iconSize: CGFloat = 10

    private func iconView(_ source: IconSource) -> some View {
        Icon(source, size: scale(Self.iconSize), tint: Self.iconTint(surface: surface, override: iconTint))
    }

    /// `+12 −3`: the two counts sit `Space.hairline` apart, closer than the label before them, so
    /// they read as one figure.
    private func diffView(_ diff: Diff) -> some View {
        HStack(spacing: scale(Space.hairline)) {
            ForEach(diff.segments, id: \.text) { segment in
                Text(segment.text)
                    .font(Typography.monoChip)
                    .foregroundStyle(Self.diffInk(surface: surface, side: segment.side))
            }
        }
    }

    private func labelView(_ text: String) -> some View {
        Text(text)
            .font(Typography.monoChip)
            .foregroundStyle(Self.labelInk(surface: surface, style: style))
    }
}

private extension View {
    @ViewBuilder
    func ifHelp(_ text: String?) -> some View {
        if let text {
            help(text)
        } else {
            self
        }
    }

    /// What VoiceOver reads: the label, or — for a badge that is only a mark — its tooltip, which
    /// names what the mark stands for.
    @ViewBuilder
    func ifAccessibilityLabel(_ text: String?) -> some View {
        if let text {
            accessibilityLabel(text)
        } else {
            self
        }
    }
}
