import Foundation
import Testing
@testable import ShellforgeTestSupport
@testable import ShellforgeUI

/// Settings › Core › Terminal: off until switched on and saved; Cancel changes nothing.
@MainActor @Suite struct TerminalMatchSettingsTests {
    @Test func itIsOffByDefault() {
        #expect(!TerminalMatchSettings(defaults: ScratchDefaults.make()).isOn)
    }

    @Test func saveKeepsTheSwitch() {
        let store = ScratchDefaults.make()
        let settings = TerminalMatchSettings(defaults: store)
        settings.draft = true
        settings.save()
        #expect(settings.isOn)
        #expect(TerminalMatchSettings(defaults: store).isOn)
    }

    @Test func cancelLeavesTheSavedValue() {
        let store = ScratchDefaults.make()
        let settings = TerminalMatchSettings(defaults: store)
        settings.beginEditing()
        settings.draft = true
        // The panel closes without Save: the next opening starts from what was saved.
        settings.beginEditing()
        #expect(!settings.draft)
        #expect(!settings.isOn)
        #expect(!TerminalMatchSettings(defaults: store).isOn)
    }

    @Test func onChangeIsCalledOnlyWhenTheSavedValueChanges() {
        let settings = TerminalMatchSettings(defaults: ScratchDefaults.make())
        var calls: [Bool] = []
        settings.onChange = { calls.append($0) }
        settings.save()
        settings.set(true)
        settings.set(true)
        settings.set(false)
        #expect(calls == [true, false])
    }
}
