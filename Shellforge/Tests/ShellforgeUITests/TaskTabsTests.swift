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

    private func close(in windows: [Window]) -> Bool {
        TaskTabs.close(taskId: task, in: windows, tabs: { $0.tabs }, paneTags: { $0.panes }, close: { $0.close($1) })
    }

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
}
