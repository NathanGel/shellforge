import Combine
import Foundation
import os
import ShellforgeCore

private let activityLog = Logger(subsystem: "io.github.nathangel.shellforge", category: "activity")

/// The activity bar's order and the panels it leaves out, one for the whole app: every window's bar
/// follows them, and a change is saved for the next launch. `defaults` nil keeps them in memory only.
@MainActor
public final class ActivityOrderSource: ObservableObject {
    @Published public private(set) var order: [ActivityPanel]
    @Published public private(set) var hidden: Set<ActivityPanel>
    private let defaults: UserDefaults?

    public init(defaults: UserDefaults?) {
        self.defaults = defaults
        let layout = ActivityLayout(saved: defaults.flatMap(ActivityOrderStore.load), hidden: defaults.flatMap(ActivityHiddenStore.load))
        order = layout.order
        hidden = layout.hidden
    }

    private var layout: ActivityLayout {
        ActivityLayout(saved: order.map(\.rawValue), hidden: hidden.map(\.rawValue))
    }

    /// Moves `panel` in front of `before` (to the end when nil); saved only when the order changed.
    public func move(_ panel: ActivityPanel, before: ActivityPanel?) {
        var layout = self.layout
        layout.move(panel, before: before)
        guard layout.order != order else { return }
        activityLog.info("activity bar order \(layout.savedValue, privacy: .public)")
        order = layout.order
        if let defaults { ActivityOrderStore.save(layout.savedValue, to: defaults) }
    }

    /// Hides or shows `panel` in every window's bar; false, and nothing changes, for the last one shown.
    @discardableResult
    public func setHidden(_ panel: ActivityPanel, _ hide: Bool) -> Bool {
        var layout = self.layout
        guard layout.setHidden(panel, hide) else { return false }
        guard layout.hidden != hidden else { return true }
        activityLog.info("activity bar hides \(layout.savedHidden, privacy: .public)")
        hidden = layout.hidden
        if let defaults { ActivityHiddenStore.save(layout.savedHidden, to: defaults) }
        return true
    }
}

/// One window's activity bar: the app's shared order and hidden panels, and the panel this window
/// shows. A panel hidden while this window shows it gives way to the first one still shown.
@MainActor
public final class ActivityModel: ObservableObject {
    @Published public private(set) var layout: ActivityLayout
    private let source: ActivityOrderSource
    private var watch: AnyCancellable?

    public init(source: ActivityOrderSource) {
        self.source = source
        layout = ActivityLayout(saved: source.order.map(\.rawValue), hidden: source.hidden.map(\.rawValue))
        watch = source.$order.combineLatest(source.$hidden).dropFirst().sink { [weak self] order, hidden in
            guard let self else { return }
            self.layout = ActivityLayout(saved: order.map(\.rawValue), hidden: hidden.map(\.rawValue), selected: self.layout.selected)
        }
    }

    /// A window of its own over the order saved in `defaults`: for tests only. The app's windows
    /// share one `ActivityOrderSource`, so a drag in one moves every bar.
    convenience init(defaults: UserDefaults) {
        self.init(source: ActivityOrderSource(defaults: defaults))
    }

    /// Shows `panel`; a hidden one stays hidden, so its key does nothing.
    public func select(_ panel: ActivityPanel) {
        guard layout.selected != panel, !layout.hidden.contains(panel) else { return }
        layout.selected = panel
    }

    /// Moves `panel` in front of `before`, or to the end when nil, in every window.
    public func move(_ panel: ActivityPanel, before: ActivityPanel?) {
        source.move(panel, before: before)
    }

    /// Hides or shows `panel` in every window; false for the last one shown.
    @discardableResult
    public func setHidden(_ panel: ActivityPanel, _ hide: Bool) -> Bool {
        source.setHidden(panel, hide)
    }

    /// The bar's drop: `offsets` dropped at `destination`, both in `layout.visibleOrder`.
    public func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let order = layout.visibleOrder
        let before = destination < order.count ? order[destination] : nil
        for panel in offsets.map({ order[$0] }) { move(panel, before: before) }
    }
}
