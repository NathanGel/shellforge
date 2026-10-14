//
//  ShellforgeTerminalMatchTest.swift
//  Shellforge
//
//  Settings › Core › Terminal: while on, every session draws in Shellforge's colours, laid over its
//  profile's copy; the saved profile is never written, and a colour set for one session wins.
//

import XCTest
@testable import iTerm2SharedARC

@MainActor
final class ShellforgeTerminalMatchTest: XCTestCase {
    private var fixture: TerminalWindowTestFixture!

    override func setUp() async throws {
        iTermShellforgeTerminalMatch.setOn(false)
        fixture = TerminalWindowTestFixture()
    }

    override func tearDown() async throws {
        iTermShellforgeTerminalMatch.setOn(false)
        fixture.close()
    }

    /// Within 2/255 per channel: the colour map may hold a colour in its own space.
    private func assertSame(_ a: NSColor?, _ b: NSColor?, _ message: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let a = try XCTUnwrap(a?.usingColorSpace(.sRGB), message, file: file, line: line)
        let b = try XCTUnwrap(b?.usingColorSpace(.sRGB), message, file: file, line: line)
        for (x, y) in [(a.redComponent, b.redComponent), (a.greenComponent, b.greenComponent), (a.blueComponent, b.blueComponent)] {
            XCTAssertEqual(Double(x), Double(y), accuracy: 2.0 / 255, message, file: file, line: line)
        }
    }

    private func background(_ session: PTYSession) -> NSColor? { session.screen.colorMap.color(forKey: kColorMapBackground) }

    func testOnColoursASessionAndLeavesTheProfile() throws {
        let session = try XCTUnwrap(fixture.terminal.currentSession())
        let guid = try XCTUnwrap(session.profile?[KEY_GUID] as? String)
        let saved = ProfileModel.sharedInstance().bookmark(withGuid: guid)?[KEY_BACKGROUND_COLOR] as? NSDictionary
        iTermShellforgeTerminalMatch.setOn(true)
        try assertSame(background(session), iTermShellforgeTerminalMatch.paletteColor(forKey: KEY_BACKGROUND_COLOR), "background")
        try assertSame(session.screen.colorMap.color(forKey: kColorMapAnsiRed),
                       iTermShellforgeTerminalMatch.paletteColor(forKey: "Ansi 1 Color"), "ansi red")
        XCTAssertEqual(ProfileModel.sharedInstance().bookmark(withGuid: guid)?[KEY_BACKGROUND_COLOR] as? NSDictionary, saved,
                       "the saved profile is not written")
    }

    func testOffBringsBackTheProfilesColours() throws {
        let session = try XCTUnwrap(fixture.terminal.currentSession())
        let before = background(session)
        iTermShellforgeTerminalMatch.setOn(true)
        iTermShellforgeTerminalMatch.setOn(false)
        try assertSame(background(session), before, "the profile's background again")
    }

    func testATabOpenedWhileOnIsMatched() throws {
        iTermShellforgeTerminalMatch.setOn(true)
        let session = fixture.addTab()
        try assertSame(background(session), iTermShellforgeTerminalMatch.paletteColor(forKey: KEY_BACKGROUND_COLOR), "new tab")
    }

    func testASessionsOwnBackgroundIsKept() throws {
        let session = try XCTUnwrap(fixture.terminal.currentSession())
        let profile = try XCTUnwrap(session.profile)
        let key = iTermAmendedColorKey(KEY_BACKGROUND_COLOR, profile, NSApp.effectiveAppearance.it_isDark)
        let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        session.setSessionSpecificProfileValues([key: red.dictionaryValue])
        iTermShellforgeTerminalMatch.setOn(true)
        try assertSame(background(session), red, "kept while on")
        iTermShellforgeTerminalMatch.setOn(false)
        try assertSame(background(session), red, "kept after off")
    }

    func testSeparateLightAndDarkColoursAreMatchedToo() throws {
        let session = try XCTUnwrap(fixture.terminal.currentSession())
        session.setSessionSpecificProfileValues([KEY_USE_SEPARATE_COLORS_FOR_LIGHT_AND_DARK_MODE: true])
        iTermShellforgeTerminalMatch.setOn(true)
        try assertSame(background(session), iTermShellforgeTerminalMatch.paletteColor(forKey: KEY_BACKGROUND_COLOR), "separate colours")
    }

    func testTheThemeIsMinimalOnlyWhileOn() {
        let saved = iTermPreferences.int(forKey: kPreferenceKeyTabStyle)
        let stored = iTermUserDefaults.userDefaults().object(forKey: kPreferenceKeyTabStyle) as? NSNumber
        iTermShellforgeTerminalMatch.setOn(true)
        XCTAssertEqual(iTermPreferences.int(forKey: kPreferenceKeyTabStyle), Int32(iTermPreferencesTabStyle.TAB_STYLE_MINIMAL.rawValue))
        XCTAssertEqual(iTermUserDefaults.userDefaults().object(forKey: kPreferenceKeyTabStyle) as? NSNumber, stored,
                       "the saved theme is not written")
        iTermShellforgeTerminalMatch.setOn(false)
        XCTAssertEqual(iTermPreferences.int(forKey: kPreferenceKeyTabStyle), saved)
    }

    nonisolated func testOverridesThemeAnswersOffTheMainThread() async {
        let answer = await Task.detached { iTermShellforgeTerminalMatch.overridesTheme }.value
        XCTAssertFalse(answer)
    }
}
