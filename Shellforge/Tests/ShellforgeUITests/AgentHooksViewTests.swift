import AppKit
import SwiftUI
import Testing
@testable import ShellforgeTestSupport
@testable import ShellforgeCore
@testable import ShellforgeUI

@MainActor @Suite struct AgentHooksViewTests {
    /// The sheet opens in a panel of its own, dark like the sidebar, and leaves the window it hangs
    /// from — iTerm2's — as it was.
    @Test func theHooksPanelIsDark() throws {
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        parent.appearance = NSAppearance(named: .aqua)
        let slot = PanelSlot()
        let panel = slot.present(over: parent) { _ in Color(nsColor: .windowBackgroundColor).frame(width: 40, height: 40) }
        let content = try #require(panel.contentView)
        content.layoutSubtreeIfNeeded()
        let bitmap = try #require(Snapshot.bitmap(of: content))
        let ground = try #require(bitmap.colorAt(x: Int(20 * Snapshot.scale), y: Int(20 * Snapshot.scale))?.usingColorSpace(.sRGB))
        #expect(ground.brightnessComponent < 0.3, "the sheet draws light: \(ground)")
        #expect(parent.appearance?.name == .aqua, "the window it hangs from keeps its own")
        slot.dismiss()
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
