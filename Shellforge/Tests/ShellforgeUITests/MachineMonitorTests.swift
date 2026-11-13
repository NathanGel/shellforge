// Ported from AiTerm (app/Tests/AiTermTests/MachineMonitorTests.swift), GPLv3, Laurens D'Hondt.
import Combine
import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

/// Hands out its samples in order, repeating the last.
private final class ScriptedSensor: MachineSensor, @unchecked Sendable {
    private let samples: Locked<[MachineSample]>
    init(_ samples: [MachineSample]) { self.samples = Locked(samples) }
    func sample() -> MachineSample {
        samples.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] }
    }
}

@MainActor
struct MachineMonitorTests {
    private func sample(user: UInt32, idle: UInt32, used: UInt64 = 8) -> MachineSample {
        MachineSample(cpu: CPUTicks(user: user, system: 0, idle: idle, nice: 0), memory: MemoryUse(used: used, total: 16),
                      throttled: false, memoryPressure: false)
    }

    /// The first sample draws ram alone and waits a moment; the second adds the CPU's share and
    /// waits the full interval.
    @Test func theCPUJoinsOnTheSecondSample() async {
        let monitor = MachineMonitor(sensor: ScriptedSensor([sample(user: 0, idle: 0), sample(user: 25, idle: 75)]),
                                     power: FakePower(), interval: .seconds(5))
        #expect(await monitor.sample() == .seconds(1))
        #expect(monitor.lines.map(\.window) == [.ram])
        #expect(await monitor.sample() == .seconds(5))
        #expect(monitor.lines.map(\.window) == [.cpu, .ram])
        #expect(monitor.lines.map(\.percent) == [25, 50])
    }

    /// The battery is the port Backpack Mode reads: on battery it joins the row.
    @Test func theBatteryJoinsOnBattery() async {
        let power = FakePower()
        power.value = PowerReading(level: 64, onBattery: true)
        let monitor = MachineMonitor(sensor: ScriptedSensor([sample(user: 0, idle: 0)]), power: power)
        _ = await monitor.sample()
        #expect(monitor.lines.last == UsageLine(window: .battery, percent: 64, warning: false))
    }

    /// A sample that reads the same as the last leaves the footer alone: a `@Published` write of an
    /// equal value still tells whatever observes it.
    @Test func anUnchangedSampleRedrawsNothing() async {
        let monitor = MachineMonitor(sensor: ScriptedSensor([sample(user: 0, idle: 0), sample(user: 10, idle: 10),
                                                             sample(user: 20, idle: 20)]),
                                     power: FakePower())
        _ = await monitor.sample()
        _ = await monitor.sample()
        var changed = false
        let watch = monitor.objectWillChange.sink { changed = true }
        _ = await monitor.sample()
        watch.cancel()
        #expect(monitor.lines.map(\.percent) == [50, 50])
        #expect(!changed)
    }

    /// Started, it samples on its own; stopped, it does not start twice or keep going.
    @Test func startSamplesUntilStopped() async {
        let monitor = MachineMonitor(sensor: ScriptedSensor([sample(user: 0, idle: 0)]), power: FakePower(),
                                     interval: .milliseconds(10))
        monitor.start()
        monitor.start()
        await eventually { !monitor.lines.isEmpty }
        monitor.stop()
        #expect(monitor.lines.map(\.window) == [.ram])
    }

    /// With no sidebar to be seen nothing is sampled; the first to show again samples at once.
    ///
    /// The loop's waits end only when it is cancelled, so each loop takes exactly one sample and
    /// the count steps 0, 1, 2 in order. It used to pass by luck: the loop paused in its wait took
    /// one more sample on the way out, so the count went 1, 2, 3 and the wait for 2 held only when
    /// it looked between the paused loop's sample and the resumed one's. And with the clock's waits
    /// a loop's second sample comes a second after its first (`min(interval, 1 s)`), which a main
    /// actor kept busy that long by the parallel runner could see before it saw the 1.
    @Test func pausedWhileNoFooterShows() async {
        let sensor = CountingSensor(sample(user: 0, idle: 0))
        let monitor = MachineMonitor(sensor: sensor, power: FakePower(), interval: .seconds(60), wait: { _ in await waitUntilCancelled() })
        monitor.setShown(false)
        monitor.start()
        #expect(!monitor.isSampling, "started while hidden, it waits")
        monitor.setShown(true)
        #expect(monitor.isSampling)
        await eventually(describing: "the first sample (taken: \(sensor.count))") { sensor.count == 1 }
        monitor.setShown(false)
        #expect(!monitor.isSampling)
        #expect(monitor.paused)
        monitor.setShown(true)
        await eventually(describing: "the resumed loop's sample, and no other (taken: \(sensor.count))") { sensor.count == 2 }
        monitor.stop()
        monitor.setShown(true)
        #expect(!monitor.isSampling, "stopped stays stopped")
    }
}

/// Counts the samples taken.
private final class CountingSensor: MachineSensor, @unchecked Sendable {
    private let taken = Locked(0)
    private let value: MachineSample
    init(_ value: MachineSample) { self.value = value }
    var count: Int { taken.withLock { $0 } }
    func sample() -> MachineSample {
        taken.withLock { $0 += 1 }
        return value
    }
}

/// Suspends until the task is cancelled: a loop's wait that only `stop()` or a pause ends. (A year
/// is never, for a test; cancellation ends the sleep at once.)
private func waitUntilCancelled() async {
    try? await Task.sleep(for: .seconds(365 * 86_400))
}
