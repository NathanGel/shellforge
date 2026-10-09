// Ported from AiTerm (app/Sources/AiTermCore/Machine/MachineSensor.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// The kernel's CPU tick counters, summed over every core, as `HOST_CPU_LOAD_INFO` reports them.
/// They only grow, and they are 32 bits wide, so on a long uptime they wrap: a busy share is the
/// difference between two of them, taken with wrapping arithmetic.
public struct CPUTicks: Equatable, Sendable {
    public var user: UInt32
    public var system: UInt32
    public var idle: UInt32
    public var nice: UInt32

    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }

    /// The share of every core's time that was busy since `earlier`, in percent; nil when no tick
    /// passed between the two.
    public func busyPercent(since earlier: CPUTicks) -> Int? {
        let busy = UInt64(user &- earlier.user) + UInt64(system &- earlier.system) + UInt64(nice &- earlier.nice)
        let total = busy + UInt64(idle &- earlier.idle)
        guard total > 0 else { return nil }
        return Int((Double(busy) / Double(total) * 100).rounded())
    }
}

/// Memory as Activity Monitor's "Memory Used" counts it: app memory, wired and compressed, out of
/// the physical memory installed.
public struct MemoryUse: Equatable, Sendable {
    public var used: UInt64
    public var total: UInt64

    public init(used: UInt64, total: UInt64) {
        self.used = used
        self.total = total
    }

    public var percent: Int? {
        guard total > 0 else { return nil }
        return min(100, Int((Double(used) / Double(total) * 100).rounded()))
    }
}

/// One look at how the Mac is coping. The two flags are macOS's own warnings, the only thing that
/// turns a reading amber: a busy CPU is working, not failing.
public struct MachineSample: Equatable, Sendable {
    /// Nil when the kernel would not say.
    public var cpu: CPUTicks?
    public var memory: MemoryUse?
    /// `ProcessInfo.thermalState` at `.serious` or worse: the Mac is slowing itself to cool down.
    public var throttled: Bool
    /// The kernel's memory-pressure level at warn or worse: it has started to swap.
    public var memoryPressure: Bool

    public init(cpu: CPUTicks?, memory: MemoryUse?, throttled: Bool, memoryPressure: Bool) {
        self.cpu = cpu
        self.memory = memory
        self.throttled = throttled
        self.memoryPressure = memoryPressure
    }

    /// What the inert sensor reads: nothing.
    public static let unknown = MachineSample(cpu: nil, memory: nil, throttled: false, memoryPressure: false)
}

/// Reads the Mac's load in-process, without privileges and without a subprocess. Cheap, but
/// called off the main actor.
public protocol MachineSensor: Sendable {
    func sample() -> MachineSample
}

/// Reads nothing: what a test or a snapshot gets unless it passes a sensor.
public struct InertMachineSensor: MachineSensor {
    public init() {}
    public func sample() -> MachineSample { .unknown }
}

/// The footer's readings row under `ctx`: `cpu ◔ 23% · ram ◔ 61%`, then `bat ◔ 64%` while the Mac
/// runs on its battery — the reading Backpack Mode ends on. Proposal 1A, 6 Oct 2026.
public enum MachineReadings {
    /// `previous` is the sample one interval ago: the CPU's share is the difference between the two,
    /// so the first sample draws no `cpu`. A reading the sensor could not take is left out.
    public static func lines(previous: MachineSample?, current: MachineSample, power: PowerReading) -> [UsageLine] {
        var lines: [UsageLine] = []
        if let earlier = previous?.cpu, let now = current.cpu, let busy = now.busyPercent(since: earlier) {
            lines.append(UsageLine(window: .cpu, percent: busy, warning: current.throttled))
        }
        if let used = current.memory?.percent {
            lines.append(UsageLine(window: .ram, percent: used, warning: current.memoryPressure))
        }
        if power.onBattery, let level = power.level {
            lines.append(UsageLine(window: .battery, percent: level, warning: power.nearCutoff))
        }
        return lines
    }
}
