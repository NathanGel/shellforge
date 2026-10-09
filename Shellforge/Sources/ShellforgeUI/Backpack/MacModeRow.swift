// Ported from AiTerm (app/Sources/AiTerm/Views/MacModeRow.swift), GPLv3, Laurens D'Hondt.
import SwiftUI
import ShellforgeCore
import ShellforgeDesign

/// What Backpack Mode needs from you while it is on. The cutoff wins over a lost hotspot: it is the
/// one that will turn the mode off.
enum BackpackNeed: Equatable { case lostHotspot, lowBattery(level: Int) }

/// The Mac's mode in SYSTEM, decided apart from the view so a test reads it (spec 2026-10-05;
/// proposal 2A and 3A, 6 Oct 2026). At the desk it draws no line of its own — the Mac's readings
/// row is its row — and in the backpack a `ToneDot` and its words.
enum MacMode: Equatable {
    case desk
    case turningOn, on, needsYou(BackpackNeed), turningOff

    init(state: BackpackState, transition: BackpackTransition?) {
        switch transition {
        case .turningOn: self = .turningOn
        case .turningOff: self = .turningOff
        case nil:
            guard case .on(let status) = state else { self = .desk; return }
            if status.nearCutoff, let level = status.power.level { self = .needsYou(.lowBattery(level: level)) }
            else if !status.joined { self = .needsYou(.lostHotspot) }
            else { self = .on }
        }
    }

    /// The backpack line's words; nil at the desk, which draws no line.
    var words: String? {
        switch self {
        case .desk: nil
        case .turningOn: "backpack turning on…"
        case .on: "backpack enabled"
        case .needsYou: "backpack needs you"
        case .turningOff: "backpack turning off…"
        }
    }

    /// The line's colour, its dot's and its words': ready while on, attention when it needs you,
    /// idle while it switches. Nil at the desk.
    var tone: SettingsTone? {
        switch self {
        case .desk: nil
        case .turningOn, .turningOff: .idle
        case .on: .ready
        case .needsYou: .attention
        }
    }
}

/// One drawn line: the mode, and the tooltip and VoiceOver sentence.
struct MacModeLine: Equatable {
    let mode: MacMode
    let help: String
}

enum MacModePresentation {
    static func line(mode: MacMode, hotspot: String?, wifi: String?) -> MacModeLine {
        let phone = hotspot ?? "the iPhone"
        let cutoff = BackpackSettings.cutoff
        switch mode {
        case .desk:
            let on = wifi.map { $0 == hotspot ? " · still on \($0)" : " · \($0)" } ?? ""
            return MacModeLine(mode: mode, help: "desk mode\(on) · ⌘B turns on backpack mode")
        case .turningOn:
            return MacModeLine(mode: mode, help: "Turning on backpack mode · joining \(phone)")
        case .on:
            return MacModeLine(mode: mode, help: "Backpack mode on · \(phone) · ends when your agents stop, or at \(cutoff) %")
        case .needsYou(.lostHotspot):
            return MacModeLine(mode: mode, help: "Backpack mode needs you · lost \(phone), open Personal Hotspot on the iPhone")
        case .needsYou(.lowBattery(let level)):
            return MacModeLine(mode: mode, help: "Backpack mode needs you · battery at \(level) %, turns off at \(cutoff) %")
        case .turningOff:
            return MacModeLine(mode: mode, help: "Turning off backpack mode · rejoining Wi-Fi")
        }
    }
}
