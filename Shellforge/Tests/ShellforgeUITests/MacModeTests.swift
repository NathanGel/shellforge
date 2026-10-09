// Ported from AiTerm (app/Tests/AiTermTests/MacModeTests.swift), GPLv3, Laurens D'Hondt.
import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI

struct MacModeTests {
    private func on(joined: Bool = true, level: Int? = 64, battery: Bool = true) -> BackpackState {
        .on(BackpackStatus(network: "Laurens’s iPhone", joined: joined, power: PowerReading(level: level, onBattery: battery)))
    }

    @Test func eachStateIsItsMode() {
        #expect(MacMode(state: .off, transition: nil) == .desk)
        #expect(MacMode(state: .off, transition: .turningOn) == .turningOn)
        #expect(MacMode(state: on(), transition: nil) == .on)
        #expect(MacMode(state: on(joined: false), transition: nil) == .needsYou(.lostHotspot))
        #expect(MacMode(state: on(level: 13), transition: nil) == .needsYou(.lowBattery(level: 13)))
        #expect(MacMode(state: on(), transition: .turningOff) == .turningOff)
    }

    /// The cutoff will end the mode; a lost hotspot can come back. The cutoff wins.
    @Test func theCutoffWinsOverALostHotspot() {
        #expect(MacMode(state: on(joined: false, level: 12), transition: nil) == .needsYou(.lowBattery(level: 12)))
    }

    /// The cutoff is a battery rule; on the charger 12 % is fine.
    @Test func onACALowLevelIsNotANeed() {
        #expect(MacMode(state: on(level: 12, battery: false), transition: nil) == .on)
    }

    /// At the desk there is no line: the readings row is the Mac's row. In the backpack the words
    /// say the state (proposal 2A and 3A, 6 Oct 2026).
    @Test func theLineSaysTheStateAndTheDeskHasNone() {
        #expect(MacMode.desk.words == nil)
        #expect(MacMode.turningOn.words == "backpack turning on…")
        #expect(MacMode.on.words == "backpack enabled")
        #expect(MacMode.needsYou(.lostHotspot).words == "backpack needs you")
        #expect(MacMode.needsYou(.lowBattery(level: 13)).words == "backpack needs you")
        #expect(MacMode.turningOff.words == "backpack turning off…")
    }

    /// The line speaks a Settings card's tone, never a task's `StatusMark`: green on, amber when it
    /// needs you, muted while it switches.
    @Test func theToneIsASettingsTone() {
        #expect(MacMode.desk.tone == nil)
        #expect(MacMode.turningOn.tone == .idle)
        #expect(MacMode.on.tone == .ready)
        #expect(MacMode.needsYou(.lostHotspot).tone == .attention)
        #expect(MacMode.turningOff.tone == .idle)
    }

    @Test func theWordsSayTheStateInFull() {
        func help(_ mode: MacMode, wifi: String? = "Office-WiFi") -> String {
            MacModePresentation.line(mode: mode, hotspot: "Laurens’s iPhone", wifi: wifi).help
        }
        #expect(help(.desk) == "desk mode · Office-WiFi · ⌘B turns on backpack mode")
        #expect(help(.desk, wifi: nil) == "desk mode · ⌘B turns on backpack mode")
        // Off with no other network in range: it stayed on the hotspot, and says so.
        #expect(help(.desk, wifi: "Laurens’s iPhone") == "desk mode · still on Laurens’s iPhone · ⌘B turns on backpack mode")
        #expect(help(.turningOn) == "Turning on backpack mode · joining Laurens’s iPhone")
        #expect(help(.on) == "Backpack mode on · Laurens’s iPhone · ends when your agents stop, or at 10 %")
        #expect(help(.needsYou(.lostHotspot)) == "Backpack mode needs you · lost Laurens’s iPhone, open Personal Hotspot on the iPhone")
        #expect(help(.needsYou(.lowBattery(level: 13))) == "Backpack mode needs you · battery at 13 %, turns off at 10 %")
        #expect(help(.turningOff) == "Turning off backpack mode · rejoining Wi-Fi")
    }
}
