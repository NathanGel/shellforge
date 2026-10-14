import Combine
import ShellforgeDesign

/// The sidebar's text size: one of `InterfaceScale.all`, stepped by ⌘+ / ⌘− / ⌘0 while the sidebar
/// is the window's active side. One for the app, so every window's sidebar draws at it, and saved,
/// so the next launch opens at it.
@MainActor
public final class SidebarZoom: ObservableObject {
    @Published public private(set) var scale: InterfaceScale
    private let settings: SidebarLayoutSettings

    public init(settings: SidebarLayoutSettings) {
        self.settings = settings
        scale = settings.scale
    }

    /// One size up; at the largest, nothing.
    public func bigger() { step(by: 1) }

    /// One size down; at `.standard`, nothing.
    public func smaller() { step(by: -1) }

    /// Back to `.standard`.
    public func reset() { set(.standard) }

    private func step(by delta: Int) {
        let sizes = InterfaceScale.all
        let index = sizes.firstIndex(of: scale) ?? 0
        set(sizes[min(max(index + delta, 0), sizes.count - 1)])
    }

    private func set(_ new: InterfaceScale) {
        guard new != scale else { return }
        scale = new
        settings.scale = new
    }
}
