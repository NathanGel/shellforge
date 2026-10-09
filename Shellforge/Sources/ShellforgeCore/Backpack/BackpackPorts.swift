// Ported from AiTerm (app/Sources/AiTermCore/Backpack/BackpackPorts.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// Lid and idle sleep, through `pmset disablesleep`, which needs root.
public protocol LidSleepControl: Sendable {
    /// Whether the sudoers rule lets Shellforge run `pmset` without a password.
    func isAllowed() -> Bool
    /// `pmset -a disablesleep 1` (true) or `0` (false). False when it did not succeed.
    func setDisabled(_ disabled: Bool) -> Bool
    /// `pmset sleepnow`, which needs no root: sleep at once. macOS sleeps on the lid's close, not
    /// on its state, so sleep coming back with the lid already shut has to ask. False when it did
    /// not run.
    func sleepNow() -> Bool
}

/// The Wi-Fi interface. Blocking: a scan takes seconds.
public protocol WiFiControl: Sendable {
    /// The networks this Mac already knows, in its own order.
    func knownNetworks() -> [String]
    /// The network joined now, or nil.
    func currentNetwork() -> String?
    func isInRange(_ network: String) -> Bool
    /// Every network one scan can see. Blocking: a scan takes seconds.
    func networksInRange() -> Set<String>
    /// Joins `network` with `password` (nil tries without one). True once joined.
    func join(_ network: String, password: String?) -> Bool
}


/// macOS hides Wi-Fi names from an app without Location access.
public protocol LocationAccess: Sendable {
    func isAuthorized() -> Bool
    /// Asks once; true when granted.
    @MainActor func request() async -> Bool
}

/// Installs and removes the sudoers rule behind `LidSleepControl`. Each call asks for an admin
/// password; false when the person cancelled or it failed.
public protocol SleepRuleInstaller: Sendable {
    func install() -> Bool
    func remove() -> Bool
}

/// Whether the lid is closed, read without privileges. Nil on a Mac without a lid.
public protocol LidSensor: Sendable {
    func isClosed() -> Bool?
}

/// Everything Backpack Mode touches outside the app, in one value so a test or a preview passes
/// fakes, or nothing at all.
public struct BackpackPorts: Sendable {
    public var lidSleep: any LidSleepControl
    public var wifi: any WiFiControl
    public var power: any PowerSource
    public var location: any LocationAccess
    public var installer: any SleepRuleInstaller
    public var lidSensor: any LidSensor

    public init(lidSleep: any LidSleepControl, wifi: any WiFiControl, power: any PowerSource,
                location: any LocationAccess, installer: any SleepRuleInstaller, lidSensor: any LidSensor) {
        self.lidSleep = lidSleep
        self.wifi = wifi
        self.power = power
        self.location = location
        self.installer = installer
        self.lidSensor = lidSensor
    }

    /// Set up for nothing, no network in range, on AC: what a controller gets unless the app passes
    /// the live ports, so no test or snapshot runs `sudo` or scans Wi-Fi by omission.
    public static let inert = BackpackPorts(lidSleep: InertPort(), wifi: InertPort(), power: InertPort(),
                                            location: InertPort(), installer: InertPort(), lidSensor: InertPort())
}

private struct InertPort: LidSleepControl, WiFiControl, PowerSource, LocationAccess, SleepRuleInstaller, LidSensor {
    func isAllowed() -> Bool { false }
    func setDisabled(_ disabled: Bool) -> Bool { false }
    func sleepNow() -> Bool { false }
    func knownNetworks() -> [String] { [] }
    func currentNetwork() -> String? { nil }
    func isInRange(_ network: String) -> Bool { false }
    func networksInRange() -> Set<String> { [] }
    func join(_ network: String, password: String?) -> Bool { false }
    func reading() -> PowerReading { .mains }
    func isAuthorized() -> Bool { false }
    @MainActor func request() async -> Bool { false }
    func install() -> Bool { false }
    func remove() -> Bool { false }
    func isClosed() -> Bool? { nil }
}
