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

    /// A window's preferred width after its edge moved `delta`: from its own preferred width, not
    /// the width a narrow window gave it, within the limits.
    public static func dragged(_ preferred: CGFloat, by delta: CGFloat) -> CGFloat { clamped(preferred + delta) }

    public static func clamped(_ width: CGFloat) -> CGFloat { min(max(width, Size.sidebarMinWidth), Self.maxWidth) }

    /// The width a window of `windowWidth` gives the sidebar: the preferred one, less what the
    /// terminal needs to keep `terminalMinWidth` beside the toolbelt's `beside`. When even the
    /// sidebar's minimum would leave the terminal less than that, the sidebar steps aside: the
    /// terminal is what the window is for.
    public static func width(_ preferred: CGFloat, windowWidth: CGFloat, beside: CGFloat = 0) -> CGFloat {
        let room = windowWidth - beside - Self.terminalMinWidth
        return room < Size.sidebarMinWidth ? 0 : min(clamped(preferred), room)
    }

    /// The narrowest a window with the sidebar showing can be dragged: the sidebar at its minimum
    /// and the terminal at its own, beside the toolbelt's `beside`. Narrower, the sidebar would jump
    /// from its minimum to nothing.
    ///
    /// iTerm2 holds the toolbelt to at most `toolbeltMaxFraction` of the window, so a wide one counts
    /// as the layout will make it: the window W where W = minimums + min(toolbelt, fraction × W).
    public static func minimumWindowWidth(beside: CGFloat, toolbeltMaxFraction: CGFloat = 1) -> CGFloat {
        let base = Size.sidebarMinWidth + Self.terminalMinWidth
        guard toolbeltMaxFraction < 1, beside > toolbeltMaxFraction * (base + beside) else { return base + beside }
        return base / (1 - toolbeltMaxFraction)
    }

    /// The drag handle across the sidebar's right `edge`: its hairline inside, and up to 3 pt over
    /// the terminal, never past its side `margin` — the list's scroller under the edge keeps its
    /// clicks, and so does the terminal's first column.
    public static func dragHandle(edge: CGFloat, margin: CGFloat) -> (x: CGFloat, width: CGFloat) {
        (edge - 1, 1 + min(3, max(0, margin)))
    }
}
