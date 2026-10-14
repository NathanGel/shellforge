# M11 Match the terminal to Shellforge — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** an optional Settings switch that draws every terminal in Shellforge's colours and iTerm2's window parts in its Minimal theme, without ever writing the user's profiles or theme setting.

**Architecture:** the palette is pure code in the Shellforge package (ShellforgeDesign); the saved switch and its Settings card are in ShellforgeUI. An app-side Swift bridge, `iTermShellforgeTerminalMatch`, answers three small hooks in iTerm2's files: `PTYSession loadColorsFromProfile:` (colours laid over the profile's copy), `iTermPreferences computedTabStyle` (Minimal) and the Appearance pane's Theme control (disabled while overridden).

**Tech Stack:** Swift 6 package (`Shellforge/`, swift-testing, `scripts/swift.sh`), the iTerm2 app (Objective-C and Swift, XCTest host tests in `ModernTests`).

**Spec:** `Shellforge/docs/plans/2026-10-14-m11-terminal-match-design.md`

## Global Constraints

- Off by default; the defaults key is `ShellforgeMatchTerminal`, in `iTermUserDefaults.userDefaults()`.
- The user's profiles (`ProfileModel`) and `kPreferenceKeyTabStyle` are never written.
- 23 palette keys; contrast at least 4.5:1 against the background for Foreground, Bold, Ansi 1–7 and 9–15; Ansi 0 and 8 exempt; a short colour is lightened in 5 % steps.
- Each palette key is written as its base key and its ` (Light)` and ` (Dark)` variants.
- Keys a session set for itself (`_overriddenFields`) are never overlaid.
- Deployment target macOS 12 (app) and 13 (package): no availability checks below that.
- User-visible strings use curly quotes and apostrophes (’ “ ”), never straight ones.
- Swift: `it_fatalError` / `it_assert`, never `fatalError` / `assert`. No force unwraps in new code.
- `git add` every new file at once. A new app-side Swift file goes into the project with `tools/add_file_to_xcodeproj.rb <path> iTerm2SharedARC`. Package and `ModernTests` files need no project entry.
- Never `git add` a submodule.
- Commands: package tests `cd Shellforge && scripts/swift.sh test --filter <Suite>`; app build `tools/build.sh`; host tests `tools/run_tests.expect ModernTests/<Class>`. Treat warnings as errors.

## Review Focus

1. A profile that uses separate light and dark colours: the match must show in both appearances. (Task 3, `testSeparateLightAndDarkColoursAreMatchedToo`.)
2. A session whose colour was set for it alone (Edit Session, the Python API): that colour survives switching on and off. (Task 3, `testASessionsOwnBackgroundIsKept`.)
3. A tab opened while the match is on: it must be matched without a toggle. (Task 3, `testATabOpenedWhileOnIsMatched`.)
4. Cancel in Settings after flipping the switch: nothing may change. (Task 2, `cancelLeavesTheSavedValue`.)
5. `computedTabStyle` may be asked off the main thread: `overridesTheme` must not touch main-actor state. (Task 4, `nonisolated`, read straight from defaults; `testOverridesThemeAnswersOffTheMainThread`.)

---

### Task 1: The palette (ShellforgeDesign)

**Files:**
- Create: `Shellforge/Sources/ShellforgeDesign/TerminalPalette.swift`
- Test: `Shellforge/Tests/ShellforgeDesignTests/TerminalPaletteTests.swift`

**Interfaces:**
- Produces:
  - `public enum TerminalColorRole: Hashable, Sendable { case background, foreground, bold, cursor, cursorText, selection, selectedText; case ansi(Int); public static let all: [TerminalColorRole]; public var needsContrast: Bool }`
  - `public struct SRGB: Equatable, Sendable { public var red, green, blue: Double; public init(red:green:blue:); public func contrast(with: SRGB) -> Double; public func lightened(by: Double) -> SRGB }`
  - `public enum ShellforgeTerminalPalette { public static let minimumContrast: Double; public static func colors(in appearance: NSAppearance?) -> [TerminalColorRole: SRGB]; public static func readable(_: SRGB, on: SRGB) -> SRGB }`

- [ ] **Step 1: Write the failing tests**

