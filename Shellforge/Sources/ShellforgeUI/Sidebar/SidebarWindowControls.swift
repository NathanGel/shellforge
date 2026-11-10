import AppKit

/// Where the window's buttons sit inside a floating sidebar (macOS 26), in the sidebar's own points
/// from its top-left corner. Their band across the sidebar's top is theirs alone, as VS Code's title
/// bar is: the activity bar and the panel's header start below it.
public struct SidebarWindowControls: Equatable, Sendable {
    /// The zoom button's right edge.
    public var buttonsMaxX: CGFloat
    /// The buttons' vertical centre, from the sidebar's top.
    public var buttonsMidY: CGFloat

    /// Full screen: no window buttons, so the toggle has the band to itself.
    public var stacked: Bool

    public init(buttonsMaxX: CGFloat, buttonsMidY: CGFloat, stacked: Bool = false) {
        self.buttonsMaxX = buttonsMaxX
        self.buttonsMidY = buttonsMidY
        self.stacked = stacked
    }

    /// The band's height: from the sidebar's top, centred on the buttons.
    var bandHeight: CGFloat { 2 * buttonsMidY }
}

/// The sidebar's share of its window's chrome, which the host updates as the window lays out: nil
/// while the window's buttons are not inside the sidebar (full screen, a compact window, macOS 15).
@MainActor final class SidebarChrome: ObservableObject {
    @Published var windowControls: SidebarWindowControls?
    /// The floating panel's corner radius, concentric with the window's as measured; nil where the
    /// sidebar does not float.
    @Published var panelCornerRadius: CGFloat?
}
