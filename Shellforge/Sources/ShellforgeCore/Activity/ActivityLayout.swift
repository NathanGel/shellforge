import Foundation

/// A panel the sidebar's activity bar can show.
public enum ActivityPanel: String, CaseIterable, Sendable {
    case sessions, metrics, files

    public var title: String {
        switch self {
        case .sessions: return "Sessions"
        case .metrics: return "Metrics"
        case .files: return "Files"
        }
    }

    public var symbol: String {
        switch self {
        case .sessions: return "rectangle.stack"
        case .metrics: return "gauge.with.dots.needle.33percent"
        case .files: return "folder"
        }
    }
}

/// The order of the activity bar's panels and which one is selected.
public struct ActivityLayout: Equatable, Sendable {
    public private(set) var order: [ActivityPanel]
    public var selected: ActivityPanel

    /// Keeps known saved values in their saved order, drops unknown values and duplicates,
    /// and appends any panel the saved list lacks in `allCases` order.
    public init(saved: [String]?, selected: ActivityPanel = .sessions) {
        var seen = Set<ActivityPanel>()
        var order = (saved ?? []).compactMap(ActivityPanel.init(rawValue:)).filter { seen.insert($0).inserted }
        order += ActivityPanel.allCases.filter { !seen.contains($0) }
        self.order = order
        self.selected = selected
    }

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
