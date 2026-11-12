//
//  ShellforgeTabLookTest.swift
//  Shellforge
//
//  VS Code’s tab look: iTerm2’s Minimal tab style whatever iTerm2 theme is saved, a 2-pt accent
//  edge along the top of the active tab, and the tab strip in the theme’s colours. Under the
//  Shellforge theme without Match Terminal, Minimal keeps its own colours.
//

import XCTest
@testable import iTerm2SharedARC

/// Minimal’s own source of colour: the terminal’s background, here a fixed red.
private final class RedTerminal: NSObject, PSMMinimalTabStyleDelegate {
    static let red = NSColor(srgbRed: 0.8, green: 0.1, blue: 0.1, alpha: 1)
    func minimalTabStyleBackgroundColor() -> NSColor { Self.red }
}

@MainActor
final class ShellforgeTabLookTest: XCTestCase {
    private var savedDefaults: ShellforgeDefaultsSnapshot!
    private let terminal = RedTerminal()

    override func setUp() async throws {
        savedDefaults = ShellforgeDefaultsSnapshot()
        iTermShellforgeTerminalMatch.setOn(false)
        iTermShellforgeThemes.save(followsMac: true)
        iTermShellforgeTabLook.start()
    }

    override func tearDown() async throws {
        savedDefaults.restore()
    }

    /// Dracula’s published colours (draculatheme.com/spec), as the catalogue gives them.
    private enum Dracula {
        static let background = NSColor(srgbRed: 0x28 / 255.0, green: 0x2A / 255.0, blue: 0x36 / 255.0, alpha: 1)
        static let sidebar = NSColor(srgbRed: 0x21 / 255.0, green: 0x22 / 255.0, blue: 0x2C / 255.0, alpha: 1)
        static let accent = NSColor(srgbRed: 0xBD / 255.0, green: 0x93 / 255.0, blue: 0xF9 / 255.0, alpha: 1)
    }

    /// Within 3/255 per channel. Not alpha: a style with no tab bar to ask reads the window as
    /// see-through, and lays its alpha over the colour.
    private func assertSame(_ a: NSColor?, _ b: NSColor?, _ message: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let a = try XCTUnwrap(a?.usingColorSpace(.sRGB), message, file: file, line: line)
        let b = try XCTUnwrap(b?.usingColorSpace(.sRGB), message, file: file, line: line)
        for (x, y) in [(a.redComponent, b.redComponent), (a.greenComponent, b.greenComponent), (a.blueComponent, b.blueComponent)] {
            XCTAssertEqual(Double(x), Double(y), accuracy: 3.0 / 255, message, file: file, line: line)
        }
    }

    private func minimalStyle() -> PSMMinimalTabStyle {
        let style = PSMMinimalTabStyle()
        style.delegate = terminal
        return style
    }

    func testTheTabStyleIsAlwaysMinimal() {
        let defaults = iTermUserDefaults.userDefaults()
        for saved in [iTermPreferencesTabStyle.TAB_STYLE_LIGHT, .TAB_STYLE_DARK, .TAB_STYLE_AUTOMATIC, .TAB_STYLE_COMPACT] {
            defaults.set(saved.rawValue, forKey: kPreferenceKeyTabStyle)
            for matched in [false, true] {
                iTermShellforgeTerminalMatch.setOn(matched)
                XCTAssertEqual(iTermPreferences.int(forKey: kPreferenceKeyTabStyle), Int32(iTermPreferencesTabStyle.TAB_STYLE_MINIMAL.rawValue),
                               "saved \(saved.rawValue), match \(matched)")
                XCTAssertEqual((defaults.object(forKey: kPreferenceKeyTabStyle) as? NSNumber)?.intValue, Int(saved.rawValue),
                               "the saved theme is not written")
            }
        }
    }

    nonisolated func testTheThemeIsOverriddenOffTheMainThread() async {
        let answer = await Task.detached { iTermShellforgeTabLook.overridesTheme }.value
        XCTAssertTrue(answer)
    }

    func testTheActiveEdgeIsTheThemesAccent() throws {
        try assertSame(iTermShellforgeTabLook.activeEdgeColor, NSColor.controlAccentColor, "Shellforge: the system accent")
        iTermShellforgeThemes.save(followsMac: false, single: "dracula")
        try assertSame(iTermShellforgeTabLook.activeEdgeColor, Dracula.accent, "Dracula’s accent")
        XCTAssertEqual(iTermShellforgeTabLook.edgeWidth, 2)
    }

