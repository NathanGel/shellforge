// Ported from AiTerm (app/Tests/AiTermTests/SearchPickerTests.swift, its DropdownKeys cases), GPLv3, Laurens D'Hondt.
import Testing
import AppKit
import SwiftUI
@testable import ShellforgeUI

@Suite struct DropdownKeysTests {
    private func handle(_ sel: Selector, count: Int = 3, index: Int = 0, open: Bool = true) -> DropdownKeys.Outcome {
        DropdownKeys.handle(selector: sel, count: count, index: index, open: open)
    }

    @Test func testArrowsWrapAround() {
        #expect(handle(#selector(NSResponder.moveDown(_:)), index: 0) == .moved(1))
        #expect(handle(#selector(NSResponder.moveDown(_:)), index: 2) == .moved(0))
        #expect(handle(#selector(NSResponder.moveUp(_:)), index: 0) == .moved(2))
        #expect(handle(#selector(NSResponder.moveUp(_:)), index: 1) == .moved(0))
    }

    @Test func testReturnAcceptsAndEscapeClosesOnlyThePopup() {
        #expect(handle(#selector(NSResponder.insertNewline(_:)), index: 2) == .accepted(2))
        #expect(handle(#selector(NSResponder.cancelOperation(_:))) == .closed)
    }

    /// Returning `.unhandled` is what leaves a key with the field and the sheet — notably ⎋, which
    /// must close the sheet when no popup is open.
    @Test func testAClosedOrEmptyPopupHandlesNothing() {
        #expect(handle(#selector(NSResponder.cancelOperation(_:)), open: false) == .unhandled)
        #expect(handle(#selector(NSResponder.moveDown(_:)), count: 0) == .unhandled)
        #expect(handle(#selector(NSResponder.insertText(_:))) == .unhandled)
    }

    /// An index past the end cannot accept out of bounds — the list can shrink under a stale index
    /// while a search result lands.
    @Test func testAcceptClampsToTheLastRow() {
        #expect(handle(#selector(NSResponder.insertNewline(_:)), count: 2, index: 5) == .accepted(1))
    }
}
