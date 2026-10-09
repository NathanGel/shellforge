// Ported from AiTerm (app/Sources/AiTerm/Views/StatusCountChips.swift), GPLv3, Laurens D'Hondt.
import SwiftUI
import ShellforgeDesign
import ShellforgeCore

/// The status counts a collapsed project header draws in place of the task rows it is hiding.
///
/// Same vocabulary as the rows themselves: `StatusMark`'s own glyph, at `Size.statusMarkSmall`, in
/// front of the number of tasks wearing it — a collapsed project should not need a second colour language to
/// say the same four things. The chips keep their intrinsic width, so the project name is what
/// gives way when the sidebar narrows, exactly as it does for the branch line's `+n`.
struct StatusCountChips: View {
    let counts: [StatusCount]
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        if !counts.isEmpty {
            HStack(spacing: scale(Space.tight)) {
                ForEach(counts, id: \.status) { StatusCountChip(count: $0) }
            }
            .fixedSize()
            .help(StatusCount.label(counts))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(StatusCount.label(counts))
        }
    }
}

/// One count. The wash carries the status, the ink is a lighter tone of it so the digit stays
/// legible at 10 pt, and the washes are the canvas' own values.
private struct StatusCountChip: View {
    let count: StatusCount
    @Environment(\.interfaceScale) private var scale

    private var ink: Color {
        switch count.status {
        case .idle: return Palette.muted
        // Brighter than idle: at 8 pt a spinner arc and a hollow ring are nearly the same shape,
        // so the ink is what separates "running" from "waiting for nobody".
        case .working: return Palette.text
        case .needsInput: return Palette.badgeAmber
        case .done: return Palette.link
        }
    }

    /// The chip's fill and edge, one `Palette` pair per status family.
    private var wash: (fill: Color, stroke: Color) {
        switch count.status {
        case .idle, .working: return (Palette.statusChipQuietFill, Palette.statusChipQuietStroke)
        case .needsInput: return (Palette.statusChipAttentionFill, Palette.statusChipAttentionStroke)
        case .done: return (Palette.statusChipDoneFill, Palette.statusChipDoneStroke)
        }
    }

    var body: some View {
        HStack(spacing: scale(Space.tight)) {
            StatusMark(status: count.status, size: scale(Size.statusMarkSmall))
            Text("\(count.count)")
                .font(Typography.monoChip)
                .foregroundStyle(ink)
        }
        .padding(.horizontal, scale(Space.tight))
        .frame(height: scale(Size.chip))
        .background(RoundedRectangle(cornerRadius: scale(Radius.chip)).fill(wash.fill))
        .overlay(RoundedRectangle(cornerRadius: scale(Radius.chip)).strokeBorder(wash.stroke, lineWidth: 1))
    }
}
