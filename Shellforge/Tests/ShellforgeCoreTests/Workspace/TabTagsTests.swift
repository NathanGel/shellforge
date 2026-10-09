import Foundation
import Testing
@testable import ShellforgeCore

/// A tab belongs to the task its panes are tagged with: the pane that opened it carries the tags, and
/// a split beside it does not, so focusing the split must not move the tab out of its task.
@Suite struct TabTagsTests {
    private let task = "6f0e2c1a-9b3d-4e5f-8a7b-0c1d2e3f4a5b", project = "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d"

    @Test func anUntaggedFocusedSplitKeepsTheTabInItsTask() {
        let tags = TabSnapshot.tags(ofPanes: [(nil, nil), (task, project)])
        #expect(tags.task == UUID(uuidString: task) && tags.project == UUID(uuidString: project))
    }

    @Test func theFocusedPanesTagsComeFirst() {
        let other = "11111111-2222-4333-8444-555555555555"
        #expect(TabSnapshot.tags(ofPanes: [(other, nil), (task, project)]).task == UUID(uuidString: other))
    }

    @Test func noTaggedPaneIsNoTask() {
        let tags = TabSnapshot.tags(ofPanes: [(nil, nil), ("not-a-uuid", nil)])
        #expect(tags.task == nil && tags.project == nil)
    }
}
