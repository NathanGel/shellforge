import Combine
import Foundation
import os
import ShellforgeCore

private let activityLog = Logger(subsystem: "io.github.nathangel.shellforge", category: "activity")

/// The activity bar's order, one for the whole app: every window's bar follows it, and a move is
/// saved for the next launch. `defaults` nil keeps it in memory only.
@MainActor
public final class ActivityOrderSource: ObservableObject {
    @Published public private(set) var order: [ActivityPanel]
    private let defaults: UserDefaults?

    public init(defaults: UserDefaults?) {
        self.defaults = defaults
        order = ActivityLayout(saved: defaults.flatMap(ActivityOrderStore.load)).order
    }

    /// Moves `panel` in front of `before` (to the end when nil); saved only when the order changed.
    public func move(_ panel: ActivityPanel, before: ActivityPanel?) {
        var layout = ActivityLayout(saved: order.map(\.rawValue))
        layout.move(panel, before: before)
        guard layout.order != order else { return }
        activityLog.info("activity bar order \(layout.savedValue, privacy: .public)")
        order = layout.order
        if let defaults { ActivityOrderStore.save(layout.savedValue, to: defaults) }
    }
}

/// One window's activity bar: the app's shared order, and the panel this window shows.
@MainActor
public final class ActivityModel: ObservableObject {
    @Published public private(set) var layout: ActivityLayout
    private let source: ActivityOrderSource
    private var watch: AnyCancellable?

    public init(source: ActivityOrderSource) {
        self.source = source
        layout = ActivityLayout(saved: source.order.map(\.rawValue))
        watch = source.$order.dropFirst().sink { [weak self] order in
            guard let self else { return }
            self.layout = ActivityLayout(saved: order.map(\.rawValue), selected: self.layout.selected)
        }
    }

    /// A window of its own over the order saved in `defaults`: for tests only. The app's windows
    /// share one `ActivityOrderSource`, so a drag in one moves every bar.
    convenience init(defaults: UserDefaults) {
        self.init(source: ActivityOrderSource(defaults: defaults))
    }

    public func select(_ panel: ActivityPanel) {
        guard layout.selected != panel else { return }
        layout.selected = panel
    }

    /// Moves `panel` in front of `before`, or to the end when nil, in every window.
    public func move(_ panel: ActivityPanel, before: ActivityPanel?) {
        source.move(panel, before: before)
    }

    /// The bar's `List.onMove`: `offsets` dropped at `destination`, both in `layout.order`.
    public func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let order = layout.order
        let before = destination < order.count ? order[destination] : nil
        for panel in offsets.map({ order[$0] }) { move(panel, before: before) }
    }
}
