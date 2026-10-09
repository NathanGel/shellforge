// Ported from AiTerm (app/Sources/AiTerm/Views/MacSettingsCard.swift), GPLv3, Laurens D'Hondt.
import SwiftUI
import ShellforgeCore
import ShellforgeDesign

/// The Mac card's words, decided apart from the view so a test reads them.
enum MacCardPresentation {
    static func status(_ setup: BackpackSetup) -> SettingsStatus {
        switch (setup.sleepRule, setup.location) {
        case (true, true): SettingsStatus(.ready, "Ready for backpack mode")
        case (false, true): SettingsStatus(.attention, "Backpack mode needs lid sleep")
        case (true, false): SettingsStatus(.attention, "Backpack mode needs network discovery")
        case (false, false): SettingsStatus(.attention, "Backpack mode needs lid sleep and network discovery")
        }
    }

    /// `NumberedSteps` for what is missing, in the order Allow… asks for them.
    static func steps(_ setup: BackpackSetup) -> [String] {
        setup.missingSteps.map {
            switch $0 {
            case .sleepRule: "Allow Shellforge to keep the Mac awake with the lid closed. macOS asks for your password once."
            case .location: "Allow Shellforge to see nearby Wi-Fi networks. macOS hides their names from apps without Location access."
            }
        }
    }

    static let summary = "Backpack mode keeps the Mac awake with the lid closed and finds your iPhone’s hotspot. Shellforge never reads where you are. Remove takes the lid-sleep rule out again."

    /// Under the permission rows the Backpack sheet shows when one is missing.
    static let alsoInSettings = "Also in Mac Settings…: right-click the Mac row at the foot of the sidebar."
}

/// Integrations › Core's second card: what Backpack Mode needs from this Mac. A harness card's
/// anatomy — check chips, one action named by its state, the steps while something is missing.
/// Allow… and Remove act at once, as a harness card's Install does; the card has no fields.
struct MacSettingsCard: View {
    let backpack: BackpackController

    var body: some View {
        let setup = backpack.setup
        SettingsCard(title: "Mac", status: MacCardPresentation.status(setup)) {
            SymbolMark(symbol: "macbook", size: Size.control, style: .paper)
        } chips: {
            check("Lid sleep", passed: setup.sleepRule)
            check("Network discovery", passed: setup.location)
        } actions: {
            if backpack.busy { ProgressView().controlSize(.small) }
            if setup.missingSteps.isEmpty {
                Button("Remove") { Task { await backpack.removeSetup() } }.disabled(backpack.busy)
            } else {
                Button("Allow…") { Task { await backpack.setUp() } }.disabled(backpack.busy)
            }
        } content: {
            let steps = MacCardPresentation.steps(setup)
            if steps.isEmpty { HelpText(MacCardPresentation.summary) } else { NumberedSteps(steps) }
        }
    }

    /// A harness card's check chip.
    private func check(_ label: String, passed: Bool) -> some View {
        Badge(label, icon: .symbol(passed ? "checkmark" : "exclamationmark"), iconTint: passed ? Palette.green : Palette.amber)
    }
}
