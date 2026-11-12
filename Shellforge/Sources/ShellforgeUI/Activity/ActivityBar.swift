import ShellforgeCore
import ShellforgeDesign
import SwiftUI

/// The sidebar's activity bar, VS Code's way: one plain line icon per panel in the shared order,
/// each centred in a square cell, the selected one in the primary ink with an accent stripe flush
/// against the bar's left edge, and the gear's menu (`GearMenu`) fixed at the bottom. Only the
/// panels the bar shows are drawn: Customize hides the others. A click selects; a press dragged
/// past `liftDistance` lifts the icon, which follows the pointer up or down the bar, and the release
/// drops it where it is (`release`). VoiceOver reorders with Move Up and Move Down instead. A drag gesture of the bar's own rather than a `List`'s move,
/// whose table added margins of its own, or per-icon `onDrag`/`onDrop`, which proved unreliable in
/// this sidebar.
struct ActivityBar: View {
    @ObservedObject var model: ActivityModel
    /// The app's theme choice and Match Terminal switch, which the gear menu changes at once.
    @ObservedObject var theme: ThemeSettings
    @ObservedObject var terminalMatch: TerminalMatchSettings
    let openSettings: () -> Void
    @Environment(\.interfaceScale) private var scale
    @Environment(\.surface) private var surface
    /// The icon being dragged and how far, while one is lifted. Gesture state, so a drag the system
    /// cancels never leaves an icon lifted.
    @GestureState private var drag: Drag?
    @State private var hovered: ActivityPanel?

    private struct Drag: Equatable {
        let panel: ActivityPanel
        let from: Int
        var translation: CGFloat
    }

    /// The bar's width, and each icon's square cell.
    static func width(_ scale: InterfaceScale) -> CGFloat { scale(Size.activityBar) }

    /// One size for every icon in the bar, the gear's too.
    static let iconStyle = TypeStyle(size: 18)

    /// The bar's, each icon's and the selected icon's stripe's `ViewMark`s.
    static let markName = "ActivityBar", iconMarkName = "ActivityBarIcon", stripeMarkName = "ActivityBarStripe"

    /// How far a press travels before it lifts the icon: less is a click's slip, which selects.
    static let liftDistance: CGFloat = Space.tight

    /// Whether a press dragged `translation` points lifts its icon.
    static func lifts(_ translation: CGFloat) -> Bool { abs(translation) >= liftDistance }

    /// The cell an icon lifted from `index` would land in after moving `translation` points down the
    /// bar (up when negative): the nearest one, held to the bar's ends.
    static func target(from index: Int, translation: CGFloat, cell: CGFloat, count: Int) -> Int {
        guard lifts(translation), cell > 0, count > 0 else { return index }
        return min(max(index + Int((translation / cell).rounded()), 0), count - 1)
    }

    /// The drop of an icon lifted from `index` and released `translation` points from where it was,
    /// as `ActivityModel.move(fromOffsets:toOffset:)` takes it; nil when it lands where it was.
    static func dropOffset(from index: Int, translation: CGFloat, cell: CGFloat, count: Int) -> Int? {
        let landing = target(from: index, translation: translation, cell: cell, count: count)
        guard landing != index else { return nil }
        return landing > index ? landing + 1 : landing
    }

    /// What a release does: a press that never lifted is a click.
    enum Release: Equatable {
        case select
        case move(toOffset: Int)
        /// Lifted, and dropped where it was.
        case stay
    }

    /// The release of a press on the icon at `index`, `translation` points from where it began.
    static func release(from index: Int, translation: CGFloat, cell: CGFloat, count: Int) -> Release {
        guard lifts(translation) else { return .select }
        return dropOffset(from: index, translation: translation, cell: cell, count: count).map { .move(toOffset: $0) } ?? .stay
    }

    /// VoiceOver's way to reorder, which a pointer drag is not.
    static let moveUp = "Move Up", moveDown = "Move Down"

    /// VoiceOver's Move Up or Move Down on the icon at `index`, as `move(fromOffsets:toOffset:)`
    /// takes it; nil when the icon is already at that end.
    static func stepOffset(from index: Int, up: Bool, count: Int) -> Int? {
        if up { return index > 0 ? index - 1 : nil }
        return index < count - 1 ? index + 2 : nil
    }

    /// The move actions the icon at `index` offers: only the ways it can go.
    static func voiceOverActions(at index: Int, count: Int) -> [String] {
        (stepOffset(from: index, up: true, count: count) == nil ? [] : [moveUp])
            + (stepOffset(from: index, up: false, count: count) == nil ? [] : [moveDown])
    }

