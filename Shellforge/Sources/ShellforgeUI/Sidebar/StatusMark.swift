// Ported from AiTerm (app/Sources/AiTerm/Views/StatusMark.swift), GPLv3, Laurens D'Hondt.
import SwiftUI
import ShellforgeDesign
import ShellforgeCore

struct StatusMark: View {
    let status: SessionState
    /// The mark's diameter in points: a row passes its trailing column's glyph,
    /// `scale(Size.trailingGlyph)` (which `Size.statusMark` aliases); the collapsed project header's
    /// count chips pass `scale(Size.statusMarkSmall)`. Every measurement below is a fraction of it,
    /// and at 10 they are the values this view was written with.
    let size: CGFloat
    /// Replaces the `onSelection: Bool` this view used to take: a selected row's surface is
    /// `.accent`, and `isOnAccent` is exactly the condition the mark used to be handed directly.
    @Environment(\.surface) private var surface
    /// The one continuous animation in the app, so the one that has to answer Reduce Motion. The
    /// design canvas has honoured it since the first artboard; the app never did.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    fileprivate static let spinDuration = 1.1

    /// Derive rotation from a shared clock instead of view lifetime. A row can disappear when its
    /// project collapses, or briefly leave `.working` when an agent reports done before resuming.
    /// Returning at the clock's current phase keeps the arc continuous in both cases.
    static func spinnerRotation(at date: Date) -> Double {
        let elapsed = date.timeIntervalSinceReferenceDate
        return elapsed.truncatingRemainder(dividingBy: spinDuration) / spinDuration * 360
    }

    var body: some View {
        ZStack {
            switch status {
            case .idle: Circle().strokeBorder(Palette.idleRing, lineWidth: size * 0.15)
            case .working:
                Circle().trim(from: 0.15, to: 1).stroke(surface.isOnAccent ? Palette.spinnerTrackOnAccent : Palette.spinnerTrack, style: StrokeStyle(lineWidth: size * 0.15, lineCap: .round))
                // Reduce Motion keeps the shape and drops the rotation: a still three-quarter arc
                // still reads as "not idle, not waiting", which is the whole job of this mark.
                if reduceMotion {
                    Circle().trim(from: 0, to: 0.5).stroke(surface.isOnAccent ? Palette.onAccent : Palette.spinner, style: StrokeStyle(lineWidth: size * 0.15, lineCap: .round))
                } else {
                    SpinnerArc(size: size, color: surface.isOnAccent ? Palette.onAccent : Palette.spinner)
                }
            case .needsInput:
                Circle().fill(Palette.amber)
            case .done:
                Circle().fill(Palette.done)
            }
        }.frame(width: size, height: size)
    }
}

/// The turning arc of a working mark. It does not poll a clock: it asks SwiftUI for one linear,
/// endlessly repeating turn, and SwiftUI interpolates that between frames without evaluating a
/// `body` — so any number of working rows cost no per-frame view work, nothing ticks once the last
/// one stops working (the arc is gone and its animation with it), and no timer is shared or owned.
///
/// The turn starts at `StatusMark.spinnerRotation(at:)` and lasts one `spinDuration`, so it stays
/// in step with that clock for as long as it runs: a row that comes back, or a second row that
/// starts later, still shows the phase every other arc shows. The seed is state, taken once: the
/// arc is built again whenever its mark's body runs (a hover or a selection changes the surface),
/// and a seed taken each time would move the arc off the clock with every one.
///
/// A list recycles a row's cell: the view leaves its window and comes back with its state kept and
/// its animation possibly dropped, which would leave a still arc. So an arc that appears a second
/// time is replaced by a new one, which seeds from the clock and starts its own turn. Replacing it
/// rather than rewinding it: a value set back and set forward again in one update never animates
/// from where it was set back to.
private struct SpinnerArc: View {
    let size: CGFloat
    let color: Color
    // `@State` is a macro in the macOS 26 SDK and its SwiftUIMacros plugin ships only with Xcode,
    // which the pinned toolchain does not need; this is the storage the macro would generate.
    var _generation = State(initialValue: 0)
    var _appeared = State(initialValue: false)
    private var generation: Int {
        get { _generation.wrappedValue }
        nonmutating set { _generation.wrappedValue = newValue }
    }
    private var appeared: Bool {
        get { _appeared.wrappedValue }
        nonmutating set { _appeared.wrappedValue = newValue }
    }

    var body: some View {
        TurningArc(size: size, color: color)
            .id(generation)
            .onAppear {
                if appeared { generation += 1 }
                appeared = true
            }
    }
}

private struct TurningArc: View {
    let size: CGFloat
    let color: Color
    var _start = State(initialValue: StatusMark.spinnerRotation(at: Date()))
    var _turning = State(initialValue: false)
    private var start: Double { _start.wrappedValue }
    private var turning: Bool {
        get { _turning.wrappedValue }
        nonmutating set { _turning.wrappedValue = newValue }
    }

    var body: some View {
        #if DEBUG
        let _ = StatusMark.arcEvaluations += 1
        #endif
        Circle().trim(from: 0, to: 0.15).stroke(color, style: StrokeStyle(lineWidth: size * 0.15, lineCap: .round))
            .rotationEffect(.degrees(start + (turning ? 360 : 0)))
            .onAppear {
                withAnimation(.linear(duration: StatusMark.spinDuration).repeatForever(autoreverses: false)) {
                    turning = true
                }
            }
    }
}

#if DEBUG
extension StatusMark {
    /// How many times a spinning arc's `body` has run, which a test reads to show that the turn is
    /// SwiftUI's to interpolate rather than a body re-run per frame. Debug builds only.
    @MainActor static var arcEvaluations = 0
}
#endif
