import AppKit
import SwiftUI
import Testing
@testable import ShellforgeTestSupport
@testable import ShellforgeCore
@testable import ShellforgeUI

@MainActor @Suite struct AgentHooksViewTests {
    /// The sheet opens in a panel of its own, in the appearance of the window it hangs from, and
    /// leaves that window as it was.
    @Test func theHooksPanelFollowsItsWindow() throws {
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        parent.appearance = NSAppearance(named: .aqua)
        let slot = PanelSlot()
        let panel = slot.present(over: parent) { _ in Color(nsColor: .windowBackgroundColor).frame(width: 40, height: 40) }
        let content = try #require(panel.contentView)
        content.layoutSubtreeIfNeeded()
        let bitmap = try #require(Snapshot.bitmap(of: content))
        let ground = try #require(bitmap.colorAt(x: Int(20 * Snapshot.scale), y: Int(20 * Snapshot.scale))?.usingColorSpace(.sRGB))
        #expect(ground.brightnessComponent > 0.7, "a light window's sheet draws light: \(ground)")
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

    /// The sheet keeps every sheet's keys: ⌘↩ presses Done and ⎋ closes; a plain ↩ does neither.
    @Test func doneAnswersCommandReturnAndEscapeButNotAPlainReturn() async throws {
        final class Count { var dismissals = 0 }
        let count = Count()
        let model = AgentHooksModel(integrations: HookIntegrations(home: TestScratch.root.appendingPathComponent("keys-home-\(UUID().uuidString)"),
                                                                   resources: .bundled(resourceURL: nil)), names: [:])
        let host = NSHostingView(rootView: AgentHooksView(model: model, dismiss: { count.dismissals += 1 }))
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        func press(_ characters: String, keyCode: UInt16, command: Bool = false) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: command ? [.command] : [], timestamp: 0,
                                         windowNumber: window.windowNumber, context: nil, characters: characters,
                                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
            _ = window.performKeyEquivalent(with: event)
        }

        // Until the first press lands: the sheet's shortcuts arrive with its first render.
        await eventually(describing: "⌘↩ pressed Done") {
            if count.dismissals == 0 { press("\r", keyCode: 36, command: true) }
            return count.dismissals == 1
        }
        press("\r", keyCode: 36)
        #expect(count.dismissals == 1, "a plain ↩ is not Done")
        press("\u{1b}", keyCode: 53)
        await eventually(describing: "⎋ closed the sheet") { count.dismissals >= 2 }
        #expect(count.dismissals == 2)
    }
}
