import AppKit

/// Which side of each window was clicked last: the sidebar, or the terminal beside it. ⌘+ / ⌘− /
/// ⌘0 zoom the sidebar while it was, though a click on a row hands the keyboard to the terminal.
@MainActor
public final class SidebarClicks {
    private let sidebarSide = NSHashTable<NSWindow>.weakObjects()

    public init() {}

    /// A mouse-down in `window`, on `view`: the sidebar's side when `view` is inside a sidebar.
    public func clicked(in window: NSWindow, on view: NSView?) {
        if ShellforgeSidebar.contains(view) {
            sidebarSide.add(window)
        } else {
            sidebarSide.remove(window)
        }
    }

    /// Whether `window`'s last click was in its sidebar.
    public func sidebarIsActive(in window: NSWindow?) -> Bool {
        guard let window else { return false }
        return sidebarSide.contains(window)
    }
}
