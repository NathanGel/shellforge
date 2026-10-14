// Ported from AiTerm (app/Sources/AiTermUI/Surface.swift), GPLv3, Laurens D'Hondt.
import SwiftUI

/// The ground a component is drawn on. A component reads this from the environment instead of
/// taking a `selected` flag, so a badge inside a selected sidebar row turns white by itself.
///
/// This replaces the `onSelection: Bool` that `EditorBadge`, `JiraChip`, `BranchLabelView` and
/// `StatusMark` each took and each re-derived the same colours from.
public enum Surface: Equatable, Sendable {
    /// The sidebar's own background, and any row at rest.
    case sidebar
    /// A hovered row: the sidebar plus a white wash.
    case hover
    /// A selected row. Everything on it turns white.
    case accent
    /// A selected row while its window is not active: macOS's unemphasized grey selection, on which
    /// everything keeps the sidebar's own ink.
    case inactiveSelection
    /// A sheet or any other surface away from the sidebar. The default.
    case sheet

    public var isOnAccent: Bool { self == .accent }

    public var ink: Color { isOnAccent ? Palette.onAccent : Palette.text }
    public var secondaryInk: Color { isOnAccent ? Palette.onAccentSecondary : Palette.muted }
    public var badgeWash: Color { isOnAccent ? Palette.badgeSelected : Palette.badge }
    public var badgeWashHovered: Color { isOnAccent ? Palette.badgeSelectedHovered : Palette.badgeHovered }

    /// The surface's own colour, opaque. A ring or divider painted *over* content needs this rather
    /// than a wash: `AvatarGroupView`'s ring has to occlude the avatar behind it, and a translucent
    /// colour lets the stacked marks show through.
    public var occludingBackground: Color {
        switch self {
        case .sidebar: Palette.sidebar
        case .hover: Palette.rowHoverSolid
        case .accent: Palette.selection
        case .inactiveSelection: Palette.controlActive
        case .sheet: Palette.surface
        }
    }
}

private struct SurfaceKey: EnvironmentKey {
    static let defaultValue: Surface = .sheet
}

public extension EnvironmentValues {
    var surface: Surface {
        get { self[SurfaceKey.self] }
        set { self[SurfaceKey.self] = newValue }
    }
}

public extension View {
    /// Declares the ground everything inside is drawn on.
    func surface(_ surface: Surface) -> some View {
        environment(\.surface, surface)
    }
}
