// Ported from AiTerm (app/Sources/AiTermCore/Backpack/BackpackState.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// What Backpack Mode still needs before it can turn on.
public struct BackpackSetup: Equatable, Sendable {
    public enum Step: Equatable, Sendable { case sleepRule, location }

    public var sleepRule: Bool
    public var location: Bool
    public var network: String?

    public init(sleepRule: Bool, location: Bool, network: String?) {
        self.sleepRule = sleepRule
        self.location = location
        self.network = network
    }

    /// The steps Set Up… runs (Settings › Integrations › Mac), in order. A missing network is a field, not a step.
    public var missingSteps: [Step] {
        (sleepRule ? [] : [.sleepRule]) + (location ? [] : [.location])
    }

    public var isComplete: Bool { missingSteps.isEmpty && network != nil }
}

/// The mode while it is on.
public struct BackpackStatus: Equatable, Sendable {
    public var network: String
    /// Whether the Mac is on `network` now.
    public var joined: Bool
    public var power: PowerReading

    public init(network: String, joined: Bool, power: PowerReading) {
        self.network = network
        self.joined = joined
        self.power = power
    }

    /// On battery, within 5 points of the cutoff.
    public var nearCutoff: Bool { power.nearCutoff }

    /// Drawn amber: off the chosen network, or close to turning itself off.
    public var degraded: Bool { !joined || nearCutoff }
}

public enum BackpackState: Equatable, Sendable {
    case off
    case on(BackpackStatus)

    public var isOn: Bool {
        if case .on = self { true } else { false }
    }
}

/// Why the mode stayed off. Each is a toast.
public enum BackpackRefusal: Error, Equatable, Sendable {
    /// No sudoers rule, no Location access, or no network chosen.
    case needsSetup
    case batteryLow(level: Int)
    case notInRange(network: String)
    case joinFailed(network: String)
    /// Shellforge is quitting: a turn-on that was still on its way. Never shown.
    case quitting

    public var message: String {
        switch self {
        case .needsSetup: "Backpack mode needs setup: Settings › Integrations › Mac"
        case .batteryLow(let level): "Battery at \(level) %: backpack mode stays off"
        case .notInRange(let network): "\(network) isn’t showing its hotspot: open Personal Hotspot on the iPhone"
        case .joinFailed(let network): "Couldn’t join \(network): check its password"
        case .quitting: "Shellforge is quitting: backpack mode stays off"
        }
    }
}

/// Why the mode ended itself.
public enum BackpackEnding: Equatable, Sendable {
    /// No session had been working, with the lid shut, for `BackpackMode.idleGrace`.
    case agentsStopped
    /// On battery, at or under `BackpackSettings.cutoff`.
    case batteryLow(level: Int)
}

/// What one 5 s check found.
public enum BackpackTick: Equatable, Sendable {
    case unchanged
    case changed
    /// The mode turned itself off.
    case ended(BackpackEnding)
}