```swift
import AppKit
import Testing
@testable import ShellforgeDesign

/// Shellforge's terminal colours: 23 keys from the sidebar's own macOS colours, each readable on
/// the sidebar's surface.
@Suite struct TerminalPaletteTests {
    private let dark = NSAppearance(named: .darkAqua)

    @Test func everyRoleHasAColour() {
        let colors = ShellforgeTerminalPalette.colors(in: dark)
        #expect(TerminalColorRole.all.count == 23)
        #expect(Set(colors.keys) == Set(TerminalColorRole.all))
    }

    @Test func theBackgroundIsTheSidebarsSurface() throws {
        var surface = SRGB(red: 0, green: 0, blue: 0)
        try #require(dark).performAsCurrentDrawingAppearance {
            surface = SRGB(NSColor.windowBackgroundColor, over: SRGB(red: 0, green: 0, blue: 0))
        }
        #expect(ShellforgeTerminalPalette.colors(in: dark)[.background] == surface)
    }

    @Test func theCursorTextIsTheBackground() {
        let colors = ShellforgeTerminalPalette.colors(in: dark)
        #expect(colors[.cursorText] == colors[.background])
    }

    @Test func everyTextColourIsReadableOnTheBackground() throws {
        let colors = ShellforgeTerminalPalette.colors(in: dark)
        let background = try #require(colors[.background])
        for role in TerminalColorRole.all where role.needsContrast {
            let color = try #require(colors[role])
            #expect(color.contrast(with: background) >= ShellforgeTerminalPalette.minimumContrast, "\(role)")
        }
    }

    @Test func blackAndBrightBlackAreExempt() {
        #expect(!TerminalColorRole.ansi(0).needsContrast)
        #expect(!TerminalColorRole.ansi(8).needsContrast)
        #expect(TerminalColorRole.ansi(1).needsContrast)
        #expect(TerminalColorRole.foreground.needsContrast)
    }

    @Test func aReadableColourIsLeftAlone() {
        let background = SRGB(red: 0.12, green: 0.12, blue: 0.12)
        let white = SRGB(red: 1, green: 1, blue: 1)
        #expect(ShellforgeTerminalPalette.readable(white, on: background) == white)
    }

    @Test func aDarkColourIsLightenedOnlyUntilItPasses() {
        let background = SRGB(red: 0.12, green: 0.12, blue: 0.12)
        let dim = SRGB(red: 0.25, green: 0.1, blue: 0.1)
        let readable = ShellforgeTerminalPalette.readable(dim, on: background)
        #expect(readable.contrast(with: background) >= ShellforgeTerminalPalette.minimumContrast)
        // One step back fails: it stopped at the first passing value, short of white.
        let stepBack = SRGB(red: (readable.red - 0.05) / 0.95, green: (readable.green - 0.05) / 0.95, blue: (readable.blue - 0.05) / 0.95)
        #expect(stepBack.contrast(with: background) < ShellforgeTerminalPalette.minimumContrast)
    }

    @Test func contrastIsTheWCAGRatio() {
        let black = SRGB(red: 0, green: 0, blue: 0), white = SRGB(red: 1, green: 1, blue: 1)
        #expect(abs(white.contrast(with: black) - 21) < 0.01)
        #expect(abs(black.contrast(with: black) - 1) < 0.0001)
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd Shellforge && scripts/swift.sh test --filter TerminalPaletteTests`
Expected: build error, `cannot find 'ShellforgeTerminalPalette' in scope`.

- [ ] **Step 3: Write the palette**

