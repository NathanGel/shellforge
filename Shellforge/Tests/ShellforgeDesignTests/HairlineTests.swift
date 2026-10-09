// Ported from AiTerm (app/Tests/AiTermUITests/HairlineTests.swift), GPLv3, Laurens D'Hondt.
import AppKit
import SwiftUI
import Testing
@testable import ShellforgeDesign

@MainActor
struct HairlineTests {
    /// Beside a label in an `HStack` — `DividerRow`'s rule either side of its name — the hairline
    /// stays a horizontal 1 pt rule, which SwiftUI's `Divider` does not, and a stroke does not grow
    /// with the sidebar's scale.
    @Test func itIsAHorizontalPointAtEveryScale() {
        for scale in InterfaceScale.all {
            let box = Box()
            let host = NSHostingView(rootView: HStack {
                Hairline().background(GeometryReader { proxy in Color.clear.onAppear { box.size = proxy.size } })
                Text("Work")
                Hairline()
            }
            .frame(width: 200)
            .interfaceScale(scale))
            host.frame = NSRect(x: 0, y: 0, width: 200, height: 40)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            #expect(box.size.height == 1, "at ×\(scale.factor)")
            #expect(box.size.width > 50, "at ×\(scale.factor)")
        }
    }

    private final class Box { var size = CGSize.zero }

    /// A sheet's section break and the sidebar's rule are one weight: the hairline draws exactly
    /// the border every field is outlined in, not a brighter `Divider` under it.
    @Test func itDrawsTheBorder() throws {
        let hairline = try #require(brightestPixel(of: VStack { Hairline() }.frame(width: 20)))
        let border = try #require(brightestPixel(of: Rectangle().fill(Palette.border).frame(width: 20, height: 1)))
        #expect(abs(hairline.redComponent - border.redComponent) < 0.005,
                "hairline \(hairline.redComponent), border \(border.redComponent)")
    }
}
