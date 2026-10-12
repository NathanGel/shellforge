import Foundation
import ShellforgeDesign

/// The sidebar's width, as dragged, and whether it is hidden (⌃⌘S): kept in the app's defaults, so
/// a new window opens as the last one was left.
public struct SidebarLayoutSettings {
    private static let widthKey = "ShellforgeSidebarWidth"
    private static let hiddenKey = "ShellforgeSidebarHidden"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) { self.defaults = defaults }

    // The sidebar's own geometry, not a design token: `Metrics.swift` stays AiTerm's (TokenParityTests).
    /// The widest it can be dragged: past it a row's branch has all the room it can use, and the
    /// terminal's columns are what the width is for.
    public static let maxWidth: CGFloat = 720
    /// What a window keeps for its terminal beside a wide sidebar: about forty columns at a usual
    /// font, so a prompt still fits.
    public static let terminalMinWidth: CGFloat = 320

    /// Between `Size.sidebarMinWidth` and `maxWidth`; `Size.sidebarWidth` until dragged.
    public var width: CGFloat {
        get {
            let saved = defaults.double(forKey: Self.widthKey)
            return saved > 0 ? Self.clamped(saved) : Size.sidebarWidth
        }
        nonmutating set { defaults.set(Double(Self.clamped(newValue)), forKey: Self.widthKey) }
    }

    public var hidden: Bool {
        get { defaults.bool(forKey: Self.hiddenKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.hiddenKey) }
    }

    static func clamped(_ width: CGFloat) -> CGFloat { min(max(width, Size.sidebarMinWidth), Self.maxWidth) }

    /// The width a window of `windowWidth` gives the sidebar: the preferred one, less what the
    /// terminal needs to keep `terminalMinWidth`, never under the sidebar's own minimum — and
    /// none at all in a window too narrow even for that.
    public static func width(_ preferred: CGFloat, windowWidth: CGFloat) -> CGFloat {
        let width = min(clamped(preferred), max(windowWidth - Self.terminalMinWidth, Size.sidebarMinWidth))
        return width > windowWidth ? 0 : width
    }
}
