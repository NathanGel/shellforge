import AppKit
import SwiftUI
import Testing
@testable import ShellforgeDesign
import ShellforgeTestSupport

/// A Settings section's box is filled as macOS's own grouped form fills one: off its ground in the
/// same direction — darker in light, lighter in dark — and by the amount each look expects.
///
/// What macOS draws natively depends on the look AppKit draws in the test host (`AppKitLook`), so
/// each look has its own expected gap between our box and the native one, in 0–255 red. In the
/// compatibility look (`scripts/swift.sh test`) the palette matches the native box. In the current
/// look, the one the app ships with, the gaps are the ones measured there: the native box is set off
/// about twice as far and draws no edge line, while the palette, tuned by eye in the app, keeps its
/// own box and edge. A change on either side moves the gap and fails.
@MainActor @Suite struct GroupFillTests {
    /// Ours minus native, per look and appearance.
    private func fillGap(_ appearance: NSAppearance.Name) -> CGFloat {
        switch AppKitLook.drawn {
        case .compatibility: 0
        case .current: appearance == .aqua ? 4 : -3
        }
    }

    private func edgeGap(_ appearance: NSAppearance.Name) -> CGFloat {
        switch AppKitLook.drawn {
        case .compatibility: 0
        case .current: appearance == .aqua ? -11 : 23
        }
    }

    private func red(_ view: some View, _ appearance: NSAppearance.Name, x: Int, y: Int, size: NSSize) throws -> CGFloat {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: appearance)
        host.frame.size = size
        host.layoutSubtreeIfNeeded()
        let color = try #require(Snapshot.bitmap(of: host)?.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        return color.redComponent * 255
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func theBoxSitsOffTheSheetAsANativeGroupDoes(appearance: NSAppearance.Name) throws {
        let form = Form { Section("Section") { Text("Row") } }.formStyle(.grouped)
        let formSize = NSSize(width: 400, height: 200)
        let nativeGround = try red(form, appearance, x: 10, y: 10, size: formSize)
        let nativeBox = try red(form, appearance, x: 400, y: 150, size: formSize)
        let swatch = NSSize(width: 20, height: 20)
        let sheet = try red(Palette.surface, appearance, x: 20, y: 20, size: swatch)
        let box = try red(Palette.surface.overlay(Palette.groupFill), appearance, x: 20, y: 20, size: swatch)
        let native = nativeBox - nativeGround, ours = box - sheet
        #expect(native != 0, "the native box is off its ground")
        #expect((native > 0) == (ours > 0) && abs(ours - native - fillGap(appearance)) <= 2,
                "\(AppKitLook.drawn) look: native \(native), ours \(ours), expected gap \(fillGap(appearance))")
    }

    /// The box's edge is the native box's: one device pixel, set off as far as macOS sets its own. The
    /// current look's native box has no edge line, so its darkest (light) or lightest (dark) pixel is
    /// its fill.
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func theEdgeIsTheNativeGroupsEdge(appearance: NSAppearance.Name) throws {
        let host = NSHostingView(rootView: Form { Section("Section") { Text("Row") } }.formStyle(.grouped))
        host.appearance = NSAppearance(named: appearance)
        host.frame.size = NSSize(width: 400, height: 200)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(Snapshot.bitmap(of: host))
        let column = (0..<rep.pixelsHigh).compactMap { rep.colorAt(x: 400, y: $0)?.usingColorSpace(.sRGB)?.redComponent }.map { $0 * 255 }
        let ground = try #require(column.first)
        let nativeEdge = try #require(appearance == .aqua ? column.min() : column.max())
        let swatch = NSSize(width: 20, height: 20)
        let sheet = try red(Palette.surface, appearance, x: 20, y: 20, size: swatch)
        let edge = try red(Palette.surface.overlay(Palette.groupEdge), appearance, x: 20, y: 20, size: swatch)
        let native = nativeEdge - ground, ours = edge - sheet
        #expect((native > 0) == (ours > 0) && abs(ours - native - edgeGap(appearance)) <= 4,
                "\(AppKitLook.drawn) look: native \(native), ours \(ours), expected gap \(edgeGap(appearance))")
        #expect(Size.groupEdge * Snapshot.scale == 1, "one device pixel at 2×")
    }
}

