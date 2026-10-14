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
}
