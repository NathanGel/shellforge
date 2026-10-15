import AppKit
import ShellforgeDesign

/// Where the window's buttons sit inside a floating sidebar (macOS 26), in the sidebar's own points
/// from its top-left corner. The header shares their row: its title starts a gap past the zoom
/// button and the row is centred on the buttons, as Finder's sidebar shares the toolbar's band.
public struct SidebarWindowControls: Equatable, Sendable {
    /// The zoom button's right edge.
    public var buttonsMaxX: CGFloat
    /// The buttons' vertical centre, from the sidebar's top.
    public var buttonsMidY: CGFloat

    public init(buttonsMaxX: CGFloat, buttonsMidY: CGFloat) {
        self.buttonsMaxX = buttonsMaxX
        self.buttonsMidY = buttonsMidY
    }

    /// Where the header's title starts: a gap past the zoom button.
    var headerLeading: CGFloat { buttonsMaxX + Space.gap }
    /// The header's height: a band from the sidebar's top, centred on the buttons.
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
