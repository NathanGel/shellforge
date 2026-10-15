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

    private func sameColor(_ a: NSColor?, _ b: NSColor?) -> Bool {
        guard let a = a?.usingColorSpace(.sRGB), let b = b?.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent) < 0.01
    }

    /// One surface: the terminal's background runs behind the panel and under the title strip, so
    /// the panel floats over the terminal rather than in a frame of the window's colour.
    func testThePanelAndTheStripSitOnTheTerminalsColour() throws {
        try XCTSkipUnless(iTermShellforgeSidebar.floats)
        root.updateTitleAndBorderViews()
        root.layoutSubtreeIfNeeded()
        let session = try XCTUnwrap(fixture.terminal.currentSession())
        let background = try XCTUnwrap(session.processedBackgroundColor)
        let panel = root.shellforgeSidebarFrame
        let solid = root.subviews.compactMap { $0 as? iTermLayerBackedSolidColorView }.filter { !$0.isHidden }
        let column = try XCTUnwrap(solid.first { $0.identifier == iTermRootTerminalView.shellforgeColumnBackgroundIdentifier },
                                   "a view behind the panel")
        XCTAssertEqual(column.frame.minX, 0)
        XCTAssertEqual(column.frame.maxX, panel.maxX + iTermShellforgeSidebar.floatingInset, accuracy: 0.5)
        XCTAssertTrue(sameColor(column.color, background), "column \(String(describing: column.color)), terminal \(background)")
        let strip = try XCTUnwrap(solid.first { $0.frame.maxY >= root.bounds.height - 0.5 && $0.frame.minX > panel.maxX }, "the title strip")
        XCTAssertTrue(sameColor(strip.color, background), "strip \(String(describing: strip.color)), terminal \(background)")
    }

    /// The surface follows the terminal's background when it changes — the colour match, a profile.
    func testTheSurfaceFollowsABackgroundChange() throws {
        try XCTSkipUnless(iTermShellforgeSidebar.floats)
        iTermShellforgeTerminalMatch.setOn(false)
        defer { iTermShellforgeTerminalMatch.setOn(false) }
        root.layoutSubtreeIfNeeded()
        let session = try XCTUnwrap(fixture.terminal.currentSession())
        iTermShellforgeTerminalMatch.setOn(true)
        // In the app the text view reports the change once the screen's state reaches it, which a
        // test window with no running terminal never does: report it as the tab then does.
        let tab = try XCTUnwrap(fixture.terminal.currentTab())
        fixture.terminal.tabSessionDidChangeBackgroundColor(tab)
        let column = try XCTUnwrap(root.subviews.compactMap { $0 as? iTermLayerBackedSolidColorView }
            .first { $0.identifier == iTermRootTerminalView.shellforgeColumnBackgroundIdentifier })
        XCTAssertTrue(sameColor(column.color, session.processedBackgroundColor),
                      "column \(String(describing: column.color)), terminal \(String(describing: session.processedBackgroundColor))")
    }

    /// The colour match borrows Minimal's colours but must not make the window compact: a compact
    /// window has no title bar of its own, so the floating panel, its buttons and strip never apply.
    func testTheColourMatchKeepsAWindowNormal() throws {
        try XCTSkipUnless(iTermShellforgeSidebar.floats)
        let saved = iTermUserDefaults.userDefaults().object(forKey: kPreferenceKeyTabStyle)
        defer { iTermUserDefaults.userDefaults().set(saved, forKey: kPreferenceKeyTabStyle); iTermShellforgeTerminalMatch.setOn(false) }
        iTermUserDefaults.userDefaults().set(Int(iTermPreferencesTabStyle.TAB_STYLE_AUTOMATIC.rawValue), forKey: kPreferenceKeyTabStyle)
        iTermShellforgeTerminalMatch.setOn(true)
        XCTAssertEqual(iTermThemedWindowType(.WINDOW_TYPE_NORMAL), .WINDOW_TYPE_NORMAL)
        XCTAssertEqual(iTermThemedWindowType(.WINDOW_TYPE_MAXIMIZED), .WINDOW_TYPE_MAXIMIZED)
        // Minimal of the user's own choosing stays iTerm2's compact window.
        iTermUserDefaults.userDefaults().set(Int(iTermPreferencesTabStyle.TAB_STYLE_MINIMAL.rawValue), forKey: kPreferenceKeyTabStyle)
        XCTAssertEqual(iTermThemedWindowType(.WINDOW_TYPE_NORMAL), .WINDOW_TYPE_COMPACT)
    }

    /// The window's buttons, in the root view's coordinates (origin top-left, as the eye reads them).
    private func buttonFrame(_ type: NSWindow.ButtonType) throws -> NSRect {
        let button = try XCTUnwrap(fixture.window.standardWindowButton(type))
        let frame = button.convert(button.bounds, to: nil)
        return NSRect(x: frame.minX, y: fixture.window.frame.height - frame.maxY, width: frame.width, height: frame.height)
    }

    /// Finder's inset: the buttons sit as far in from the panel's left edge as from its top, well
    /// clear of its corner, rather than at the title bar's own spot a point inside it.
    func testTheWindowButtonsSitEvenlyInsideThePanel() throws {
        try XCTSkipUnless(iTermShellforgeSidebar.floats)
        root.layoutSubtreeIfNeeded()
        let close = try buttonFrame(.closeButton), panel = root.shellforgeSidebarFrame
        let fromLeft = close.minX - panel.minX, fromTop = close.minY - (root.bounds.height - panel.maxY)
        XCTAssertGreaterThanOrEqual(fromTop, 8, "clear of the panel's top")
        XCTAssertEqual(fromLeft, fromTop, accuracy: 1.5)
    }

    /// The strip is the buttons' band, and the window's title is centred on the buttons' row.
    func testTheStripIsTheButtonsBand() throws {
        try XCTSkipUnless(iTermShellforgeSidebar.floats)
        root.updateTitleAndBorderViews()
        root.layoutSubtreeIfNeeded()
        let close = try buttonFrame(.closeButton)
        let terminalTop = root.bounds.height - (try terminalFrame().maxY)
        XCTAssertEqual(terminalTop, close.midY * 2, accuracy: 1, "the terminal starts below a band centred on the buttons")
        let title = root.shellforgeWindowTitleFrame
        XCTAssertEqual(root.bounds.height - title.midY, close.midY, accuracy: 2, "the title sits on the buttons' row")
    }

    /// The sidebar hears where the window's buttons sit in it, so its header shares their row.
    func testTheSidebarKnowsWhereTheButtonsSit() throws {
        try XCTSkipUnless(iTermShellforgeSidebar.floats)
        root.layoutSubviews()
        let sidebar = try XCTUnwrap(root.shellforgeSidebarView)
        let controls = try XCTUnwrap(iTermShellforgeSidebar.reportedWindowControls(of: sidebar), "the buttons are inside the panel")
        let zoom = try buttonFrame(.zoomButton), close = try buttonFrame(.closeButton), panel = root.shellforgeSidebarFrame
        XCTAssertEqual(controls.buttonsMaxX, zoom.maxX - panel.minX, accuracy: 0.5)
        XCTAssertEqual(controls.buttonsMidY, close.midY - (root.bounds.height - panel.maxY), accuracy: 0.5)
    }

    /// Glass in light mode over a dark terminal turns murky with dark text on it: behind the panel
    /// the terminal's colour stands only when its lightness agrees with the window's.
    func testADarkTerminalInALightWindowKeepsTheWindowColourBehindThePanel() throws {
        try XCTSkipUnless(iTermShellforgeSidebar.floats)
        let session = try XCTUnwrap(fixture.terminal.currentSession())
        let saved = fixture.window.appearance
        defer { fixture.window.appearance = saved }
        let dark = try XCTUnwrap(session.processedBackgroundColor).isDark
        fixture.window.appearance = NSAppearance(named: dark ? .aqua : .darkAqua)
        root.updateTitleAndBorderViews()
        let column = try XCTUnwrap(root.subviews.compactMap { $0 as? iTermLayerBackedSolidColorView }
            .first { $0.identifier == iTermRootTerminalView.shellforgeColumnBackgroundIdentifier })
        XCTAssertFalse(column.isHidden == false && sameColor(column.color, session.processedBackgroundColor),
                       "the terminal's colour behind the panel in a window of the other lightness")
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
        // M12g: the one view meant to be there is the terminal's own colour behind the panel.
        let covering = root.subviews.filter {
            !$0.isHidden && $0 is iTermLayerBackedSolidColorView && $0.frame.minX < sidebar.maxX && $0.frame.maxY > sidebar.maxY - 20 && $0.frame.width > 0
                && $0.identifier != iTermRootTerminalView.shellforgeColumnBackgroundIdentifier
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
