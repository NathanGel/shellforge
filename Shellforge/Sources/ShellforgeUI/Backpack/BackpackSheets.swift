import Foundation
import ObjectiveC

/// How each window's sidebar opens the Backpack sheet, for the View menu's ⌘B. Only the key
/// window's sidebar is asked; with no window of ours key there is nothing to open, never an
/// arbitrary other window.
///
/// A presenter holds its window's whole sidebar, so it must go the moment its window does. A weak-
/// to-strong `NSMapTable` keeps a value until the table next resizes, long after its key is gone:
/// each window instead carries a token whose release, with the window, removes its entry.
@MainActor
public final class BackpackSheets {
    private struct Entry { weak var window: AnyObject?; let present: @MainActor () -> Void }
    private var byWindow: [ObjectIdentifier: Entry] = [:]

    /// Released with its window: takes the window's entry out.
    private final class Token {
        let remove: () -> Void
        init(_ remove: @escaping () -> Void) { self.remove = remove }
        deinit { remove() }
    }
    private static var tokenKey = 0

    public init() {}

    public func register(_ window: AnyObject, _ present: @escaping @MainActor () -> Void) {
        let id = ObjectIdentifier(window)
        byWindow[id] = Entry(window: window, present: present)
        let token = Token { [weak self] in
            // A window is released on the main thread, and its entry goes at once; one released
            // elsewhere has it taken out on the main thread's next turn.
            if Thread.isMainThread { MainActor.assumeIsolated { self?.forget(id) } } else { Task { @MainActor in self?.forget(id) } }
        }
        objc_setAssociatedObject(window, &Self.tokenKey, token, .OBJC_ASSOCIATION_RETAIN)
    }

    private func forget(_ id: ObjectIdentifier) {
        // An id reused by a new window registered meanwhile is that window's: kept.
        if byWindow[id]?.window == nil { byWindow[id] = nil }
    }

    /// Opens the sheet on `window`'s sidebar; false when it has none.
    @discardableResult
    public func present(for window: AnyObject?) -> Bool {
        guard let window, let entry = byWindow[ObjectIdentifier(window)], entry.window === window else { return false }
        entry.present()
        return true
    }

    /// The windows still registered.
    public var count: Int { byWindow.values.filter { $0.window != nil }.count }
}
