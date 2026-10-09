// Ported from AiTerm (app/Sources/AiTerm/BackpackController.swift), GPLv3, Laurens D'Hondt.
import Combine
import Foundation
import ShellforgeCore

/// A turn-on or turn-off under way, which the header draws as a spinner.
public enum BackpackTransition: Equatable { case turningOn, turningOff }

/// Where a connect stands: the Backpack sheet's checks read it.
public enum ConnectPhase: Equatable {
    case joining
    /// The last join could not see the hotspot; another follows after a delay.
    case notInRange
    /// Joined; the marker and `disablesleep 1` are running.
    case keepingAwake
    case safe
    /// Final until Back or Cancel: `.joinFailed`, `.batteryLow` or `.needsSetup`.
    case failed(BackpackRefusal)
    /// The typed password could not be stored.
    case keychainRefused
}

/// Backpack Mode as the app drives it: `BackpackMode`'s blocking calls run on one serial thread, so a
/// connect, a turn-off and a tick never overlap, and their outcome is published here on the main
/// actor for the Backpack sheet, the footer's Mac rows and Settings › Integrations.
@MainActor
public final class BackpackController: ObservableObject {
    /// The glyph on every Backpack toast: the mode's own, the iPhone it runs through.
    static let symbol = "iphone"

    @Published public private(set) var state: BackpackState = .off
    @Published public private(set) var setup = BackpackSetup(sleepRule: false, location: false, network: nil)
    /// The battery as last read: with setup, and on every check while on.
    @Published public private(set) var power = PowerReading.mains
    /// A turn-on, turn-off or setup is running. ⌘B is ignored until it ends.
    @Published public private(set) var busy = false
    /// Set for as long as a turn-on or turn-off runs: joining a hotspot takes seconds.
    @Published public private(set) var transition: BackpackTransition?
    /// Where the last connect stands; nil until one runs, and again after a turn-off or Cancel.
    @Published public private(set) var phase: ConnectPhase?
    /// The Wi-Fi network the Mac is on, as last read: for the desk tooltip.
    @Published public private(set) var currentNetwork: String?

    private let mode: BackpackMode
    private let ports: BackpackPorts
    private let toast: @MainActor (String) -> Void
    /// Opens Location in System Settings: where Allow… sends the person once macOS will not ask.
    private let openLocationSettings: @MainActor () -> Void
    private let tickInterval: Duration
    /// A thread of its own, not a Dispatch queue: a join blocks for up to a minute (see `SerialThread`).
    private let worker = SerialThread(name: "io.github.nathangel.shellforge.backpack")
    private var ticking: Task<Void, Never>?
    private let retryDelays: [Duration]
    /// Whether any session in the workspace is `.working`: the 5 s check's reason to stay on.
    private let agentsWorking: @MainActor () -> Bool
    private var cancelled = false
    /// The sheet closed under the connect (the lid): nobody is left to Cancel, so a hotspot not in
    /// range is no longer waited for. Reset by each connect.
    private var sheetGone = false
    private var retryWait: Task<Void, Never>?
    /// A connect may have moved the Mac onto the hotspot: it was on another network, or none,
    /// when the connect began. Only then does a Cancel's undo leave the hotspot — a Mac already
    /// tethered to it stays as it was. Kept across connects until an undo or a turn-off, so a
    /// retry from the hotspot the last one joined still knows it joined it.
    private var joinedHotspot = false

    public init(ports: BackpackPorts, settings: BackpackSettings, tickInterval: Duration = .seconds(5),
         retryDelays: [Duration] = [.seconds(5), .seconds(10), .seconds(20), .seconds(30)],
         now: @escaping @Sendable () -> Date = Date.init, agentsWorking: @escaping @MainActor () -> Bool = { false },
         openLocationSettings: @escaping @MainActor () -> Void = {},
         toast: @escaping @MainActor (String) -> Void) {
        self.openLocationSettings = openLocationSettings
        self.ports = ports
        mode = BackpackMode(ports: ports, settings: settings, now: now)
        self.tickInterval = tickInterval
        self.retryDelays = retryDelays
        self.agentsWorking = agentsWorking
        self.toast = toast
        setup.network = settings.network
    }

    /// Over the inert ports, in memory: for a sheet or a test that never turns it on.
    static func inert() -> BackpackController {
        BackpackController(ports: .inert, settings: BackpackSettings(defaults: nil), toast: { _ in })
    }

    var isOn: Bool { state.isOn }

    /// The hotspot and its password, written on Save. A change takes effect at the next turn-on.
    var network: String? {
        get { mode.settings.network }
        set { mode.settings.network = newValue; setup.network = newValue }
    }
    /// A Keychain read: off the main actor where it can be (`savedPassword()`).
    var password: String? {
        get { mode.settings.password }
        set { mode.settings.setPassword(newValue) }
    }

    /// Writes the password to the Keychain; false when it refused.
    func setPassword(_ value: String) -> Bool { mode.settings.setPassword(value) }