```swift
import AppKit

/// One of the 23 colours a terminal profile carries that the Shellforge match sets.
public enum TerminalColorRole: Hashable, Sendable {
    case background, foreground, bold, cursor, cursorText, selection, selectedText
    /// ANSI colour 0–15: 0–7 normal, 8–15 bright.
    case ansi(Int)

    public static let all: [TerminalColorRole] =
        [.background, .foreground, .bold, .cursor, .cursorText, .selection, .selectedText] + (0..<16).map { .ansi($0) }

    /// Held to `ShellforgeTerminalPalette.minimumContrast` against the background. Black and bright
    /// black are meant to be dim; the cursor and selection are fills, not text.
    public var needsContrast: Bool {
        switch self {
        case .foreground, .bold: true
        case .ansi(let index): index != 0 && index != 8
        case .background, .cursor, .cursorText, .selection, .selectedText: false
        }
    }
}

/// An opaque sRGB colour, components 0…1.
public struct SRGB: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// `color` in sRGB, its alpha composited over `background`: the label colours are white at
    /// less than full alpha, and a terminal colour cannot be translucent.
    init(_ color: NSColor, over background: SRGB) {
        guard let srgb = color.usingColorSpace(.sRGB) else {
            self = background
            return
        }
        let alpha = Double(srgb.alphaComponent)
        red = Double(srgb.redComponent) * alpha + background.red * (1 - alpha)
        green = Double(srgb.greenComponent) * alpha + background.green * (1 - alpha)
        blue = Double(srgb.blueComponent) * alpha + background.blue * (1 - alpha)
    }

    /// WCAG 2 relative luminance.
    private var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG 2 contrast ratio, 1…21.
    public func contrast(with other: SRGB) -> Double {
        let (a, b) = (luminance + 0.05, other.luminance + 0.05)
        return max(a, b) / min(a, b)
    }

    /// Mixed with `fraction` white.
    public func lightened(by fraction: Double) -> SRGB {
        SRGB(red: red + (1 - red) * fraction, green: green + (1 - green) * fraction, blue: blue + (1 - blue) * fraction)
    }
}

/// Shellforge's terminal colours: the sidebar's own macOS colours, read under `appearance` (dark,
/// as the sidebar always is) each time they are asked for, so they follow the accent colour and
/// Increase Contrast.
public enum ShellforgeTerminalPalette {
    public static let minimumContrast = 4.5

    public static func colors(in appearance: NSAppearance? = NSAppearance(named: .darkAqua)) -> [TerminalColorRole: SRGB] {
        var colors: [TerminalColorRole: SRGB] = [:]
        let draw = { (work: () -> Void) in
            if let appearance { appearance.performAsCurrentDrawingAppearance(work) } else { work() }
        }
        draw {
            let opaqueBlack = SRGB(red: 0, green: 0, blue: 0)
            let background = SRGB(NSColor.windowBackgroundColor, over: opaqueBlack)
            func read(_ color: NSColor) -> SRGB { SRGB(color, over: background) }
            colors[.background] = background
            colors[.foreground] = read(.labelColor)
            colors[.bold] = read(.labelColor)
            colors[.cursor] = read(.controlAccentColor)
            colors[.cursorText] = background
            colors[.selection] = read(.selectedContentBackgroundColor)
            colors[.selectedText] = read(.labelColor)
            colors[.ansi(0)] = read(.underPageBackgroundColor)
            colors[.ansi(8)] = read(.tertiaryLabelColor)
            colors[.ansi(7)] = read(.secondaryLabelColor)
            colors[.ansi(15)] = read(.labelColor)
            let hues: [(Int, NSColor)] = [(1, .systemRed), (2, .systemGreen), (3, .systemYellow),
                                          (4, .systemBlue), (5, .systemPurple), (6, .systemTeal)]
            for (index, hue) in hues {
                colors[.ansi(index)] = read(hue)
                colors[.ansi(index + 8)] = read(hue).lightened(by: 0.2)
            }
            for role in TerminalColorRole.all where role.needsContrast {
                if let color = colors[role] { colors[role] = readable(color, on: background) }
            }
        }
        return colors
    }

    /// `color`, lightened in 5 % steps until it reaches `minimumContrast` on `background`.
    public static func readable(_ color: SRGB, on background: SRGB) -> SRGB {
        var color = color
        for _ in 0..<100 where color.contrast(with: background) < minimumContrast {
            color = color.lightened(by: 0.05)
        }
        return color
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `cd Shellforge && scripts/swift.sh test --filter TerminalPaletteTests`
Expected: `✔ Test run with 8 tests in 1 suite passed`.

- [ ] **Step 5: Commit**

```bash
git add Shellforge/Sources/ShellforgeDesign/TerminalPalette.swift Shellforge/Tests/ShellforgeDesignTests/TerminalPaletteTests.swift
git commit -m "M11 task 1: Shellforge's terminal palette — 23 colours from the sidebar's macOS colours, read in dark, each text colour lightened until it reads at 4.5:1 on the sidebar's surface"
```

### Task 2: The saved switch and its Settings card (ShellforgeUI)

**Files:**
- Create: `Shellforge/Sources/ShellforgeUI/Settings/TerminalMatchSettings.swift`
- Create: `Shellforge/Sources/ShellforgeUI/Settings/TerminalMatchCard.swift`
- Modify: `Shellforge/Sources/ShellforgeUI/Settings/SettingsPanel.swift` (the `Core` section, `save()`)
- Modify: `Shellforge/Sources/ShellforgeUI/ShellforgeSidebar.swift` (`makeView`, `SidebarView`, `showMacSettings()`)
- Modify: `Shellforge/Tests/ShellforgeUITests/SidebarTests.swift`, `ReleaseTests.swift`, `SidebarClicksTests.swift` (the new `makeView` argument)
- Modify: `sources/TerminalView/iTermShellforgeSidebar.swift` (passes the app's switch; see Task 3 for where it lives)
- Test: `Shellforge/Tests/ShellforgeUITests/TerminalMatchSettingsTests.swift`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces:
  - `@MainActor public final class TerminalMatchSettings: ObservableObject { public static let defaultsKey = "ShellforgeMatchTerminal"; public init(defaults: UserDefaults); public private(set) var isOn: Bool; @Published public var draft: Bool; public var onChange: (@MainActor (Bool) -> Void)?; public func beginEditing(); public func save(); public func set(_ on: Bool) }`
  - `ShellforgeSidebar.makeView(…, zoom:, terminalMatch: TerminalMatchSettings, showBackpack:, hideSidebar:)` — `terminalMatch` right after `zoom`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import ShellforgeTestSupport
@testable import ShellforgeUI

/// Settings › Core › Terminal: off until switched on and saved; Cancel changes nothing.
@MainActor @Suite struct TerminalMatchSettingsTests {
    @Test func itIsOffByDefault() {
        #expect(!TerminalMatchSettings(defaults: ScratchDefaults.make()).isOn)
    }

    @Test func saveKeepsTheSwitch() {
        let store = ScratchDefaults.make()
        let settings = TerminalMatchSettings(defaults: store)
        settings.draft = true
        settings.save()
        #expect(settings.isOn)
        #expect(TerminalMatchSettings(defaults: store).isOn)
    }

    @Test func cancelLeavesTheSavedValue() {
        let store = ScratchDefaults.make()
        let settings = TerminalMatchSettings(defaults: store)
        settings.beginEditing()
        settings.draft = true
        // The panel closes without Save: the next opening starts from what was saved.
        settings.beginEditing()
        #expect(!settings.draft)
        #expect(!settings.isOn)
        #expect(!TerminalMatchSettings(defaults: store).isOn)
    }

    @Test func onChangeIsCalledOnlyWhenTheSavedValueChanges() {
        let settings = TerminalMatchSettings(defaults: ScratchDefaults.make())
        var calls: [Bool] = []
        settings.onChange = { calls.append($0) }
        settings.save()
        settings.set(true)
        settings.set(true)
        settings.set(false)
        #expect(calls == [true, false])
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd Shellforge && scripts/swift.sh test --filter TerminalMatchSettingsTests`
Expected: build error, `cannot find 'TerminalMatchSettings' in scope`.

