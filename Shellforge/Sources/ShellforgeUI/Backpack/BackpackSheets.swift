import Foundation

/// How each window's sidebar opens the Backpack sheet, for the View menu's ⌘B. Only the key
/// window's sidebar is asked; with no window of ours key there is nothing to open, never an
/// arbitrary other window.
///
/// A presenter that held its window's whole sidebar would keep it, still ticking and refreshing, as
/// long as its entry stayed. `ShellforgeSidebar.makeView` therefore hands out one that reaches the
/// sidebar weakly, through the sidebar's own view, so an entry left behind holds nothing but that
/// closure; and an entry whose window is gone is dropped each time the table is used. iTerm2's
/// undo-close keeps a closed window, and its sidebar, alive for a while: its entry stays as long.
@MainActor
public final class BackpackSheets {
    private struct Entry { weak var window: AnyObject?; let present: @MainActor () -> Void }
    private var byWindow: [ObjectIdentifier: Entry] = [:]

    public init() {}

    public func register(_ window: AnyObject, _ present: @escaping @MainActor () -> Void) {
        prune()
        byWindow[ObjectIdentifier(window)] = Entry(window: window, present: present)
    }

    /// Opens the sheet on `window`'s sidebar; false when it has none.
    @discardableResult
    public func present(for window: AnyObject?) -> Bool {
        prune()
        guard let window, let entry = byWindow[ObjectIdentifier(window)], entry.window === window else { return false }
        entry.present()
        return true
    }

    /// The windows still registered.
    public var count: Int {
        prune()
        return byWindow.count
    }

    /// Entries whose window has gone. An id reused by a window registered since is that window's,
    /// and its entry has a live window: kept.
    private func prune() {
        byWindow = byWindow.filter { $0.value.window != nil }
    }
}
