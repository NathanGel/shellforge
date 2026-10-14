import AppKit
import SwiftUI
import Testing
@testable import ShellforgeTestSupport
import ShellforgeDesign
@testable import ShellforgeUI

/// macOS 26's sheets: the buttons sit on the sheet itself, with no band or rule of their own.
@MainActor @Suite struct SheetChromeTests {
    private func nameSheet() -> NSHostingView<NameSheet> {
        let sheet = NameSheet(title: "Rename", subtitle: "A name.", fieldLabel: "Name", placeholder: "Name",
                              confirmLabel: "Rename", initialName: "x", submit: { _ in }, dismiss: {})
        let view = NSHostingView(rootView: sheet)
        view.appearance = NSAppearance(named: .aqua)
        view.frame.size = view.fittingSize
        view.layoutSubtreeIfNeeded()
        return view
    }

    @Test func theFooterIsDrawnOnTheSheetItself() throws {
        let view = nameSheet()
        let rep = try #require(Snapshot.bitmap(of: view))
        // The margin's column, clear of every control: from the foot of the sheet to its middle.
        let x = Int(Space.margin * Snapshot.scale) / 2
        let body = try #require(rep.colorAt(x: x, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        for y in (rep.pixelsHigh / 2)..<rep.pixelsHigh {
            let pixel = try #require(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            let difference = abs(pixel.redComponent - body.redComponent) + abs(pixel.greenComponent - body.greenComponent)
                + abs(pixel.blueComponent - body.blueComponent)
            #expect(difference < 0.01, "row \(y) of \(rep.pixelsHigh): \(pixel) against the body's \(body)")
            if difference >= 0.01 { return }
        }
    }

    /// One field needs no 560 pt sheet: Rename, New Terminal and Add Divider fit their content.
    @Test func aOneFieldSheetFitsItsContent() {
        #expect(nameSheet().fittingSize.height < 300)
    }

    /// A sheet whose content scrolls under its buttons draws the rule above them; one whose content
    /// fits draws none. Only the margin column at the foot of the sheet is read.
    @Test(arguments: [(CGFloat(1000), true), (CGFloat(40), false)])
    func theRuleAboveTheButtonsShowsOnlyWhenTheContentScrolls(contentHeight: CGFloat, ruled: Bool) throws {
        let sheet = SheetLayout(title: "Settings", height: 360) { EmptyView() } content: {
            Color.clear.frame(height: contentHeight)
        } footer: { SheetFooter(primary: "Save", cancel: {}, submit: {}) }
        let view = NSHostingView(rootView: sheet)
        view.appearance = NSAppearance(named: .aqua)
        view.frame.size = view.fittingSize
        view.layoutSubtreeIfNeeded()
        let rep = try #require(Snapshot.bitmap(of: view))
        let x = Int(Space.margin * Snapshot.scale) / 2
        let body = try #require(rep.colorAt(x: x, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        let differing = try ((rep.pixelsHigh / 2)..<rep.pixelsHigh).filter { y in
            let pixel = try #require(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            return abs(pixel.redComponent - body.redComponent) + abs(pixel.greenComponent - body.greenComponent)
                + abs(pixel.blueComponent - body.blueComponent) >= 0.01
        }
        #expect(!differing.isEmpty == ruled, "rows \(differing) of \(rep.pixelsHigh)")
    }
}

