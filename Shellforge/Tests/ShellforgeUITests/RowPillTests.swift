import SwiftUI
import Testing
import ShellforgeDesign
@testable import ShellforgeUI

/// A selected row is a soft accent wash with an accent outline while its window is key — its text
/// keeps its own ink — and the unemphasized grey, without the outline, while it is not.
@MainActor @Suite struct RowPillTests {
    @Test func aSelectedRowKeepsItsInkWhileActiveAndIsGreyWhileNot() {
        let active = RowPill.surface(selected: true, hovered: false, windowActive: true)
        #expect(!active.isOnAccent)
        #expect(active.ink == Palette.text)
        #expect(RowPill.surface(selected: true, hovered: false, windowActive: false) == .inactiveSelection)
        #expect(RowPill.surface(selected: false, hovered: true, windowActive: false) == .hover)
        #expect(RowPill.surface(selected: false, hovered: false, windowActive: true) == .sidebar)
    }

    @Test func eachStateHasItsFill() {
        #expect(RowPill.fill(selected: true, hovered: false, windowActive: true) == RowPill.selectionWash)
        #expect(RowPill.fill(selected: true, hovered: true, windowActive: true) == RowPill.selectionWash)
        #expect(RowPill.fill(selected: true, hovered: false, windowActive: false) == Palette.controlActive)
        #expect(RowPill.fill(selected: false, hovered: true, windowActive: true) == Palette.rowHover)
        #expect(RowPill.fill(selected: false, hovered: false, windowActive: true) == .clear)
    }

    /// The outline is the key window's selection's alone.
    @Test func onlyAnActiveSelectionIsOutlined() {
        #expect(RowPill.outline(selected: true, windowActive: true) == RowPill.selectionOutline)
        #expect(RowPill.outline(selected: true, windowActive: false) == nil)
        #expect(RowPill.outline(selected: false, windowActive: true) == nil)
    }

    /// Review fix: only the key window's selection is the accent, as AppKit's tables do; a window that
    /// is main but not key (another panel is key) shows the grey selection.
    @Test func onlyTheKeyWindowIsActive() {
        #expect(RowPill.windowActive(.key))
        #expect(!RowPill.windowActive(.active))
        #expect(!RowPill.windowActive(.inactive))
    }
}
