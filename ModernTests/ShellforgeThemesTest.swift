//
//  ShellforgeThemesTest.swift
//  Shellforge
//
//  Settings › Core › Theme: a single light or dark theme holds the app to its appearance, the
//  Shellforge theme leaves it to the Mac, the Mac turning dark brings the dark slot's theme, and
//  Match Terminal lays the theme over the terminal only while it is on.
//

import XCTest
@testable import iTerm2SharedARC

@MainActor
final class ShellforgeThemesTest: XCTestCase {
    private var savedDefaults: ShellforgeDefaultsSnapshot!
    private var savedAppearance: NSAppearance?

    override func setUp() async throws {
        savedDefaults = ShellforgeDefaultsSnapshot()
        savedAppearance = NSApp.appearance
        iTermShellforgeTerminalMatch.setOn(false)
        // iTerm2's own Light and Dark themes pin the app's appearance; Automatic leaves it be.
        iTermUserDefaults.userDefaults().set(iTermPreferencesTabStyle.TAB_STYLE_AUTOMATIC.rawValue, forKey: kPreferenceKeyTabStyle)
        iTermShellforgeThemes.save(followsMac: true)
    }

    override func tearDown() async throws {
        savedDefaults.restore()
        NSApp.appearance = savedAppearance
    }

    func testASingleThemeSetsTheAppAppearance() {
        iTermShellforgeThemes.save(followsMac: false, single: "dracula")
        XCTAssertEqual(iTermShellforgeThemes.currentThemeID, "dracula")
        XCTAssertEqual(NSApp.appearance?.name, .darkAqua)
        iTermShellforgeThemes.save(followsMac: false, single: "github-light")
        XCTAssertEqual(iTermShellforgeThemes.currentThemeID, "github-light")
        XCTAssertEqual(NSApp.appearance?.name, .aqua)
    }

    func testShellforgeClearsTheForcedAppearance() {
        iTermShellforgeThemes.save(followsMac: false, single: "dracula")
        XCTAssertNotNil(NSApp.appearance)
        iTermShellforgeThemes.save(followsMac: false, single: "shellforge")
        XCTAssertNil(NSApp.appearance, "the adaptive theme leaves the appearance to the Mac")
        XCTAssertEqual(iTermShellforgeThemes.currentThemeID, "shellforge")
        iTermShellforgeThemes.save(followsMac: false, single: "nord")
        iTermShellforgeThemes.save(followsMac: true, light: "github-light", dark: "dracula")
        XCTAssertNil(NSApp.appearance, "following the Mac leaves it to the Mac")
    }

    /// iTerm2 setting its own appearance — on a tab style change, or Match Terminal's recolour —
    /// keeps the theme's.
    func testITerm2KeepsTheForcedAppearance() {
        iTermShellforgeThemes.save(followsMac: false, single: "github-light")
        (NSApp as? iTermApplication)?.updateAppearance()
        XCTAssertEqual(NSApp.appearance?.name, .aqua)
        iTermShellforgeTerminalMatch.setOn(true)
        XCTAssertEqual(NSApp.appearance?.name, .aqua)
    }

    func testAnAppearanceFlipReappliesTheTheme() {
        iTermShellforgeThemes.save(followsMac: true, light: "github-light", dark: "dracula")
        iTermShellforgeThemes.appearanceChanged(isDark: true)
        XCTAssertEqual(iTermShellforgeThemes.currentThemeID, "dracula")
        iTermShellforgeThemes.appearanceChanged(isDark: false)
        XCTAssertEqual(iTermShellforgeThemes.currentThemeID, "github-light")
        iTermShellforgeThemes.appearanceChanged(isDark: true)
        XCTAssertEqual(iTermShellforgeThemes.currentThemeID, "dracula")
    }

    func testMatchOffLeavesProfilesAlone() {
        iTermShellforgeThemes.save(followsMac: false, single: "dracula")
        let profile: [AnyHashable: Any] = [KEY_BACKGROUND_COLOR: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1).dictionaryValue,
                                           KEY_FOREGROUND_COLOR: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1).dictionaryValue]
        let result = iTermShellforgeTerminalMatch.profile(forColors: profile, keeping: nil)
        XCTAssertEqual(result as NSDictionary, profile as NSDictionary)
    }

    /// With Match Terminal on, choosing another theme recolours the open sessions at once.
    func testAThemeChangeRecoloursAMatchedTerminal() throws {
        let fixture = TerminalWindowTestFixture()
        defer { fixture.close() }
        let session = try XCTUnwrap(fixture.terminal.currentSession())
        iTermShellforgeTerminalMatch.setOn(true)
        iTermShellforgeThemes.save(followsMac: false, single: "github-light")
        let light = try XCTUnwrap(session.screen.colorMap.color(forKey: kColorMapBackground)?.usingColorSpace(.sRGB))
        iTermShellforgeThemes.save(followsMac: false, single: "dracula")
        let dark = try XCTUnwrap(session.screen.colorMap.color(forKey: kColorMapBackground)?.usingColorSpace(.sRGB))
        let expected = try XCTUnwrap(iTermShellforgeTerminalMatch.paletteColor(forKey: KEY_BACKGROUND_COLOR)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(light.brightnessComponent, dark.brightnessComponent + 0.3, "GitHub Light, then Dracula")
        XCTAssertEqual(Double(dark.redComponent), Double(expected.redComponent), accuracy: 2.0 / 255)
        XCTAssertEqual(Double(dark.greenComponent), Double(expected.greenComponent), accuracy: 2.0 / 255)
        XCTAssertEqual(Double(dark.blueComponent), Double(expected.blueComponent), accuracy: 2.0 / 255)
    }
}
