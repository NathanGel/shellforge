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

    /// A development build offers only the install for this build, where an install is allowed at all.
    @Test func aDevBuildOffersOnlyTheInstallForThisBuild() {
        #expect(AgentHooksView.buttonTitle(.outdated, sharedWithInstalledApp: true) == "Install for This Build Anyway…")
        #expect(AgentHooksView.buttonTitle(.current, sharedWithInstalledApp: false) == "Reinstall")
        #expect(AgentHooksView.buttonTitle(.foreign, sharedWithInstalledApp: true) == nil)
    }

    private static var hooksFolder: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("hooks")
    }

    /// A dev build's model asks first: Cancel writes nothing; a yes installs with the build's port.
    @Test func aDevBuildInstallsOnlyOnceConfirmed() async throws {
        let home = TestScratch.root.appendingPathComponent("dev-hooks-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let support = ShellforgeSupport(folder: home.appendingPathComponent("Library/Application Support/example-dev"), home: home)
        let model = AgentHooksModel(integrations: HookIntegrations(home: home, support: support,
                                                                   resources: HookResources(folder: Self.hooksFolder, installationAllowed: true, unavailableReason: nil)),
                                    names: ["codex": "Codex"])
        let prompter = ScriptedPrompter([AlertAnswer(button: 1), AlertAnswer(button: 0)])
        model.prompter = prompter
        #expect(model.isSharedWithInstalledApp)
        await model.install("codex")
        #expect(!FileManager.default.fileExists(atPath: home.path), "Cancel writes nothing")
        #expect(prompter.asked.first == AgentHooksModel.installForThisBuildPrompt(name: "Codex"))
        await model.install("codex")
        #expect(model.lastError == nil)
        let config = try String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8)
        #expect(config.contains("127.0.0.1:\(support.hookPort)/"))
        #expect(prompter.asked.count == 2)
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
