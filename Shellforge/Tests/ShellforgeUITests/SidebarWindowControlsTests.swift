import AppKit
import SwiftUI
import Testing
@testable import ShellforgeTestSupport
import ShellforgeDesign
@testable import ShellforgeUI

/// macOS 26: the window's buttons sit inside the floating panel, and the sidebar's header shares
/// their row — its title after the zoom button, the row centred on the buttons — rather than
/// sitting on a row of its own below an empty band.
@MainActor @Suite struct SidebarWindowControlsTests {
    static let controls = SidebarWindowControls(buttonsMaxX: 60, buttonsMidY: 18)

    private func render(_ header: SidebarHeader) throws -> (NSBitmapImageRep, NSSize) {
        let host = NSHostingView(rootView: header.frame(width: 400).background(Color.black))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        return (try #require(Snapshot.bitmap(of: host)), host.fittingSize)
    }

    @Test func theHeaderIsTheButtonsBand() throws {
        let (_, size) = try render(SidebarHeader(addProject: {}, showHooks: {}, showMacSettings: {}, windowControls: Self.controls))
        #expect(size.height == Self.controls.bandHeight)
        #expect(Self.controls.bandHeight == 36, "centred on the buttons, 18 pt down")
    }

    @Test func nothingIsDrawnWhereTheButtonsSit() throws {
        let (rep, _) = try render(SidebarHeader(addProject: {}, showHooks: {}, showMacSettings: {}, windowControls: Self.controls))
        func inked(_ columns: Range<Int>) -> Bool {
            columns.contains { x in (0..<rep.pixelsHigh).contains { y in
                (rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)?.brightnessComponent ?? 0) > 0.2 } }
        }
        let leading = Int(Self.controls.headerLeading * Snapshot.scale)
        #expect(!inked(0..<leading), "the buttons' place is left clear")
        #expect(inked(leading..<(leading + Int(40 * Snapshot.scale))), "the title starts after them")
    }

    /// Full screen has no window buttons: the toggle has a row of its own at the panel's top, and the
    /// header sits below it at the rows' own leading edge — not after the toggle.
    @Test func inFullScreenTheHeaderSitsBelowTheTogglesRow() throws {
        let stacked = SidebarWindowControls(buttonsMaxX: 40, buttonsMidY: 20, stacked: true)
        let (rep, size) = try render(SidebarHeader(addProject: {}, showHooks: {}, showMacSettings: {}, windowControls: stacked))
        #expect(size.height > stacked.bandHeight + Size.menuRow - 1, "the header's row comes after the toggle's")
        let band = Int(stacked.bandHeight * Snapshot.scale)
        let inkedBand = (0..<band).contains { y in (0..<rep.pixelsWide).contains { x in
            (rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)?.brightnessComponent ?? 0) > 0.2 } }
        #expect(!inkedBand, "the toggle's row is left to the toggle")
        let titleRows = band..<rep.pixelsHigh
        let first = (0..<rep.pixelsWide).first { x in titleRows.contains { y in
            (rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)?.brightnessComponent ?? 0) > 0.2 } }
        let leading = CGFloat(try #require(first)) / Snapshot.scale
        #expect(leading < stacked.buttonsMaxX, "the title starts at the rows' edge, not after the toggle: \(leading)")
    }
}

