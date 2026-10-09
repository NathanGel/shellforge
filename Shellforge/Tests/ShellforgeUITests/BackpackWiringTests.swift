import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

/// Backpack Mode as Shellforge drives it: the footer's click and ⌘B are one rule (AiTerm's
/// `toggleBackpack`), and quitting gives the Mac its lid sleep back.
@MainActor @Suite(.serialized) struct BackpackWiringTests {
    private func controller(_ fake: FakeBackpack) -> BackpackController {
        BackpackController(ports: fake.ports, settings: fake.settings, tickInterval: .seconds(3600),
                           retryDelays: [.milliseconds(10)], toast: { _ in })
    }

    /// Off → the sheet; on → off; nothing while switching.
    @Test func theFooterClickIsCommandB() async {
        let fake = FakeBackpack()
        let backpack = controller(fake)
        final class Count { var sheets = 0 }
        let count = Count()
        let toggle = BackpackToggle(backpack: backpack, presentSheet: { count.sheets += 1 })
        toggle.run()
        #expect(count.sheets == 1)
        await backpack.connect(network: "Phone", password: nil)
        #expect(backpack.isOn)
        toggle.run()
        await eventually { !backpack.isOn && !backpack.busy }
        #expect(count.sheets == 1, "on, the click turns it off rather than opening the sheet")
        backpack.preview(state: .off, setup: backpack.setup, transition: .turningOn)
        toggle.run()
        #expect(count.sheets == 1, "switching ignores the click")
    }

    /// Quitting with the mode on turns lid sleep back on before the app goes.
    @Test func quittingTurnsBackpackModeOff() async {
        let fake = FakeBackpack()
        let backpack = controller(fake)
        await backpack.connect(network: "Phone", password: nil)
        #expect(fake.lid.calls.last == true, "on: lid sleep disabled")
        backpack.shutdown()
        #expect(fake.lid.calls.last == false, "quit: lid sleep back on")
    }
}
