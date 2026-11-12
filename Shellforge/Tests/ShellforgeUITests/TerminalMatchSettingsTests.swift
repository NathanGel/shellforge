import Foundation
import Testing
@testable import ShellforgeTestSupport
@testable import ShellforgeUI
@testable import ShellforgeCore
import ShellforgeDesign
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

    static func switches(in view: NSView) -> [NSSwitch] {
        view.subviews.compactMap { $0 as? NSSwitch } + view.subviews.flatMap { switches(in: $0) }
    }

    /// Presses Save, ⌘↩, in a window of its own for `sheet`; the window is handed back to close.
    static func save(_ sheet: NSView) throws -> NSWindow {
        let window = NSWindow(contentRect: sheet.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sheet
        sheet.layoutSubtreeIfNeeded()
        let commandReturn = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                                                          windowNumber: window.windowNumber, context: nil, characters: "\r",
                                                          charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        _ = window.performKeyEquivalent(with: commandReturn)
        return window
    }

    /// Which of a Settings sheet's switches is the one whose Save makes `saved` true, found by what
    /// it does: each is clicked and saved in a scratch sheet of its own. No control carries a tag
    /// for tests, and a switch added to Settings doesn't move it.
    static func switchIndex(where saved: (TerminalMatchSettings, ThemeSettings) -> Bool) throws -> Int? {
        let count = switches(in: sheet(match: TerminalMatchSettings(defaults: ScratchDefaults.make()),
                                       theme: ThemeSettings(defaults: ScratchDefaults.make()))).count
        for index in 0..<count {
            let match = TerminalMatchSettings(defaults: ScratchDefaults.make())
            let theme = ThemeSettings(defaults: ScratchDefaults.make())
            let scratch = sheet(match: match, theme: theme)
            switches(in: scratch)[index].performClick(nil)
            let window = try save(scratch)
            window.close()
            if saved(match, theme) { return index }
        }
        return nil
    }

    /// Each Settings sheet keeps its own unsaved switch: one opened in another window neither resets
    /// it nor saves it.
    @Test func twoSettingsSheetsDoNotShareTheirSwitch() throws {
        let index = try #require(try Self.switchIndex { match, _ in match.isOn }, "Match Terminal")
        let settings = TerminalMatchSettings(defaults: ScratchDefaults.make())
        let theme = ThemeSettings(defaults: ScratchDefaults.make())
        let first = Self.sheet(match: settings, theme: theme), second = Self.sheet(match: settings, theme: theme)
        let a = Self.switches(in: first)[index], b = Self.switches(in: second)[index]
        a.performClick(nil)
        first.layoutSubtreeIfNeeded(); second.layoutSubtreeIfNeeded()
        #expect(a.state == .on)
        #expect(b.state == .off, "the other sheet's switch is its own")
        #expect(!settings.isOn, "nothing saved")
    }

    /// The theme twin: Follow Mac Appearance turned off in one sheet is that sheet's own until its
    /// Save, which writes the choice; the other sheet, unsaved, neither shows nor writes it.
    @Test func theThemeIsSavedOnlyByItsOwnSheetsSave() throws {
        let index = try #require(try Self.switchIndex { _, theme in !theme.choice.followsMac }, "Follow Mac Appearance")
        let store = ScratchDefaults.make()
        let theme = ThemeSettings(defaults: store)
        let match = TerminalMatchSettings(defaults: ScratchDefaults.make())
        let first = Self.sheet(match: match, theme: theme), second = Self.sheet(match: match, theme: theme)
        let a = Self.switches(in: first)[index], b = Self.switches(in: second)[index]
        a.performClick(nil)
        first.layoutSubtreeIfNeeded(); second.layoutSubtreeIfNeeded()
        #expect(a.state == .off)
        #expect(b.state == .on, "the other sheet's switch is its own")
        #expect(theme.choice.followsMac, "nothing saved yet")
        #expect(store.object(forKey: ThemeSettings.followsMacKey) == nil)
        let window = try Self.save(first)
        defer { window.close() }
        #expect(!theme.choice.followsMac, "Save wrote the sheet's choice")
        #expect(store.object(forKey: ThemeSettings.followsMacKey) as? Bool == false)
    }

    /// Final-review fix: a theme or Match Terminal changed from a gear menu while a Settings sheet
    /// is open survives that sheet's Save when the sheet left it alone.
    @Test func aGearChangeMadeWhileTheSheetIsOpenSurvivesItsSave() throws {
        let theme = ThemeSettings(defaults: ScratchDefaults.make())
        let match = TerminalMatchSettings(defaults: ScratchDefaults.make())
        let sheet = Self.sheet(match: match, theme: theme)
        let outside = ThemeChoice(followsMac: true, dark: "dracula")
        theme.save(outside)
        match.save(true)
        let window = try Self.save(sheet)
        defer { window.close() }
        #expect(theme.choice == outside, "the gear's theme is kept")
        #expect(match.isOn, "the gear's Match Terminal is kept")
    }

    /// Field by field: Follow Mac turned off in the sheet and a dark theme picked from the gear
    /// meanwhile both hold after the sheet's Save.
    @Test func theSheetSavesOnlyTheFieldsItChanged() throws {
        let index = try #require(try Self.switchIndex { _, theme in !theme.choice.followsMac }, "Follow Mac Appearance")
        let theme = ThemeSettings(defaults: ScratchDefaults.make())
        let match = TerminalMatchSettings(defaults: ScratchDefaults.make())
        let sheet = Self.sheet(match: match, theme: theme)
        Self.switches(in: sheet)[index].performClick(nil)
        theme.save(ThemeChoice(followsMac: true, dark: "nord"))
        let window = try Self.save(sheet)
        defer { window.close() }
        #expect(theme.choice == ThemeChoice(followsMac: false, dark: "nord"))
    }

    @Test func mergingKeepsWhatTheSheetLeftAlone() {
        let opened = ThemeChoice()
        var draft = opened
        draft.single = "nord"
        let now = ThemeChoice(followsMac: false, light: "github-light", single: "dracula")
        #expect(now.merging(draft, openedWith: opened) == ThemeChoice(followsMac: false, light: "github-light", single: "nord"))
        #expect(now.merging(opened, openedWith: opened) == now, "an unchanged sheet changes nothing")
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
