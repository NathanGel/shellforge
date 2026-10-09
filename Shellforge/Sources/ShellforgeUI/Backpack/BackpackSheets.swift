import Foundation

/// How each window's sidebar opens the Backpack sheet, for the View menu's ⌘B: by the window's
/// controller, held weakly, so a closed window is forgotten. Only the key window's sidebar is asked;
/// with no window of ours key there is nothing to open, never an arbitrary other window.
@MainActor
public final class BackpackSheets {
    private final class Presenter { let present: @MainActor () -> Void; init(_ p: @escaping @MainActor () -> Void) { present = p } }
    private let byWindow = NSMapTable<AnyObject, Presenter>.weakToStrongObjects()

    public init() {}

    public func register(_ window: AnyObject, _ present: @escaping @MainActor () -> Void) {
        byWindow.setObject(Presenter(present), forKey: window)
    }

    /// Opens the sheet on `window`'s sidebar; false when it has none.
    @discardableResult
    public func present(for window: AnyObject?) -> Bool {
        guard let window, let presenter = byWindow.object(forKey: window) else { return false }
        presenter.present()
        return true
    }

    /// The windows still registered.
    public var count: Int { byWindow.keyEnumerator().allObjects.count }
}
