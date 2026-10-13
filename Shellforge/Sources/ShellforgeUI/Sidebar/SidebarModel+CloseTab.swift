import Foundation
import ShellforgeCore

/// Close Tab, from a tab row or a task's row — Close Pane on a tab split with ⌘D, which closes its
/// focused pane as iTerm2's Close does. A task left with no pane anywhere closes too: its last asks,
/// through Remove Task's own confirmation, then closes as Close does — a running job asks too —
/// before the removal goes on; cancelled at either, both stay.
extension SidebarModel {
    public func closeTab(_ id: String) {
        if let tab = host.tabs.first(where: { $0.id == id }), tab.paneCount > 1 {
            host.closePane(ofTab: id)
            return
        }
        if let task = tree.projects.lazy.flatMap(\.tasks).first(where: { $0.tabs.contains { $0.id == id } }),
           host.paneCount(ofTask: task.id) <= 1 {
            sheetRequests.send(.closeLastTab(task: task.id, tab: id))
            return
        }
        host.close(tab: id)
    }

    /// A task row's Close: the task's tab now selected, else its first.
    public func closeCurrentTab(ofTask id: UUID) {
        guard let tab = currentTab(ofTask: id) else { return }
        closeTab(tab.id)
    }

    /// "Close Pane" for a split tab, "Close Tab" otherwise.
    public func closeTitle(ofTab id: String) -> String {
        (host.tabs.first { $0.id == id }?.paneCount ?? 1) > 1 ? "Close Pane" : "Close Tab"
    }

    public func closeTitle(ofTask id: UUID) -> String {
        currentTab(ofTask: id).map { closeTitle(ofTab: $0.id) } ?? "Close Tab"
    }

    /// By tab id, read from the window now: focusing another pane renames the tab's session.
    private func currentTab(ofTask id: UUID) -> TabSnapshot? {
        guard let task = tree.projects.lazy.flatMap(\.tasks).first(where: { $0.id == id }) else { return nil }
        let current = host.tabs.first { $0.id == host.selectedTabId }?.tabId
        return task.tabs.first(where: { $0.tabId == current }) ?? task.tabs.first
    }
}
