import AppKit
import SwiftUI
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI

@MainActor @Suite struct AgentHooksViewTests {
    /// The sheet opens in a panel of its own, dark like the sidebar, and leaves the window it hangs
    /// from — iTerm2's — as it was.
    @Test func theHooksPanelIsDark() throws {
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        parent.appearance = NSAppearance(named: .aqua)
        let panel = DarkPanel.present(Text("x"), over: parent)
        #expect(panel.appearance?.name == .darkAqua)
        #expect(parent.appearance?.name == .aqua, "the window it hangs from keeps its own")
        DarkPanel.dismiss(panel)
    }

    /// Every state says itself in words, and offers at most one action: none where an install would
    /// be refused anyway.
    @Test(arguments: [(HookState.missing, "Not installed", Optional("Install")), (.current, "Installed", "Reinstall"),
                      (.outdated, "Out of date", "Repair"), (.invalidOwned, "Needs repair", "Repair"),
                      (.foreign, "Another file is in the way", nil), (.unreadable, "Can’t be read", nil),
                      (.resourceUnavailable, "Unavailable", nil), (.notChecked, "Checking…", nil)])
    func eachStateHasItsWordsAndOneAction(state: HookState, words: String, action: String?) {
        #expect(AgentHooksView.words(state) == words)
        #expect(AgentHooksView.buttonTitle(state) == action)
    }
}
