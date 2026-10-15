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

    func testOnlyTitledTypesGainFullSizeContent() throws {
        try XCTSkipUnless(iTermShellforgeSidebar.floats)
        for type in [iTermWindowType.WINDOW_TYPE_NORMAL, .WINDOW_TYPE_MAXIMIZED, .WINDOW_TYPE_CENTERED] {
            let mask = PseudoTerminal.styleMask(for: type, savedWindowType: type, hotkeyWindowType: .none)
            XCTAssertTrue(mask.contains(.fullSizeContentView), "\(type.rawValue)")
        }
        let accessory = PseudoTerminal.styleMask(for: .WINDOW_TYPE_ACCESSORY, savedWindowType: .WINDOW_TYPE_ACCESSORY,
                                                 hotkeyWindowType: .none)
        XCTAssertFalse(accessory.contains(.fullSizeContentView), "an accessory window stays as upstream has it")
    }

    func testTheWindowsTitleBarGivesWayToThePanel() throws {
        try XCTSkipUnless(iTermShellforgeSidebar.floats)
        XCTAssertTrue(fixture.window.styleMask.contains(.fullSizeContentView))
        XCTAssertEqual(fixture.window.titleVisibility, .hidden)
        XCTAssertTrue(fixture.window.titlebarAppearsTransparent)
    }

    /// The current session's view, in the root view's coordinates.
    private func terminalFrame() throws -> NSRect {
        let view = try XCTUnwrap(fixture.terminal.currentSession()?.view)
        return view.convert(view.bounds, to: root)
    }

    func testTheTerminalStartsBelowTheTitleStrip() throws {
        try XCTSkipUnless(iTermShellforgeSidebar.floats)
        let terminal = try terminalFrame()
        XCTAssertLessThan(terminal.maxY, root.bounds.height - 10, "the strip is above the terminal")
        XCTAssertGreaterThanOrEqual(terminal.minX, root.shellforgeSidebarFrame.maxX)
    }

    /// The panel stands off the terminal as it stands off the window's edges, and the drag handle
    /// lies in that gap rather than over the glass or the text.
    func testThePanelStandsOffTheTerminalByItsInset() throws {
        try XCTSkipUnless(iTermShellforgeSidebar.floats)
        let panel = root.shellforgeSidebarFrame, inset = iTermShellforgeSidebar.floatingInset
        XCTAssertEqual(try terminalFrame().minX, panel.maxX + inset, accuracy: 0.5)
        let handle = iTermShellforgeSidebar.dragHandleFrame(forSidebar: panel)
        XCTAssertEqual(handle.minX, panel.maxX, accuracy: 0.5)
        XCTAssertEqual(handle.maxX, panel.maxX + inset, accuracy: 0.5)
    }

    func testAHiddenSidebarLeavesNoGap() throws {
        try XCTSkipUnless(iTermShellforgeSidebar.floats)
        root.toggleShellforgeSidebar()
        defer { root.toggleShellforgeSidebar() }
        root.layoutSubtreeIfNeeded()
        XCTAssertLessThan(try terminalFrame().minX, 30, "the terminal takes the sidebar's place")
        XCTAssertTrue(fixture.window.styleMask.contains(.fullSizeContentView), "the window's style stays while hidden")
    }

    func testTheDragHandleFollowsThePanel() throws {
        try XCTSkipUnless(iTermShellforgeSidebar.floats)
        let handle = iTermShellforgeSidebar.dragHandleFrame(forSidebar: root.shellforgeSidebarFrame)
        XCTAssertEqual(handle.minY, root.shellforgeSidebarFrame.minY)
        XCTAssertEqual(handle.height, root.shellforgeSidebarFrame.height)
    }

    /// Review of the snapshot: the title strip's background ran over the sidebar column and showed
    /// through the glass panel.
    func testNothingInTheRootViewSpansTheTopOfTheSidebarColumn() throws {
        try XCTSkipUnless(iTermShellforgeSidebar.floats)
        root.layoutSubtreeIfNeeded()
        let sidebar = root.shellforgeSidebarFrame
        let covering = root.subviews.filter {
            !$0.isHidden && $0 is iTermLayerBackedSolidColorView && $0.frame.minX < sidebar.maxX && $0.frame.maxY > sidebar.maxY - 20 && $0.frame.width > 0
        }
        XCTAssertEqual(covering.map { NSStringFromRect($0.frame) }, [])
    }

    // Review fixes.

    func testOnlyNormalMaximizedAndCentredWindowsFloat() {
        let floats = iTermShellforgeSidebar.floats
        for type in [iTermWindowType.WINDOW_TYPE_NORMAL, .WINDOW_TYPE_MAXIMIZED, .WINDOW_TYPE_CENTERED] {
            XCTAssertEqual(iTermShellforgeSidebar.floatsWindow(ofType: type), floats, "\(type.rawValue)")
        }
        for type in [iTermWindowType.WINDOW_TYPE_TOP_PERCENTAGE, .WINDOW_TYPE_LEFT_CELLS, .WINDOW_TYPE_NO_TITLE_BAR,
                     .WINDOW_TYPE_CENTERED_NO_TITLE_BAR, .WINDOW_TYPE_ACCESSORY, .WINDOW_TYPE_TRADITIONAL_FULL_SCREEN] {
            XCTAssertFalse(iTermShellforgeSidebar.floatsWindow(ofType: type), "\(type.rawValue)")
        }
    }

    func testTheTitleStripIsDrawnWhateverTheTabPosition() throws {
        try XCTSkipUnless(iTermShellforgeSidebar.floats)
        let saved = iTermPreferences.int(forKey: kPreferenceKeyTabPosition)
        defer { iTermPreferences.setInt(saved, forKey: kPreferenceKeyTabPosition) }
        iTermPreferences.setInt(2, forKey: kPreferenceKeyTabPosition) // PSMTab_LeftTab
        root.layoutSubviews()
        XCTAssertLessThan(try terminalFrame().maxY, root.bounds.height - 10, "the strip stays above the terminal with tabs on the left")
    }

    func testAHiddenSidebarsTitleClearsTheWindowButtons() throws {
        try XCTSkipUnless(iTermShellforgeSidebar.floats)
        root.toggleShellforgeSidebar()
        defer { root.toggleShellforgeSidebar() }
        root.layoutSubtreeIfNeeded()
        let zoom = try XCTUnwrap(fixture.window.standardWindowButton(.zoomButton))
        try XCTSkipIf(zoom.isHidden, "a compact window draws its own buttons")
        let buttons = zoom.convert(zoom.bounds, to: root)
        XCTAssertGreaterThanOrEqual(root.shellforgeWindowTitleFrame.minX, buttons.maxX)
    }

    func testTheDragHandleNeverMovesTheWindow() {
        XCTAssertFalse(iTermDragHandleView(frame: NSRect(x: 0, y: 0, width: 4, height: 100)).mouseDownCanMoveWindow)
    }
}
