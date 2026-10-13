// Ported from AiTerm (app/Tests/AiTermTests/BackpackControllerTests.swift), GPLv3, Laurens D'Hondt.
import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

@MainActor
@Suite(.serialized) struct BackpackControllerTests {
    private func controller(_ fake: FakeBackpack, toasts: Recorder = Recorder(),
                            working: @escaping @MainActor () -> Bool = { true },
                            now: @escaping @Sendable () -> Date = Date.init,
                            openLocationSettings: @escaping @MainActor () -> Void = {}) -> BackpackController {
        BackpackController(ports: fake.ports, settings: fake.settings, tickInterval: .seconds(3600),
                           retryDelays: [.milliseconds(10)], now: now, agentsWorking: working,
                           openLocationSettings: openLocationSettings, toast: { toasts.lines.append($0) })
    }

    final class Recorder { var lines: [String] = [] }

    @Test func aConnectEndsSafeAndOnWithoutAToast() async {
        let fake = FakeBackpack(), toasts = Recorder()
        let backpack = controller(fake, toasts: toasts)
        await backpack.connect(network: "Phone", password: nil)
        #expect(backpack.phase == .safe)
        #expect(backpack.isOn)
        #expect(toasts.lines.isEmpty, "the sheet says it; a toast would say it twice")
    }

    @Test func aConnectSavesTheHotspotAndATypedPassword() async {
        let fake = FakeBackpack()
        fake.settings.network = "Home"
        let backpack = controller(fake)
        await backpack.connect(network: "Phone", password: "hunter2")
        #expect(fake.settings.network == "Phone")
        #expect(fake.settings.password == "hunter2")
        #expect(fake.wifi.passwords == ["hunter2"])
    }

    @Test func anEmptyPasswordKeepsTheSavedOne() async {
        let fake = FakeBackpack()
        fake.settings.password = "saved"
        let backpack = controller(fake)
        await backpack.connect(network: "Phone", password: nil)
        #expect(fake.wifi.passwords == ["saved"])
    }

    /// The phase walks joining → keepingAwake → safe; keepingAwake is set from `onJoined`.
    @Test func thePhaseIsKeepingAwakeOnceJoined() async {
        let fake = FakeBackpack()
        let release = DispatchSemaphore(value: 0)
        fake.lid.onSet = { if $0 { release.wait() } }
        let backpack = controller(fake)
        let run = Task { await backpack.connect(network: "Phone", password: nil) }
        await eventually { backpack.phase == .keepingAwake }
        #expect(backpack.transition == .turningOn)
        release.signal()
        await run.value
        #expect(backpack.phase == .safe)
    }

    @Test func aHotspotOutOfSightIsRetriedUntilItShows() async {
        let fake = FakeBackpack()
        fake.wifi.inRange = ["Home"]
        fake.wifi.joinSucceeds = false
        let backpack = controller(fake)
        let run = Task { await backpack.connect(network: "Phone", password: nil) }
        await eventually { fake.wifi.joins.count >= 2 }
        #expect(backpack.phase == .notInRange || backpack.phase == .joining)
        fake.wifi.joinSucceeds = true
        await run.value
        #expect(backpack.phase == .safe)
    }

    @Test func aWrongPasswordIsFinal() async {
        let fake = FakeBackpack()
        fake.wifi.joinSucceeds = false   // in range: a password problem
        let backpack = controller(fake)
        await backpack.connect(network: "Phone", password: nil)
        #expect(backpack.phase == .failed(.joinFailed(network: "Phone")))
        #expect(!backpack.busy && !backpack.isOn)
    }

    /// The failed joins dropped "Home": the undo joins it again.
    @Test func cancelStopsTheRetriesAndPutsTheWiFiBack() async {
        let fake = FakeBackpack()
        fake.wifi.inRange = ["Home"]
        fake.wifi.failingJoins = ["Phone"]
        let backpack = controller(fake)
        let run = Task { await backpack.connect(network: "Phone", password: nil) }
        await eventually { !fake.wifi.joins.isEmpty }
        await backpack.cancelConnect()
        await run.value
        #expect(!backpack.isOn && !backpack.busy)
        #expect(fake.lid.calls.isEmpty, "sleep was never touched")
        #expect(backpack.phase == nil)
        #expect(fake.wifi.current == "Home")
        #expect(fake.wifi.joins.last == "Home")
        #expect(backpack.currentNetwork == "Home")
    }

