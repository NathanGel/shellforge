import AppKit
import SwiftUI
import Testing
@testable import ShellforgeUI

@MainActor @Suite struct PanelsTests {
    /// Add Project's folder chooser is dark like the sidebar, whatever iTerm2's appearance: the
    /// app-modal panel would take the application's, not the sidebar's.
    @Test func theFolderChooserIsDark() {
        let panel = FolderChooser.panel()
        #expect(panel.appearance?.name == .darkAqua)
        #expect(panel.canChooseDirectories && !panel.canChooseFiles)
        #expect(panel.prompt == "Add Project")
    }

    /// One sheet at a time: a second request while it is up brings back the same panel.
    @Test func aSlotPresentsOnePanelAtATime() {
        let slot = PanelSlot()
        let first = slot.present(over: nil) { _ in Text("x") }
        let second = slot.present(over: nil) { _ in Text("y") }
        #expect(first === second)
        slot.dismiss()
        #expect(slot.panel == nil)
    }

    /// A dismissed sheet goes away: nothing it drew stays alive after the view's own dismiss ran.
    @Test func aDismissedPanelIsReleased() {
        let slot = PanelSlot()
        weak var gone: NSPanel?
        autoreleasepool {
            var dismiss: (() -> Void)?
            gone = slot.present(over: nil) { close in dismiss = close; return Text("x") }
            dismiss?()
        }
        #expect(gone == nil, "the dismissed panel is still alive")
    }

    /// The row painter turns off the highlight of the sidebar's own list only: a table outside the
    /// sidebar's host — one of iTerm2's — keeps its own.
    @Test func theRowPainterStaysInsideTheSidebar() {
        final class Boundary: NSView, RowHighlightBoundary {}
        let window = NSView(), foreign = NSTableView(), sidebar = Boundary(), list = NSTableView()
        let probe = NativeRowHighlight.Probe(frame: .zero)
        window.addSubview(foreign); window.addSubview(sidebar)
        sidebar.addSubview(probe)
        probe.apply()
        #expect(foreign.selectionHighlightStyle == .regular, "iTerm2's table lost its highlight")
        sidebar.addSubview(list)
        probe.apply()
        #expect(list.selectionHighlightStyle == .none)
        #expect(foreign.selectionHighlightStyle == .regular)
    }
}
