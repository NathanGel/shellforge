// Ported from AiTerm (app/Sources/AiTermUI/InterfaceScale.swift), GPLv3, Laurens D'Hondt.
import SwiftUI

/// How much larger than Apple's own sizes a surface is drawn: the one knob someone on a large
/// display turns so the sidebar reads at arm's length.
///
/// A number from `Metrics` is a size at ×1. It becomes points on screen where a view reads it:
/// through `scale(token)` for `Space`, `Radius` and `Size`, and automatically for `Typography`,
/// because `View.font(TypeStyle)` reads this from the environment. Strokes (hairlines, borders,
/// outline rings, the focus ring) are not sizes and do not scale.
///
/// Read from the environment, like `Surface`, so a subtree can be drawn at a different scale from
/// its parent. The sidebar is scaled; every sheet resets to `.standard`, because AppKit's own
/// pop-up and push-button bezels stop at 28 pt (`.extraLarge` draws the `.large` bezel on
/// macOS 26) and could not grow with the fields beside them.
public struct InterfaceScale: Equatable, Sendable {
    public let factor: CGFloat

    private init(factor: CGFloat) { self.factor = factor }

    /// Apple's sizes. `callAsFunction` is the identity here, so ×1 draws what it always drew.
    public static let standard = InterfaceScale(factor: 1)
    /// Body text at 15 pt instead of 13: Apple's own next step up.
    public static let large = InterfaceScale(factor: 1.15)
    /// Body text at 17 pt.
    public static let extraLarge = InterfaceScale(factor: 1.3)
    /// In order, smallest first.
    public static let all = [standard, large, extraLarge]

    /// A `Space`, `Radius` or `Size` token at this scale, on whole points so a 1x display still
    /// draws every edge on a pixel. At ×1 the input comes back untouched, fractions included.
    public func callAsFunction(_ points: CGFloat) -> CGFloat {
        factor == 1 ? points : (points * factor).rounded()
    }
}

private struct InterfaceScaleKey: EnvironmentKey {
    static let defaultValue = InterfaceScale.standard
}

public extension EnvironmentValues {
    var interfaceScale: InterfaceScale {
        get { self[InterfaceScaleKey.self] }
        set { self[InterfaceScaleKey.self] = newValue }
    }
}

public extension View {
    /// Draws everything inside at `scale`.
    func interfaceScale(_ scale: InterfaceScale) -> some View {
        environment(\.interfaceScale, scale)
    }
}