    /// Started on "Home", the join failed for good and dropped it: Cancel brings the Mac back
    /// onto a preferred network, not leaves it on none.
    @Test func cancelAfterAFailedJoinPutsTheMacBackOnAPreferredNetwork() async {
        let fake = FakeBackpack()
        fake.wifi.failingJoins = ["Phone"]   // in range: joinFailed
        let backpack = controller(fake)
        await backpack.connect(network: "Phone", password: nil)
        #expect(backpack.phase == .failed(.joinFailed(network: "Phone")))
        #expect(fake.wifi.current == nil)
        await backpack.cancelConnect()
        #expect(fake.wifi.current == "Home")
        #expect(backpack.currentNetwork == "Home")
        #expect(backpack.phase == nil && !backpack.busy)
        #expect(fake.lid.calls.isEmpty, "sleep was never touched")
    }

    @Test func cancelAfterAJoinLeavesTheHotspot() async {
        let fake = FakeBackpack()
        fake.wifi.known = ["Home", "Phone"]
        let release = DispatchSemaphore(value: 0)
        fake.lid.onSet = { if $0 { release.wait() } }
        let backpack = controller(fake)
        let run = Task { await backpack.connect(network: "Phone", password: nil) }
        await eventually { backpack.phase == .keepingAwake }
        let cancel = Task { await backpack.cancelConnect() }
        release.signal()
        await run.value
        await cancel.value
        #expect(!backpack.isOn)
        #expect(fake.wifi.current == "Home")
        #expect(fake.lid.calls == [true, false])
    }

    /// Already on the hotspot when the connect began: Cancel puts sleep back and leaves the Wi-Fi.
    @Test func cancelLeavesAMacThatWasAlreadyOnTheHotspotThere() async {
        let fake = FakeBackpack()
        fake.wifi.current = "Phone"
        let release = DispatchSemaphore(value: 0)
        fake.lid.onSet = { @Sendable in if $0 { release.wait() } }
        let backpack = controller(fake)
        let run = Task { await backpack.connect(network: "Phone", password: nil) }
        await eventually { backpack.phase == .keepingAwake }
        let cancel = Task { await backpack.cancelConnect() }
        release.signal()
        await run.value
        await cancel.value
        #expect(!backpack.isOn)
        #expect(fake.wifi.joins.isEmpty)
        #expect(fake.wifi.current == "Phone")
        #expect(fake.lid.calls == [true, false])
    }

    /// Cancel after `disablesleep 1` ran, and `disablesleep 0` then fails: said, and retried by the
    /// checks, as a turn-off by hand is — never left disabled until the next launch.
    @Test func aFailedRestoreOnCancelSaysSoAndKeepsTrying() async {
        let fake = FakeBackpack(), toasts = Recorder()
        let release = DispatchSemaphore(value: 0)
        let lid = fake.lid
        // `disablesleep 1` succeeds once released; the `disablesleep 0` after it fails.
        lid.onSet = { @Sendable disabled in if disabled { release.wait() } else { lid.succeeds = false } }
        // Checks every 10 ms: the retry has to come from them, not from the test.
        let backpack = BackpackController(ports: fake.ports, settings: fake.settings, tickInterval: .milliseconds(10),
                                          retryDelays: [.milliseconds(10)], agentsWorking: { true },
                                          toast: { toasts.lines.append($0) })
        let run = Task { await backpack.connect(network: "Phone", password: nil) }
        await eventually { backpack.phase == .keepingAwake }
        let cancel = Task { await backpack.cancelConnect() }
        release.signal()
        await run.value
        await cancel.value
        #expect(!backpack.isOn)
        #expect(toasts.lines == [BackpackController.restoreFailed])
        #expect(fake.settings.engaged)
        lid.onSet = { _ in }
        lid.succeeds = true
        let deadline = Date().addingTimeInterval(2)
        while fake.settings.engaged, Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(!fake.settings.engaged, "the checks put sleep back")
        backpack.shutdown()
    }

