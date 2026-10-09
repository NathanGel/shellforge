// Ported from AiTerm (app/Sources/AiTerm/AppController.swift, `toggleBackpack`), GPLv3, Laurens D'Hondt.
import Foundation

/// AiTerm's `toggleBackpack`, shared by the View menu's ⌘B and the footer's click on the Mac row:
/// ignored while a turn-on, turn-off or setup runs; on, it turns the mode off; otherwise it opens
/// the Backpack sheet.
@MainActor
public struct BackpackToggle {
    public let backpack: BackpackController
    public let presentSheet: @MainActor () -> Void

    public init(backpack: BackpackController, presentSheet: @escaping @MainActor () -> Void) {
        self.backpack = backpack
        self.presentSheet = presentSheet
    }

    public func run() {
        guard !backpack.busy, backpack.transition == nil else { return }
        if backpack.isOn { Task { await backpack.turnOff() } } else { presentSheet() }
    }
}
