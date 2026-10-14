// Ported from AiTerm (app/Sources/AiTerm/Views/SidebarRows.swift: SidebarRowLayout, AddMenu,
// SelectableRow, RowPill, the header's chevron and title, RowTitle, RowCaption, the debug hover keys
// and ProviderIcon),
// GPLv3, Laurens D'Hondt.
import SwiftUI
import ShellforgeDesign
import ShellforgeCore

/// The measurements every sidebar row shares, at the scale the row is drawn at.
enum SidebarRowLayout {
    /// Everything in the sidebar's trailing column — both "+" glyphs and a row's status mark —
    /// is ~10 pt of ink centred in a 20 pt click target, so they all share one centre line.
    static func trailingGlyph(_ scale: InterfaceScale) -> CGFloat { scale(Size.trailingGlyph) }
    static func trailingSlot(_ scale: InterfaceScale) -> CGFloat { scale(Size.slot) }
    /// A row insets that *ink* by `Space.base`, matching its own leading padding, so the glyphs end
    /// where the chevron and the project title start on the left. The slot is wider than its
    /// glyph, so it overhangs the row's padding by half the difference. Worked from the scaled
    /// parts rather than scaling the ×1 result, so the glyph's edge stays on the padding line.
    static func trailingInset(_ scale: InterfaceScale) -> CGFloat {
        scale(Space.base) - (trailingSlot(scale) - trailingGlyph(scale)) / 2
    }
    /// The project row's own leading disclosure chevron width.
    static func chevronWidth(_ scale: InterfaceScale) -> CGFloat { scale(Size.chevron) }
}

/// The add glyph, drawn identically wherever it appears. `.borderlessButton` hands the label to
/// an AppKit pop-up button, which draws the same `Image` a point larger than a `Button` does;
/// `.button` + `.plain` keeps the menu's click and gives back the button's own rendering.
struct AddMenu<Items: View>: View {
    let help: String?
    let enabled: Bool
    @ViewBuilder let items: () -> Items
    @Environment(\.interfaceScale) private var scale
    /// A selected project header's "+" sits on the accent.
    @Environment(\.surface) private var surface

    var body: some View {
        Menu(content: items) {
            Image(systemName: "plus").font(Typography.label).foregroundStyle(surface.secondaryInk)
        }
        .disabled(!enabled)
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .frame(width: SidebarRowLayout.trailingSlot(scale), height: SidebarRowLayout.trailingSlot(scale))
        .help(help ?? "")
    }
}


struct SelectableRow<Content: View>: View {
    let selected: Bool
    let activate: () -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.interfaceScale) private var scale
    // `@State` is a macro in the macOS 26 SDK and its SwiftUIMacros plugin ships only with Xcode,
    // which the pinned toolchain does not need; this is the storage the macro would generate.
    private var _hovered = State(initialValue: false)
    private var hovered: Bool {
        get { _hovered.wrappedValue }
        nonmutating set { _hovered.wrappedValue = newValue }
    }
    #if DEBUG
    @Environment(\.rowHovered) private var seededHover
    #endif

    init(selected: Bool, activate: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content) {
        self.selected = selected; self.activate = activate; self.content = content
    }

    /// The pointer's hover, or in a debug build a test's.
    private var drawsHover: Bool {
        #if DEBUG
        hovered || seededHover
        #else
        hovered
        #endif
    }

    var body: some View {
        content()
            .padding(.leading, scale(Space.base)).padding(.trailing, SidebarRowLayout.trailingInset(scale))
            .padding(.vertical, scale(Space.base))
            .frame(minHeight: scale(Size.row))
            .modifier(RowPill(selected: selected, hovered: drawsHover))
            // The pill is inset from the project row, so the indent goes *outside* the background —
            // painting it inside made the blue run all the way to the sidebar's edge. Selection is drawn
            // here too, not by the list: AppKit's own row highlight covers the whole row rect, which is
            // 26 pt wider on the leading edge and 8 pt taller than this pill. One painter, one rectangle.
            .padding(.leading, scale(Space.section))
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .onTapGesture(perform: activate)
            // AiTerm's `.allowsWindowActivationEvents()` (a first click both activates and selects) needs
            // macOS 15; inside iTerm2's own window the sidebar is already in the active window.
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            .accessibilityAction { activate() }
    }
}

/// The pill a selectable sidebar row is drawn in — a task's, a terminal's, a project header's: the
/// selection fill, else the hover wash, behind the row's own padding. It declares the ground
/// everything inside reads.
struct RowPill: ViewModifier {
    let selected: Bool
    var hovered = false
    @Environment(\.interfaceScale) private var scale
    @Environment(\.controlActiveState) private var controlActiveState

    /// The ground a row is on: the accent while selected in an active window, macOS's unemphasized
    /// grey while selected in an inactive one, the hover wash, or the sidebar. `.hover`, not
    /// `.sidebar`, while merely hovered: `AvatarGroupView`'s ring reads `occludingBackground`.
    static func surface(selected: Bool, hovered: Bool, windowActive: Bool) -> Surface {
        if selected { return windowActive ? .accent : .inactiveSelection }
        return hovered ? .hover : .sidebar
    }

    /// The pill's fill on `surface`.
    static func fill(for surface: Surface) -> Color {
        switch surface {
        case .accent: Palette.selection
        case .inactiveSelection: Palette.controlActive
        case .hover: Palette.rowHover
        case .sidebar, .sheet: .clear
        }
    }

