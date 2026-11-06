import AppKit

/// Whether a window's sidebar can be seen now: what the app's tick asks before it spends git on a
/// window's badges, and what keeps the Mac's readings sampled only while some footer shows them.
@MainActor
public enum SidebarVisibility {
    /// A sidebar shows when its view is not hidden — the sidebar closed with ⌃⌘S, or not revealed
    /// in full screen — and its window is on screen, not in the Dock, and not wholly covered.
    public static func isShowing(viewHidden: Bool, windowVisible: Bool, miniaturized: Bool,
                                 occlusion: NSWindow.OcclusionState) -> Bool {
        !viewHidden && windowVisible && !miniaturized && occlusion.contains(.visible)
    }

    /// `isShowing` for a sidebar view `ShellforgeSidebar.makeView` made; false for one in no window.
    public static func isShowing(_ view: NSView) -> Bool {
        guard let window = view.window else { return false }
        return isShowing(viewHidden: view.isHiddenOrHasHiddenAncestor, windowVisible: window.isVisible,
                         miniaturized: window.isMiniaturized, occlusion: window.occlusionState)
    }
}
