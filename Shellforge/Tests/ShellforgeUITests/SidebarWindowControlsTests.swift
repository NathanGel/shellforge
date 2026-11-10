import AppKit
import SwiftUI
import Testing
@testable import ShellforgeTestSupport
import ShellforgeDesign
@testable import ShellforgeUI

/// macOS 26: the window's buttons sit inside the floating panel. Their band across its top is
/// theirs alone, VS Code's way: the sidebar's header is a row of its own below it, in the panel
/// column beside the activity bar (`ActivityBarTests.theBarIsCentredAndRunsBesideThePanel`), its
/// title at the rows' own leading edge rather than after the buttons.
@MainActor @Suite struct SidebarWindowControlsTests {
    nonisolated static let controls = SidebarWindowControls(buttonsMaxX: 60, buttonsMidY: 18)

    private func render(_ header: SidebarHeader) throws -> (NSBitmapImageRep, NSSize) {
        let host = NSHostingView(rootView: header.frame(width: 400).background(Color.black))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        return (try #require(Snapshot.bitmap(of: host)), host.fittingSize)
    }

    @Test func theBandIsCentredOnTheButtons() {
        #expect(Self.controls.bandHeight == 36, "centred on the buttons, 18 pt down")
    }

    /// The header is its own row, the same with the buttons or the full-screen toggle in the band:
    /// one `menuRow` inside its padding, not the band's height.
    @Test(arguments: [controls, SidebarWindowControls(buttonsMaxX: 40, buttonsMidY: 20, stacked: true)])
    func theHeaderIsARowBelowTheBand(controls: SidebarWindowControls) throws {
        let (rep, size) = try render(SidebarHeader(addProject: {}, showHooks: {}, showMacSettings: {}, windowControls: controls))
        #expect(abs(size.height - (Size.menuRow + Space.base + Space.tight)) < 0.5, "the header is \(size.height) pt high")
        let first = (0..<rep.pixelsWide).first { x in (0..<rep.pixelsHigh).contains { y in
            (rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)?.brightnessComponent ?? 0) > 0.2 } }
        let leading = CGFloat(try #require(first)) / Snapshot.scale
        #expect(leading < controls.buttonsMaxX, "the title starts at the rows' edge, not after the buttons: \(leading)")
    }
}
