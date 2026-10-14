import Foundation
import Testing
@testable import ShellforgeUI

/// Closing a task's tabs, the first step of removing it: every tab any of whose panes is tagged
/// with the task, in every window, and nothing else.
@MainActor @Suite struct TaskTabsTests {
    final class Tab {
        let name: String, panes: [String?]
        init(_ name: String, panes: [String?]) { self.name = name; self.panes = panes }
    }
    final class Window {
        var tabs: [Tab]
        /// A tab that refuses to close stays, as one iTerm2 could not close would.
        var stubborn: Set<String> = []
        init(_ tabs: [Tab]) { self.tabs = tabs }
        func close(_ tab: Tab) { if !stubborn.contains(tab.name) { tabs.removeAll { $0 === tab } } }
    }

    private let task = UUID(), other = UUID()

    private func close(in windows: [Window], keep: @escaping (Window) -> Bool = { _ in true }) -> Bool {
        TaskTabs.close(taskId: task, in: windows, tabs: { $0.tabs }, paneTags: { $0.panes }, keep: keep, close: { $0.close($1) })
    }

    /// A window's fresh tab, as the app adds iTerm2's own: untagged.
    private func fresh(_ window: Window) -> Bool { window.tabs.append(Tab("fresh", panes: [nil])); return true }

    @Test func everyTabOfTheTaskClosesInEveryWindowAndNoOther() {
        let id = task.uuidString.lowercased(), elsewhere = other.uuidString.lowercased()
        let first = Window([Tab("a", panes: [id]), Tab("b", panes: [elsewhere]), Tab("c", panes: [nil])])
        // A split whose focused pane is untagged still belongs to the task.
        let second = Window([Tab("d", panes: [nil, id]), Tab("e", panes: [nil])])
        #expect(close(in: [first, second]))
        #expect(first.tabs.map(\.name) == ["b", "c"])
        #expect(second.tabs.map(\.name) == ["e"])
    }

    @Test func aTabThatStaysOpenIsSaid() {
        let window = Window([Tab("a", panes: [task.uuidString.lowercased()])])
        window.stubborn = ["a"]
        #expect(!close(in: [window]))
    }

    @Test func aTaskWithNoTabsHasNothingToClose() {
        #expect(close(in: [Window([Tab("b", panes: [other.uuidString.lowercased()])])]))
    }

    // -- M4e: a window emptied by the close keeps a fresh tab, added first --

    @Test func aWindowTheCloseWouldEmptyGetsAFreshTabFirst() {
        let id = task.uuidString.lowercased()
        let only = Window([Tab("a", panes: [id])])
        let shared = Window([Tab("b", panes: [id]), Tab("c", panes: [nil])])
        var kept: [String] = []
        #expect(close(in: [only, shared]) { kept.append($0.tabs[0].name); return self.fresh($0) })
        #expect(kept == ["a"], "only the window the close would empty, before anything closes")
        #expect(only.tabs.map(\.name) == ["fresh"] && shared.tabs.map(\.name) == ["c"])
    }

    /// A tab whose focused pane is another task's but which holds one of ours still counts: the
    /// window is judged by what the close actually closes.
    @Test func aWindowIsJudgedByEveryPane() {
        let id = task.uuidString.lowercased(), elsewhere = other.uuidString.lowercased()
        let window = Window([Tab("a", panes: [elsewhere, id])])
        #expect(close(in: [window], keep: fresh))
        #expect(window.tabs.map(\.name) == ["fresh"])
    }

    /// No fresh tab could be added (a layout-locked window): that window's tabs stay, and the
    /// close says so, so a removal stops before anything is deleted.
    @Test func aWindowThatCannotKeepATabKeepsItsTabs() {
        let window = Window([Tab("a", panes: [task.uuidString.lowercased()])])
        #expect(!close(in: [window]) { _ in false })
        #expect(window.tabs.map(\.name) == ["a"])
    }

    @Test func closingAWindowsOnlyTabAddsAFreshOneFirst() {
        let window = Window([Tab("a", panes: [nil])])
        #expect(closeOne(window.tabs[0], in: window))
        #expect(window.tabs.map(\.name) == ["fresh"])
        let two = Window([Tab("a", panes: [nil]), Tab("b", panes: [nil])])
        var kept = 0
        #expect(TaskTabs.closeOne(two.tabs[0], in: two, tabs: { $0.tabs }, keep: { _ in kept += 1; return nil },
                                  select: { _, _ in }, close: { $0.close($1) }, discard: { $0.close($1) }))
        #expect(kept == 0 && two.tabs.map(\.name) == ["b"])
    }

    /// A pane split off a task's (⌘D) carries no tag; it takes the tab's, so closing the agent's
    /// pane leaves the task a pane, not an Other tab.
    @Test func panesSplitOffATaskJoinIt() {
        let id = task.uuidString.lowercased()
        #expect(TaskTabs.joining([id, nil]) == id)
        #expect(TaskTabs.joining([nil, id, nil]) == id)
        #expect(TaskTabs.joining([id, id]) == nil, "nothing to tag")
        #expect(TaskTabs.joining([nil, nil]) == nil, "no task's tab")
    }

    /// A tab two tasks share: its untagged pane counts for the task it will join, not for both.
    @Test func aSharedTabsUntaggedPaneCountsForOneTask() {
        let a = "a", b = "b"
        #expect(TaskTabs.paneCount(of: a, in: [a, b, nil]) == 2)
        #expect(TaskTabs.paneCount(of: b, in: [a, b, nil]) == 1)
        #expect(TaskTabs.paneCount(of: a, in: [a, nil, nil]) == 3)
        #expect(TaskTabs.paneCount(of: a, in: [b, nil]) == 0)
    }

    // -- M5e --

    /// The fresh tab, as the app opens iTerm2's own.
    private func freshTab(_ window: Window) -> Tab? { let tab = Tab("fresh", panes: [nil]); window.tabs.append(tab); return tab }

    private func closeOne(_ tab: Tab, in window: Window, selected: ((String) -> Void)? = nil) -> Bool {
        TaskTabs.closeOne(tab, in: window, tabs: { $0.tabs }, keep: freshTab, select: { _, tab in selected?(tab.name) },
                          close: { $0.close($1) }, discard: { $0.close($1) })
    }

    /// iTerm2's alert answered Cancel on a window's only tab: the fresh tab opened for it goes again.
    @Test func aRefusedCloseTakesItsFreshTabAway() {
        let window = Window([Tab("a", panes: [nil])])
        window.stubborn = ["a"]
        #expect(!closeOne(window.tabs[0], in: window))
        #expect(window.tabs.map(\.name) == ["a"])
    }

    /// The tab being closed is in front when iTerm2 asks about it, not the fresh one.
    @Test func theClosedTabIsInFrontWhenItAsks() {
        let window = Window([Tab("a", panes: [nil])])
        var selected: [String] = []
        #expect(closeOne(window.tabs[0], in: window) { selected.append($0) })
        #expect(selected == ["a"])
    }
}
