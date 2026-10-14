import SwiftUI
import Testing
import ShellforgeDesign
@testable import ShellforgeUI

/// A selected row takes the system's selection: the accent while its window is active, the
/// unemphasized grey while it is not.
@MainActor @Suite struct RowPillTests {
    @Test func aSelectedRowIsAccentWhileActiveAndGreyWhileNot() {
        #expect(RowPill.surface(selected: true, hovered: false, windowActive: true) == .accent)
        #expect(RowPill.surface(selected: true, hovered: false, windowActive: false) == .inactiveSelection)
        #expect(RowPill.surface(selected: false, hovered: true, windowActive: false) == .hover)
        #expect(RowPill.surface(selected: false, hovered: false, windowActive: true) == .sidebar)
    }

    @Test func eachSurfaceHasItsFill() {
        #expect(RowPill.fill(for: .accent) == Palette.selection)
        #expect(RowPill.fill(for: .inactiveSelection) == Palette.controlActive)
        #expect(RowPill.fill(for: .hover) == Palette.rowHover)
        #expect(RowPill.fill(for: .sidebar) == .clear)
    }
}
