import ShellforgeCore
import ShellforgeDesign
import SwiftUI

/// The sidebar's activity bar, VS Code's way: one icon per panel in the shared order, the selected
/// one marked by an accent edge, and Settings fixed at the bottom. Icons reorder by dragging them:
/// the drag is a `List`'s own move, drawn as a bar — per-icon `onDrag`/`onDrop` proved unreliable
/// in this sidebar.
struct ActivityBar: View {
    @ObservedObject var model: ActivityModel
    let openSettings: () -> Void
    @Environment(\.interfaceScale) private var scale
    @Environment(\.surface) private var surface

    /// The bar's width, and each icon's square cell.
    static func width(_ scale: InterfaceScale) -> CGFloat { scale(Size.control + 2 * Space.base) }

    var body: some View {
        let cell = Self.width(scale)
        VStack(spacing: 0) {
            List {
                ForEach(model.layout.order, id: \.self) { panel in
                    icon(panel, cell: cell)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                .onMove { [model] source, destination in model.move(fromOffsets: source, toOffset: destination) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .environment(\.defaultMinListRowHeight, cell)
            .background(NativeRowHighlight.off)
            .frame(height: cell * CGFloat(model.layout.order.count))
            Spacer(minLength: 0)
            Button(action: openSettings) {
                Image(systemName: "gearshape").font(Typography.title).foregroundStyle(surface.secondaryInk)
                    .frame(width: cell, height: cell)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings…")
            .accessibilityLabel("Settings")
        }
        .frame(width: cell)
        .overlay(alignment: .trailing) { SidebarEdge() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Activity bar")
    }

    /// A panel's icon: a tap shows it, a drag moves it. A tap, not a `Button`, so the List's drag
    /// starts on the icon itself.
    private func icon(_ panel: ActivityPanel, cell: CGFloat) -> some View {
        let selected = model.layout.selected == panel
        return SymbolMark(symbol: panel.symbol, size: scale(Size.control), tint: selected ? Palette.accent : surface.secondaryInk)
            .frame(width: cell, height: cell)
            .overlay(alignment: .leading) {
                if selected { Rectangle().fill(Palette.accent).frame(width: Space.hairline) }
            }
            .contentShape(Rectangle())
            .onTapGesture { model.select(panel) }
            .help(panel.title)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(panel.title)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { model.select(panel) }
    }
}

/// A panel still to come: its title, where its content will be. `titled` false when the title is
/// already on the window buttons' row.
struct ActivityPanelPlaceholder: View {
    let panel: ActivityPanel
    let titled: Bool
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if titled {
                SidebarHeading(panel.title)
                    .frame(height: scale(Size.menuRow))
                    .padding(.horizontal, scale(Space.base))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
