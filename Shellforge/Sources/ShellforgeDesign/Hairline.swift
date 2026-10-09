// Ported from AiTerm (app/Sources/AiTermUI/Hairline.swift), GPLv3, Laurens D'Hondt.
import SwiftUI

/// The one 1 pt rule: `Palette.border` on a filled rectangle, the same stroke as every control's
/// outline. The sidebar's rules (either side of a `DividerRow`'s name, the sidebar footer's scroll edge), the
/// step bar's connectors and a sheet's section breaks — its header's and footer's edges, under a
/// Settings card's header, between the Interface tab's rows — all draw it.
///
/// A rectangle, not SwiftUI's `Divider`, so it stays horizontal inside an `HStack`, where `Divider`
/// turns vertical. The sheets used to lay `Divider` under the border, which read a third brighter
/// than this; that second weight was folded into this one. A stroke, so it does not scale.
public struct Hairline: View {
    public init() {}

    public var body: some View {
        Rectangle().fill(Palette.border).frame(height: 1)
    }
}
