// Ported from AiTerm (app/Sources/AiTerm/Views/ToneDot.swift), GPLv3, Laurens D'Hondt.
import SwiftUI
import ShellforgeDesign

/// The three states every Settings card speaks, whether it describes a harness or a service, and
/// the footer's backpack line speaks too (proposal 2A, 6 Oct 2026): the Mac card says "Ready for
/// backpack mode" in this voice, so the footer says the mode is on in it.
enum SettingsTone: Equatable {
    case ready
    case attention
    case idle

    var color: Color {
        switch self {
        case .ready: Palette.green
        case .attention: Palette.amber
        case .idle: Palette.muted
        }
    }
}

/// A tone's dot, led into the words it colours: a Settings card's status line and the footer's
/// backpack line. Not a `StatusMark`, which is an agent's state: the two kinds of dot keep one
/// meaning each. `size` is points on screen — a card passes `Size.statusMarkSmall`, the footer
/// `scale(Size.statusMarkSmall)`.
struct ToneDot: View {
    let color: Color
    let size: CGFloat

    init(tone: SettingsTone, size: CGFloat) { color = tone.color; self.size = size }
    /// A tunnel row's state, which has a failure the three tones do not.
    init(color: Color, size: CGFloat) { self.color = color; self.size = size }

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}
