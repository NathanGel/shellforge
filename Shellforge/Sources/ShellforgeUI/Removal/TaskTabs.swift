import Foundation

/// Closing a task's tabs: every tab any of whose panes is tagged with the task, in every window —
/// a split focused beside the pane that opened it still belongs to the task. Generic over the
/// window and tab types, so the rule is tested without iTerm2; the app hands in its own.
///
/// iTerm2 closes a window with its last tab, and a Shellforge window's sidebar with it. A window
/// the close would empty gets a fresh tab first (`keep`); one that cannot keeps its tabs.
public enum TaskTabs {
    /// True once none of the task's tabs is left open.
    @MainActor
    public static func close<Window, Tab>(taskId: UUID, in windows: [Window], tabs: (Window) -> [Tab],
                                          paneTags: (Tab) -> [String?], keep: (Window) -> Bool = { _ in true },
                                          close: (Window, Tab) -> Void) -> Bool {
        let tag = taskId.uuidString.lowercased()
        func ours(_ tab: Tab) -> Bool { paneTags(tab).contains(tag) }
        for window in windows {
            let all = tabs(window)
            let closing = all.filter(ours)
            guard !closing.isEmpty else { continue }
            if closing.count == all.count, !keep(window) { continue }
            for tab in closing { close(window, tab) }
        }
        return !windows.contains { tabs($0).contains(where: ours) }
    }

    /// One tab, closed; a window's only tab gets a fresh one beside it first. True once it closed.
    @MainActor
    public static func closeOne<Window, Tab: AnyObject>(_ tab: Tab, in window: Window, tabs: (Window) -> [Tab],
                                                        keep: (Window) -> Bool, close: (Window, Tab) -> Void) -> Bool {
        if tabs(window).count == 1, !keep(window) { return false }
        close(window, tab)
        return !tabs(window).contains { $0 === tab }
    }
}