    /// The saved password, read off the main actor: the sheet fills its field with it, as if typed.
    func savedPassword() async -> String? {
        let settings = mode.settings
        return await ThreadWork.run { settings.password }
    }

    /// What a failed `disablesleep 0` says; the checks keep trying until it works.
    static let restoreFailed = "Couldn’t turn lid sleep back on: Shellforge keeps trying"

    /// The sheet's Connect: saves the hotspot (and a typed password), then turns on, retrying a
    /// hotspot that isn't showing on `retryDelays` until it shows, a final refusal, Cancel, quit or
    /// the sheet closing (`finishWithoutSheet()`).
    public func connect(network: String, password: String?) async {
        guard !busy, !isOn else { return }
        self.network = network
        if let password, !password.isEmpty, !setPassword(password) { phase = .keychainRefused; return }
        busy = true
        transition = .turningOn
        defer { busy = false; transition = nil }
        cancelled = false
        sheetGone = false
        phase = .joining
        let wifi = ports.wifi
        let before = await worker.run { wifi.currentNetwork() }
        if before != network { joinedHotspot = true }
        var attempt = 0
        let mode = self.mode
        attempts: while !cancelled {
            // Weak from the outer closure on: `onJoined` runs on the mode's thread, which must not
            // keep the controller alive.
            let joined: @Sendable () -> Void = { [weak self] in
                Task { @MainActor [weak self] in
                    if self?.phase == .joining { self?.phase = .keepingAwake }
                }
            }
            let result = await worker.run { mode.turnOn(onJoined: joined) }
            state = mode.state
            switch result {
            case .success(let status):
                if cancelled { break attempts }
                setup = BackpackSetup(sleepRule: true, location: true, network: status.network)
                currentNetwork = status.network
                phase = .safe
                startTicking()
                return
            case .failure(.notInRange):
                // Cancelled, or the sheet gone, while that join ran: undo now, not after the wait.
                if cancelled || sheetGone { break attempts }
                phase = .notInRange
                let delay = retryDelays[min(attempt, retryDelays.count - 1)]
                attempt += 1
                retryWait = Task { try? await Task.sleep(for: delay) }
                await retryWait?.value
                if cancelled || sheetGone { break attempts }
                phase = .joining
            case .failure(.quitting):
                phase = nil
                return
            case .failure(let refusal):
                // Cancel wins over a refusal it came before: undo, and show no failure.
                if cancelled { break attempts }
                phase = .failed(refusal)
                if refusal == .needsSetup { await refreshSetupWhileBusy() }
                return
            }
        }
        await undoWhileBusy(leaving: network)
    }

    /// The sheet's Cancel, and its lid close with no connect running. During a connect: stop after
    /// the attempt under way, then undo. After a final refusal: retry a failed sleep restore, and put the Wi-Fi back if the attempt
    /// moved the Mac onto the hotspot. Otherwise nothing changed, and nothing is touched.
    public func cancelConnect() async {
        if busy {
            cancelled = true
            retryWait?.cancel()
            return
        }
        guard !isOn, mode.settings.engaged || joinedHotspot, let network else { phase = nil; return }
        busy = true
        defer { busy = false; transition = nil }
        await undoWhileBusy(leaving: network)
    }

    /// The sheet closed under a connect — the lid. The attempt under way finishes on its own, but
    /// one that finds no hotspot ends as a Cancel does, and a wait for the next attempt stops now:
    /// with the sheet gone nothing would ever stop the retries.
    public func finishWithoutSheet() {
        sheetGone = true
        retryWait?.cancel()
    }

    /// Off by hand: sleep back, then the best known network in range.
    public func turnOff() async {
        guard !busy, isOn else { return }
        busy = true
        transition = .turningOff
        defer { busy = false; transition = nil }
        ticking?.cancel()
        let mode = self.mode, wifi = ports.wifi, hotspot = network ?? ""
        joinedHotspot = false
        let (restored, current) = await worker.run { () -> (Bool, String?) in
            let restored = mode.turnOff()
            _ = mode.rejoinPreferred(leaving: hotspot)
            return (restored, wifi.currentNetwork())
        }
        state = mode.state
        phase = nil
        currentNetwork = current
        if !restored {
            toast(Self.restoreFailed)
            startTicking()
        }
    }

    /// Cancel's undo, under `busy`: off if it got that far, then off the hotspot if the connect
    /// put the Mac on it. A failed `disablesleep 0` is said and retried by the checks, as in
    /// `turnOff()`.
    private func undoWhileBusy(leaving hotspot: String) async {
        transition = .turningOff
        let mode = self.mode, wifi = ports.wifi, leave = joinedHotspot
        joinedHotspot = false
        let (restored, current) = await worker.run { () -> (Bool, String?) in
            let restored = mode.turnOff()
            if leave { _ = mode.rejoinPreferred(leaving: hotspot) }
            return (restored, wifi.currentNetwork())
        }
        state = mode.state
        phase = nil
        currentNetwork = current
        if !restored {
            toast(Self.restoreFailed)
            startTicking()
        }
    }

