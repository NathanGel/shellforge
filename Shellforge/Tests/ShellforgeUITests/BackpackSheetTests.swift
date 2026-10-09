// Ported from AiTerm (app/Tests/AiTermTests/BackpackSheetTests.swift), GPLv3, Laurens D'Hondt.
import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

@MainActor
@Suite(.serialized) struct BackpackSheetTests {
    private func backpack(_ fake: FakeBackpack, retryDelays: [Duration] = [.milliseconds(10)]) -> BackpackController {
        BackpackController(ports: fake.ports, settings: fake.settings, tickInterval: .seconds(3600),
                           retryDelays: retryDelays, toast: { _ in })
    }

    /// Spins the main actor until `condition` holds or `timeout` passes; whether it held.
    private func until(_ timeout: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { await Task.yield() }
        return condition()
    }

    @Test func itOpensOnTheRememberedHotspotWithItsPasswordFilledIn() async {
        let fake = FakeBackpack()
        fake.settings.password = "saved"
        let model = BackpackSheetModel(backpack: backpack(fake))
        await model.load()
        #expect(!model.isConnecting && !model.started)
        #expect(model.network == "Phone")
        #expect(model.password == "saved", "filled in as if typed: the field shows its dots")
        #expect(model.choices == [nil, "Phone", "Home"], "the remembered one first, then the rest in range")
        #expect(model.hotspotHelp == BackpackSheetPresentation.remembered)
    }

    /// Only what one scan finds now: a network the Mac knows but cannot see is not offered, and
    /// neither is a nameless one.
    @Test func onlyNetworksInRangeAreOffered() async {
        let fake = FakeBackpack()
        fake.wifi.known = ["Office", "Home", "Phone"]
        fake.wifi.inRange = ["Home", "Café", ""]
        let model = BackpackSheetModel(backpack: backpack(fake))
        await model.load()
        #expect(model.choices == [nil, "Café", "Home"])
        #expect(model.network == nil, "the remembered hotspot is not showing: nothing is chosen")
        #expect(model.password.isEmpty)
        #expect(model.hotspotHelp == BackpackSheetPresentation.looking)
        #expect(!model.canConnect)
    }

    /// The iPhone shows its hotspot only while Personal Hotspot is open: when it turns up on a later
    /// scan, it is chosen, and its password filled in.
    @Test func theRememberedHotspotIsChosenOnceItShowsUp() async {
        let fake = FakeBackpack()
        fake.settings.password = "saved"
        fake.wifi.inRange = ["Home"]
        let model = BackpackSheetModel(backpack: backpack(fake))
        await model.load()
        #expect(model.network == nil)
        fake.wifi.inRange = ["Home", "Phone"]
        await model.refreshNetworks()
        #expect(model.network == "Phone")
        #expect(model.password == "saved")
    }

    /// A scan never overrides a choice the person made.
    @Test func aRefreshKeepsTheChosenHotspot() async {
        let fake = FakeBackpack()
        fake.wifi.inRange = ["Home"]
        let model = BackpackSheetModel(backpack: backpack(fake))
        await model.load()
        model.choose("Home")
        fake.wifi.inRange = ["Home", "Phone"]
        await model.refreshNetworks()
        #expect(model.network == "Home")
    }

    /// A choice that drops out of range stays chosen, and listed, rather than vanishing from the menu.
    @Test func aChosenHotspotOutOfRangeStaysListed() async {
        let fake = FakeBackpack()
        let model = BackpackSheetModel(backpack: backpack(fake))
        await model.load()
        fake.wifi.inRange = ["Home"]
        await model.refreshNetworks()
        #expect(model.network == "Phone")
        #expect(model.choices == [nil, "Phone", "Home"])
    }

    /// The one saved password belongs to the remembered hotspot: another hotspot starts empty, and
    /// going back fills it in again.
    @Test func choosingAnotherHotspotEmptiesThePasswordAndBackRefillsIt() async {
        let fake = FakeBackpack()
        fake.settings.password = "saved"
        let model = BackpackSheetModel(backpack: backpack(fake))
        await model.load()
        model.choose("Home")
        #expect(model.password.isEmpty)
        #expect(model.hotspotHelp == BackpackSheetPresentation.newHotspot)
        model.choose("Phone")
        #expect(model.password == "saved")
        model.choose(nil)
        #expect(model.password.isEmpty)
        #expect(model.hotspotHelp == BackpackSheetPresentation.looking)
    }

