# M12b The floating sidebar — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** on macOS 26 and later the sidebar is a rounded glass panel inside the one window, the window's buttons inside its top and the window's title over the terminal; on macOS 12–15 it is the classic full-height sidebar in the system's sidebar material.

**Architecture:** iTerm2's layout calculator gains a `leftPanelInset`, so the panel stands off the window's edges. Shellforge's normal windows on macOS 26 use full-size content with a hidden, transparent title bar — a few one-line hooks in iTerm2's window-style code — so macOS's own window buttons sit inside the panel's top. iTerm2's existing fake title (`iTermFakeWindowTitleLabel`, used by its compact windows) becomes the title strip over the terminal, offset past the panel. The sidebar's SwiftUI draws `MaterialBackground` (M12a) in a rounded shape when it floats, and the sidebar material when it does not.

**Tech Stack:** iTerm2 (Objective-C, Swift; XCTest host tests in `ModernTests`), the Shellforge Swift package (swift-testing).

**Spec:** `Shellforge/docs/plans/2026-10-14-m12-modern-ui-design.md` (step 2)

## Before and after (the step's agreed list; the user waived sign-off and asked for it to be recorded here)

| | Before | After, macOS 26+ | After, macOS 12–15 |
| --- | --- | --- | --- |
| Sidebar shape | Flush, full height, opaque | Rounded panel, inset 8 pt from top, left and bottom, corner radius concentric with the window's (window radius − 8) | Flush, full height |
| Sidebar fill | `Palette.sidebar` | `MaterialBackground` glass (opaque with Reduce Transparency) | System sidebar material (opaque with Reduce Transparency) |
| Sidebar edge | M11's 1 pt line | The panel's 1 pt `Palette.border` outline | M11's line |
| Window buttons | In the title bar above the sidebar | Inside the panel's top-left (macOS's own, or iTerm2's in compact windows, moved in by the inset) | In the title bar |
| Title | System title bar, centred over the window | Title strip over the terminal, starting at the panel's right edge, draggable | System title bar |
| Terminal top | Below the title bar | Below the title strip | Below the title bar |
| Hidden sidebar (⌃⌘S) | Ordinary title bar + Show Sidebar button | Title strip across the window, Show Sidebar button beside the window buttons | Unchanged |
| Full screen | Sidebar flush | Panel keeps its inset and corners; no title strip | Unchanged |

## Global Constraints

