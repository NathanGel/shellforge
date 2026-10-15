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
    /// A background change reaches the surface through the window's own hook — the colour match,
    /// a profile edit, an escape sequence — not only through the next layout: a stale colour is
    /// replaced by the hook alone.
    func testTheSurfaceFollowsABackgroundChange() throws {
        try XCTSkipUnless(iTermShellforgeSidebar.floats)
        root.layoutSubtreeIfNeeded()
        let session = try XCTUnwrap(fixture.terminal.currentSession())
        let column = try XCTUnwrap(root.subviews.compactMap { $0 as? iTermLayerBackedSolidColorView }
            .first { $0.identifier == iTermRootTerminalView.shellforgeColumnBackgroundIdentifier })
        column.color = .systemRed
        // In the app the text view reports the change once the screen's state reaches it, which a
        // test window with no running terminal never does: report it as the tab then does.
        let tab = try XCTUnwrap(fixture.terminal.currentTab())
        fixture.terminal.tabSessionDidChangeBackgroundColor(tab)
        XCTAssertTrue(sameColor(column.color, session.processedBackgroundColor),
                      "column \(String(describing: column.color)), terminal \(String(describing: session.processedBackgroundColor))")
    }

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
        // The window buttons, then the toggle, come before the header's title.
        XCTAssertGreaterThan(controls.buttonsMaxX, zoom.maxX - panel.minX)
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
        // The strip too: its title is inked for the window's lightness, not the terminal's.
        let strip = try XCTUnwrap(root.subviews.compactMap { $0 as? iTermLayerBackedSolidColorView }
            .first { !$0.isHidden && $0.frame.maxY >= root.bounds.height - 0.5 && $0.frame.minX > root.shellforgeSidebarFrame.maxX })
        XCTAssertFalse(sameColor(strip.color, session.processedBackgroundColor), "the strip in a window of the other lightness")
    }

    /// The panel's corners are concentric with the window's: its radius less the inset, never below 0.
    func testThePanelCornerFollowsTheWindowsRadius() {
        XCTAssertEqual(iTermShellforgeSidebar.panelCornerRadius(forWindowRadius: 30), 30 - iTermShellforgeSidebar.floatingInset)
    }

    /// A measured radius below a plain window's is a mismeasure — a toolbar window is never less
    /// round — and the panel never goes square: 8.5 pt was measured once, and the panel lost its
    /// corners.
    func testThePanelNeverGoesSquare() {
        let floor = iTermShellforgeSidebar.panelCornerRadius(forWindowRadius: iTermWindowCornerRadiusDetector.fallbackCornerRadius)
        XCTAssertEqual(iTermShellforgeSidebar.panelCornerRadius(forWindowRadius: 8.5), floor)
        XCTAssertGreaterThanOrEqual(floor, 8)
    }

    /// A toolbar rounds a macOS 26 window's corners further, so a radius measured without one must
    /// not stand for a window with one.
    func testTheMeasuredRadiusIsKeptPerToolbar() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let bare = iTermWindowCornerRadiusDetector.cacheKey(for: window)
        window.toolbar = NSToolbar(identifier: "test")
        XCTAssertNotEqual(iTermWindowCornerRadiusDetector.cacheKey(for: window), bare)
    }

    /// The sidebar draws its panel with the window's radius as measured: a radius in the detector's
    /// cache for this window reaches the panel, less the inset.
    func testTheSidebarHearsThePanelRadius() throws {
        try XCTSkipUnless(iTermShellforgeSidebar.floats)
        let saved = iTermUserDefaults.windowCornerRadiusCache
        defer { iTermUserDefaults.windowCornerRadiusCache = saved }
        var cache = saved ?? [:]
        cache[iTermWindowCornerRadiusDetector.cacheKey(for: fixture.window)] = 27
        iTermUserDefaults.windowCornerRadiusCache = cache
        root.updateTitleAndBorderViews()
        let sidebar = try XCTUnwrap(root.shellforgeSidebarView)
        XCTAssertEqual(iTermShellforgeSidebar.reportedPanelCornerRadius(of: sidebar),
                       27 - iTermShellforgeSidebar.floatingInset)
    }

    func testFittingTheWindowToItsTabsKeepsTheColumns() throws {
        try XCTSkipUnless(iTermShellforgeSidebar.floats)
        let session = try XCTUnwrap(fixture.terminal.currentSession())
        root.layoutSubtreeIfNeeded()
        let columns = session.screen.width()
        for _ in 0..<2 {
            fixture.terminal.fitWindow(toTabsExcludingTmuxTabs: false)
            root.layoutSubtreeIfNeeded()
        }
        XCTAssertEqual(session.screen.width(), columns)
    }

    /// A see-through terminal keeps iTerm2's own see-through window: a solid block of its colour
    /// behind the panel would be the opposite of one surface.
    func testASeeThroughTerminalGetsNoSolidColumn() throws {
        try XCTSkipUnless(iTermShellforgeSidebar.floats)
        let session = try XCTUnwrap(fixture.terminal.currentSession())
        session.setSessionSpecificProfileValues([KEY_TRANSPARENCY: 0.4])
        root.updateTitleAndBorderViews()
        let column = root.subviews.compactMap { $0 as? iTermLayerBackedSolidColorView }
            .first { $0.identifier == iTermRootTerminalView.shellforgeColumnBackgroundIdentifier }
        XCTAssertTrue(column?.isHidden ?? true, "transparency \(session.textview?.transparencyAlpha ?? 1)")
    }

    /// The header shares the toolbar's band, but a click there is the sidebar's: the window's title
    /// bar must not take it for a drag or let it fall through to nothing.
    func testAClickOnTheHeaderReachesTheSidebar() throws {
        try XCTSkipUnless(iTermShellforgeSidebar.floats)
        root.layoutSubviews()
        let sidebar = try XCTUnwrap(root.shellforgeSidebarView)
        let controls = try XCTUnwrap(iTermShellforgeSidebar.reportedWindowControls(of: sidebar))
        let frameView = try XCTUnwrap(fixture.window.contentView?.superview)
        let panel = root.shellforgeSidebarFrame
        // On the header's row, among its trailing buttons, in window coordinates.
        let point = NSPoint(x: panel.maxX - 40, y: panel.maxY - controls.buttonsMidY)
        let hit = try XCTUnwrap(frameView.hitTest(frameView.convert(point, from: root)))
        XCTAssertTrue(hit === sidebar || hit.isDescendant(of: sidebar), "the click lands on \(hit)")
    }

    /// A floating window in Lion full screen still floats its sidebar: the surface behind the panel
    /// must not fall back to the window's grey there.
    func testAFullScreenWindowFromAFloatingOneStillFloats() throws {
        try XCTSkipUnless(iTermShellforgeSidebar.floats)
        XCTAssertTrue(iTermShellforgeSidebar.floatsWindow(ofType: .WINDOW_TYPE_LION_FULL_SCREEN, savedType: .WINDOW_TYPE_NORMAL))
        XCTAssertTrue(iTermShellforgeSidebar.floatsWindow(ofType: .WINDOW_TYPE_NORMAL, savedType: .WINDOW_TYPE_NORMAL))
        XCTAssertFalse(iTermShellforgeSidebar.floatsWindow(ofType: .WINDOW_TYPE_LION_FULL_SCREEN, savedType: .WINDOW_TYPE_ACCESSORY))
    }

    /// A square window — full screen — keeps a rounded panel: the panel is rounded for itself there.
    func testASquareWindowKeepsARoundedPanel() {
        XCTAssertEqual(iTermShellforgeSidebar.panelCornerRadius(forWindowRadius: 0),
                       iTermShellforgeSidebar.panelCornerRadius(forWindowRadius: iTermWindowCornerRadiusDetector.fallbackCornerRadius))
        XCTAssertGreaterThan(iTermShellforgeSidebar.panelCornerRadius(forWindowRadius: 0), 0)
    }

    /// The panel stands a little further off the window's edges than a hairline gap: 10 pt.
    func testThePanelsInsetIsTenPoints() {
        XCTAssertEqual(iTermShellforgeSidebar.floatingInset, 10)
    }

    /// The sidebar's one toggle: just after the window buttons, on their row — as Finder's.
    func testTheToggleSitsJustAfterTheWindowButtons() throws {
        try XCTSkipUnless(iTermShellforgeSidebar.floats)
        root.layoutSubviews()
        let toggle = root.shellforgeToggleFrame
        let zoom = try XCTUnwrap(fixture.window.standardWindowButton(.zoomButton))
        let zoomFrame = zoom.convert(zoom.bounds, to: root)
        XCTAssertEqual(toggle.minX, zoomFrame.maxX + 12, accuracy: 0.5)
        XCTAssertEqual(toggle.midY, zoomFrame.midY, accuracy: 0.5)
    }

    /// Open or closed, the toggle stays where it is.
    func testTheToggleStaysPutWhenTheSidebarHides() throws {
        try XCTSkipUnless(iTermShellforgeSidebar.floats)
        root.layoutSubviews()
        let open = root.shellforgeToggleFrame
        root.toggleShellforgeSidebar()
        defer { root.toggleShellforgeSidebar() }
        root.layoutSubviews()
        XCTAssertEqual(root.shellforgeToggleFrame, open)
    }

    /// The header starts after the toggle, on its row.
    func testTheHeaderStartsAfterTheToggle() throws {
        try XCTSkipUnless(iTermShellforgeSidebar.floats)
        root.layoutSubviews()
        let sidebar = try XCTUnwrap(root.shellforgeSidebarView)
        let controls = try XCTUnwrap(iTermShellforgeSidebar.reportedWindowControls(of: sidebar))
        let toggle = root.shellforgeToggleFrame, panel = root.shellforgeSidebarFrame
        XCTAssertEqual(controls.buttonsMaxX, toggle.maxX - panel.minX, accuracy: 0.5)
        XCTAssertEqual(controls.buttonsMidY, panel.maxY - toggle.midY, accuracy: 0.5)
    }

    /// Without window buttons — full screen — the toggle has a row of its own at the panel's top, its
    /// glyph in line with the rows' leading edge; nothing is left of the terminal while closed.
    func testWithoutWindowButtonsTheToggleTopsThePanel() {
        let frame = iTermShellforgeSidebar.toggleFrame(zoomButton: .zero, hasWindowButtons: false, rootHeight: 500)
        XCTAssertGreaterThan(frame.minX, iTermShellforgeSidebar.floatingInset, "inside the panel")
        XCTAssertEqual(500 - frame.midY, iTermShellforgeSidebar.floatingInset + iTermShellforgeSidebar.fullScreenHeaderMidY, accuracy: 0.5)
    }

    /// The reveal: the edge shows the sidebar; leaving it hides it after the delay — unless the
    /// pointer came back, or it is still wanted then; reset puts it away at once.
    func testTheRevealShowsAndHides() {
        var pending: [() -> Void] = []
        let reveal = ShellforgeSidebarReveal(schedule: { _, work in pending.append(work) })
        var changes = 0
        reveal.onChange = { changes += 1 }
        reveal.pointerEntered()
        XCTAssertTrue(reveal.revealed)
        reveal.pointerExited()
        reveal.pointerEntered()              // back before the delay is up
        pending.removeFirst()()
        XCTAssertTrue(reveal.revealed, "the pointer came back")
        reveal.shouldConceal = { false }     // a menu is open
        reveal.pointerExited()
        pending.removeFirst()()
        XCTAssertTrue(reveal.revealed, "still wanted")
        reveal.shouldConceal = { true }
        pending.removeFirst()()              // it asked again after another delay
        XCTAssertFalse(reveal.revealed)
        reveal.pointerEntered()
        reveal.reset()
        XCTAssertFalse(reveal.revealed)
        XCTAssertEqual(changes, 4)
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
        XCTAssertGreaterThanOrEqual(root.shellforgeWindowTitleFrame.minX, root.shellforgeToggleFrame.maxX)
    }

    func testTheDragHandleNeverMovesTheWindow() {
        XCTAssertFalse(iTermDragHandleView(frame: NSRect(x: 0, y: 0, width: 4, height: 100)).mouseDownCanMoveWindow)
    }
}
