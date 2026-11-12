import ShellforgeCore
import ShellforgeDesign
import SwiftUI

/// A tab a panel opened, on one line indented under the row it belongs to: its title; a click
/// brings it forward and its × closes it, as closing a tab in Sessions does. The SSH, Files and Git
/// panels list their tabs with it.
struct PanelTabLine: View {
    let tab: TabSnapshot
    let selected: Bool
    /// How far the line starts from the panel's edge.
    let indent: CGFloat
    let show: () -> Void
    let close: () -> Void
    let closeTitle: String
    @Environment(\.interfaceScale) private var scale
    @Environment(\.surface) private var surface

    static let showTitle = "Show"

    /// The line for `tab` over `model`: its click selects the tab, its × closes it through the
    /// model's close path.
    init(tab: TabSnapshot, indent: CGFloat, model: SidebarModel) {
        self.init(tab: tab, selected: tab.id == model.drawnTabId, indent: indent,
                  show: { model.select(tab: tab.id) }, close: { model.closeTab(tab.id) }, closeTitle: model.closeTitle(ofTab: tab.id))
    }

    init(tab: TabSnapshot, selected: Bool, indent: CGFloat, show: @escaping () -> Void, close: @escaping () -> Void, closeTitle: String) {
        self.tab = tab
        self.selected = selected
        self.indent = indent
        self.show = show
        self.close = close
        self.closeTitle = closeTitle
    }

    var body: some View {
        SelectableRow(selected: selected, activate: show) {
            HStack(spacing: scale(Space.inset)) {
                RowTitle(tab.title)
                Spacer(minLength: scale(Space.tight))
                Button(action: close) {
                    Image(systemName: "xmark").font(Typography.micro).foregroundStyle(surface.secondaryInk)
                }
                .buttonStyle(.plain)
                .frame(width: SidebarRowLayout.trailingSlot(scale), height: SidebarRowLayout.trailingSlot(scale))
                .help(closeTitle)
            }
        }
        .padding(.leading, indent)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tab.title)
        .accessibilityAction(named: Text(Self.showTitle), show)
        .accessibilityAction(named: Text(closeTitle), close)
        .contextMenu { Button(closeTitle, action: close) }
    }
}
