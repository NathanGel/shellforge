// Ported from AiTerm (app/Sources/AiTerm/Views/AvatarGroupView.swift), GPLv3, Laurens D'Hondt.
import SwiftUI
import ShellforgeDesign
import ShellforgeCore

/// Nuxt-UI style avatar group at the project tile's size: 18 px marks, 5 px overlap, a ring in the
/// row's own background colour so the circles read as stacked, and "+n" in the last slot once
/// there are more sessions than fit (design canvas, 17 Sep 2026).
struct AvatarGroupView: View {
    /// How far each mark overlaps the one before it, so the group reads as a stack rather than a row.
    private static let overlap: CGFloat = -5
    /// The occluding ring every mark and the `+n` slot draw around themselves. A stroke, so it does
    /// not scale.
    private static let ringWidth: CGFloat = 2
    @Environment(\.interfaceScale) private var scale
    private var size: CGFloat { scale(Size.avatar) }
    /// The group's fixed width: two stacked marks, which is all `SidebarModel.avatarMax` lets a row
    /// draw. A group with one mark still takes this width, so every row's title starts at the same x.
    private var columnWidth: CGFloat { size * 2 + scale(Self.overlap) }
    let group: AvatarGroup
    /// Replaces the `ring: Color` this view used to take. The ring is painted *over* the avatar
    /// behind it, so it needs `Surface.occludingBackground` — an opaque colour — rather than a
    /// wash, which would let the stacked mark show through.
    @Environment(\.surface) private var surface
    var body: some View {
        HStack(spacing: scale(Self.overlap)) {
            ForEach(Array(group.marks.enumerated()), id: \.offset) { _, agent in
                VendorMark(agent: agent, size: size).overlay(Circle().stroke(surface.occludingBackground, lineWidth: Self.ringWidth))
            }
            if group.overflow > 0 {
                ZStack { Circle().fill(Palette.controlActive); Text("+\(group.overflow)").font(Typography.micro).foregroundStyle(Palette.text) }
                    .frame(width: size, height: size).overlay(Circle().stroke(surface.occludingBackground, lineWidth: Self.ringWidth))
            }
        }
        .frame(width: columnWidth, alignment: .leading)
    }
}
