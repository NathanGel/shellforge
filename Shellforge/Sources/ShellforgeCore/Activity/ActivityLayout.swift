import Foundation

/// A panel the sidebar's activity bar can show.
public enum ActivityPanel: String, CaseIterable, Sendable {
    case sessions, metrics, files, git, ssh

    public var title: String {
        switch self {
        case .sessions: return "Sessions"
        case .metrics: return "Metrics"
        case .files: return "Files"
        case .git: return "Git"
        case .ssh: return "SSH"
        }
    }

    public var symbol: String {
        switch self {
        case .sessions: return "rectangle.stack"
        case .metrics: return "gauge.with.dots.needle.33percent"
        case .files: return "folder"
        case .git: return "arrow.triangle.branch"
        case .ssh: return "server.rack"
        }
    }
}

/// The order of the activity bar's panels, which of them the bar leaves out, and which one is
/// selected. At least one panel always shows, and the selected one is always a shown one.
public struct ActivityLayout: Equatable, Sendable {
    public private(set) var order: [ActivityPanel]
    /// The panels the bar leaves out (Customize in the gear menu): never every panel.
    public private(set) var hidden: Set<ActivityPanel>
    public var selected: ActivityPanel

    /// Keeps known saved values in their saved order, drops unknown values and duplicates,
    /// and appends any panel the saved list lacks in `allCases` order. Unknown `hidden` values are
    /// ignored; were every panel hidden, the first in the order shows. A hidden `selected` gives way
    /// to the first shown panel.
    public init(saved: [String]?, hidden: [String]? = nil, selected: ActivityPanel = .sessions) {
        var seen = Set<ActivityPanel>()
        var order = (saved ?? []).compactMap(ActivityPanel.init(rawValue:)).filter { seen.insert($0).inserted }
        order += ActivityPanel.allCases.filter { !seen.contains($0) }
        var hiddenPanels = Set((hidden ?? []).compactMap(ActivityPanel.init(rawValue:)))
        if hiddenPanels.count == ActivityPanel.allCases.count, let first = order.first { hiddenPanels.remove(first) }
        self.order = order
        self.hidden = hiddenPanels
        self.selected = selected
        keepSelectionShown()
    }

    /// The panels the bar shows, in its order.
    public var visibleOrder: [ActivityPanel] { order.filter { !hidden.contains($0) } }

    /// Hides or shows `panel`. Hiding the last shown panel is refused: false, and nothing changes.
    /// Hiding the selected panel selects the first one still shown.
    @discardableResult
    public mutating func setHidden(_ panel: ActivityPanel, _ hide: Bool) -> Bool {
        if hide {
            guard visibleOrder != [panel] else { return false }
            hidden.insert(panel)
        } else {
            hidden.remove(panel)
        }
        keepSelectionShown()
        return true
    }

    private mutating func keepSelectionShown() {
        if hidden.contains(selected), let first = visibleOrder.first { selected = first }
    }

    /// `hidden` as it is saved: raw values, in `allCases` order.
    public var savedHidden: [String] { ActivityPanel.allCases.filter(hidden.contains).map(\.rawValue) }

    /// Moves `panel` in front of `before`, or to the end when `before` is nil. A panel dropped on
    /// itself stays where it is.
    public mutating func move(_ panel: ActivityPanel, before: ActivityPanel?) {
        guard panel != before else { return }
        order.removeAll { $0 == panel }
        if let before, let index = order.firstIndex(of: before) {
            order.insert(panel, at: index)
        } else {
            order.append(panel)
        }
    }

    public var savedValue: [String] { order.map(\.rawValue) }
}

public enum ActivityOrderStore {
    public static let key = "NoSyncShellforgeActivityOrder"

    public static func load(_ defaults: UserDefaults) -> [String]? {
        defaults.stringArray(forKey: key)
    }

    public static func save(_ order: [String], to defaults: UserDefaults) {
        defaults.set(order, forKey: key)
    }
}

/// Which panels the activity bar leaves out, saved on this Mac only.
public enum ActivityHiddenStore {
    public static let key = "NoSyncShellforgeActivityHidden"

    public static func load(_ defaults: UserDefaults) -> [String]? {
        defaults.stringArray(forKey: key)
    }

    public static func save(_ hidden: [String], to defaults: UserDefaults) {
        defaults.set(hidden, forKey: key)
    }
}