    func body(content: Content) -> some View {
        let windowActive = controlActiveState == .key || controlActiveState == .active
        let surface = Self.surface(selected: selected, hovered: hovered, windowActive: windowActive)
        content
            .surface(surface)
            // macOS 26's sidebar selection: a little rounder than a control.
            .background(RoundedRectangle(cornerRadius: scale(Radius.group), style: .continuous).fill(Self.fill(for: surface)))
    }
}

/// A project header's disclosure chevron, in its surface's secondary ink.
struct HeaderChevron: View {
    let collapsed: Bool
    @Environment(\.surface) private var surface

    var body: some View {
        Image(systemName: collapsed ? "chevron.right" : "chevron.down")
            .font(Typography.micro).foregroundStyle(surface.secondaryInk)
    }
}

/// A project header's name, in its surface's ink — white on the selection.
struct HeaderTitle: View {
    let text: String
    @Environment(\.surface) private var surface

    var body: some View {
        Text(text).font(Typography.bodyEmphasis).foregroundStyle(surface.ink)
            .lineLimit(1).truncationMode(.tail)
    }
}

/// A default accessibility action that is there only while `enabled`: unlike a menu item, an action
/// cannot be greyed, only left out.
private struct DefaultAccessibilityAction: ViewModifier {
    let enabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if enabled { content.accessibilityAction(.default, action) } else { content }
    }
}

/// A sidebar row's title, in its surface's ink — white on the selection — read from the ground
/// `SelectableRow` declares, not worked out from a `selected` flag. `dimmed` draws it in the
/// secondary ink, as a row on its way out has it.
struct RowTitle: View {
    let text: String
    var dimmed = false
    @Environment(\.surface) private var surface

    init(_ text: String, dimmed: Bool = false) { self.text = text; self.dimmed = dimmed }

    var body: some View {
        Text(text).font(Typography.body).foregroundStyle(dimmed ? surface.secondaryInk : surface.ink).lineLimit(1)
    }
}

/// A line under a sidebar row's title — a removal's progress, why it stopped, what the task is
/// missing — in its surface's secondary ink. `warns` is amber, except on the accent, where amber
/// does not read.
struct RowCaption: View {
    let text: String
    var warns = false
    @Environment(\.surface) private var surface

    init(_ text: String, warns: Bool = false) { self.text = text; self.warns = warns }

    var body: some View {
        Text(text).font(Typography.help).foregroundStyle(warns && !surface.isOnAccent ? Palette.amber : surface.secondaryInk)
    }
}


#if DEBUG
/// Counts the sidebar rows' body evaluations by row id, for the tests that hold an arrow key, a
/// removal and a missing checkout to the rows they touch. Unset everywhere else.
@MainActor
final class RowBodyCounter {
    private(set) var counts: [UUID: Int] = [:]
    func count(_ id: UUID) { counts[id, default: 0] += 1 }
    func reset() { counts = [:] }
}

private struct RowBodyCounterKey: EnvironmentKey { static let defaultValue: RowBodyCounter? = nil }

extension EnvironmentValues {
    var rowBodyCounter: RowBodyCounter? {
        get { self[RowBodyCounterKey.self] }
        set { self[RowBodyCounterKey.self] = newValue }
    }
}

/// The task row a test draws hovered with no pointer over it, set on the sidebar
/// (`SidebarRowGeometryTests`). The row it names hands `rowHovered` to its `SelectableRow`.
struct HoveredRowKey: EnvironmentKey { static let defaultValue: UUID? = nil }
struct RowHoveredKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var hoveredRow: UUID? {
        get { self[HoveredRowKey.self] }
        set { self[HoveredRowKey.self] = newValue }
    }
    var rowHovered: Bool {
        get { self[RowHoveredKey.self] }
        set { self[RowHoveredKey.self] = newValue }
    }
}
#endif

/// A project header's `ProjectJiraBadge`, drawn as `BranchLabelView` draws a branch and its `+n`: a
/// quiet `Badge` opening the first project, then — `Space.snug` after it — a boxed `+n` `Badge` whose
/// menu offers every project and ends in the context menu's "Jira Projects…", greyed as it is there

struct ProviderIcon: View {
    let provider: Provider
    @Environment(\.interfaceScale) private var scale
    @Environment(\.surface) private var surface
    /// The GitLab and GitHub marks' drawn size, inside the ``Size/avatar`` square — neither `Size` nor
    /// `Typography` has a step this close without visibly shrinking or enlarging the logo.
    private static let logoSize: CGFloat = 13
    /// The plain SF Symbol fallbacks (no vendor mark): smaller than ``logoSize`` because a system
    /// glyph reads bigger than a custom logo at the same point size.
    private static let glyphSize: CGFloat = 10
    var body: some View {
        ZStack {
            switch provider {
            case .gitlab:
                Icon(.gitlabTanuki, size: scale(Self.logoSize))
            case .github:
                Icon(.brand(Palette.github), size: scale(Self.logoSize), tint: surface.ink)
            case .git: Icon(.symbol("arrow.triangle.branch"), size: scale(Self.glyphSize), tint: surface.secondaryInk)
            case .none: Icon(.symbol("folder.fill"), size: scale(Self.glyphSize), tint: surface.secondaryInk)
            }
        }.frame(width: scale(Size.avatar), height: scale(Size.avatar))
    }
}
