//
//  ShellforgeFloatingSidebarTest.swift
//  Shellforge
//
//  On macOS 26 the sidebar is a panel inset from the window's edges; before, it is flush.
//

import XCTest
@testable import iTerm2SharedARC

@MainActor
final class ShellforgeFloatingSidebarTest: XCTestCase {
    private var fixture: TerminalWindowTestFixture!
    private var root: iTermRootTerminalView!

    override func setUp() async throws {
        fixture = TerminalWindowTestFixture()
        root = try XCTUnwrap(fixture.terminal.contentView)
        if root.shellforgeSidebarHidden { root.toggleShellforgeSidebar() }
        root.layoutSubtreeIfNeeded()
    }

    override func tearDown() async throws {
        fixture.close()
    }

    func testFloatingIsMacOS26AndLater() {
        XCTAssertEqual(iTermShellforgeSidebar.floats, ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26)
    }

    func testThePanelIsInsetOnlyWhenItFloats() {
        let frame = root.shellforgeSidebarFrame
        let inset: CGFloat = iTermShellforgeSidebar.floats ? iTermShellforgeSidebar.floatingInset : 0
        XCTAssertEqual(frame.minX, inset)
        XCTAssertEqual(frame.minY, inset)
        XCTAssertEqual(frame.maxY, root.bounds.height - inset)
    }
}
