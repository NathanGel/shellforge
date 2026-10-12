import Foundation

/// Closing a task's tabs: every tab any of whose panes is tagged with the task, in every window —
/// a split focused beside the pane that opened it still belongs to the task. Generic over the
/// window and tab types, so the rule is tested without iTerm2; the app hands in its own.
public enum TaskTabs {
    /// True once none of the task's tabs is left open.
    @MainActor
    public static func close<Window, Tab>(taskId: UUID, in windows: [Window], tabs: (Window) -> [Tab],
                                          paneTags: (Tab) -> [String?], close: (Window, Tab) -> Void) -> Bool {
        let tag = taskId.uuidString.lowercased()
        func ours(_ tab: Tab) -> Bool { paneTags(tab).contains(tag) }
        for window in windows {
            for tab in tabs(window) where ours(tab) { close(window, tab) }
        }
        return !windows.contains { tabs($0).contains(where: ours) }
    }
}