    /// Nothing remembered and nothing in range — Connect waits for a hotspot, and
    /// shows it is looking.
    @Test func connectWaitsForAHotspot() async {
        let fake = FakeBackpack()
        fake.settings.network = nil
        fake.wifi.inRange = []
        let model = BackpackSheetModel(backpack: backpack(fake))
        await model.load()
        #expect(model.choices == [nil])
        #expect(!model.canConnect)
        #expect(model.hotspotHelp == "Looking for hotspots…")
        model.connect()
        #expect(!model.started && !model.isConnecting)
        #expect(model.isLooking, "the help line spins while a scan finds nothing")
    }

    @Test func connectWaitsForBothPermissions() async {
        let fake = FakeBackpack()
        fake.lid.allowed = false
        let model = BackpackSheetModel(backpack: backpack(fake))
        await model.load()
        #expect(!model.canConnect)
        fake.lid.allowed = true
        await model.backpack.refreshSetup()
        #expect(model.canConnect)
    }

    /// One sheet: Connect runs in place — the fields hold still and no second Connect is offered —
    /// and it ends safe.
    @Test func connectRunsInPlaceAndEndsSafe() async {
        let fake = FakeBackpack()
        let model = BackpackSheetModel(backpack: backpack(fake))
        await model.load()
        model.connect()
        #expect(model.started && model.isConnecting)
        #expect(!model.canConnect, "the fields hold still while it connects")
        #expect(await until { model.backpack.phase == .safe })
        #expect(model.backpack.isOn)
        #expect(model.isSafe && !model.isConnecting)
    }

    /// No Back: a failure leaves the fields live, the person fixes the password, and Connect retries.
    @Test func aFailureLeavesTheFieldsLiveAndConnectRetries() async {
        let fake = FakeBackpack()
        fake.wifi.joinSucceeds = false   // in range: a password problem
        let model = BackpackSheetModel(backpack: backpack(fake))
        await model.load()
        model.connect()
        #expect(await until { model.backpack.phase == .failed(.joinFailed(network: "Phone")) && !model.isConnecting })
        #expect(model.canConnect)
        fake.wifi.joinSucceeds = true
        model.password = "right"
        model.connect()
        #expect(await until { model.backpack.phase == .safe })
        #expect(fake.wifi.passwords.last == "right")
    }

    /// Option B's order: the hotspot leads, and the iPhone's steps under it are its help — in full
    /// while nothing is chosen, receding once a hotspot is.
    @Test func theIPhoneStepsRecedeOnceAHotspotIsChosen() async {
        let fake = FakeBackpack()
        fake.wifi.inRange = []
        let model = BackpackSheetModel(backpack: backpack(fake))
        await model.load()
        #expect(!model.phoneStepsRecede)
        fake.wifi.inRange = ["Phone"]
        await model.refreshNetworks()
        #expect(model.phoneStepsRecede)
        #expect(!model.isLooking)
    }

    @Test func theSheetSaysWhatItDoes() {
        #expect(BackpackSheetPresentation.subtitle == "Keeps your agents working with the lid closed, online through your iPhone.")
        #expect(BackpackSheetPresentation.thisMac == "This Mac")
        #expect(BackpackSheetPresentation.onTheIPhone == "On the iPhone")
        #expect(BackpackSheetPresentation.looking == "Looking for hotspots…")
    }