- [ ] **Step 3: Write the settings**

`Shellforge/Sources/ShellforgeUI/Settings/TerminalMatchSettings.swift`:

```swift
import Combine
import Foundation

/// Settings › Core › Terminal's switch: whether every terminal draws in Shellforge's colours and
/// iTerm2's Minimal theme. Off until saved on. `draft` is the switch while the panel is open;
/// only Save makes it `isOn`, as with every other Settings card.
@MainActor
public final class TerminalMatchSettings: ObservableObject {
    public static let defaultsKey = "ShellforgeMatchTerminal"

    private let defaults: UserDefaults
    public private(set) var isOn: Bool
    @Published public var draft: Bool
    /// After a Save that changed `isOn`: the app recolours every terminal.
    public var onChange: (@MainActor (Bool) -> Void)?

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        isOn = defaults.bool(forKey: Self.defaultsKey)
        draft = isOn
    }

    /// The panel opens: the switch shows what is saved.
    public func beginEditing() { draft = isOn }

    /// Save: `draft` becomes what every terminal draws in.
    public func save() {
        guard draft != isOn else { return }
        isOn = draft
        defaults.set(isOn, forKey: Self.defaultsKey)
        onChange?(isOn)
    }

    /// Switches and saves at once, for the app's tests.
    public func set(_ on: Bool) {
        draft = on
        save()
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `cd Shellforge && scripts/swift.sh test --filter TerminalMatchSettingsTests`
Expected: `✔ Test run with 4 tests in 1 suite passed`.

- [ ] **Step 5: Write the card**

`Shellforge/Sources/ShellforgeUI/Settings/TerminalMatchCard.swift`:

```swift
import ShellforgeDesign
import SwiftUI

/// Settings › Core › Terminal: the switch that matches every terminal to Shellforge.
struct TerminalMatchCard: View {
    @ObservedObject var settings: TerminalMatchSettings

    private var status: SettingsStatus {
        settings.draft ? SettingsStatus(.ready, "Matched to Shellforge") : SettingsStatus(.idle, "Your profiles’ colours")
    }