    /// No other known network in range: the Mac stays on the hotspot, and the tooltip says so.
    @Test func anUndoWithNowhereToGoReportsTheHotspot() async {
        let fake = FakeBackpack()
        fake.wifi.inRange = ["Phone"]
        let release = DispatchSemaphore(value: 0)
        fake.lid.onSet = { @Sendable in if $0 { release.wait() } }
        let backpack = controller(fake)
        let run = Task { await backpack.connect(network: "Phone", password: nil) }
        await eventually { backpack.phase == .keepingAwake }
        let cancel = Task { await backpack.cancelConnect() }
        release.signal()
        await run.value
        await cancel.value
        #expect(fake.wifi.current == "Phone")
        #expect(backpack.currentNetwork == "Phone")
    }

    /// Cancel while a join is under way: once it answers, undo at once, not after a retry's wait.
    @Test func cancelDuringAJoinSkipsTheRetryWait() async {
        let fake = FakeBackpack()
        fake.wifi.inRange = ["Home"]
        fake.wifi.failingJoins = ["Phone"]
        let release = DispatchSemaphore(value: 0), entered = Locked(false)
        // Holds the connect's join only: the undo's join of "Home" runs straight through.
        fake.wifi.onJoin = { @Sendable in if entered.withLock({ let first = !$0; $0 = true; return first }) { release.wait() } }
        let backpack = BackpackController(ports: fake.ports, settings: fake.settings, tickInterval: .seconds(3600),
                                          retryDelays: [.seconds(5)], toast: { _ in })
        let run = Task { await backpack.connect(network: "Phone", password: nil) }
        await eventually { entered.withLock { $0 } }
        await backpack.cancelConnect()
        let started = Date()
        release.signal()
        await run.value
        #expect(Date().timeIntervalSince(started) < 1, "no wait before the undo")
        #expect(backpack.phase == nil && !backpack.busy)
        #expect(fake.wifi.joins == ["Phone", "Home"], "no retry of the hotspot; the undo puts the dropped network back")
    }

    /// Cancel while a join is under way that then fails for good: Cancel wins, not the refusal.
    @Test func cancelDuringAJoinThatFailsClearsThePhase() async {
        let fake = FakeBackpack()
        fake.wifi.joinSucceeds = false   // in range: joinFailed
        let release = DispatchSemaphore(value: 0), entered = Locked(false)
        // Holds the connect's join only: the undo's join of "Home" runs straight through.
        fake.wifi.onJoin = { @Sendable in if entered.withLock({ let first = !$0; $0 = true; return first }) { release.wait() } }
        let backpack = controller(fake)
        let run = Task { await backpack.connect(network: "Phone", password: nil) }
        await eventually { entered.withLock { $0 } }
        await backpack.cancelConnect()
        release.signal()
        await run.value
        #expect(backpack.phase == nil, "the sheet was cancelled: no failure to show")
        #expect(!backpack.busy && !backpack.isOn)
    }

    /// Quit while it waits to retry stops the loop; sleep stays enabled.
    @Test func quitStopsARetryingConnect() async {
        let fake = FakeBackpack()
        fake.wifi.inRange = ["Home"]
        fake.wifi.joinSucceeds = false
        let backpack = controller(fake)
        let run = Task { await backpack.connect(network: "Phone", password: nil) }
        await eventually { !fake.wifi.joins.isEmpty }
        backpack.shutdown()
        await run.value
        let joins = fake.wifi.joins.count
        try? await Task.sleep(for: .milliseconds(50))
        #expect(fake.wifi.joins.count == joins, "no retry after quit")
        #expect(fake.lid.calls.allSatisfy { !$0 })
    }

    @Test func turningOffRejoinsTheBestNetworkAndClearsThePhase() async {
        let fake = FakeBackpack()
        fake.wifi.known = ["Phone", "Home"]
        let backpack = controller(fake)
        await backpack.connect(network: "Phone", password: nil)
        await backpack.turnOff()
        #expect(!backpack.isOn)
        #expect(fake.wifi.current == "Home")
        #expect(backpack.phase == nil)
        #expect(backpack.currentNetwork == "Home")
    }

