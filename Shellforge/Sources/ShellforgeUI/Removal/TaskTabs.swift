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

    /// The tag an untagged pane of a tab takes: its tab's, from the pane that carries one. Nil when
    /// no pane does, or none lacks it. A pane split off a task's (⌘D) carries no tag of its own.
    public static func joining(_ paneTags: [String?]) -> String? {
        guard paneTags.contains(nil) else { return nil }
        return paneTags.lazy.compactMap { $0 }.first
    }

    /// How many of a tab's panes are task `tag`'s: its own, and the untagged ones that will join it —
    /// `joining`'s, so in a tab two tasks share an untagged pane counts for one of them, not both.
    public static func paneCount(of tag: String, in paneTags: [String?]) -> Int {
        guard paneTags.contains(tag) else { return 0 }
        let untagged = joining(paneTags) == tag ? paneTags.filter { $0 == nil }.count : 0
        return paneTags.filter { $0 == tag }.count + untagged
    }

    /// One tab, closed. A window's only tab gets a fresh one beside it first (`keep`, which hands it
    /// back), and is brought in front again (`select`) so iTerm2's question is about it. Refused, the
    /// fresh tab goes again (`discard`): the window is as it was. True once it closed.
    @MainActor
    public static func closeOne<Window, Tab: AnyObject>(_ tab: Tab, in window: Window, tabs: (Window) -> [Tab],
                                                        keep: (Window) -> Tab?, select: (Window, Tab) -> Void,
                                                        close: (Window, Tab) -> Void, discard: (Window, Tab) -> Void) -> Bool {
        var fresh: Tab?
        if tabs(window).count == 1 {
            guard let added = keep(window) else { return false }
            fresh = added
            select(window, tab)
        }
        close(window, tab)
        let closed = !tabs(window).contains { $0 === tab }
        if !closed, let fresh { discard(window, fresh) }
        return closed
    }
}
