//
//  ShellforgeSidebarZoomTest.swift
//  Shellforge
//
//  ⌘+ / ⌘− / ⌘0 size the sidebar's text after a click in the sidebar, and the terminal's font
//  after a click in the terminal. Clicks go through NSApp.sendEvent, as a user's do, so the
//  sidebar's event monitor sees them.
//

import XCTest
@testable import iTerm2SharedARC

@MainActor
final class ShellforgeSidebarZoomTest: XCTestCase {
    private var fixture: TerminalWindowTestFixture!
    private var root: iTermRootTerminalView!
    private var wasHidden = false
    private var savedDefaults: ShellforgeDefaultsSnapshot!

    override func setUp() async throws {
        savedDefaults = ShellforgeDefaultsSnapshot()
        fixture = TerminalWindowTestFixture()
        root = try XCTUnwrap(fixture.terminal.contentView)
        try XCTSkipUnless(root.hasShellforgeSidebar, "this window has no sidebar")
        wasHidden = root.shellforgeSidebarHidden
        if wasHidden { root.toggleShellforgeSidebar() }
        root.layoutSubtreeIfNeeded()
    }

    override func tearDown() async throws {
        // The size is saved for the app: put it back as a user would find it.
        iTermShellforgeSidebar.resetTextScale()
        if wasHidden { root.toggleShellforgeSidebar() }
        fixture.close()
        savedDefaults.restore()
    }

    /// A click in the window at `point`, mouse-up queued first so no tracking loop waits on it.
    private func click(at point: NSPoint, down: NSEvent.EventType, up: NSEvent.EventType) throws {
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        NSApp.postEvent(try event(up), atStart: false)
        NSApp.sendEvent(try event(down))
    }

    /// The sidebar's middle, in window coordinates.
    private var inSidebar: NSPoint { NSPoint(x: root.shellforgeSidebarWidth / 2, y: fixture.window.contentLayoutRect.midY) }

    /// The terminal's middle, right of the sidebar.
    private var inTerminal: NSPoint {
        let rect = fixture.window.contentLayoutRect
        return NSPoint(x: (root.shellforgeSidebarWidth + rect.maxX) / 2, y: rect.midY)
    }

    private var terminalFontSize: CGFloat { fixture.terminal.currentSession()?.textview?.fontTable.asciiFont.font.pointSize ?? 0 }

    /// View › Make Text Bigger (1), Smaller (-1) or Normal Size (0), as the menu sends them.
    private func textSize(_ step: Int) {
        let action = step > 0 ? "biggerFont:" : step < 0 ? "smallerFont:" : "returnToDefaultSize:"
        _ = fixture.terminal.perform(NSSelectorFromString(action), with: nil)
    }

    func testTheKeysSizeTheSidebarAfterAClickInIt() throws {
        let font = terminalFontSize
        try click(at: inSidebar, down: .otherMouseDown, up: .otherMouseUp)
        textSize(1)
        XCTAssertEqual(iTermShellforgeSidebar.textScaleFactor, 1.15)
        XCTAssertEqual(terminalFontSize, font, "the terminal's font is left alone")
        textSize(-1)
        XCTAssertEqual(iTermShellforgeSidebar.textScaleFactor, 1)
    }

    func testTheKeysSizeTheTerminalAfterAClickInIt() throws {
        try click(at: inSidebar, down: .otherMouseDown, up: .otherMouseUp)
        try click(at: inTerminal, down: .leftMouseDown, up: .leftMouseUp)
        let font = terminalFontSize
        textSize(1)
        XCTAssertEqual(iTermShellforgeSidebar.textScaleFactor, 1, "the sidebar is left alone")
        XCTAssertGreaterThan(terminalFontSize, font)
        textSize(-1)
    }

    func testAHiddenSidebarLeavesTheKeysToTheTerminal() throws {
        try click(at: inSidebar, down: .otherMouseDown, up: .otherMouseUp)
        root.toggleShellforgeSidebar()
        defer { root.toggleShellforgeSidebar() }
        let font = terminalFontSize
        textSize(1)
        XCTAssertEqual(iTermShellforgeSidebar.textScaleFactor, 1)
        XCTAssertGreaterThan(terminalFontSize, font)
        textSize(-1)
    }
}