    /// The 5 s tick while on: a tick that changes nothing redraws no footer.
    @Test func anUnchangedBackpackTickRedrawsNothing() async {
        let fake = FakeBackpack()
        let backpack = controller(fake, working: { true })
        await backpack.connect(network: "Phone", password: nil)
        await backpack.tick()
        var redraws = 0
        let subscription = backpack.objectWillChange.sink { redraws += 1 }
        await backpack.tick()
        subscription.cancel()
        #expect(backpack.isOn)
        #expect(redraws == 0)
    }

    /// With the lid open only the battery cutoff ends it: an open lid holds the idle grace.
    @Test func endingItselfRejoinsTheNetworkTheMacWasOn() async {
        let fake = FakeBackpack()
        let backpack = controller(fake, working: { false })
        await backpack.connect(network: "Phone", password: nil)
        fake.power.value = PowerReading(level: BackpackSettings.cutoff, onBattery: true)
        await backpack.tick()
        #expect(!backpack.isOn)
        #expect(backpack.phase == nil, "off: the sheet must not read safe")
        #expect(backpack.currentNetwork == "Home", "back on the network the Mac was on")
        #expect(backpack.transition == nil)
        #expect(fake.lid.sleeps == 0, "the lid was open: the Mac decides when to sleep")
    }

    /// macOS sleeps on the lid's close, not on its state: sleep coming back with the lid already
    /// shut — the Mac in a bag — would leave it awake. So the ending asks for sleep itself, and the
    /// Wi-Fi rejoins on wake rather than now.
    @Test(arguments: [false, true])
    func endingItselfWithTheLidClosedPutsTheMacToSleep(onBatteryCutoff: Bool) async {
        let fake = FakeBackpack()
        fake.wifi.known = ["Home", "Phone"]
        let start = Date(timeIntervalSince1970: 1_000)
        let clock = Locked(start)
        // The cutoff ends it with an agent still working; the idle grace needs none working.
        let backpack = controller(fake, working: { onBatteryCutoff }, now: { clock.withLock { $0 } })
        await backpack.connect(network: "Phone", password: nil)
        fake.lidSensor.closed = true
        if onBatteryCutoff {
            fake.power.value = PowerReading(level: BackpackSettings.cutoff, onBattery: true)
        } else {
            clock.withLock { $0 = start.addingTimeInterval(BackpackMode.idleGrace) }
        }
        await backpack.tick()
        #expect(!backpack.isOn)
        #expect(fake.lid.calls == [true, false])
        #expect(fake.lid.sleeps == 1)
        #expect(fake.wifi.joins == ["Phone"], "no rejoin before sleeping: it happens on wake")
        #expect(backpack.transition == nil)
    }

    /// Sleep did not come back: asking for sleep would be pointless, and the restore retries.
    @Test func aFailedRestoreAtTheEndingNeverAsksForSleep() async {
        let fake = FakeBackpack(), toasts = Recorder()
        let start = Date(timeIntervalSince1970: 1_000)
        let clock = Locked(start)
        let backpack = controller(fake, toasts: toasts, working: { false }, now: { clock.withLock { $0 } })
        await backpack.connect(network: "Phone", password: nil)
        fake.lidSensor.closed = true
        fake.lid.succeeds = false
        clock.withLock { $0 = start.addingTimeInterval(BackpackMode.idleGrace) }
        await backpack.tick()
        #expect(fake.lid.sleeps == 0)
        #expect(toasts.lines.last == BackpackController.restoreFailed)
    }

    /// A lid already closed (clamshell with a display) never yields; only a close does.
    /// Laurens's Mac often runs lid-closed on an external display: the sheet opening must not end it.
    @Test func aLidAlreadyClosedNeverYields() async {
        let fake = FakeBackpack()
        fake.lidSensor.closed = true
        let backpack = controller(fake)
        let yields = Locked(0)
        let stream = backpack.lidCloses(every: .milliseconds(5))
        let watch = Task { for await _ in stream { yields.withLock { $0 += 1 } } }
        try? await Task.sleep(for: .milliseconds(40))
        #expect(yields.withLock { $0 } == 0, "closed from the start is not a close")
        fake.lidSensor.closed = false
        try? await Task.sleep(for: .milliseconds(40))
        #expect(yields.withLock { $0 } == 0, "an opening is not a close")
        fake.lidSensor.closed = true
        let deadline = Date().addingTimeInterval(2)
        while yields.withLock({ $0 }) == 0, Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        // Long enough for a second, wrong yield to show while the lid stays closed.
        try? await Task.sleep(for: .milliseconds(40))
        #expect(yields.withLock { $0 } == 1, "open → closed yields, once")
        watch.cancel()
        await watch.value
    }