- Floating is decided once per launch: `iTermShellforgeSidebar.floats` is true on macOS 26 and later.
- Every change in an iTerm2 file is marked `// Shellforge:` and listed in `Shellforge/docs/upstream-hook-points.md`.
- Upstream's `ModernTests/iTermLayoutCalculatorTest.swift` (31 tests) stays green unchanged.
- Colours only from `Palette`, sizes only from `Metrics` (`DesignRulesTests`); the inset is `Space.base` (8).
- Deployment target macOS 12 (app), 13 (package); `@available(macOS 26, *)` / `#available` for 26 APIs.
- Swift: no `fatalError`/`assert`, no force unwraps in new code. `git add` new files at once; a new app Swift file is added to the project beside an existing one in `iTerm2SharedARC` (the `xcodeproj` gem is not installed; M11's Task 3 did it by hand with `plutil -lint`).
- Commands: package `cd Shellforge && scripts/swift.sh test`; app `tools/build.sh`; host tests `tools/run_tests.expect ModernTests/<Class>`. Warnings are errors.

## Review Focus

1. Upstream windows that were never Shellforge's concern (hotkey, edge-anchored, no-title-bar types) keep their own style: only NORMAL, MAXIMIZED and CENTERED gain full-size content. (Task 4, `testOnlyTitledTypesGainFullSizeContent`.)
2. The sidebar hidden with ⌃⌘S on macOS 26: the terminal and the title strip take the full width, no gap is left where the panel was. (Task 4, `testAHiddenSidebarLeavesNoGap`.)
3. Full screen on macOS 26: no title strip, the terminal starts at the top, the panel keeps its inset. (Task 1, `testTheInsetPanelInFullScreen`.)
4. The drag handle still sits on the panel's right edge, at the panel's height. (Task 1 via `leftPanelFrame`; Task 4, `testTheDragHandleFollowsThePanel`.)
5. Existing upstream window tests under a full-size window on macOS 26 — the full ModernTests run decides (Task 5).

---

### Task 1: The calculator's panel inset

**Files:**
- Modify: `sources/TerminalView/iTermLayoutCalculator.h` (`iTermLayoutInputs`, after `leftPanelWidth`)
- Modify: `sources/TerminalView/iTermLayoutCalculator.m:35-52` (`calculateLayoutWithInputs:`)
- Test: `ModernTests/ShellforgeSidebarLayoutTest.swift`

**Interfaces:**
- Produces: `CGFloat leftPanelInset` in `iTermLayoutInputs`; `leftPanelFrame` = `(inset, inset, sidebar − inset, height − 2·inset)` when the sidebar's width is non-zero; every other output as before.

- [ ] **Step 1: Write the failing tests**

Add to `ShellforgeSidebarLayoutTest` (its `inputs(sidebar:toolbelt:)` helper builds an 800×600 window):

```swift
    func testTheInsetPanelStandsOffTheWindowsEdges() {
        var inputs = inputs(sidebar: 240)
        inputs.leftPanelInset = 8
        let outputs = iTermLayoutCalculator.calculateLayout(with: inputs)
        XCTAssertEqual(outputs.leftPanelFrame, CGRect(x: 8, y: 8, width: 232, height: 584))
    }

    func testTheInsetMovesNothingElse() {
        var inset = inputs(sidebar: 240)
        inset.leftPanelInset = 8
        let flush = iTermLayoutCalculator.calculateLayout(with: inputs(sidebar: 240))
        let moved = iTermLayoutCalculator.calculateLayout(with: inset)
        XCTAssertEqual(moved.tabViewFrame, flush.tabViewFrame)
        XCTAssertEqual(moved.toolbeltFrame, flush.toolbeltFrame)
        XCTAssertEqual(moved.tabBarFrame, flush.tabBarFrame)
    }

    func testTheInsetPanelInFullScreen() {
        var inputs = inputs(sidebar: 240)
        inputs.leftPanelInset = 8
        inputs.inFullscreen = true
        XCTAssertEqual(iTermLayoutCalculator.calculateLayout(with: inputs).leftPanelFrame, CGRect(x: 8, y: 8, width: 232, height: 584))
    }

    func testAHiddenSidebarHasNoPanelWhateverTheInset() {
        var inputs = inputs(sidebar: 0)
        inputs.leftPanelInset = 8
        XCTAssertEqual(iTermLayoutCalculator.calculateLayout(with: inputs).leftPanelFrame, CGRect(x: 0, y: 0, width: 0, height: 600))
    }
```

- [ ] **Step 2: Run them to see them fail**

Run: `tools/run_tests.expect ModernTests/ShellforgeSidebarLayoutTest`
Expected: build error, `value of type 'iTermLayoutInputs' has no member 'leftPanelInset'`.

- [ ] **Step 3: Add the input**

`iTermLayoutCalculator.h`, after the `leftPanelWidth` field and its comment:

```objc
    // Shellforge: how far the panel stands off the window's top, left and bottom edges (the floating
    // sidebar on macOS 26); 0 for a flush sidebar.
    CGFloat leftPanelInset;
```

`iTermLayoutCalculator.m`, in `calculateLayoutWithInputs:`, replace the `leftPanelFrame` line:

```objc
    // Shellforge: the panel stands off the window's edges by the inset; the column it sits in, and
    // so everything right of it, is unchanged.
    const CGFloat inset = sidebar > 0 ? inputs.leftPanelInset : 0;
    outputs.leftPanelFrame = CGRectMake(inset, inset, MAX(0, sidebar - inset), MAX(0, inputs.contentViewHeight - 2 * inset));
```

- [ ] **Step 4: Run the tests**

Run: `tools/run_tests.expect ModernTests/ShellforgeSidebarLayoutTest ModernTests/iTermLayoutCalculatorTest`
Expected: `** TEST SUCCEEDED **`, 8 + 31 tests.

- [ ] **Step 5: Commit**

```bash
git add sources/TerminalView/iTermLayoutCalculator.h sources/TerminalView/iTermLayoutCalculator.m ModernTests/ShellforgeSidebarLayoutTest.swift
git commit -m "M12b task 1: the layout calculator's leftPanelInset — the sidebar panel stands off the window's top, left and bottom edges; nothing else moves"
```

### Task 2: The panel's look (Shellforge package)

**Files:**
- Modify: `Shellforge/Sources/ShellforgeUI/ShellforgeSidebar.swift` (`makeView`, `SidebarView`, `SidebarEdge`)
- Test: `Shellforge/Tests/ShellforgeUITests/FloatingPanelTests.swift`

**Interfaces:**
- Consumes: `MaterialBackground` (M12a).
- Produces: `ShellforgeSidebar.makeView(…, panelCornerRadius: CGFloat? = nil, showBackpack:, hideSidebar:)` — `panelCornerRadius` after `terminalMatch`; nil draws the classic sidebar.

- [ ] **Step 1: Write the failing tests**

```swift
import AppKit
import SwiftUI
import Testing
@testable import ShellforgeTestSupport
@testable import ShellforgeCore
import ShellforgeDesign
@testable import ShellforgeUI

/// The floating sidebar is a rounded panel: its corners show what is behind it, its edge is the
/// panel's outline. The classic sidebar fills its column to the corner.
@MainActor @Suite struct FloatingPanelTests {
    private func render(panelCornerRadius: CGFloat?) throws -> NSBitmapImageRep {
        let document = WorkspaceDocument(store: WorkspaceStore(folder: TestScratch.root.appendingPathComponent("float-\(UUID().uuidString)")))
        let launcher = CommandLauncher(resolve: { ResolvedEnvironment(variables: ["PATH": "/usr/bin"], source: .loginShell("/bin/zsh")) })
        let model = SidebarModel(host: FakeTerminalHost(), document: document, launcher: launcher, jiraSettings: { nil })
        let hooks = AgentHooksModel(integrations: HookIntegrations(home: TestScratch.root.appendingPathComponent("float-home-\(UUID().uuidString)"),
                                                                   resources: .bundled(resourceURL: nil)), names: [:])
        let view = ShellforgeSidebar.makeView(model: model, chooseFolder: { nil }, hooks: hooks,
                                              machine: MachineMonitor(sensor: InertMachineSensor(), power: InertPower()),
                                              backpack: BackpackController(ports: .inert, settings: BackpackSettings(defaults: nil), toast: { _ in }),
                                              zoom: SidebarZoom(settings: SidebarLayoutSettings(defaults: ScratchDefaults.make())),
                                              terminalMatch: TerminalMatchSettings(defaults: ScratchDefaults.make()),
                                              panelCornerRadius: panelCornerRadius)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: view.frame.width, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = .systemRed
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        window.close()
        return rep
    }

    private func isRedOrClear(_ color: NSColor?) -> Bool {
        guard let c = color?.usingColorSpace(.sRGB) else { return true }
        return c.alphaComponent < 0.1 || (c.redComponent > 0.8 && c.greenComponent < 0.3)
    }

    @Test func aFloatingPanelHasRoundCorners() throws {
        let rep = try render(panelCornerRadius: 8)
        #expect(isRedOrClear(rep.colorAt(x: 0, y: 0)), "the top-left corner shows what is behind the panel")
        #expect(!isRedOrClear(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)), "the panel's middle is the panel")
    }

    @Test func theClassicSidebarFillsItsCorner() throws {
        let rep = try render(panelCornerRadius: nil)
        #expect(!isRedOrClear(rep.colorAt(x: 0, y: 0)))
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd Shellforge && scripts/swift.sh test --filter FloatingPanelTests`
Expected: build error, `extra argument 'panelCornerRadius' in call`.

- [ ] **Step 3: The panel**

In `ShellforgeSidebar.swift`:
- `makeView` gains `panelCornerRadius: CGFloat? = nil` after `terminalMatch: TerminalMatchSettings,`, documented: “`panelCornerRadius`, when given, draws the sidebar as a floating panel with those corners (macOS 26); nil draws the classic sidebar.” Pass it to `SidebarView(…, panelCornerRadius: panelCornerRadius, …)`.
- `SidebarView` gains `let panelCornerRadius: CGFloat?` after `terminalMatch`.
- In `SidebarView.body`, replace

```swift
        .overlay(alignment: .trailing) { SidebarEdge() }
        .frame(minWidth: scale(Size.sidebarMinWidth), maxHeight: .infinity, alignment: .top)
        .background(Palette.sidebar)
```

with

```swift
        .overlay(alignment: .trailing) { if panelCornerRadius == nil { SidebarEdge() } }
        .frame(minWidth: scale(Size.sidebarMinWidth), maxHeight: .infinity, alignment: .top)
        .background { SidebarGround(cornerRadius: panelCornerRadius) }
```

- Add, beside `SidebarEdge`:

```swift
/// What the sidebar is drawn on: the floating panel — a rounded `MaterialBackground` with a hairline
/// outline — or, classic, the sidebar material filling its column. Either runs under the title bar,
/// so it ignores the safe area the content keeps to.
struct SidebarGround: View {
    let cornerRadius: CGFloat?

    var body: some View {
        Group {
            if let cornerRadius {
                let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                MaterialBackground(shape)
                    .overlay { shape.strokeBorder(Palette.border, lineWidth: 1) }
            } else {
                MaterialBackground(Rectangle(), kind: ShellforgeMaterial.current == .glass ? .sidebar : ShellforgeMaterial.current)
            }
        }
        .ignoresSafeArea()
    }
}
```

(The classic sidebar on macOS 26 — only when floating is off — uses the sidebar material, not glass: glass is for the floating panel.)

- [ ] **Step 4: Run the tests, then every package test**

Run: `cd Shellforge && scripts/swift.sh test --filter 'FloatingPanelTests|SidebarEdgeTests|AppearanceTests'` — expected `✔`.
Run: `cd Shellforge && scripts/swift.sh test` — expected every run `✔`. `DesignRulesTests` flags `lineWidth:` literals only in `.frame`/`.padding` forms, so the stroke passes; if it flags it, add an `Exception` beside M11's `SidebarEdge` one with the reason “the panel's outline is the hairline's one-point stroke”.

- [ ] **Step 5: Commit**

```bash
git add Shellforge/Tests/ShellforgeUITests/FloatingPanelTests.swift
git add -u Shellforge
git commit -m "M12b task 2: the sidebar draws as a rounded material panel with a hairline outline when given a corner radius, and in the sidebar material otherwise"
```

### Task 3: The app floats the sidebar on macOS 26

**Files:**
- Modify: `sources/TerminalView/iTermShellforgeSidebar.swift` (`makeView(for:)`, a new `floats`/`floatingInset`/`panelCornerRadius`)
- Modify: `sources/TerminalView/iTermRootTerminalView.m` (`layoutInputsForWindow:` after `inputs.leftPanelWidth = …`)
- Modify: `sources/TerminalView/iTermRootTerminalView.h` (a read-only `shellforgeSidebarFrame` for tests)
- Test: `ModernTests/ShellforgeFloatingSidebarTest.swift`

**Interfaces:**
- Produces: `@objc static var floats: Bool` (macOS ≥ 26), `@objc static var floatingInset: CGFloat` (`Space.base`), `static var panelCornerRadius: CGFloat` (`iTermWindowCornerRadiusDetector.fallbackCornerRadius − floatingInset`) on `iTermShellforgeSidebar`; `@property (nonatomic, readonly) NSRect shellforgeSidebarFrame` on `iTermRootTerminalView`.

- [ ] **Step 1: Write the failing host tests**

```swift
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
```

Run: `tools/run_tests.expect ModernTests/ShellforgeFloatingSidebarTest`
Expected: build error, `type 'iTermShellforgeSidebar' has no member 'floats'`.

- [ ] **Step 2: The bridge**

In `iTermShellforgeSidebar.swift`, in the extension that holds `defaultPreferredWidth` (“The sidebar's width, as dragged…”), add:

```swift
    /// The sidebar floats as a rounded panel inside the window on macOS 26 and later.
    @objc static var floats: Bool { ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 }

    /// How far the floating panel stands off the window's edges.
    @objc static var floatingInset: CGFloat { Space.base }

    /// The panel's corners, concentric with the window's.
    static var panelCornerRadius: CGFloat { max(0, iTermWindowCornerRadiusDetector.fallbackCornerRadius - floatingInset) }
```

(Add `import ShellforgeDesign` at the top if `Space` is not visible.)

In `makeView(for:)`, pass `panelCornerRadius: floats ? panelCornerRadius : nil,` after `terminalMatch: iTermShellforgeTerminalMatch.settings,`.

- [ ] **Step 3: The root view**

`iTermRootTerminalView.h`, beside the other Shellforge properties:

```objc
// Shellforge: the sidebar's frame, for tests.
@property(nonatomic, readonly) NSRect shellforgeSidebarFrame;
```

`iTermRootTerminalView.m`, beside `hasShellforgeSidebar`:

```objc
- (NSRect)shellforgeSidebarFrame {
    return _shellforgeSidebar.frame;
}
```

In `layoutInputsForWindow:`, after `inputs.leftPanelWidth = self.shellforgeSidebarWidth;`:

```objc
    // Shellforge: the floating panel stands off the window's edges.
    inputs.leftPanelInset = [iTermShellforgeSidebar floats] ? [iTermShellforgeSidebar floatingInset] : 0;
```

- [ ] **Step 4: Run the tests**

Run: `tools/run_tests.expect ModernTests/ShellforgeFloatingSidebarTest ModernTests/ShellforgeSidebarLayoutTest ModernTests/ShellforgeSidebarZoomTest`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add ModernTests/ShellforgeFloatingSidebarTest.swift sources/TerminalView/iTermShellforgeSidebar.swift sources/TerminalView/iTermRootTerminalView.h sources/TerminalView/iTermRootTerminalView.m
git commit -m "M12b task 3: on macOS 26 the sidebar floats — inset by Space.base, corners concentric with the window's"
```

### Task 4: The window around the panel (macOS 26)

**Files:**
- Modify: `sources/TerminalView/PseudoTerminal+WindowStyle.m` (`styleMaskForWindowType:…`, NORMAL/ACCESSORY/LION_FS and MAXIMIZED/CENTERED branches; `shouldHideWindowTitleForWindowType:`)
- Modify: `sources/TerminalView/PseudoTerminal.m` (`rootTerminalViewShouldDrawWindowTitleInPlaceOfTabBar`; `titleBarShouldAppearTransparentForWindowType:`)
- Modify: `sources/TerminalView/iTermRootTerminalView.m` (`frameForWindowTitleLabel…`, `frameForStandardWindowButtons`)
- Test: `ModernTests/ShellforgeFloatingSidebarTest.swift`

**Interfaces:**
- Consumes: `iTermShellforgeSidebar.floats`, `.floatingInset`, `root.shellforgeSidebarFrame` (Task 3).

- [ ] **Step 1: Write the failing host tests**

Add to `ShellforgeFloatingSidebarTest`:

```swift
    func testOnlyTitledTypesGainFullSizeContent() throws {
        try XCTSkipUnless(iTermShellforgeSidebar.floats)
        for type in [iTermWindowType.WINDOW_TYPE_NORMAL, .WINDOW_TYPE_MAXIMIZED, .WINDOW_TYPE_CENTERED] {
            let mask = PseudoTerminal.styleMask(for: type, savedWindowType: type, hotkeyWindowType: .iTermHotkeyWindowTypeNone)
            XCTAssertTrue(mask.contains(.fullSizeContentView), "\(type.rawValue)")
        }
        let accessory = PseudoTerminal.styleMask(for: .WINDOW_TYPE_ACCESSORY, savedWindowType: .WINDOW_TYPE_ACCESSORY,
                                                 hotkeyWindowType: .iTermHotkeyWindowTypeNone)
        XCTAssertFalse(accessory.contains(.fullSizeContentView), "an accessory window stays as upstream has it")
    }

    func testTheWindowsTitleBarGivesWayToThePanel() throws {
        try XCTSkipUnless(iTermShellforgeSidebar.floats)
        XCTAssertTrue(fixture.window.styleMask.contains(.fullSizeContentView))
        XCTAssertEqual(fixture.window.titleVisibility, .hidden)
        XCTAssertTrue(fixture.window.titlebarAppearsTransparent)
        XCTAssertTrue(fixture.terminal.rootTerminalViewShouldDrawWindowTitleInPlaceOfTabBar())
    }

    func testTheTerminalStartsBelowTheTitleStrip() throws {
        try XCTSkipUnless(iTermShellforgeSidebar.floats)
        let tabView = try XCTUnwrap(fixture.terminal.tabView)
        XCTAssertLessThan(tabView.frame.maxY, root.bounds.height - 10, "the strip is above the terminal")
        XCTAssertGreaterThanOrEqual(tabView.frame.minX, root.shellforgeSidebarFrame.maxX)
    }

    func testAHiddenSidebarLeavesNoGap() throws {
        try XCTSkipUnless(iTermShellforgeSidebar.floats)
        root.toggleShellforgeSidebar()
        defer { root.toggleShellforgeSidebar() }
        root.layoutSubtreeIfNeeded()
        let tabView = try XCTUnwrap(fixture.terminal.tabView)
        XCTAssertEqual(tabView.frame.minX, 0, accuracy: 1)
        XCTAssertTrue(fixture.window.styleMask.contains(.fullSizeContentView), "the window's style stays while hidden")
    }

    func testTheDragHandleFollowsThePanel() throws {
        try XCTSkipUnless(iTermShellforgeSidebar.floats)
        let handle = iTermShellforgeSidebar.dragHandleFrame(forSidebar: root.shellforgeSidebarFrame)
        XCTAssertEqual(handle.minY, root.shellforgeSidebarFrame.minY)
        XCTAssertEqual(handle.height, root.shellforgeSidebarFrame.height)
    }
```

Run: `tools/run_tests.expect ModernTests/ShellforgeFloatingSidebarTest`
Expected: `testOnlyTitledTypesGainFullSizeContent`, `testTheWindowsTitleBarGivesWayToThePanel` and `testTheTerminalStartsBelowTheTitleStrip` fail; the hidden and drag-handle tests may already pass.

If `PseudoTerminal.styleMask(for:savedWindowType:hotkeyWindowType:)` is not the Swift name of `+styleMaskForWindowType:savedWindowType:hotkeyWindowType:`, use the name the compiler suggests and ledger it.

- [ ] **Step 2: Full-size content for Shellforge's titled windows**

`PseudoTerminal+WindowStyle.m`, `styleMaskForWindowType:savedWindowType:hotkeyWindowType:`:
- In the `WINDOW_TYPE_MAXIMIZED` / `WINDOW_TYPE_CENTERED` branch, before its `return`, add:

```objc
            // Shellforge: on macOS 26 the floating sidebar's window runs its content under the title bar.
            if ([iTermShellforgeSidebar floats]) {
                mask |= NSWindowStyleMaskFullSizeContentView;
            }
```

- In the `WINDOW_TYPE_LION_FULL_SCREEN` / `WINDOW_TYPE_ACCESSORY` / `WINDOW_TYPE_NORMAL` branch, change the `if` to:

```objc
            // Shellforge: on macOS 26 the floating sidebar's window runs its content under the title bar —
            // a normal window, or one in Lion full screen from a normal window; not an accessory window.
            const BOOL shellforgeFloats = [iTermShellforgeSidebar floats] &&
                (windowType == WINDOW_TYPE_NORMAL ||
                 (windowType == WINDOW_TYPE_LION_FULL_SCREEN && iTermThemedWindowType(savedWindowType) == WINDOW_TYPE_NORMAL));
            if ([self windowTypeHasFullSizeContentView:iTermThemedWindowType(savedWindowType)] || shellforgeFloats) {
```

`shouldHideWindowTitleForWindowType:` — split the case group that returns `NO`: keep `WINDOW_TYPE_TRADITIONAL_FULL_SCREEN`, `WINDOW_TYPE_LION_FULL_SCREEN` and `WINDOW_TYPE_ACCESSORY` returning `NO`, and give NORMAL, MAXIMIZED and CENTERED their own:

```objc
            case WINDOW_TYPE_NORMAL:
            case WINDOW_TYPE_MAXIMIZED:
            case WINDOW_TYPE_CENTERED:
                // Shellforge: the title strip over the terminal draws the title beside the floating sidebar.
                return [iTermShellforgeSidebar floats];
```

If the file does not yet import the Swift header, add `#import "iTerm2SharedARC-Swift.h"`; if that makes an existing line ambiguous (M11 met this in AppearancePreferencesViewController.m), declare only `iTermShellforgeSidebar`'s two class properties in an `@interface` there instead, as M11 did, and ledger it.

- [ ] **Step 3: A transparent title bar and the title strip**

`PseudoTerminal.m`, `+titleBarShouldAppearTransparentForWindowType:` (the class method the instance one calls): at its top,

```objc
    // Shellforge: the floating sidebar's title bar is transparent, over the panel and the title strip.
    if ([iTermShellforgeSidebar floats] &&
        (windowType == WINDOW_TYPE_NORMAL || windowType == WINDOW_TYPE_MAXIMIZED || windowType == WINDOW_TYPE_CENTERED)) {
        return YES;
    }
```

`rootTerminalViewShouldDrawWindowTitleInPlaceOfTabBar`, replace

```objc
    if (!iTermWindowTypeIsCompact(self.windowType)) {
        return NO;
    }
```

with

```objc
    // Shellforge: the floating sidebar's window draws its title in the strip, as compact windows do.
    if (!iTermWindowTypeIsCompact(self.windowType) && ![iTermShellforgeSidebar floats]) {
        return NO;
    }
```

- [ ] **Step 4: The title starts past the panel; compact buttons move in**

`iTermRootTerminalView.m`, `frameForWindowTitleLabel…`: after the frame is computed and before it is returned, shift it past the sidebar's column:

```objc
    // Shellforge: the title strip starts past the sidebar's column.
    const CGFloat sidebarColumn = self.shellforgeSidebarWidth;
    if (sidebarColumn > 0) {
        frame.origin.x += sidebarColumn;
        frame.size.width = MAX(0, frame.size.width - sidebarColumn);
    }
```

(Use the name of the frame variable the method returns.)

`frameForStandardWindowButtons`: before `return [self retinaRoundRect:frame];`,

```objc
    // Shellforge: iTerm2's own window buttons (compact windows) move in with the floating panel.
    if ([iTermShellforgeSidebar floats] && self.shellforgeSidebarWidth > 0) {
        frame.origin.x += [iTermShellforgeSidebar floatingInset];
        frame.origin.y -= [iTermShellforgeSidebar floatingInset];
    }
```

- [ ] **Step 5: Run the tests**

Run: `tools/run_tests.expect ModernTests/ShellforgeFloatingSidebarTest ModernTests/ShellforgeSidebarLayoutTest ModernTests/ShellforgeHostTest ModernTests/ShellforgeSidebarZoomTest ModernTests/ShellforgeTerminalMatchTest`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add -u sources ModernTests
git commit -m "M12b task 4: on macOS 26 Shellforge's titled windows run under a transparent title bar — the window buttons sit in the panel, the title strip starts past it, the terminal below it"
```

### Task 5: Snapshots, every test, docs

**Files:**
- Create: `ModernTests/ShellforgeSnapshotTest.swift`
- Modify: `Shellforge/docs/features.md`, `Shellforge/docs/upstream-hook-points.md`

- [ ] **Step 1: A snapshot test for looking at it**

Renders a fixture window's frame view (title bar included) to PNG in light and dark, only when `SHELLFORGE_SNAPSHOT_DIR` is set, so the normal suite skips it:

```swift
//
//  ShellforgeSnapshotTest.swift
//  Shellforge
//
//  Writes a window with the sidebar to PNG, light and dark, for looking at the layout without screen
//  recording. Runs only with SHELLFORGE_SNAPSHOT_DIR set (TEST_RUNNER_SHELLFORGE_SNAPSHOT_DIR for
//  xcodebuild).
//

import XCTest
@testable import iTerm2SharedARC

@MainActor
final class ShellforgeSnapshotTest: XCTestCase {
    func testWriteSnapshots() throws {
        let directory = try XCTUnwrap(ProcessInfo.processInfo.environment["SHELLFORGE_SNAPSHOT_DIR"].flatMap { $0.isEmpty ? nil : $0 },
                                      "set SHELLFORGE_SNAPSHOT_DIR")
        let fixture = TerminalWindowTestFixture()
        defer { fixture.close() }
        fixture.window.setContentSize(NSSize(width: 1100, height: 700))
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            fixture.window.appearance = NSAppearance(named: appearance)
            let frameView = try XCTUnwrap(fixture.window.contentView?.superview)
            frameView.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds))
            frameView.cacheDisplay(in: frameView.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("sidebar-\(name).png"))
        }
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SHELLFORGE_SNAPSHOT_DIR"]?.isEmpty == false)
    }
}
```

Run: `TEST_RUNNER_SHELLFORGE_SNAPSHOT_DIR=<scratch dir> tools/run_tests.expect ModernTests/ShellforgeSnapshotTest`, then look at both PNGs. Check the before-and-after table's macOS 26 column: inset panel, round corners, buttons inside the panel's top, title past the panel, terminal below the strip. The glass may render flat in a cached display; that is expected.

- [ ] **Step 2: Every test**

Run: `tools/build.sh` — `Build succeeded.`, no warning in a changed file.
Run: `cd Shellforge && scripts/swift.sh test` — every run `✔`.
Run: `tools/run_tests.expect ModernTests` — the only failures allowed are the known `TriggerTimeoutDescriptionTests` (en_BE). An upstream test that fails because its window is now full-size on macOS 26: check whether it measures something the floating window legitimately changes (a title bar's height, a content frame's origin). If it does, make it build its window as before by setting the window's style mask back for that test only, and ledger it; if it does not, it is a bug — fix the hook.

- [ ] **Step 3: Docs**

`features.md`, `## The sidebar`, after the “Where it is” bullet:

