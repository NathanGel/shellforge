import Foundation
import ShellforgeCore

/// Close Tab, from a tab row or a task's row. A task left with no tab anywhere closes too: its last
/// tab asks, through Remove Task's own confirmation, then closes as Close Tab does — a running job
/// asks too — before the removal goes on; cancelled at either, both stay.
extension SidebarModel {
    public func closeTab(_ id: String) {
        if let task = tree.projects.lazy.flatMap(\.tasks).first(where: { $0.tabs.contains { $0.id == id } }),
           host.tabCount(ofTask: task.id) <= 1 {
            sheetRequests.send(.closeLastTab(task: task.id, tab: id))
            return
        }
        keepingWindow(closing: { $0.id == id })
        host.close(tab: id)
    }

    /// iTerm2 closes a window with its last tab, and the sidebar with it: when every tab of this
    /// window is about to close, a plain shell opens first, and the window stays.
    func keepingWindow(closing: (TabSnapshot) -> Bool) {
        let tabs = host.tabs
        if !tabs.isEmpty, tabs.allSatisfy(closing) { host.openShellTab() }
    }

    /// A task row's Close Tab: the task's tab now selected, else its first.
    public func closeCurrentTab(ofTask id: UUID) {
        guard let task = tree.projects.lazy.flatMap(\.tasks).first(where: { $0.id == id }) else { return }
        // By tab id, read from the window now: focusing another pane renames the tab's session.
        let current = host.tabs.first { $0.id == host.selectedTabId }?.tabId
        guard let tab = task.tabs.first(where: { $0.tabId == current }) ?? task.tabs.first else { return }
        closeTab(tab.id)
    }
}
