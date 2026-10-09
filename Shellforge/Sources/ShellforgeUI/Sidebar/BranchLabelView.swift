// Ported from AiTerm (app/Sources/AiTerm/Views/BranchLabelView.swift), GPLv3, Laurens D'Hondt.
import SwiftUI
import ShellforgeDesign
import ShellforgeCore

/// The branch line of a sidebar row: the branch of the tab you are looking at, plus a `+n` chip
/// when the same window has other branches open (design canvas, "Branch awareness · 17 Sep",
/// option A).
///
/// The name is the only thing allowed to truncate. The chip carries the fact that there is more to
/// see, so it keeps its intrinsic width however narrow the row gets — `fixedSize` plus the higher
/// layout priority is what makes SwiftUI shorten the name instead of the chip. Amber means the
/// agent is not on the branch the row is bound to; the tooltip then names both.
struct BranchLabelView: View {
    let label: BranchLabel
    /// Replaces the `onSelection: Bool` this view used to take. `Surface.secondaryInk` is exactly
    /// the resting/selected pair (`Palette.muted` / `Palette.onAccentSecondary`) the drift-free
    /// branch name used, computed by hand, below.
    @Environment(\.surface) private var surface
    @Environment(\.interfaceScale) private var scale

    private var nameColor: Color {
        if label.drifted { return Palette.amber }
        return surface.secondaryInk
    }

    var body: some View {
        if !label.name.isEmpty {
            HStack(spacing: scale(Space.snug)) {
                Text(label.name)
                    .font(Typography.mono)
                    .foregroundStyle(nameColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(0)
                if label.extra > 0 {
                    Badge("+\(label.extra)")
                        .fixedSize()
                        .layoutPriority(1)
                }
            }
            .help(label.detail.isEmpty ? label.name : label.detail)
        }
    }
}