    public func refreshSetup() async {
        guard !busy else { return }
        await refreshSetupWhileBusy()
    }

    /// Set Up…: the sudoers rule's admin prompt, then the Location prompt, each only if missing.
    public func setUp() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        await refreshSetupWhileBusy()
        // Not on the mode's thread: the admin prompt waits on the person.
        if setup.missingSteps.contains(.sleepRule) {
            let installer = ports.installer
            _ = await ThreadWork.run { installer.install() }
        }
        if setup.missingSteps.contains(.location), !(await ports.location.request()) { openLocationSettings() }
        await refreshSetupWhileBusy()
    }

    /// Remove Setup: off first, then the rule. Location stays granted; System Settings revokes it.
    public func removeSetup() async {
        if isOn { await turnOff() }
        guard !busy else { return }
        // Without the rule nothing could put sleep back.
        if mode.settings.engaged {
            toast(Self.restoreFailed)
            return
        }
        busy = true
        defer { busy = false }
        let installer = ports.installer
        _ = await ThreadWork.run { installer.remove() }
        await refreshSetupWhileBusy()
    }

    /// What one scan finds now, by name, for the sheet's Hotspot menu. Blocking for seconds, so off
    /// the main actor.
    public func networksInRange() async -> [String] {
        let wifi = ports.wifi
        return await ThreadWork.run { wifi.networksInRange().filter { !$0.isEmpty } }
    }

    /// The 5 s check: the cutoff, the work, and the network.
    public func tick() async {
        let mode = self.mode, working = agentsWorking()
        let outcome: BackpackTick? = await worker.run { mode.tick(agentsWorking: working) }
        state = mode.state
        if case .on(let status) = state { power = status.power }
        guard case .ended? = outcome else { return }
        let restored = !mode.settings.engaged
        if !restored { toast(Self.restoreFailed) }
        phase = nil
        joinedHotspot = false
        // Sleep is back, but macOS sleeps on the lid's close, not its state: with the lid already
        // shut — the Mac in a bag — it would stay awake. Ask for sleep; the Wi-Fi rejoins on wake.
        let lidSleep = ports.lidSleep
        if restored, ports.lidSensor.isClosed() == true {
            _ = await worker.run { lidSleep.sleepNow() }
            return
        }
        transition = .turningOff
        let wifi = ports.wifi, hotspot = network ?? ""
        currentNetwork = await worker.run { () -> String? in
            _ = mode.rejoinPreferred(leaving: hotspot)
            return wifi.currentNetwork()
        }
        // Not a connect's `.turningOn` that started during the rejoin.
        if transition == .turningOff { transition = nil }
    }

    /// Yields each time the lid goes from open to closed. A lid already closed when this starts —
    /// a Mac in clamshell with a display — yields only after it opens and closes again; a Mac
    /// without a lid never yields.
    public func lidCloses(every interval: Duration = .milliseconds(500)) -> AsyncStream<Void> {
        let sensor = ports.lidSensor
        return AsyncStream { continuation in
            let task = Task {
                var last = sensor.isClosed()
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    let now = sensor.isClosed()
                    if last == false, now == true { continuation.yield() }
                    last = now
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// At launch, before anything else: a marker left by a crash puts sleep back.
    public func recoverAtLaunch() {
        let mode = self.mode
        worker.sync { mode.recoverAtLaunch() }
    }

    /// Launch: put sleep back if a crash left it off, then read setup, so the header's menu knows.
    public func launch() async {
        recoverAtLaunch()
        await refreshSetup()
    }

    /// At quit. Closes the mode — waiting only for a turn-on in the middle of committing — then
    /// turns it off at once: not behind a join on the worker, which can take a minute. A turn-on
    /// still on its way finds the mode closed, so Shellforge never exits leaving lid sleep disabled.
    public func shutdown() {
        ticking?.cancel()
        cancelled = true
        retryWait?.cancel()
        let mode = self.mode
        mode.close()
        mode.turnOff()
        state = mode.state
    }

    #if DEBUG
    /// Snapshots draw a state without turning anything on.
    public func preview(state: BackpackState, setup: BackpackSetup, transition: BackpackTransition? = nil,
                 phase: ConnectPhase? = nil, busy: Bool = false) {
        self.state = state
        self.busy = busy
        self.setup = setup
        self.transition = transition
        self.phase = phase
        if case .on(let status) = state { power = status.power }
    }
    #endif

    private func refreshSetupWhileBusy() async {
        let mode = self.mode, powerSource = ports.power, wifi = ports.wifi
        let fresh = await worker.run { (mode.setup(), powerSource.reading(), wifi.currentNetwork()) }
        setup = fresh.0
        power = fresh.1
        currentNetwork = fresh.2
    }

    private func startTicking() {
        ticking?.cancel()
        let interval = tickInterval
        ticking = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                // On, or off with a failed restore still to retry.
                guard !Task.isCancelled, let self, self.isOn || self.mode.settings.engaged else { return }
                await self.tick()
            }
        }
    }
}
