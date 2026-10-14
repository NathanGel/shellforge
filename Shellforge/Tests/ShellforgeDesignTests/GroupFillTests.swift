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
}
