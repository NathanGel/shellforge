// Ported from AiTerm (app/Sources/AiTermCore/Backpack/BackpackMode.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// Keeps the Mac awake with the lid closed, on one known Wi-Fi network: the decisions, over ports a
/// test fakes. Every method blocks — a scan takes seconds, `sudo` a moment — so the app calls them
/// on one serial thread of its own, never two at once.
public final class BackpackMode: Sendable {
    private let ports: BackpackPorts
    public let settings: BackpackSettings
    private let now: @Sendable () -> Date
    private let current = Locked(BackpackState.off)
    /// Whether `close()` has run, for good. Its lock is also the turn-on's commit — the marker,
    /// `disablesleep 1` and the state — so quit either waits for a commit under way or stops it.
    private let closed = Locked(false)
    /// The password the mode turned on with: a Save while on takes effect at the next turn-on.
    private let activePassword = Locked<String?>(nil)
    /// Off the network: when the next rejoin may be tried, and how many have been since the drop.
    private let rejoin = Locked<(next: Date?, tries: Int)>((nil, 0))
    /// When a session was last seen working while on; a turn-on starts it.
    private let lastWork = Locked<Date?>(nil)

    /// How long the mode waits after the last working session before it turns itself off: long
    /// enough to bridge one turn ending and a queued one starting, short enough not to keep a
    /// finished Mac hot in a bag (spec 2026-10-05). An open lid holds it: the person is at the Mac,
    /// and the wait counts from when they shut it.
    public static let idleGrace: TimeInterval = 120

    /// The waits between rejoin attempts: a 5 s check that scanned every time would keep the Wi-Fi
    /// busy for as long as the hotspot is gone.
    static let rejoinDelays: [TimeInterval] = [5, 10, 20, 30]

    public init(ports: BackpackPorts, settings: BackpackSettings, now: @escaping @Sendable () -> Date = Date.init) {
        self.ports = ports
        self.settings = settings
        self.now = now
    }

    public var state: BackpackState { current.withLock { $0 } }

    public func setup() -> BackpackSetup {
        BackpackSetup(sleepRule: ports.lidSleep.isAllowed(), location: ports.location.isAuthorized(), network: settings.network)
    }

    /// The spec's order: setup, battery, join, marker, then `disablesleep 1`. The first failure
    /// leaves the mode off and nothing changed but, at most, the Wi-Fi network. The join comes
    /// without a scan first: a locked iPhone's hotspot is missing from scans but joins with its
    /// password; the scan only decides which failure to report. `onJoined` runs once the Mac is on
    /// the hotspot, before the marker.
    public func turnOn(onJoined: @escaping @Sendable () -> Void = {}) -> Result<BackpackStatus, BackpackRefusal> {
        if closed.withLock({ $0 }) { return .failure(.quitting) }
        if case .on(let status) = state { return .success(status) }
        let setup = setup()
        guard setup.isComplete, let network = setup.network else { return .failure(.needsSetup) }
        let power = ports.power.reading()
        if power.onBattery, let level = power.level, level <= BackpackSettings.cutoff { return .failure(.batteryLow(level: level)) }
        let password = settings.password
        if ports.wifi.currentNetwork() != network, !ports.wifi.join(network, password: password) {
            return .failure(ports.wifi.isInRange(network) ? .joinFailed(network: network) : .notInRange(network: network))
        }
        onJoined()
        return closed.withLock { isClosed -> Result<BackpackStatus, BackpackRefusal> in
            // Quit may have come while the join ran.
            if isClosed { return .failure(.quitting) }
            settings.engaged = true
            guard ports.lidSleep.setDisabled(true) else {
                settings.engaged = false
                return .failure(.needsSetup)
            }
            let status = BackpackStatus(network: network, joined: true, power: power)
            current.withLock { $0 = .on(status) }
            activePassword.withLock { $0 = password }
            rejoin.withLock { $0 = (nil, 0) }
            lastWork.withLock { $0 = now() }
            return .success(status)
        }
    }

    /// Puts sleep back. False when `disablesleep 0` failed: the marker stays, and every `tick()`
    /// and the next launch try again. The Wi-Fi network stays as it is.
    @discardableResult
    public func turnOff() -> Bool {
        guard state.isOn || settings.engaged else { return true }
        current.withLock { $0 = .off }
        guard ports.lidSleep.setDisabled(false) else { return false }
        settings.engaged = false
        return true
    }

    private func rejoinIsDue() -> Bool {
        let time = now()
        return rejoin.withLock { state in state.next.map { time >= $0 } ?? true }
    }

    /// Booked once a failed join has ended — a join can take a minute, and counting from its start
    /// would run the next one straight after.
    private func bookNextRejoin() {
        let time = now()
        rejoin.withLock { state in
            let delay = Self.rejoinDelays[min(state.tries, Self.rejoinDelays.count - 1)]
            state = (time.addingTimeInterval(delay), state.tries + 1)
        }
    }

    /// Quit: from now on every turn-on refuses. Safe from any thread, and immediate — unlike the
    /// thread the app runs this mode on — so a turn-on still on its way finds it.
    public func close() {
        closed.withLock { $0 = true }
    }

    /// A launch after a crash or a force quit: the marker says Shellforge left sleep disabled.
    public func recoverAtLaunch() {
        guard settings.engaged else { return }
        if ports.lidSleep.setDisabled(false) { settings.engaged = false }
    }

    /// The 5 s check while on: the battery cutoff, then the work — an open lid counting as work —
    /// then the network. Off the network, a rejoin is tried at once, then after each of
    /// `rejoinDelays`, the last repeating; joined again, that starts over.
    public func tick(agentsWorking: Bool) -> BackpackTick {
        guard case .on(let old) = state else {
            // Off, but a failed `disablesleep 0` left sleep disabled: try again.
            guard settings.engaged else { return .unchanged }
            return turnOff() ? .changed : .unchanged
        }
        let power = ports.power.reading()
        if power.onBattery, let level = power.level, level <= BackpackSettings.cutoff {
            turnOff()
            return .ended(.batteryLow(level: level))
        }
        let time = now()
        if agentsWorking || ports.lidSensor.isClosed() == false {
            lastWork.withLock { $0 = time }
        } else if let last = lastWork.withLock({ $0 }), time.timeIntervalSince(last) >= Self.idleGrace {
            turnOff()
            return .ended(.agentsStopped)
        }
        var joined = ports.wifi.currentNetwork() == old.network
        if !joined, rejoinIsDue() {
            joined = ports.wifi.join(old.network, password: activePassword.withLock { $0 })
            if !joined { bookNextRejoin() }
        }
        if joined { rejoin.withLock { $0 = (nil, 0) } }
        let next = BackpackStatus(network: old.network, joined: joined, power: power)
        guard next != old else { return .unchanged }
        current.withLock { if $0.isOn { $0 = .on(next) } }
        return .changed
    }

    /// After off: leave `hotspot` — or no network at all, which a failed join leaves — for the first
    /// of the Mac's preferred networks that one scan finds, the hotspot excluded, joined as a known
    /// network (no password: it is the Mac's). A Mac on some other network stays there. The network
    /// the Mac ends up on; nil when none was in range and it stays where it was.
    public func rejoinPreferred(leaving hotspot: String) -> String? {
        if let current = ports.wifi.currentNetwork(), current != hotspot { return current }
        let inRange = ports.wifi.networksInRange()
        for network in ports.wifi.knownNetworks() where network != hotspot && inRange.contains(network) {
            if ports.wifi.join(network, password: nil) { return network }
        }
        return nil
    }
}