    var body: some View {
        SettingsCard(title: "Terminal", status: status) {
            SymbolMark(symbol: "paintpalette", size: Size.control, style: .paper)
        } chips: {
            EmptyView()
        } actions: {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: Space.snug) {
                Toggle("Match the terminal to Shellforge", isOn: $settings.draft)
                Text("Uses Shellforge’s colours and iTerm2’s Minimal theme. Your profiles are not changed.")
                    .font(Typography.help)
                    .foregroundStyle(Palette.muted)
            }
        }
    }
}
```

- [ ] **Step 6: Put it in the panel**

In `SettingsPanel.swift`, add the property after `var environment: EnvironmentModel?`:

```swift
    let terminalMatch: TerminalMatchSettings
```

In the `Core` section, after the `EnvironmentCard` line:

```swift
                    TerminalMatchCard(settings: terminalMatch)
```

After `.task { await backpack.refreshSetup() }`:

```swift
        .onAppear { terminalMatch.beginEditing() }
```

Replace `save()`:

```swift
    private func save() {
        failure = integrations.save()
        guard failure == nil else { return }
        terminalMatch.save()
        Task { @MainActor in close() }
    }
```

- [ ] **Step 7: Hand it down from `makeView`**

In `ShellforgeSidebar.swift`:
- `makeView`'s parameters: after `zoom: SidebarZoom,` add `terminalMatch: TerminalMatchSettings,`; add to its doc comment: `` `terminalMatch` is the app's one Settings › Core › Terminal switch.``
- In `makeView`'s body, pass `terminalMatch: terminalMatch` to `SidebarView(…)` after `backpack: backpack`.
- In `struct SidebarView`, after `let backpack: BackpackController`, add `let terminalMatch: TerminalMatchSettings`.
- In `showMacSettings()`, change the panel to `SettingsPanel(backpack: backpack, integrations: integrations, environment: environment, terminalMatch: terminalMatch, close: dismiss)`.

In the three test files, wherever `zoom: SidebarZoom(settings: SidebarLayoutSettings(defaults: ScratchDefaults.make()))` is passed to `makeView`, add after it:

```swift
, terminalMatch: TerminalMatchSettings(defaults: ScratchDefaults.make())
```

(in `ReleaseTests.swift` the arguments are on separate lines; keep its layout.)

The app's call to `makeView` is updated in Task 3, which adds the switch it passes. Until then the app does not build; the package does.

- [ ] **Step 8: Run the package's tests**

Run: `cd Shellforge && scripts/swift.sh test`
Expected: every run line `✔ … passed`, none `✘`.

- [ ] **Step 9: Commit**

```bash
git add Shellforge/Sources/ShellforgeUI/Settings/TerminalMatchSettings.swift Shellforge/Sources/ShellforgeUI/Settings/TerminalMatchCard.swift Shellforge/Tests/ShellforgeUITests/TerminalMatchSettingsTests.swift
git add -u Shellforge
git commit -m "M11 task 2: Settings › Core › Terminal — Match the terminal to Shellforge, off by default, ShellforgeMatchTerminal written only by Save"
```

### Task 3: The bridge and the colour hook (app)

**Files:**
- Create: `sources/TerminalView/iTermShellforgeTerminalMatch.swift` (then `tools/add_file_to_xcodeproj.rb sources/TerminalView/iTermShellforgeTerminalMatch.swift iTerm2SharedARC`)
- Modify: `sources/PTYSession/PTYSession.m:5901` (`loadColorsFromProfile:`)
- Modify: `sources/PTYSession/PTYSession.h` (declare `loadColorsFromProfile:` beside `setSessionSpecificProfileValues:`, line 1326)
- Modify: `sources/TerminalView/iTermShellforgeSidebar.swift` (Task 2 Step 7's line)
- Test: `ModernTests/ShellforgeTerminalMatchTest.swift`

**Interfaces:**
- Consumes: `ShellforgeTerminalPalette.colors(in:)`, `TerminalColorRole` (Task 1); `TerminalMatchSettings` (Task 2).
- Produces:
  - `@objc(iTermShellforgeTerminalMatch) @MainActor final class iTermShellforgeTerminalMatch: NSObject`
  - `static let settings: TerminalMatchSettings`
  - `@objc static func profile(forColors profile: [AnyHashable: Any], keeping overridden: Set<String>?) -> [AnyHashable: Any]` — ObjC `profileForColors:keeping:`
  - `@objc nonisolated static var overridesTheme: Bool` (Task 4 uses it)
  - `@objc static let didChangeNotification: NSNotification.Name` (Task 4 observes it)
  - `static func setOn(_ on: Bool)`, `static func paletteColor(forKey key: String) -> NSColor?` (tests)

- [ ] **Step 1: Write the failing host tests**

`ModernTests/ShellforgeTerminalMatchTest.swift`:

```swift
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
}
```

- [ ] **Step 2: Write the bridge**

`sources/TerminalView/iTermShellforgeTerminalMatch.swift`:

```swift
//
//  iTermShellforgeTerminalMatch.swift
//  Shellforge
//
//  Settings › Core › Terminal's match, for iTerm2's own code: Shellforge's colours laid over the
//  profile a session loads its colours from, and iTerm2's Minimal theme, while it is on. Neither
//  the profiles nor the theme setting are ever written.
//