```markdown
- **On macOS 26 and later** the sidebar floats: a rounded glass panel a little inside the window, with the window buttons in its top corner and the window's title over the terminal. Earlier macOS versions keep the full-height sidebar.
```

`upstream-hook-points.md`, append rows:

```markdown
| `sources/TerminalView/iTermLayoutCalculator.{h,m}` | `leftPanelInset` in; `leftPanelFrame` inset from the top, left and bottom | The floating sidebar's panel (macOS 26) |
| `sources/TerminalView/iTermRootTerminalView.{h,m}` | `leftPanelInset` fed from `iTermShellforgeSidebar.floats`; `shellforgeSidebarFrame`; the fake title shifted past the sidebar's column; iTerm2's compact window buttons moved in by the inset | The panel, the title strip beside it, the buttons inside it |
| `sources/TerminalView/PseudoTerminal+WindowStyle.m` (`styleMaskForWindowType:…`, `shouldHideWindowTitleForWindowType:`) | NORMAL, MAXIMIZED and CENTERED get full-size content and a hidden system title on macOS 26 | The window buttons sit inside the panel; the title is drawn in the strip |
| `sources/TerminalView/PseudoTerminal.m` (`titleBarShouldAppearTransparentForWindowType:`, `rootTerminalViewShouldDrawWindowTitleInPlaceOfTabBar`) | Transparent title bar and the title strip for those windows on macOS 26 | As above |
```

- [ ] **Step 4: Commit**

```bash
git add ModernTests/ShellforgeSnapshotTest.swift Shellforge/docs/features.md Shellforge/docs/upstream-hook-points.md
git commit -m "M12b docs: the floating sidebar; its hooks; a snapshot test for looking at the layout"
```
