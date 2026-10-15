import Foundation
import Testing
@testable import ShellforgeTestSupport
@testable import ShellforgeUI
@testable import ShellforgeCore
import AppKit
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

    /// Each Settings sheet keeps its own unsaved switch: one opened in another window neither resets
    /// it nor saves it.
    @Test func twoSettingsSheetsDoNotShareTheirSwitch() throws {
        let store = ScratchDefaults.make()
        let settings = TerminalMatchSettings(defaults: store)
        func sheet() -> NSHostingView<SettingsPanel> {
            let integrations = IntegrationSettingsModel(jira: nil, gitLab: nil, gitHub: nil, store: MemorySecretStore(),
                                                        defaults: ScratchDefaults.make(), record: ServiceTestRecord(),
                                                        retestDelay: .milliseconds(20), testJira: { _ in "x" },
                                                        testGitLab: { _ in "x" }, testGitHub: { _ in "x" })
            let backpack = BackpackController(ports: .inert, settings: BackpackSettings(defaults: nil), toast: { _ in })
            let host = NSHostingView(rootView: SettingsPanel(backpack: backpack, integrations: integrations, environment: nil,
                                                             terminalMatch: settings,
                                                             agentDefaults: AgentDefaultsSettingsModel(agents: [], catalogue: { _ in [] }, remembered: [:],
                                                                                                       defaults: ScratchDefaults.make()),
                                                             close: {}))
            host.frame = NSRect(x: 0, y: 0, width: 600, height: 900)
            host.layoutSubtreeIfNeeded()
            return host
        }
        func switches(_ view: NSView) -> [NSSwitch] {
            view.subviews.compactMap { $0 as? NSSwitch } + view.subviews.flatMap { switches($0) }
        }
        let first = sheet(), second = sheet()
        let a = try #require(switches(first).first), b = try #require(switches(second).first)
        a.performClick(nil)
        first.layoutSubtreeIfNeeded(); second.layoutSubtreeIfNeeded()
        #expect(a.state == .on)
        #expect(b.state == .off, "the other sheet's switch is its own")
        #expect(!settings.isOn, "nothing saved")
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