    @Test func theChecksFollowThePhase() {
        let phone = "Laurens’s iPhone"
        func checks(_ phase: ConnectPhase?) -> [ConnectCheck] { BackpackSheetPresentation.checks(phase: phase, hotspot: phone) }
        #expect(checks(.joining) == [ConnectCheck(text: "Joining Laurens’s iPhone…", mark: .working, warns: false),
                                     ConnectCheck(text: "Keeping the Mac awake", mark: .idle, warns: false)])
        #expect(checks(.notInRange)[0] == ConnectCheck(text: "Laurens’s iPhone isn’t showing its hotspot yet", mark: .working, warns: true))
        #expect(checks(.keepingAwake) == [ConnectCheck(text: "Joined Laurens’s iPhone", mark: .done, warns: false),
                                          ConnectCheck(text: "Keeping the Mac awake…", mark: .working, warns: false)])
        #expect(checks(.safe).allSatisfy { $0.mark == .done && !$0.warns })
        #expect(checks(.failed(.joinFailed(network: phone)))[0]
                == ConnectCheck(text: "Couldn’t join Laurens’s iPhone: check its password", mark: .idle, warns: true))
        #expect(checks(.failed(.batteryLow(level: 8)))[0]
                == ConnectCheck(text: "Battery at 8 %: backpack mode stays off", mark: .idle, warns: true))
        #expect(checks(.keychainRefused)[0]
                == ConnectCheck(text: "Couldn’t save the hotspot password in Keychain", mark: .idle, warns: true))
    }

    @Test func theSafeStateSaysWhatHappensNext() {
        #expect(BackpackSheetPresentation.safeHelp(hotspot: "Laurens’s iPhone")
                == "On Laurens’s iPhone. Backpack mode ends when your agents stop, or at 10 % battery.")
        #expect(BackpackSheetPresentation.title == "Backpack mode")
        #expect(BackpackSheetPresentation.subtitle.hasSuffix("through your iPhone."))
    }

    @Test func theChoicesPutTheRememberedHotspotFirstAndSortTheRest() {
        #expect(BackpackSheetPresentation.choices(inRange: ["home", "Café", "Phone"], remembered: "Phone", chosen: nil)
                == [nil, "Phone", "Café", "home"])
        #expect(BackpackSheetPresentation.choices(inRange: ["Home"], remembered: "Phone", chosen: nil) == [nil, "Home"])
        #expect(BackpackSheetPresentation.choices(inRange: ["Home"], remembered: "Phone", chosen: "Phone") == [nil, "Phone", "Home"])
        #expect(BackpackSheetPresentation.choices(inRange: ["", "Home", "Home"], remembered: nil, chosen: nil) == [nil, "Home"])
    }

    @Test func cancelLeavesAMacAlreadyOnTheHotspotThere() async {
        let fake = FakeBackpack()
        fake.wifi.current = "Phone"
        let model = BackpackSheetModel(backpack: backpack(fake))
        await model.load()
        await model.cancel().value
        #expect(fake.wifi.joins.isEmpty)
        #expect(fake.wifi.current == "Phone")
        #expect(fake.lid.calls.isEmpty)
    }

    /// A refusal before any join — the battery — then Cancel: still on the hotspot it started on.
    @Test func cancelAfterABatteryRefusalLeavesAMacAlreadyOnTheHotspotThere() async {
        let fake = FakeBackpack()
        fake.wifi.current = "Phone"
        fake.power.value = PowerReading(level: 8, onBattery: true)
        let model = BackpackSheetModel(backpack: backpack(fake))
        await model.load()
        model.connect()
        await eventually { model.backpack.phase == .failed(.batteryLow(level: 8)) }
        await model.cancel().value
        #expect(fake.wifi.joins.isEmpty)
        #expect(fake.wifi.current == "Phone")
        #expect(model.backpack.phase == nil)
    }

    /// The sheet is over — it closes — once a connect it started has left the mode off with nothing
    /// running: turned off under the sheet, or ended by itself. Not before Connect, and not in the
    /// turn between Connect and the connect starting.
    @Test func theSheetIsOverOnceItsModeIsOffAndIdle() async {
        let fake = FakeBackpack()
        let model = BackpackSheetModel(backpack: backpack(fake))
        await model.load()
        #expect(!model.isOver, "nothing started: never over")
        model.connect()
        #expect(!model.isOver, "the connect has not started yet")
        await eventually { model.backpack.phase == .safe }
        #expect(!model.isOver)
        await model.backpack.turnOff()
        await eventually { !model.backpack.busy }
        #expect(model.isOver)
    }

    // -- the lid closing under the sheet ------------------------------------------------

    /// Before Connect: a lid close is a Cancel, and nothing was changed to put back.
    @Test func aLidCloseBeforeConnectCancels() async {
        let fake = FakeBackpack()
        let model = BackpackSheetModel(backpack: backpack(fake))
        await model.load()
        await model.lidClosed()?.value
        #expect(!model.backpack.busy && !model.backpack.isOn)
        #expect(model.backpack.phase == nil)
        #expect(fake.wifi.joins.isEmpty)
        #expect(fake.wifi.current == "Home")
        #expect(fake.lid.calls.isEmpty)
    }

    /// After a failure, with nothing running: a lid close is a Cancel too, so a failed join that
    /// left the Mac on no network puts it back on a preferred one.
    @Test func aLidCloseAfterAFailureCancelsAndPutsTheWiFiBack() async {
        let fake = FakeBackpack()
        fake.wifi.known = ["Home", "Phone"]
        fake.wifi.joinSucceeds = false
        let model = BackpackSheetModel(backpack: backpack(fake))
        await model.load()
        model.connect()
        #expect(await until { model.backpack.phase == .failed(.joinFailed(network: "Phone")) && !model.isConnecting })
        #expect(fake.wifi.current == nil, "the failed associate dropped Home")
        fake.wifi.joinSucceeds = true
        await model.lidClosed()?.value
        #expect(await until { !model.backpack.busy })
        #expect(fake.wifi.current == "Home")
        #expect(fake.lid.calls.isEmpty)
    }

    /// Connecting, waiting for a hotspot that isn't showing: with the sheet gone nobody is left to
    /// Cancel, so the wait stops at once — not after its 5 s — and the undo puts the Wi-Fi back.
    @Test func aLidCloseWhileWaitingForTheHotspotStopsTheRetries() async {
        let fake = FakeBackpack()
        fake.wifi.inRange = ["Home"]
        fake.wifi.failingJoins = ["Phone"]
        let model = BackpackSheetModel(backpack: backpack(fake, retryDelays: [.seconds(5)]))
        await model.load()
        // Seen when it was chosen; out of range since.
        model.choose("Phone")
        model.connect()
        #expect(await until { model.backpack.phase == .notInRange })
        model.lidClosed()
        #expect(await until(1) { !model.backpack.busy }, "stopped at once, not after the retry's wait")
        let joins = fake.wifi.joins
        try? await Task.sleep(for: .milliseconds(50))
        #expect(fake.wifi.joins == joins, "no further joins")
        #expect(joins == ["Phone", "Home"], "one try at the hotspot, then the undo's rejoin")
        #expect(!fake.lid.calls.contains(true), "sleep untouched")
        #expect(!model.backpack.isOn)
        #expect(model.backpack.phase == nil)
        #expect(fake.wifi.current == "Home")
    }

    /// Connecting, a join in flight that then finds no hotspot: no retry follows it.
    @Test func aLidCloseDuringAJoinThatMissesTheHotspotRetriesNoMore() async {
        let fake = FakeBackpack()
        fake.wifi.inRange = ["Home"]
        fake.wifi.failingJoins = ["Phone"]
        let release = DispatchSemaphore(value: 0), entered = Locked(false)
        // Holds the connect's first join only.
        fake.wifi.onJoin = { @Sendable in if entered.withLock({ let first = !$0; $0 = true; return first }) { release.wait() } }
        let model = BackpackSheetModel(backpack: backpack(fake))
        await model.load()
        // Seen when it was chosen; out of range since.
        model.choose("Phone")
        model.connect()
        #expect(await until { entered.withLock { $0 } })
        model.lidClosed()
        release.signal()
        #expect(await until { !model.backpack.busy })
        let joins = fake.wifi.joins
        try? await Task.sleep(for: .milliseconds(50))
        #expect(fake.wifi.joins == joins, "no further joins")
        #expect(joins.filter { $0 == "Phone" }.count == 1)
        #expect(!fake.lid.calls.contains(true), "sleep untouched")
        #expect(!model.backpack.isOn)
    }

    /// Connecting, a join that succeeds while the lid closes: a turn-on in progress keeps going.
    @Test func aLidCloseDuringASucceedingJoinStillEndsSafe() async {
        let fake = FakeBackpack()
        let release = DispatchSemaphore(value: 0)
        fake.lid.onSet = { @Sendable in if $0 { release.wait() } }
        let model = BackpackSheetModel(backpack: backpack(fake))
        await model.load()
        model.connect()
        #expect(await until { model.backpack.phase == .keepingAwake })
        model.lidClosed()
        release.signal()
        #expect(await until { model.backpack.phase == .safe })
        #expect(model.backpack.isOn)
        #expect(!model.backpack.busy)
        #expect(fake.lid.calls == [true])
    }

    @Test func aFailedConnectIsNotOver() async {
        let fake = FakeBackpack()
        fake.wifi.joinSucceeds = false
        let model = BackpackSheetModel(backpack: backpack(fake))
        await model.load()
        model.connect()
        await eventually { model.backpack.phase == .failed(.joinFailed(network: "Phone")) }
        await eventually { !model.backpack.busy }
        #expect(!model.isOver, "the fields and Connect stay for a failure")
    }
}