import AppKit
import ShellforgeDesign
import ShellforgeUI

@objc(iTermShellforgeTerminalMatch)
@MainActor
final class iTermShellforgeTerminalMatch: NSObject {
    /// The app's one switch, in iTerm2's defaults domain so a `-suite` run keeps its own. Made on
    /// first use, which also starts following the accent colour and Increase Contrast.
    static let settings: TerminalMatchSettings = {
        let settings = TerminalMatchSettings(defaults: iTermUserDefaults.userDefaults())
        settings.onChange = { _ in recolour() }
        let recolourIfOn: @Sendable (Notification) -> Void = { _ in
            MainActor.assumeIsolated { if settings.isOn { recolour() } }
        }
        NotificationCenter.default.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main,
                                               using: recolourIfOn)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                          object: nil, queue: .main, using: recolourIfOn)
        return settings
    }()

    /// Posted after every session has been recoloured: Settings › Appearance greys its Theme control.
    @objc static let didChangeNotification = NSNotification.Name("iTermShellforgeTerminalMatchDidChange")

    /// Whether iTerm2's theme reads as Minimal. Asked from `computedTabStyle`, on any thread, so it
    /// reads the saved value straight from defaults rather than the main-actor `settings`.
    @objc nonisolated static var overridesTheme: Bool {
        iTermUserDefaults.userDefaults().bool(forKey: TerminalMatchSettings.defaultsKey)
    }

    /// The profile `loadColorsFromProfile:` reads: `profile` itself while off; while on, a copy with
    /// each palette key, and its light and dark variants, set to Shellforge's colour — except the
    /// keys in `overridden`, which the session set for itself.
    @objc static func profile(forColors profile: [AnyHashable: Any], keeping overridden: Set<String>?) -> [AnyHashable: Any] {
        guard settings.isOn else { return profile }
        var result = profile
        for (role, color) in ShellforgeTerminalPalette.colors() {
            let value = nsColor(color).dictionaryValue
            let base = key(for: role)
            for key in [base, base + COLORS_LIGHT_MODE_SUFFIX, base + COLORS_DARK_MODE_SUFFIX] where overridden?.contains(key) != true {
                result[key] = value
            }
        }
        return result
    }

    /// Switches and saves at once, for host tests, which cannot import ShellforgeUI.
    static func setOn(_ on: Bool) { settings.set(on) }

    /// The palette's colour for an iTerm2 base colour key, for host tests.
    static func paletteColor(forKey key: String) -> NSColor? {
        ShellforgeTerminalPalette.colors().first { self.key(for: $0.key) == key }.map { nsColor($0.value) }
    }

    /// The profile key iTerm2 keeps `role` under.
    private static func key(for role: TerminalColorRole) -> String {
        switch role {
        case .background: KEY_BACKGROUND_COLOR
        case .foreground: KEY_FOREGROUND_COLOR
        case .bold: KEY_BOLD_COLOR
        case .cursor: KEY_CURSOR_COLOR
        case .cursorText: KEY_CURSOR_TEXT_COLOR
        case .selection: KEY_SELECTION_COLOR
        case .selectedText: KEY_SELECTED_TEXT_COLOR
        case .ansi(let index): "Ansi \(index) Color"
        }
    }

    private static func nsColor(_ color: SRGB) -> NSColor {
        NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
    }

    /// Every open session reloads its colours from its own profile, through the hook; then iTerm2
    /// redraws its windows as it does when its theme setting changes.
    private static func recolour() {
        for session in iTermController.sharedInstance()?.allSessions() ?? [] {
            if let profile = session.profile { session.loadColors(fromProfile: profile) }
        }
        (NSApp as? iTermApplication)?.updateAppearance()
        NotificationCenter.default.post(name: NSNotification.Name(kRefreshTerminalNotification), object: nil)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}
