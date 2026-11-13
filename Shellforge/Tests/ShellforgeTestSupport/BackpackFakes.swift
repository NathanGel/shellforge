// Ported from AiTerm (app/Tests/AiTermTestSupport/BackpackFakes.swift), GPLv3, Laurens D'Hondt.
import Foundation
import ShellforgeCore

/// Test doubles for Backpack Mode's ports. `@unchecked Sendable`: each test owns its own and
/// drives it from one thread at a time.
final class FakeLidSleep: LidSleepControl, @unchecked Sendable {
    var allowed = true
    var succeeds = true
    /// Every `setDisabled` call, in order.
    private(set) var calls: [Bool] = []
    /// Called inside `setDisabled`, before it returns: lets a test hold a call in flight.
    var onSet: (Bool) -> Void = { _ in }
    func isAllowed() -> Bool { allowed }
    func setDisabled(_ disabled: Bool) -> Bool { onSet(disabled); calls.append(disabled); return succeeds }
    /// How many times `sleepNow` was asked.
    private(set) var sleeps = 0
    func sleepNow() -> Bool { sleeps += 1; return true }
}

final class FakeWiFi: WiFiControl, @unchecked Sendable {
    var known: [String] = []
    var current: String?
    var inRange: Set<String> = []
    var joinSucceeds = true
    private(set) var joins: [String] = []
    /// The password each join was given, in order.
    private(set) var passwords: [String?] = []
    /// Called inside `join`, before it answers: lets a test hold a join in flight or make it slow.
    var onJoin: () -> Void = {}
    func knownNetworks() -> [String] { known }
    func currentNetwork() -> String? { current }
    func isInRange(_ network: String) -> Bool { inRange.contains(network) }
    /// Networks whose join fails even in range, for walking the preferred list.
    var failingJoins: Set<String> = []
    func networksInRange() -> Set<String> { inRange }
    func join(_ network: String, password: String?) -> Bool {
        onJoin()
        joins.append(network)
        passwords.append(password)
        let ok = joinSucceeds && !failingJoins.contains(network)
        // A failed associate drops the network the Mac was on, as macOS does.
        current = ok ? network : nil
        return ok
    }
}

final class FakePower: PowerSource, @unchecked Sendable {
    var value = PowerReading.mains
    func reading() -> PowerReading { value }
}

final class FakeLocation: LocationAccess, @unchecked Sendable {
    var authorized = true
    var grantsOnRequest = true
    private(set) var requests = 0
    func isAuthorized() -> Bool { authorized }
    @MainActor func request() async -> Bool { requests += 1; authorized = grantsOnRequest; return authorized }
}

final class FakeInstaller: SleepRuleInstaller, @unchecked Sendable {
    let lid: FakeLidSleep
    var succeeds = true
    private(set) var installs = 0, removes = 0
    init(lid: FakeLidSleep) { self.lid = lid }
    func install() -> Bool { installs += 1; if succeeds { lid.allowed = true }; return succeeds }
    func remove() -> Bool { removes += 1; if succeeds { lid.allowed = false }; return succeeds }
}

final class FakeLidSensor: LidSensor, @unchecked Sendable {
    var closed: Bool? = false
    private let readings = Locked(0)
    /// How many times the lid has been read: a watcher that read it and said nothing has polled.
    var reads: Int { readings.withLock { $0 } }
    func isClosed() -> Bool? {
        readings.withLock { $0 += 1 }
        return closed
    }
}

/// All six fakes, set up and in range of "Phone" on AC, with their ports and settings.
struct FakeBackpack {
    let lid = FakeLidSleep()
    let wifi = FakeWiFi()
    let power = FakePower()
    let location = FakeLocation()
    let lidSensor = FakeLidSensor()
    let installer: FakeInstaller
    let settings: BackpackSettings

    init(defaults: UserDefaults? = nil) {
        self.init(settings: BackpackSettings(defaults: defaults))
    }

    init(settings: BackpackSettings) {
        installer = FakeInstaller(lid: lid)
        self.settings = settings
        settings.network = "Phone"
        wifi.known = ["Home", "Phone"]
        wifi.current = "Home"
        wifi.inRange = ["Home", "Phone"]
    }

    var ports: BackpackPorts {
        BackpackPorts(lidSleep: lid, wifi: wifi, power: power, location: location, installer: installer,
                      lidSensor: lidSensor)
    }
}