    /// The edge is drawn along the top of the selected tab, 2 pt deep, and nowhere else.
    func testTheEdgeIsDrawnAlongTheTopOfTheActiveTab() throws {
        iTermShellforgeThemes.save(followsMac: false, single: "dracula")
        let size = NSSize(width: 400, height: 24)
        let bar = PSMTabBarControl(frame: NSRect(origin: .zero, size: size))
        let cell = try XCTUnwrap(PSMTabBarCell(controlView: bar))
        cell.frame = NSRect(x: 100, y: 0, width: 120, height: 24)
        let style = minimalStyle()
        style.tabBar = bar
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        // The tab bar is flipped: y = 0 is its top.
        context.cgContext.translateBy(x: 0, y: size.height)
        context.cgContext.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        style.drawPostHocDecorations(onSelectedCell: cell, tabBarControl: bar)
        // The accent as this bitmap holds it, to compare with: bottom left, clear of the edge.
        Dracula.accent.set()
        NSRect(x: 0, y: 20, width: 10, height: 4).fill()
        NSGraphicsContext.restoreGraphicsState()
        // colorAt's y = 0 is the top row.
        let accent = rep.colorAt(x: 5, y: 22)
        try assertSame(rep.colorAt(x: 160, y: 0), accent, "the edge’s first row")
        try assertSame(rep.colorAt(x: 160, y: 1), accent, "the edge’s second row")
        XCTAssertEqual(rep.colorAt(x: 160, y: 0)?.alphaComponent, 1, "opaque")
        XCTAssertEqual(rep.colorAt(x: 160, y: 2)?.alphaComponent, 0, "2 pt deep")
        XCTAssertEqual(rep.colorAt(x: 50, y: 0)?.alphaComponent, 0, "not over another tab")
        XCTAssertEqual(rep.colorAt(x: 300, y: 0)?.alphaComponent, 0, "not past the tab")
    }

    func testShellforgeLeavesMinimalsColours() throws {
        XCTAssertNil(iTermShellforgeTabLook.stripColor)
        XCTAssertNil(iTermShellforgeTabLook.activeTabColor)
        XCTAssertNil(iTermShellforgeTabLook.inactiveTabColor)
        let style = minimalStyle()
        try assertSame(style.tabBarColor, RedTerminal.red, "the strip is the terminal’s background, as Minimal draws it")
        try assertSame(style.backgroundColorSelected(true, highlightAmount: 0), RedTerminal.red, "the active tab too")
    }

    func testMatchTerminalColoursTheStripInShellforgesColours() throws {
        iTermShellforgeTerminalMatch.setOn(true)
        let strip = try XCTUnwrap(iTermShellforgeTabLook.stripColor)
        XCTAssertNotNil(iTermShellforgeTabLook.activeTabColor)
        XCTAssertNil(iTermShellforgeTabLook.inactiveTabColor, "Minimal steps the other tabs off the strip")
        try assertSame(minimalStyle().tabBarColor, strip, "the strip, not the terminal’s own background")
    }

    func testAThemeColoursTheStrip() throws {
        iTermShellforgeThemes.save(followsMac: false, single: "dracula")
        try assertSame(iTermShellforgeTabLook.stripColor, Dracula.sidebar, "strip")
        try assertSame(iTermShellforgeTabLook.activeTabColor, Dracula.background, "active tab")
        try assertSame(iTermShellforgeTabLook.inactiveTabColor, Dracula.sidebar, "inactive tab")
        let style = minimalStyle()
        try assertSame(style.tabBarColor, Dracula.sidebar, "Minimal’s strip")
        try assertSame(style.backgroundColorSelected(true, highlightAmount: 0), Dracula.background, "Minimal’s active tab")
    }

    /// Heard as a theme change, as Match Terminal’s recolour is: every window’s tab bar takes a new
    /// style and redraws.
    func testAThemeChangeRedrawsTheTabs() {
        var heard = false
        iTermPreferenceDidChangeNotification.subscribe(self) { notification in
            if notification.key == kPreferenceKeyTabStyle { heard = true }
        }
        iTermShellforgeThemes.save(followsMac: false, single: "nord")
        XCTAssertTrue(heard)
    }
}