    @Test func noLidNeverYields() async {
        let fake = FakeBackpack()
        fake.lidSensor.closed = nil
        let backpack = controller(fake)
        let watch = Task { () -> Bool in for await _ in backpack.lidCloses(every: .milliseconds(5)) { return true }; return false }
        try? await Task.sleep(for: .milliseconds(40))
        watch.cancel()
        #expect(await watch.value == false)
    }

    /// Quit during a turn-on: shutdown waits for it, then puts sleep back, so the Mac never stays
    /// sleepless after Shellforge is gone.
    @Test func shutdownWaitsForAnInFlightTurnOnAndEndsOff() async {
        let fake = FakeBackpack()
        let release = DispatchSemaphore(value: 0)
        let entered = Locked(false)
        fake.lid.onSet = { @Sendable in if $0 { entered.withLock { $0 = true }; release.wait() } }
        let toasts = Recorder()
        let backpack = controller(fake, toasts: toasts)
        let first = Task { await backpack.connect(network: "Phone", password: nil) }
        // Until the turn-on's work is on the queue: `busy` is set a moment before it gets there.
        await eventually { entered.withLock { $0 } }
        let releaser = Thread { Thread.sleep(forTimeInterval: 0.2); release.signal() }
        releaser.start()
        backpack.shutdown()
        #expect(fake.lid.calls == [true, false])
        #expect(!fake.settings.engaged)
        await first.value
        #expect(!backpack.isOn)
        #expect(toasts.lines.isEmpty, "no toast for a mode the quit already turned off")
    }

    /// The gap the test above cannot hold open: quit lands after ⌘B set `busy` but before its work
    /// reached the queue. That turn-on must find the mode closed.
    @Test func aTurnOnThatReachesTheQueueAfterShutdownDoesNothing() async {
        let fake = FakeBackpack()
        let backpack = controller(fake)
        backpack.shutdown()
        await backpack.connect(network: "Phone", password: nil)
        #expect(!fake.lid.calls.contains(true))
        #expect(!backpack.isOn)
    }

    @Test func theTickAtTheCutoffTurnsItOff() async {
        let fake = FakeBackpack(), toasts = Recorder()
        fake.power.value = PowerReading(level: 40, onBattery: true)
        let backpack = controller(fake, toasts: toasts)
        await backpack.connect(network: "Phone", password: nil)
        fake.power.value = PowerReading(level: 9, onBattery: true)
        await backpack.tick()
        #expect(!backpack.isOn)
        #expect(toasts.lines.isEmpty, "no turn-on toast, and the ending is not toasted")
    }

    @Test func setUpRunsTheMissingStepsAndRefreshes() async {
        let fake = FakeBackpack()
        fake.lid.allowed = false
        fake.location.authorized = false
        let backpack = controller(fake)
        await backpack.refreshSetup()
        #expect(backpack.setup.missingSteps == [.sleepRule, .location])
        await backpack.setUp()
        #expect(fake.installer.installs == 1 && fake.location.requests == 1)
        #expect(backpack.setup.missingSteps.isEmpty)
    }

    /// The Battery card reads the level even while the mode is off.
    @Test func refreshingReadsTheBatteryToo() async {
        let fake = FakeBackpack()
        fake.power.value = PowerReading(level: 64, onBattery: true)
        let backpack = controller(fake)
        await backpack.refreshSetup()
        #expect(backpack.power == PowerReading(level: 64, onBattery: true))
    }

    @Test func removeSetupTurnsTheModeOffFirst() async {
        let fake = FakeBackpack()
        let backpack = controller(fake)
        await backpack.connect(network: "Phone", password: nil)
        await backpack.removeSetup()
        #expect(!backpack.isOn)
        #expect(fake.lid.calls == [true, false])
        #expect(fake.installer.removes == 1)
        #expect(backpack.setup.missingSteps == [.sleepRule])
    }

