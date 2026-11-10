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
        let (rep, size) = try render(SidebarHeader(addProject: {}, showHooks: {}, windowControls: controls))
        #expect(abs(size.height - (Size.menuRow + Space.base + Space.tight)) < 0.5, "the header is \(size.height) pt high")
        let first = (0..<rep.pixelsWide).first { x in (0..<rep.pixelsHigh).contains { y in
            (rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)?.brightnessComponent ?? 0) > 0.2 } }
        let leading = CGFloat(try #require(first)) / Snapshot.scale
        #expect(leading < controls.buttonsMaxX, "the title starts at the rows' edge, not after the buttons: \(leading)")
    }

    /// Settings is the activity bar's gear alone: with the window holding the sidebar toggle, the
    /// header's trailing buttons are Agent hooks, New Tab in Home Folder and “+” — three marks.
    @Test func theHeaderHasNoSettingsGear() throws {
        let (rep, size) = try render(SidebarHeader(addProject: {}, showHooks: {}, windowControls: Self.controls))
        let lit = (0..<rep.pixelsWide).map { x in (0..<rep.pixelsHigh).contains { y in
            (rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)?.brightnessComponent ?? 0) > 0.2 } }
        // Runs of inked columns in the header's right half, a gap of 3 pt or more between two marks.
        let gap = Int(3 * Snapshot.scale)
        var marks = 0, blank = gap
        for x in Int(size.width / 2 * Snapshot.scale)..<rep.pixelsWide {
            if lit[x] { if blank >= gap { marks += 1 }; blank = 0 } else { blank += 1 }
        }
        #expect(marks == 3, "\(marks) buttons in the header")
    }
}
