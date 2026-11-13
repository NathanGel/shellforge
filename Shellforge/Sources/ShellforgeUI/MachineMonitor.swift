// Ported from AiTerm (app/Sources/AiTerm/MachineMonitor.swift), GPLv3, Laurens D'Hondt.
import Combine
import Foundation
import ShellforgeCore

private let machineLog = PackageLogger(category: "machine")

/// The Mac's readings under `ctx` (proposal 1A, 6 Oct 2026): its CPU, its memory and, on battery,
/// its charge, sampled off the main actor and published here for the footer. An owner of the
/// composition root, started at launch and stopped at quit with the rest. While no footer can be
/// seen it is `paused`: nothing is sampled, and the first footer to show again samples at once.
@MainActor
public final class MachineMonitor: ObservableObject {
    /// What the readings row draws, in its order: cpu, ram, then bat while on battery. Empty until
    /// the first sample lands.
    @Published public private(set) var lines: [UsageLine] = []

    private let sensor: any MachineSensor
    /// The battery, as Backpack Mode reads it: one port for both.
    private let power: any PowerSource
    private let interval: Duration
    /// How the loop waits between samples: the clock, unless a test holds it.
    private let wait: @Sendable (Duration) async -> Void
    private var previous: MachineSample?
    private var sampling: Task<Void, Never>?
    /// Between `start()` and `stop()`.
    private var started = false
    /// No sidebar's footer can be seen (`setShown`).
    public private(set) var paused = false
    /// Whether a sampling loop runs now, for tests.
    var isSampling: Bool { sampling != nil }

    public init(sensor: any MachineSensor, power: any PowerSource, interval: Duration = .seconds(5),
                wait: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.sensor = sensor
        self.power = power
        self.interval = interval
        self.wait = wait
    }

    /// Samples until `stop()`, except while paused. Once started, a second call does nothing.
    public func start() {
        started = true
        resume()
    }

    /// Whether any footer can be seen: false pauses the sampling, true resumes it with a sample
    /// at once. Only a change does anything.
    public func setShown(_ shown: Bool) {
        guard shown == paused else { return }
        paused = !shown
        if paused {
            sampling?.cancel()
            sampling = nil
            // A CPU share across the whole pause is not "now": the next sample starts afresh, and
            // its second follows a second later, as at launch.
            previous = nil
            machineLog.debug("Sampling paused: no sidebar shows")
        } else {
            machineLog.debug("Sampling resumed")
            resume()
        }
    }

    private func resume() {
        guard started, !paused, sampling == nil else { return }
        // Weak: the loop must not keep the monitor alive, and it ends when the monitor goes.
        let wait = self.wait
        // Cancelled while it waits, the loop ends there: a wait cut short by a pause is no cue
        // for one more sample, which read the sensor while no footer showed.
        sampling = Task { [weak self] in
            while !Task.isCancelled, let pause = await self?.sample(), !Task.isCancelled {
                await wait(pause)
            }
        }
    }

    public func stop() {
        started = false
        sampling?.cancel()
        sampling = nil
    }

    /// Takes one sample and publishes what it reads; returns how long to wait for the next. The
    /// first wait is short: the CPU's share needs a second sample, and a row without `cpu` for a
    /// whole interval after launch reads as broken.
    public func sample() async -> Duration {
        let sensor = self.sensor, power = self.power
        let (current, battery) = await BackgroundWork.run { (sensor.sample(), power.reading()) }
        let next = MachineReadings.lines(previous: previous, current: current, power: battery)
        let pause = previous == nil ? min(interval, .seconds(1)) : interval
        // A loop paused while this sample was read: it is not the one after a resume's.
        guard !Task.isCancelled else { return pause }
        previous = current
        // An equal write still notifies observers, and would redraw the footer for nothing.
        if next != lines { lines = next }
        return pause
    }
}