    /// Location already refused: macOS will not ask again, so Allow… opens its pane in System
    /// Settings instead, and the controller is free again at once.
    @Test func allowOpensLocationSettingsWhenTheRequestCannotAsk() async {
        let fake = FakeBackpack()
        fake.location.authorized = false
        fake.location.grantsOnRequest = false
        let opened = Recorder()
        let backpack = controller(fake, openLocationSettings: { opened.lines.append("opened") })
        await backpack.setUp()
        #expect(opened.lines == ["opened"])
        #expect(!backpack.busy)
    }

    @Test func aFailedTurnOffSaysSoAndKeepsTrying() async {
        let fake = FakeBackpack(), toasts = Recorder()
        let backpack = controller(fake, toasts: toasts)
        await backpack.connect(network: "Phone", password: nil)
        fake.lid.succeeds = false
        await backpack.turnOff()
        #expect(!backpack.isOn)
        #expect(toasts.lines.last == "Couldn’t turn lid sleep back on: Shellforge keeps trying")
        #expect(fake.settings.engaged)
        fake.lid.succeeds = true
        await backpack.tick()
        #expect(!fake.settings.engaged)
    }

    /// Removing the rule while sleep is still disabled would leave nothing able to put it back.
    @Test func removeSetupRefusesWhileSleepIsStillDisabled() async {
        let fake = FakeBackpack(), toasts = Recorder()
        let backpack = controller(fake, toasts: toasts)
        await backpack.connect(network: "Phone", password: nil)
        fake.lid.succeeds = false
        await backpack.removeSetup()
        #expect(fake.installer.removes == 0)
        #expect(toasts.lines.last == "Couldn’t turn lid sleep back on: Shellforge keeps trying")
    }

    /// Quit does not sit behind a join that takes a minute: it closes the mode and turns off now.
    @Test func quitDoesNotWaitBehindASlowJoin() async {
        let fake = FakeBackpack()
        let release = DispatchSemaphore(value: 0), entered = Locked(false)
        fake.wifi.onJoin = { @Sendable in entered.withLock { $0 = true }; release.wait() }
        let backpack = controller(fake)
        let first = Task { await backpack.connect(network: "Phone", password: nil) }
        await eventually { entered.withLock { $0 } }
        let started = Date()
        backpack.shutdown()
        #expect(Date().timeIntervalSince(started) < 1)
        release.signal()
        await first.value
        #expect(!fake.lid.calls.contains(true))
        #expect(!backpack.isOn)
    }

    @Test func aSuccessfulTurnOnMarksSetupComplete() async {
        let fake = FakeBackpack()
        let backpack = controller(fake)
        #expect(!backpack.setup.isComplete)
        await backpack.connect(network: "Phone", password: nil)
        #expect(backpack.setup.isComplete)
    }

    /// At launch the header's menu must know setup is done, not wait for Settings to open.
    @Test func launchPutsSleepBackAndReadsSetup() async {
        let fake = FakeBackpack()
        fake.settings.engaged = true
        let backpack = controller(fake)
        await backpack.launch()
        #expect(fake.lid.calls == [false])
        #expect(backpack.setup.isComplete)
    }

    @Test func launchRecoveryClearsALeftoverMarker() {
        let fake = FakeBackpack()
        fake.settings.engaged = true
        controller(fake).recoverAtLaunch()
        #expect(fake.lid.calls == [false])
    }

    @Test func theInertControllerTouchesNothing() async {
        let backpack = BackpackController.inert()
        await backpack.connect(network: "Phone", password: nil)
        #expect(!backpack.isOn)
        #expect(await backpack.networksInRange().isEmpty)
        #expect(await backpack.savedPassword() == nil)
    }

    /// One scan, as names: the sheet lists them, nameless ones dropped.
    @Test func networksInRangeAreOneScansNames() async {
        let fake = FakeBackpack()
        fake.wifi.inRange = ["Home", "", "Phone"]
        let backpack = controller(fake)
        #expect(Set(await backpack.networksInRange()) == ["Home", "Phone"])
    }

    @Test func theSavedPasswordIsReadForTheSheet() async {
        let fake = FakeBackpack()
        fake.settings.password = "saved"
        #expect(await controller(fake).savedPassword() == "saved")
    }
}
