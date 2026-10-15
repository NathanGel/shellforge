import AppKit
import SwiftUI
import Testing
@testable import ShellforgeDesign
import ShellforgeTestSupport

/// A Settings section's box is filled as macOS's own grouped form fills one: off its ground in the
/// same direction, and by about as much — darker in light, lighter in dark.
@MainActor @Suite struct GroupFillTests {
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
        #expect((native > 0) == (ours > 0) && abs(native - ours) <= 2, "native \(native), ours \(ours)")
    }

    /// The box's edge is the native box's: one device pixel, set off as far as macOS sets its own.
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
        #expect((native > 0) == (ours > 0) && abs(native - ours) <= 4, "native \(native), ours \(ours)")
        #expect(Size.groupEdge * Snapshot.scale == 1, "one device pixel at 2×")
    }
}

