// Ported from AiTerm (app/Tests/AiTermCoreTests/BackpackLivePortsTests.swift), GPLv3, Laurens D'Hondt.
import Foundation
import Testing
@testable import ShellforgeCore

@Suite struct BackpackLivePortsTests {
    /// networksetup indents each name with one tab; a name keeps its spaces and punctuation.
    @Test func preferredNetworksKeepTheirExactNames() {
        let output = "Preferred networks on en0:\n\tOoststraat 106\n\tLaurens D’Hondt - iPhone\n\t café  \n\tFFXGK79V0F0X (2)\n"
        #expect(CoreWLANWiFi.parsePreferred(output) == ["Ooststraat 106", "Laurens D’Hondt - iPhone", " café  ", "FFXGK79V0F0X (2)"])
    }

    @Test func anErrorOrNoNetworksParsesToNone() {
        #expect(CoreWLANWiFi.parsePreferred("en9 is not a Wi-Fi interface.\n").isEmpty)
        #expect(CoreWLANWiFi.parsePreferred("Preferred networks on en0:\n").isEmpty)
    }

    /// `ioreg -r -k AppleClamshellState` prints `Yes` or `No`; the sensor reads the same property.
    @Test func theLidSensorParsesTheClamshellProperty() {
        #expect(IOKitLidSensor.parse(kCFBooleanTrue) == true)
        #expect(IOKitLidSensor.parse(kCFBooleanFalse) == false)
        #expect(IOKitLidSensor.parse(nil) == nil)
        #expect(IOKitLidSensor.parse("Yes" as CFString) == nil, "anything but a boolean reads as no lid")
    }

    @Test func theInternalBatteryGivesALevelAndWhetherItRunsOnIt() {
        let battery: [String: Any] = ["Type": "InternalBattery", "Current Capacity": 64, "Max Capacity": 100,
                                      "Power Source State": "Battery Power"]
        #expect(IOKitPowerSource.reading(from: [battery]) == PowerReading(level: 64, onBattery: true))
        var charging = battery
        charging["Power Source State"] = "AC Power"
        #expect(IOKitPowerSource.reading(from: [charging]) == PowerReading(level: 64, onBattery: false))
        let scaled: [String: Any] = ["Type": "InternalBattery", "Current Capacity": 3000, "Max Capacity": 6000,
                                     "Power Source State": "Battery Power"]
        #expect(IOKitPowerSource.reading(from: [scaled]).level == 50)
    }

    /// macOS answers `requestWhenInUseAuthorization` only while undetermined: asking again after a
    /// "Don't Allow" would wait for a callback that never comes.
    @Test func locationIsAskedForOnlyWhileUndetermined() {
        #expect(CoreLocationAccess.canAsk(.notDetermined))
        #expect(!CoreLocationAccess.canAsk(.denied))
        #expect(!CoreLocationAccess.canAsk(.restricted))
        #expect(!CoreLocationAccess.canAsk(.authorizedAlways))
    }

    @Test func noInternalBatteryReadsAsMains() {
        #expect(IOKitPowerSource.reading(from: []) == .mains)
        #expect(IOKitPowerSource.reading(from: [["Type": "UPS", "Power Source State": "Battery Power"]]) == .mains)
    }
}