```

Then:

```bash
git add sources/TerminalView/iTermShellforgeTerminalMatch.swift ModernTests/ShellforgeTerminalMatchTest.swift
tools/add_file_to_xcodeproj.rb sources/TerminalView/iTermShellforgeTerminalMatch.swift iTerm2SharedARC
```

If `kRefreshTerminalNotification` is not visible to Swift, use `NSNotification.Name("kRefreshTerminalNotification")` (its value, `PreferencePanel.m:115`).

`recolour()` calls `loadColors(fromProfile:)`, private to `PTYSession.m` until now. In `sources/PTYSession/PTYSession.h`, after the `setSessionSpecificProfileValues:` declarations (line 1326):

```objc
// Shellforge: public so the terminal match can reload every session's colours.
- (void)loadColorsFromProfile:(Profile *)aDict;
```

In `sources/TerminalView/iTermShellforgeSidebar.swift`, `makeView(for:)`: after `backpack: backpack, zoom: zoom,` add `terminalMatch: iTermShellforgeTerminalMatch.settings,` (Task 2's new `makeView` argument).

- [ ] **Step 3: Run the host tests to see them fail**

Run: `tools/run_tests.expect ModernTests/ShellforgeTerminalMatchTest`
Expected: builds; `testOnColoursASessionAndLeavesTheProfile`, `testATabOpenedWhileOnIsMatched` and `testSeparateLightAndDarkColoursAreMatchedToo` fail (the background is the profile's, not the palette's), because nothing calls the bridge yet.

- [ ] **Step 4: Add the hook**

`sources/PTYSession/PTYSession.m`, first line of `loadColorsFromProfile:`:

```objc
- (void)loadColorsFromProfile:(Profile *)aDict {
    // Shellforge: Shellforge's colours over the profile's while the terminal match is on.
    aDict = [iTermShellforgeTerminalMatch profileForColors:aDict keeping:_overriddenFields];
    const BOOL dark = [NSApp effectiveAppearance].it_isDark;
```

- [ ] **Step 5: Run the host tests**

Run: `tools/run_tests.expect ModernTests/ShellforgeTerminalMatchTest`
Expected: `Executed 5 tests, with 0 failures`.

- [ ] **Step 6: Build**

Run: `tools/build.sh`
Expected: `Build succeeded.`; no warning in `iTermShellforgeTerminalMatch.swift`, `PTYSession.m` or `PTYSession.h` (`grep -E 'iTermShellforgeTerminalMatch|PTYSession\.[hm].*warning' tmp/build.log` prints nothing).

- [ ] **Step 7: Commit**

```bash
git add sources/PTYSession/PTYSession.h sources/PTYSession/PTYSession.m sources/TerminalView/iTermShellforgeSidebar.swift iTerm2.xcodeproj/project.pbxproj
git commit -m "M11 task 3: while the terminal match is on, every session loads Shellforge's colours laid over its profile's copy, keys the session set for itself excepted; switching recolours every open session"
```

### Task 4: The Minimal theme

**Files:**
- Modify: `sources/Settings/iTermPreferences.m:1230` (`computedTabStyle`)
- Modify: `sources/Settings/AppearancePreferencesViewController.m` (import, the `_tabStyle` control at line 148, a new method)
- Test: `ModernTests/ShellforgeTerminalMatchTest.swift` (two more tests)

**Interfaces:**
- Consumes: `iTermShellforgeTerminalMatch.overridesTheme`, `.didChangeNotification`, `.setOn(_:)` (Task 3).
- Produces: nothing new.

- [ ] **Step 1: Write the failing tests**

Add to `ShellforgeTerminalMatchTest`:

```swift
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
```

- [ ] **Step 2: Run them to see the first fail**

Run: `tools/run_tests.expect ModernTests/ShellforgeTerminalMatchTest/testTheThemeIsMinimalOnlyWhileOn`
Expected: FAIL, the theme is the saved one while on.

- [ ] **Step 3: Add the theme hook**

`sources/Settings/iTermPreferences.m`, first lines of `computedTabStyle`:

```objc
+ (NSNumber *)computedTabStyle {
    // Shellforge: the Minimal theme while the terminal matches Shellforge; the saved one is kept.
    if ([iTermShellforgeTerminalMatch overridesTheme]) {
        return @(TAB_STYLE_MINIMAL);
    }
    NSNumber *value;
```

- [ ] **Step 4: Grey the Theme control while overridden**

`sources/Settings/AppearancePreferencesViewController.m`: add `#import "iTerm2SharedARC-Swift.h"` after the file's last `#import`. After the `_tabStyle` control's `[self updateNonDefaultIndicatorVisibleForInfo:info];` (line 157):

```objc
    // Shellforge: while the terminal match is on, the theme is Minimal and this control has no effect.
    info.shouldBeEnabled = ^BOOL{ return ![iTermShellforgeTerminalMatch overridesTheme]; };
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(shellforgeTerminalMatchDidChange:)
                                                 name:iTermShellforgeTerminalMatch.didChangeNotification
                                               object:nil];
    [self shellforgeTerminalMatchDidChange:nil];
```

And a method in the same `@implementation`:

```objc
// Shellforge: the Theme control follows the terminal match, and says why when it is greyed.
- (void)shellforgeTerminalMatchDidChange:(NSNotification *)notification {
    [self updateEnabledState];
    _tabStyle.toolTip = [iTermShellforgeTerminalMatch overridesTheme] ? @"Shellforge’s terminal match uses the Minimal theme." : nil;
}
```

- [ ] **Step 5: Run the host tests**

Run: `tools/run_tests.expect ModernTests/ShellforgeTerminalMatchTest`
Expected: `Executed 7 tests, with 0 failures`.

- [ ] **Step 6: Build**

Run: `tools/build.sh`
Expected: `Build succeeded.`, no warning in the two changed files.

- [ ] **Step 7: Commit**

```bash
git add sources/Settings/iTermPreferences.m sources/Settings/AppearancePreferencesViewController.m ModernTests/ShellforgeTerminalMatchTest.swift
git commit -m "M11 task 4: iTerm2's theme reads as Minimal while the terminal matches Shellforge, the saved theme untouched; Settings › Appearance greys its Theme control and says why"
```

### Task 5: Docs and the check by hand

**Files:**
- Modify: `Shellforge/docs/features.md` (`## Settings and connections`)
- Modify: `Shellforge/docs/upstream-hook-points.md` (table end)

- [ ] **Step 1: features.md**

At the end of the `## Settings and connections` section:

```markdown
- **Terminal.** Settings › Core › Terminal › Match the terminal to Shellforge, off by default, takes effect on Save.
  - Every terminal, including tabs opened later, uses Shellforge's colours: the sidebar's background, its text and selection colours, the macOS accent colour for the cursor, and macOS's system colours for the 16 terminal colours, each readable on the background.
  - iTerm2 uses its Minimal theme, so the title bar and window edges match. Settings › Appearance's Theme is greyed out while it is on.
  - Your profiles and your theme setting are not changed. Switching it off brings them back at once.
  - A colour set for one tab (Edit Session, the Python API) still wins.
```

- [ ] **Step 2: upstream-hook-points.md**

Append rows:

```markdown
| `sources/PTYSession/PTYSession.{h,m}` (`loadColorsFromProfile:`) | Declared in the header; first line asks `iTermShellforgeTerminalMatch profileForColors:keeping:` for the profile it reads | The terminal match lays Shellforge's colours over each session's profile copy without writing the profile |
| `sources/Settings/iTermPreferences.m` (`computedTabStyle`) | Minimal while `iTermShellforgeTerminalMatch overridesTheme` | The match's window theme, leaving the saved theme alone |
| `sources/Settings/AppearancePreferencesViewController.m` (`_tabStyle`) | Disabled, with a tooltip, while the match is on | The control would have no effect |
| `sources/TerminalView/iTermShellforgeTerminalMatch.swift` (new) | The match's `@objc` bridge to ShellforgeDesign and ShellforgeUI | Objective-C cannot import the Swift package |
```

- [ ] **Step 3: Check by hand**

Run: `make run`. In the app:
1. Sidebar gear › Core › Terminal: switch on, Save. Every tab, and the title bar, take the sidebar's dark colour; `ls --color` shows the system colours.
2. Settings › Appearance: Theme is greyed, its tooltip says why.
3. Open a new tab and a new window: both matched.
4. System Settings › Appearance: change the accent colour; the cursor follows. Switch macOS to Light: the terminal stays matched.
5. Gear › Terminal: switch off, Save. Every tab shows its profile's colours again; Appearance › Theme is enabled and shows your theme.
6. Switch on, then press Cancel instead of Save: nothing changes.

Quit the test app.

- [ ] **Step 4: Run every test once more**

Run: `cd Shellforge && scripts/swift.sh test` and `tools/run_tests.expect ModernTests/ShellforgeHostTest ModernTests/ShellforgeSidebarLayoutTest ModernTests/ShellforgeReportsTest ModernTests/ShellforgeSidebarZoomTest ModernTests/ShellforgeTerminalMatchTest`
Expected: every package run `✔`; `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Shellforge/docs/features.md Shellforge/docs/upstream-hook-points.md
git commit -m "M11 docs: Settings › Core › Terminal in features.md; the match's hooks in upstream-hook-points.md"
```
