// Ported from AiTerm (app/Tests/AiTermCoreTests/BackpackStateTests.swift), GPLv3, Laurens D'Hondt.
import Testing
@testable import ShellforgeCore

@Suite struct BackpackStateTests {
    @Test func refusalsSayWhyInTheSpecsWords() {
        #expect(BackpackRefusal.needsSetup.message == "Backpack mode needs setup: Settings › Integrations › Mac")
        #expect(BackpackRefusal.batteryLow(level: 8).message == "Battery at 8 %: backpack mode stays off")
        #expect(BackpackRefusal.notInRange(network: "Laurens D’Hondt - iPhone").message
                == "Laurens D’Hondt - iPhone isn’t showing its hotspot: open Personal Hotspot on the iPhone")
        #expect(BackpackRefusal.joinFailed(network: "Phone").message == "Couldn’t join Phone: check its password")
    }

    @Test func degradedWhenNotJoinedOrWithinFivePointsOfTheCutoffOnBattery() {
        let fine = BackpackStatus(network: "P", joined: true, power: PowerReading(level: 16, onBattery: true))
        #expect(!fine.degraded)
        #expect(BackpackStatus(network: "P", joined: true, power: PowerReading(level: 15, onBattery: true)).nearCutoff)
        #expect(BackpackStatus(network: "P", joined: false, power: .mains).degraded)
        // On AC the battery level never degrades it.
        #expect(!BackpackStatus(network: "P", joined: true, power: PowerReading(level: 11, onBattery: false)).degraded)
    }

    @Test func setupIsCompleteOnlyWithTheRuleLocationAndANetwork() {
        #expect(BackpackSetup(sleepRule: true, location: true, network: "P").isComplete)
        #expect(!BackpackSetup(sleepRule: false, location: true, network: "P").isComplete)
        #expect(!BackpackSetup(sleepRule: true, location: false, network: "P").isComplete)
        #expect(!BackpackSetup(sleepRule: true, location: true, network: nil).isComplete)
        #expect(BackpackSetup(sleepRule: true, location: false, network: nil).missingSteps == [.location])
    }

    @Test func theInertPortsAreSetUpForNothing() {
        let ports = BackpackPorts.inert
        #expect(!ports.lidSleep.isAllowed())
        #expect(!ports.location.isAuthorized())
        #expect(ports.wifi.knownNetworks().isEmpty)
        #expect(ports.power.reading() == .mains)
    }
}
