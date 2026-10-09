// Ported from AiTerm (app/Tests/AiTermTests/MacSettingsCardTests.swift), GPLv3, Laurens D'Hondt.
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI

@MainActor
struct MacSettingsCardTests {
    private func setup(_ sleep: Bool, _ location: Bool) -> BackpackSetup {
        BackpackSetup(sleepRule: sleep, location: location, network: nil)
    }

    @Test func theStatusSaysWhatIsMissing() {
        #expect(MacCardPresentation.status(setup(true, true)) == SettingsStatus(.ready, "Ready for backpack mode"))
        #expect(MacCardPresentation.status(setup(false, true)) == SettingsStatus(.attention, "Backpack mode needs lid sleep"))
        #expect(MacCardPresentation.status(setup(true, false)) == SettingsStatus(.attention, "Backpack mode needs network discovery"))
        #expect(MacCardPresentation.status(setup(false, false))
                == SettingsStatus(.attention, "Backpack mode needs lid sleep and network discovery"))
    }

    /// A network is the sheet's business now: a card without one is still Ready.
    @Test func aMissingNetworkIsNotTheCardsConcern() {
        #expect(MacCardPresentation.status(BackpackSetup(sleepRule: true, location: true, network: nil)).tone == .ready)
    }

    @Test func theStepsAreTheMissingOnesInOrder() {
        #expect(MacCardPresentation.steps(setup(false, false)) == [
            "Allow Shellforge to keep the Mac awake with the lid closed. macOS asks for your password once.",
            "Allow Shellforge to see nearby Wi-Fi networks. macOS hides their names from apps without Location access.",
        ])
        #expect(MacCardPresentation.steps(setup(true, false)).count == 1)
        #expect(MacCardPresentation.steps(setup(true, true)).isEmpty)
    }

    @Test func theReadyCardSaysWhatTheModeDoes() {
        #expect(MacCardPresentation.summary == "Backpack mode keeps the Mac awake with the lid closed and finds your iPhone’s hotspot. Shellforge never reads where you are. Remove takes the lid-sleep rule out again.")
    }
}
