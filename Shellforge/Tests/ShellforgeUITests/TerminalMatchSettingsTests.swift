import Foundation
import Testing
@testable import ShellforgeTestSupport
@testable import ShellforgeUI
@testable import ShellforgeCore
import AppKit
import Combine
import SwiftUI

/// Settings › Core › Terminal: off until switched on and saved; Cancel changes nothing.
@MainActor @Suite struct TerminalMatchSettingsTests {
    @Test func itIsOffByDefault() {
        #expect(!TerminalMatchSettings(defaults: ScratchDefaults.make()).isOn)
    }

    @Test func saveKeepsTheSwitch() {
        let store = ScratchDefaults.make()
        let settings = TerminalMatchSettings(defaults: store)
        settings.save(true)
        #expect(settings.isOn)
        #expect(TerminalMatchSettings(defaults: store).isOn)
    }

    /// A Settings sheet over its own scratch services, with `match` and `theme` as the app's.
    static func sheet(match: TerminalMatchSettings, theme: ThemeSettings) -> NSHostingView<SettingsPanel> {
        let integrations = IntegrationSettingsModel(jira: nil, gitLab: nil, gitHub: nil, store: MemorySecretStore(),
                                                    defaults: ScratchDefaults.make(), record: ServiceTestRecord(),
                                                    retestDelay: .milliseconds(20), testJira: { _ in "x" },
                                                    testGitLab: { _ in "x" }, testGitHub: { _ in "x" })
        let backpack = BackpackController(ports: .inert, settings: BackpackSettings(defaults: nil), toast: { _ in })
        let host = NSHostingView(rootView: SettingsPanel(backpack: backpack, integrations: integrations, environment: nil,
                                                         terminalMatch: match, theme: theme,
                                                         feedback: FeedbackPrompt(defaults: ScratchDefaults.make(), channel: .dev),
                                                         agentDefaults: AgentDefaultsSettingsModel(agents: [], catalogue: { _ in [] }, remembered: [:],
                                                                                                   defaults: ScratchDefaults.make()),
                                                         agents: AgentListModel(registry: AgentRegistry(folder: TestScratch.root.appendingPathComponent("agents-\(UUID().uuidString)")),
                                                                                secrets: MemorySecretStore(),
                                                                                launcher: CommandLauncher(resolve: { ResolvedEnvironment(variables: ["PATH": "/nowhere"], source: .loginShell("/bin/zsh")) }),
                                                                                tasks: { [] }, prompter: ScriptedPrompter([]), tools: .none,
                                                                                store: Empty().eraseToAnyPublisher(), changed: {}),
                                                         close: {}))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 900)
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// The switch with the accessibility identifier `identifier` in `view`.
    static func settingsSwitch(_ identifier: String, in view: NSView) -> NSSwitch? {
        if let found = view as? NSSwitch, found.accessibilityIdentifier() == identifier { return found }
        return view.subviews.lazy.compactMap { settingsSwitch(identifier, in: $0) }.first
    }

    /// Each Settings sheet keeps its own unsaved switch: one opened in another window neither resets
    /// it nor saves it.
    @Test func twoSettingsSheetsDoNotShareTheirSwitch() throws {
        let settings = TerminalMatchSettings(defaults: ScratchDefaults.make())
        let theme = ThemeSettings(defaults: ScratchDefaults.make())
        let first = Self.sheet(match: settings, theme: theme), second = Self.sheet(match: settings, theme: theme)
        let a = try #require(Self.settingsSwitch(ThemeCard.matchIdentifier, in: first))
        let b = try #require(Self.settingsSwitch(ThemeCard.matchIdentifier, in: second))
        a.performClick(nil)
        first.layoutSubtreeIfNeeded(); second.layoutSubtreeIfNeeded()
        #expect(a.state == .on)
        #expect(b.state == .off, "the other sheet's switch is its own")
        #expect(!settings.isOn, "nothing saved")
    }

    /// The theme twin: Follow Mac Appearance turned off in one sheet is that sheet's own until its
    /// Save, which writes the choice; the other sheet, unsaved, neither shows nor writes it.
    @Test func theThemeIsSavedOnlyByItsOwnSheetsSave() throws {
        let store = ScratchDefaults.make()
        let theme = ThemeSettings(defaults: store)
        let match = TerminalMatchSettings(defaults: ScratchDefaults.make())
        let first = Self.sheet(match: match, theme: theme), second = Self.sheet(match: match, theme: theme)
        let a = try #require(Self.settingsSwitch(ThemeCard.followMacIdentifier, in: first))
        let b = try #require(Self.settingsSwitch(ThemeCard.followMacIdentifier, in: second))
        a.performClick(nil)
        first.layoutSubtreeIfNeeded(); second.layoutSubtreeIfNeeded()
        #expect(a.state == .off)
        #expect(b.state == .on, "the other sheet's switch is its own")
        #expect(theme.choice.followsMac, "nothing saved yet")
        #expect(store.object(forKey: ThemeSettings.followsMacKey) == nil)
        // Save is ⌘↩, in the sheet's window.
        let window = NSWindow(contentRect: first.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = first
        defer { window.close() }
        first.layoutSubtreeIfNeeded()
        let commandReturn = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                                                          windowNumber: window.windowNumber, context: nil, characters: "\r",
                                                          charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        _ = window.performKeyEquivalent(with: commandReturn)
        #expect(!theme.choice.followsMac, "Save wrote the sheet's choice")
        #expect(store.object(forKey: ThemeSettings.followsMacKey) as? Bool == false)
    }

    @Test func onChangeIsCalledOnlyWhenTheSavedValueChanges() {
        let settings = TerminalMatchSettings(defaults: ScratchDefaults.make())
        var calls: [Bool] = []
        settings.onChange = { calls.append($0) }
        settings.save(false)
        settings.set(true)
        settings.set(true)
        settings.set(false)
        #expect(calls == [true, false])
    }
}