    private static let space = "ActivityBar"

    var body: some View {
        let cell = Self.width(scale)
        let order = model.layout.visibleOrder
        VStack(spacing: 0) {
            ForEach(Array(order.enumerated()), id: \.element) { index, panel in
                icon(panel, at: index, cell: cell, count: order.count)
            }
            Spacer(minLength: 0)
            // `.button` + `.plain`, as `AddMenu`'s: the glyph drawn as the panels' are, not by a pop-up button.
            Menu {
                GearMenuContent(items: GearMenu.items(choice: theme.choice, match: terminalMatch.isOn, layout: model.layout)) { action in
                    GearMenu.perform(action, theme: theme, terminalMatch: terminalMatch, activity: model, openSettings: openSettings)
                }
            } label: {
                glyph("gearshape", ink: surface.secondaryInk)
                    .frame(width: cell, height: cell)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .frame(width: cell, height: cell)
            .help("Manage")
            .accessibilityLabel("Manage")
        }
        .coordinateSpace(name: Self.space)
        .frame(width: cell)
        .frame(maxHeight: .infinity)
        .background(ViewMark(name: Self.markName))
        .overlay(alignment: .trailing) { SidebarEdge() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Activity bar")
    }

    /// An icon as the bar draws it: a plain line symbol, centred, at the bar's one size.
    private func glyph(_ symbol: String, ink: Color) -> some View {
        Image(systemName: symbol)
            .font(Self.iconStyle)
            .foregroundStyle(ink)
            .background(ViewMark(name: Self.iconMarkName))
    }

    /// A panel's icon: a click shows it, a drag moves it.
    private func icon(_ panel: ActivityPanel, at index: Int, cell: CGFloat, count: Int) -> some View {
        let selected = model.layout.selected == panel
        let lifted = drag?.panel == panel
        let ink = selected || hovered == panel ? surface.ink : surface.secondaryInk
        return glyph(panel.symbol, ink: ink)
            .frame(width: cell, height: cell)
            .overlay(alignment: .leading) {
                if selected {
                    Rectangle().fill(Palette.accent).frame(width: Space.hairline)
                        .background(ViewMark(name: Self.stripeMarkName))
                }
            }
            .contentShape(Rectangle())
            .offset(y: offset(of: index, lifted: lifted, cell: cell, count: count))
            .zIndex(lifted ? 1 : 0)
            .animation(lifted ? nil : .easeOut(duration: 0.15), value: drag)
            .onHover { inside in
                if inside { hovered = panel } else if hovered == panel { hovered = nil }
            }
            .gesture(press(panel, at: index, cell: cell, count: count))
            .help(panel.title)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(panel.title)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { model.select(panel) }
            .modifier(step(at: index, up: true, count: count))
            .modifier(step(at: index, up: false, count: count))
    }

    /// Move Up or Move Down for VoiceOver, offered only where the icon can go.
    private func step(at index: Int, up: Bool, count: Int) -> NamedAccessibilityAction {
        let destination = Self.stepOffset(from: index, up: up, count: count)
        return NamedAccessibilityAction(name: up ? Self.moveUp : Self.moveDown, enabled: destination != nil) { [model] in
            if let destination { model.move(fromOffsets: IndexSet(integer: index), toOffset: destination) }
        }
    }

    /// Where the icon at `index` is drawn during a drag: the lifted one under the pointer, held to
    /// the bar; the ones it passed a cell over, to make room.
    private func offset(of index: Int, lifted: Bool, cell: CGFloat, count: Int) -> CGFloat {
        guard let drag else { return 0 }
        if lifted {
            return min(max(drag.translation, -CGFloat(drag.from) * cell), CGFloat(count - 1 - drag.from) * cell)
        }
        let landing = Self.target(from: drag.from, translation: drag.translation, cell: cell, count: count)
        if drag.from < index && index <= landing { return -cell }
        if landing <= index && index < drag.from { return cell }
        return 0
    }

    /// A press on `panel`'s icon: released where it began it selects the panel; dragged, it moves it.
    private func press(_ panel: ActivityPanel, at index: Int, cell: CGFloat, count: Int) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .updating($drag) { value, drag, _ in
                let translation = value.translation.height
                if drag != nil || Self.lifts(translation) {
                    drag = Drag(panel: panel, from: index, translation: translation)
                }
            }
            .onEnded { [model] value in
                switch Self.release(from: index, translation: value.translation.height, cell: cell, count: count) {
                case .select: model.select(panel)
                case .move(let destination): model.move(fromOffsets: IndexSet(integer: index), toOffset: destination)
                case .stay: break
                }
            }
    }
}
