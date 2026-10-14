# M12a The design system follows light and dark — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Shellforge's sidebar, sheets and panels follow the window's light or dark appearance, every colour reads in both, a translucency component is ready for the floating sidebar, and the terminal match has a light palette.

**Architecture:** the forced `.darkAqua` goes from the four places that set it. The handful of colours that only work on dark become adaptive in `Palette`, through one `adaptive(light:dark:)` helper backed by a dynamic `NSColor`. `Icon` resolves tints in the appearance it draws in. `ShellforgeMaterial` decides between macOS 26 glass, the sidebar material and an opaque colour. The terminal palette resolves in the app's appearance, with a light background a step lighter than the sidebar.

**Tech Stack:** Swift 6 package (`Shellforge/`, swift-testing, `scripts/swift.sh`), the iTerm2 app (XCTest host tests in `ModernTests`).

**Spec:** `Shellforge/docs/plans/2026-10-14-m12-modern-ui-design.md` (step 1; this plan also takes step 6, see below)

## Deviations from the spec's step order

- **Step 6's light palette is done here (Task 4).** Once the sidebar follows the appearance, the
  terminal match would paint a dark terminal beside a light sidebar until step 6. Cost if wrong:
  none; step 6 then has nothing left.
- **`Metrics` is not changed here.** Sizes are lined up with macOS 26 in M12b (the panel) and M12c
  (rows), where they can be compared by eye; changed alone, they would shift today's layout for no
  visible gain.

## Global Constraints

- Nothing in Shellforge sets `.darkAqua` after this plan, except the terminal palette's tests and
  `ColorProbe`'s default.
- Colours only in `Palette.swift` (`DesignRulesTests`); sizes only in `Metrics.swift`.
- `TokenParityTests`: a ported file this plan edits joins the `changed` set (it is no longer compared
  with AiTerm) and its `baseline` digest is moved to the new one. Ported files keep their credit line.
- Dark values stay as they are today: every existing test that resolves in dark keeps passing
  unchanged.
- Deployment targets: app macOS 12, package macOS 13; macOS 26 APIs behind `#available(macOS 26, *)`.
- Swift: no `fatalError`/`assert`, no force unwraps in new code. `git add` new files at once; `git mv` to rename.
- Commands: package tests `cd Shellforge && scripts/swift.sh test` (filter with `--filter <Suite>`);
  app build `tools/build.sh`; host tests `tools/run_tests.expect ModernTests/<Class>`. Warnings are errors.

## Review Focus

1. iTerm2's Appearance set to Dark while macOS is Light: the sidebar follows the window, not macOS. (Task 2, `theSidebarFollowsItsWindow`.)
2. Reduce Transparency on: no glass, no material, the opaque colour. (Task 3, `reduceTransparencyIsAlwaysOpaque`.)
3. A selected row in light: its title and badges stay white on the accent. (Task 1, `aSelectedRowIsWhiteOnTheAccentInLight`.)
4. A tinted icon drawn in dark, then in light: it must not keep the dark hex. (Task 1, `aTintIsResolvedPerAppearance`.)
5. The match on, macOS switches to light: open terminals take the light palette. (Task 4, `testAnAppearanceChangeRecoloursASession`.)

---

### Task 1: Colours that read in light and dark

**Files:**
- Modify: `Shellforge/Sources/ShellforgeDesign/Palette.swift` (`codeBackground`, `badgeHovered`, `rowHover`, `rowHoverSolid`, new `adaptive`)
- Modify: `Shellforge/Sources/ShellforgeDesign/IconSource.swift` (`Icon`, `hexString`)
- Modify: `Shellforge/Sources/ShellforgeUI/Sidebar/VendorMark.swift` (a ring on every disc)
- Modify: `Shellforge/Sources/ShellforgeUI/Sidebar/SidebarRowParts.swift:240` (the GitHub mark's tint)
- Modify: `Shellforge/Tests/ShellforgeDesignTests/ColorProbe.swift` (an appearance parameter)
- Modify: `Shellforge/Tests/ShellforgeDesignTests/TokenParityTests.swift` (`changed`, `baseline`)
- Test: `Shellforge/Tests/ShellforgeDesignTests/AdaptivePaletteTests.swift`

**Interfaces:**
- Produces: `Palette.adaptive(light: NSColor, dark: NSColor) -> Color` (internal to ShellforgeDesign); `Icon.hexString(_ color: Color, dark: Bool) -> String`; `ColorProbe.hex(_:in:)`, `ColorProbe.rgba(_:in:)` with `in appearance: NSAppearance.Name = .darkAqua`.

- [ ] **Step 1: Give `ColorProbe` an appearance**

In `ColorProbe.swift`, give `hex` and `rgba` a parameter `in name: NSAppearance.Name = .darkAqua` and resolve under `NSAppearance(named: name)` instead of `.darkAqua`:

```swift
    static func hex(_ color: Color, in name: NSAppearance.Name = .darkAqua) -> String {
        var hex = "#000000"
        let appearance = NSAppearance(named: name) ?? NSAppearance.currentDrawing()
        appearance.performAsCurrentDrawingAppearance {
            guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            hex = String(format: "#%02X%02X%02X",
                         Int((srgb.redComponent * 255).rounded()),
                         Int((srgb.greenComponent * 255).rounded()),
                         Int((srgb.blueComponent * 255).rounded()))
        }
        return hex
    }

    static func rgba(_ color: Color, in name: NSAppearance.Name = .darkAqua) -> String {
        var out = "rgba(0, 0, 0, 1)"
        let appearance = NSAppearance(named: name) ?? NSAppearance.currentDrawing()
        appearance.performAsCurrentDrawingAppearance {
            guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            out = String(format: "rgba(%d, %d, %d, %.3f)",
                         Int((srgb.redComponent * 255).rounded()),
                         Int((srgb.greenComponent * 255).rounded()),
                         Int((srgb.blueComponent * 255).rounded()),
                         srgb.alphaComponent)
        }
        return out
    }
```

Update its doc comment's first paragraph to: “Every colour is resolved under a named appearance, `.darkAqua` unless a test asks for another, so a test's outcome never depends on the machine's setting.”

- [ ] **Step 2: Write the failing tests**

`Shellforge/Tests/ShellforgeDesignTests/AdaptivePaletteTests.swift`:

```swift
import AppKit
import SwiftUI
import Testing
@testable import ShellforgeDesign

/// The colours that only worked on AiTerm's dark sidebar now read in light too; their dark values
/// are what they always were.
@MainActor @Suite struct AdaptivePaletteTests {
    @Test(arguments: ["rowHover", "badgeHovered", "codeBackground", "rowHoverSolid"])
    func theColourDiffersInLightAndDark(name: String) {
        let color = Self.colors[name] ?? .clear
        #expect(ColorProbe.rgba(color, in: .aqua) != ColorProbe.rgba(color, in: .darkAqua), "\(name)")
    }

    private static let colors: [String: Color] = [
        "rowHover": Palette.rowHover, "badgeHovered": Palette.badgeHovered,
        "codeBackground": Palette.codeBackground, "rowHoverSolid": Palette.rowHoverSolid,
    ]

    @Test func darkIsUnchanged() {
        #expect(ColorProbe.hex(Palette.codeBackground) == "#141519")
        #expect(ColorProbe.rgba(Palette.rowHover) == "rgba(255, 255, 255, 0.060)")
        #expect(ColorProbe.rgba(Palette.badgeHovered) == "rgba(255, 255, 255, 0.140)")
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func aHoveredRowIsNotTheSidebar(appearance: NSAppearance.Name) {
        #expect(ColorProbe.hex(Palette.rowHoverSolid, in: appearance) != ColorProbe.hex(Palette.sidebar, in: appearance))
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func theCodeBlockStandsOffTheSheet(appearance: NSAppearance.Name) {
        #expect(ColorProbe.hex(Palette.codeBackground, in: appearance) != ColorProbe.hex(Palette.surface, in: appearance))
    }

    @Test func aSelectedRowIsWhiteOnTheAccentInLight() {
        #expect(ColorProbe.hex(Surface.accent.ink, in: .aqua) == "#FFFFFF")
    }

    @Test func aTintIsResolvedPerAppearance() {
        let dark = Icon.hexString(Palette.text, dark: true)
        let light = Icon.hexString(Palette.text, dark: false)
        #expect(dark != light)
        #expect(Icon.hexString(Palette.text, dark: true) == dark, "remembered per appearance")
    }
}
```

- [ ] **Step 3: Run them to see them fail**

Run: `cd Shellforge && scripts/swift.sh test --filter AdaptivePaletteTests`
Expected: build error, `extra argument 'dark' in call` (no `hexString(_:dark:)` yet).

- [ ] **Step 4: Make the colours adaptive**

In `Palette.swift`, after `private let rowHoverAlpha = 0.06`:

```swift
/// The black wash a hovered row takes in the light appearance: lighter than the dark's white one,
/// because black on a light grey reads stronger than white on a dark one.
private let rowHoverLightAlpha = 0.05
```

Inside `enum Palette`, after `hex(_:)`:

```swift
    /// A colour with one value in the light appearance and another in the dark, resolved by AppKit
    /// wherever it is drawn.
    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
```

Replace `codeBackground`:

```swift
    /// The command preview block in a sheet, kept visually distinct from the surrounding surface:
    /// AppKit's text background resolves too close to the window background in both appearances.
    public static let codeBackground = adaptive(light: NSColor(srgbRed: 0.949, green: 0.949, blue: 0.957, alpha: 1),
                                                dark: NSColor(srgbRed: 0x14 / 255.0, green: 0x15 / 255.0, blue: 0x19 / 255.0, alpha: 1))
```

Replace `badgeHovered`:

```swift
    /// A badge under the pointer, on any ground but the accent: a white wash in dark, a black one
    /// in light.
    public static let badgeHovered = adaptive(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.14))
```

Replace `rowHover`:

```swift
    /// The wash painted behind a sidebar row while the pointer is over it: literal white in dark,
    /// literal black in light. Not `.primary`, whose own alpha (≈0.847) compounds with an opacity.
    public static let rowHover = adaptive(light: NSColor(white: 0, alpha: rowHoverLightAlpha), dark: NSColor(white: 1, alpha: rowHoverAlpha))
```

Replace `rowHoverSolid` and its doc comment:

```swift
    /// The opaque colour a hovered row's avatar ring is painted: `rowHover` composited over
    /// `sidebar`, in whichever appearance it is drawn. Derived, not hardcoded, so the two can never
    /// drift.
    ///
    /// Composited by hand in sRGB, not with `NSColor.blended(withFraction:of:)`: that method
    /// converts through `NSCalibratedRGBColorSpace`, whose gamma distorts a dark base colour.
    public static let rowHoverSolid = Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        var base = NSColor.windowBackgroundColor
        appearance.performAsCurrentDrawingAppearance {
            base = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? NSColor.windowBackgroundColor
        }
        let (wash, alpha): (CGFloat, CGFloat) = dark ? (1, rowHoverAlpha) : (0, rowHoverLightAlpha)
        return NSColor(srgbRed: base.redComponent * (1 - alpha) + wash * alpha,
                       green: base.greenComponent * (1 - alpha) + wash * alpha,
                       blue: base.blueComponent * (1 - alpha) + wash * alpha,
                       alpha: 1)
    })
```

- [ ] **Step 5: Resolve tints per appearance**

In `IconSource.swift`, in `struct Icon`, add beside `@Environment(\.surface) private var surface`:

```swift
    @Environment(\.colorScheme) private var colorScheme
```

Change the line that builds `LogoGlyph` (line 52) to:

```swift
            LogoGlyph(brand: brand, fill: tint.map { Self.hexString($0, dark: colorScheme == .dark) } ?? brand.hex, size: size)
```

Replace `hexString` and `hexes`:

```swift
    /// `color` as `#RRGGBB` for an SVG fill, resolved in the appearance the icon draws in.
    /// Remembered per colour and appearance: a body asks again each time it runs.
    @MainActor
    static func hexString(_ color: Color, dark: Bool) -> String {
        let key = HexKey(color: color, dark: dark)
        if let known = hexes[key] { return known }
        var hex = "#000000"
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
        appearance.performAsCurrentDrawingAppearance {
            guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            hex = String(format: "#%02X%02X%02X",
                         Int((srgb.redComponent * 255).rounded()),
                         Int((srgb.greenComponent * 255).rounded()),
                         Int((srgb.blueComponent * 255).rounded()))
        }
        hexes[key] = hex
        return hex
    }

    private struct HexKey: Hashable {
        let color: Color
        let dark: Bool
    }

    @MainActor private static var hexes: [HexKey: String] = [:]
```

Update `hexString`'s old doc paragraph that mentions resolving under `.darkAqua` to say it resolves in the appearance it is given.

- [ ] **Step 6: Marks that read on a light sidebar**

In `VendorMark.swift`, after the `switch` inside the `ZStack` (before `}.frame(width: size, height: size)`), add a ring every disc carries:

```swift
            // The disc's edge: a white Codex disc on a light sidebar, or a black Pi disc on a dark
            // one, would otherwise have no edge.
            Circle().strokeBorder(Palette.border, lineWidth: 1)
```

In `SidebarRowParts.swift:240`, give the GitHub mark the row's ink, so it is black on a light row and white on a dark or selected one:

```swift
                Icon(.brand(Palette.github), size: scale(Self.logoSize), tint: surface.ink)
```

- [ ] **Step 7: Run the tests**

Run: `cd Shellforge && scripts/swift.sh test --filter 'AdaptivePaletteTests|PaletteDistinction|SurfaceTests'`
Expected: every run `✔`.

- [ ] **Step 8: Move the parity pins**

Run: `cd Shellforge && scripts/swift.sh test --filter TokenParityTests`
Expected: FAIL for `Palette` and `IconSource`, each message ending `its digest is <hex>`.

In `TokenParityTests.swift`, add both to `changed`:

```swift
    static let changed: Set = ["FormField", "Input", "SegmentedControl", "Palette", "IconSource"]
```

and set `baseline["Palette"]` and `baseline["IconSource"]` to the digests the failure printed. Run it again; expected `✔`.

- [ ] **Step 9: Run every package test**

Run: `cd Shellforge && scripts/swift.sh test`
Expected: every run `✔`.

- [ ] **Step 10: Commit**

```bash
git add Shellforge/Tests/ShellforgeDesignTests/AdaptivePaletteTests.swift
git add -u Shellforge
git commit -m "M12a task 1: colours that read in light and dark — the row hover, badge hover and code block adapt, tints resolve in the appearance they draw in, vendor discs get an edge, and the GitHub mark takes the row's ink"
```

### Task 2: Nothing forced dark

**Files:**
- Modify: `Shellforge/Sources/ShellforgeUI/ShellforgeSidebar.swift:27-33` (`makeView`)
- Rename: `Shellforge/Sources/ShellforgeUI/DarkPanel.swift` → `ShellforgePanel.swift` (`git mv`); `enum DarkPanel` → `enum ShellforgePanel`
- Modify: the same file's `FolderChooser.panel()`
- Test: `Shellforge/Tests/ShellforgeUITests/AppearanceTests.swift`

**Interfaces:**
- Produces: `ShellforgePanel.present(_:over:) -> NSPanel`, `ShellforgePanel.dismiss(_:)` (same signatures as `DarkPanel`'s).

- [ ] **Step 1: Write the failing tests**

`Shellforge/Tests/ShellforgeUITests/AppearanceTests.swift`:

```swift
import AppKit
import SwiftUI
import Testing
@testable import ShellforgeTestSupport
@testable import ShellforgeCore
import ShellforgeDesign
@testable import ShellforgeUI

/// Nothing Shellforge draws forces an appearance: the sidebar, its sheets and its folder picker take
/// their window's, which is macOS's or iTerm2's Appearance setting.
@MainActor @Suite struct AppearanceTests {
    private func sidebar() -> NSView {
        let document = WorkspaceDocument(store: WorkspaceStore(folder: TestScratch.root.appendingPathComponent("appearance-\(UUID().uuidString)")))
        let launcher = CommandLauncher(resolve: { ResolvedEnvironment(variables: ["PATH": "/usr/bin"], source: .loginShell("/bin/zsh")) })
        let model = SidebarModel(host: FakeTerminalHost(), document: document, launcher: launcher, jiraSettings: { nil })
        let hooks = AgentHooksModel(integrations: HookIntegrations(home: TestScratch.root.appendingPathComponent("appearance-home-\(UUID().uuidString)"),
                                                                   resources: .bundled(resourceURL: nil)), names: [:])
        return ShellforgeSidebar.makeView(model: model, chooseFolder: { nil }, hooks: hooks,
                                          machine: MachineMonitor(sensor: InertMachineSensor(), power: InertPower()),
                                          backpack: BackpackController(ports: .inert, settings: BackpackSettings(defaults: nil), toast: { _ in }),
                                          zoom: SidebarZoom(settings: SidebarLayoutSettings(defaults: ScratchDefaults.make())),
                                          terminalMatch: TerminalMatchSettings(defaults: ScratchDefaults.make()))
    }

    @Test func theSidebarFollowsItsWindow() {
        let view = sidebar()
        #expect(view.appearance == nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = view
        #expect(view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua)
        window.appearance = NSAppearance(named: .darkAqua)
        #expect(view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        window.close()
    }

    @Test func aSheetPanelFollowsItsWindow() {
        let panel = ShellforgePanel.present(Text(verbatim: "x"), over: nil)
        #expect(panel.appearance == nil)
        #expect(panel.contentView?.appearance == nil)
        ShellforgePanel.dismiss(panel)
    }

    @Test func theFolderPickerFollowsTheApp() {
        #expect(FolderChooser.panel().appearance == nil)
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd Shellforge && scripts/swift.sh test --filter AppearanceTests`
Expected: build error, `cannot find 'ShellforgePanel' in scope`.

- [ ] **Step 3: Rename the panel and drop the forced appearances**

```bash
git mv Shellforge/Sources/ShellforgeUI/DarkPanel.swift Shellforge/Sources/ShellforgeUI/ShellforgePanel.swift
```

In `ShellforgePanel.swift`:
- `public enum DarkPanel` → `public enum ShellforgePanel`, with the doc comment: “A sheet in a panel of its own, on its parent window, in that window's appearance.”
- In `present`, delete `panel.appearance = NSAppearance(named: .darkAqua)` and `host.appearance = NSAppearance(named: .darkAqua)`.
- In `PanelSlot`, `DarkPanel.present` → `ShellforgePanel.present` and `DarkPanel.dismiss` → `ShellforgePanel.dismiss`.
- In `FolderChooser.panel()`, delete `panel.appearance = NSAppearance(named: .darkAqua)`, and change its doc comment to: “Folder choosing for Add Project, in the app's appearance.”

In `ShellforgeSidebar.swift`'s `makeView`, delete the three lines:

```swift
        // AiTerm is dark-only and forced the whole app dark; here only the sidebar is, so iTerm2's
        // own windows keep the appearance the user chose. Every colour below resolves against this.
        host.appearance = NSAppearance(named: .darkAqua)
```

- [ ] **Step 4: Run the tests**

Run: `cd Shellforge && scripts/swift.sh test --filter AppearanceTests`
Expected: `✔ Test run with 3 tests in 1 suite passed`.

Then: `grep -rn 'darkAqua' Shellforge/Sources | grep -v TerminalPalette` — expected: only `Palette.swift`'s `bestMatch` lines (in `adaptive` and `rowHoverSolid`) and `IconSource.swift`'s `dark ? .darkAqua : .aqua`.

- [ ] **Step 5: Run every package test**

Run: `cd Shellforge && scripts/swift.sh test`
Expected: every run `✔`. A test that rendered the sidebar and expected dark pixels now renders in the test process's appearance; if one fails for that reason, set its window's `appearance` to `.darkAqua` in the test (the test is about layout, not the appearance) and ledger it.

- [ ] **Step 6: Commit**

```bash
git add Shellforge/Tests/ShellforgeUITests/AppearanceTests.swift
git add -u Shellforge
git commit -m "M12a task 2: nothing forced dark — the sidebar, its sheets (DarkPanel is now ShellforgePanel) and the folder picker take their window's appearance"
```

### Task 3: `ShellforgeMaterial`

**Files:**
- Create: `Shellforge/Sources/ShellforgeDesign/ShellforgeMaterial.swift`
- Test: `Shellforge/Tests/ShellforgeDesignTests/ShellforgeMaterialTests.swift`

**Interfaces:**
- Produces: `public enum ShellforgeMaterial { public enum Kind: Equatable, Sendable { case glass, sidebar, opaque }; public static func kind(macOSMajor: Int, reduceTransparency: Bool) -> Kind; public static var current: Kind }`; `public struct MaterialBackground<S: Shape>: View { public init(_ shape: S, kind: ShellforgeMaterial.Kind = ShellforgeMaterial.current) }`. M12b uses `MaterialBackground` for the panel.

- [ ] **Step 1: Write the failing tests**

```swift
import AppKit
import SwiftUI
import Testing
@testable import ShellforgeDesign

/// One place decides how a surface is translucent: macOS 26's glass, the sidebar material before it,
/// and an opaque colour whenever Reduce Transparency is on.
@MainActor @Suite struct ShellforgeMaterialTests {
    @Test func macOS26IsGlass() {
        #expect(ShellforgeMaterial.kind(macOSMajor: 26, reduceTransparency: false) == .glass)
        #expect(ShellforgeMaterial.kind(macOSMajor: 27, reduceTransparency: false) == .glass)
    }

    @Test func earlierIsTheSidebarMaterial() {
        for major in 12...15 {
            #expect(ShellforgeMaterial.kind(macOSMajor: major, reduceTransparency: false) == .sidebar)
        }
    }

    @Test func reduceTransparencyIsAlwaysOpaque() {
        for major in [12, 15, 26] {
            #expect(ShellforgeMaterial.kind(macOSMajor: major, reduceTransparency: true) == .opaque)
        }
    }

    @Test(arguments: [ShellforgeMaterial.Kind.glass, .sidebar, .opaque])
    func everyKindDraws(kind: ShellforgeMaterial.Kind) throws {
        let host = NSHostingView(rootView: MaterialBackground(RoundedRectangle(cornerRadius: Radius.control), kind: kind)
            .frame(width: 120, height: 80))
        host.frame = NSRect(x: 0, y: 0, width: 120, height: 80)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        #expect(rep.pixelsWide > 0)
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd Shellforge && scripts/swift.sh test --filter ShellforgeMaterialTests`
Expected: build error, `cannot find 'ShellforgeMaterial' in scope`.

- [ ] **Step 3: Write the material**

```swift
import AppKit
import SwiftUI

/// How a Shellforge surface is translucent, decided in one place: macOS 26's glass, the system
/// sidebar material before it, and the opaque window colour whenever Reduce Transparency is on.
public enum ShellforgeMaterial {
    public enum Kind: Equatable, Sendable { case glass, sidebar, opaque }

    public static func kind(macOSMajor: Int, reduceTransparency: Bool) -> Kind {
        if reduceTransparency { return .opaque }
        return macOSMajor >= 26 ? .glass : .sidebar
    }

    /// This Mac's kind, now.
    @MainActor public static var current: Kind {
        kind(macOSMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
             reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
    }
}

/// `shape` filled with a Shellforge material.
public struct MaterialBackground<S: Shape>: View {
    let shape: S
    let kind: ShellforgeMaterial.Kind

    public init(_ shape: S, kind: ShellforgeMaterial.Kind = ShellforgeMaterial.current) {
        self.shape = shape
        self.kind = kind
    }

    public var body: some View {
        switch kind {
        case .glass:
            if #available(macOS 26, *) {
                shape.fill(Color.clear).glassEffect(.regular, in: shape)
            } else {
                SidebarMaterial().clipShape(shape)
            }
        case .sidebar:
            SidebarMaterial().clipShape(shape)
        case .opaque:
            shape.fill(Palette.surface)
        }
    }
}

/// The system sidebar material, behind the window.
struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
```

```bash
git add Shellforge/Sources/ShellforgeDesign/ShellforgeMaterial.swift Shellforge/Tests/ShellforgeDesignTests/ShellforgeMaterialTests.swift
```

- [ ] **Step 4: Run the tests, then every package test**

Run: `cd Shellforge && scripts/swift.sh test --filter ShellforgeMaterialTests` — expected `✔`, 6 tests (3 + 3 arguments).
Run: `cd Shellforge && scripts/swift.sh test` — expected every run `✔` (DesignRulesTests included: the material draws no colour of its own but `Palette.surface`).

- [ ] **Step 5: Commit**

```bash
git commit -m "M12a task 3: ShellforgeMaterial — macOS 26's glass, the sidebar material before it, the opaque window colour with Reduce Transparency; ready for M12b's panel"
```

### Task 4: The terminal match's light palette

**Files:**
- Modify: `Shellforge/Sources/ShellforgeDesign/TerminalPalette.swift` (`colors(in:)`, `readable(_:on:)`)
- Modify: `sources/TerminalView/iTermShellforgeTerminalMatch.swift` (`profile(forColors:keeping:)`, `paletteColor(forKey:)`)
- Test: `Shellforge/Tests/ShellforgeDesignTests/TerminalPaletteTests.swift`, `ModernTests/ShellforgeTerminalMatchTest.swift`

**Interfaces:**
- Consumes: nothing from Tasks 1–3.
- Produces: `ShellforgeTerminalPalette.colors(in:)` resolves in the appearance it is given, light or dark; `readable(_:on:)` darkens on a light background.

- [ ] **Step 1: Write the failing package tests**

Add to `TerminalPaletteTests`:

```swift
    private let light = NSAppearance(named: .aqua)

    @Test func theLightBackgroundIsAStepLighterThanTheLightSidebar() throws {
        var surface = SRGB(red: 0, green: 0, blue: 0)
        try #require(light).performAsCurrentDrawingAppearance {
            surface = SRGB(TerminalSource.surface, over: SRGB(red: 0, green: 0, blue: 0))
        }
        let background = try #require(ShellforgeTerminalPalette.colors(in: light)[.background])
        #expect(background == surface.lightened(by: ShellforgeTerminalPalette.backgroundStep))
    }

    @Test func everyTextColourIsReadableOnTheLightBackground() throws {
        let colors = ShellforgeTerminalPalette.colors(in: light)
        let background = try #require(colors[.background])
        for role in TerminalColorRole.all where role.needsContrast {
            let color = try #require(colors[role])
            #expect(color.contrast(with: background) >= ShellforgeTerminalPalette.minimumContrast, "\(role)")
        }
    }

    @Test func aLightColourIsDarkenedOnALightBackground() {
        let background = SRGB(red: 0.97, green: 0.97, blue: 0.97)
        let pale = SRGB(red: 0.9, green: 0.75, blue: 0.75)
        let readable = ShellforgeTerminalPalette.readable(pale, on: background)
        #expect(readable.contrast(with: background) >= ShellforgeTerminalPalette.minimumContrast)
        #expect(readable.red < pale.red, "darkened, not lightened")
    }
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd Shellforge && scripts/swift.sh test --filter TerminalPaletteTests`
Expected: the three new tests fail (the background is darkened, and `readable` lightens towards white).

- [ ] **Step 3: Resolve in either appearance**

In `TerminalPalette.swift`, in `colors(in:)`, replace the background line:

```swift
            let surface = SRGB(TerminalSource.surface, over: opaqueBlack)
            let isLight = surface.luminanceIsLight
            // A step off the sidebar: darker beside a dark sidebar, lighter beside a light one, so
            // the terminal is the panel the eye rests on.
            let background = isLight ? surface.lightened(by: backgroundStep) : surface.darkened(by: backgroundStep)
```

Replace `readable(_:on:)`:

```swift
    /// `color`, moved in 5 % steps until it reaches `minimumContrast` on `background`: lightened on a
    /// dark background, darkened on a light one.
    public static func readable(_ color: SRGB, on background: SRGB) -> SRGB {
        var color = color
        let towardBlack = background.luminanceIsLight
        for _ in 0..<100 where color.contrast(with: background) < minimumContrast {
            color = towardBlack ? color.darkened(by: 0.05) : color.lightened(by: 0.05)
        }
        return color
    }
```

In `struct SRGB`, after `luminance`:

```swift
    /// Whether text on this colour should be dark: its luminance is past the middle of the WCAG scale.
    var luminanceIsLight: Bool { luminance > 0.18 }
```

(0.18 is where black and white text have equal contrast on a colour: (L + 0.05)/0.05 = 1.05/(L + 0.05).)

Update `colors(in:)`'s doc comment: “read under `appearance` each time they are asked for — light or dark, as the window is — so they follow the accent colour, Increase Contrast and the appearance.”

- [ ] **Step 4: Run the package tests**

Run: `cd Shellforge && scripts/swift.sh test --filter TerminalPaletteTests` — expected `✔`, every test.

- [ ] **Step 5: Write the failing host test**

Add to `ShellforgeTerminalMatchTest`:

```swift
    func testAnAppearanceChangeRecoloursASession() throws {
        let session = try XCTUnwrap(fixture.terminal.currentSession())
        let previous = NSApp.appearance
        defer { NSApp.appearance = previous }
        NSApp.appearance = NSAppearance(named: .darkAqua)
        iTermShellforgeTerminalMatch.setOn(true)
        let dark = try XCTUnwrap(background(session)?.usingColorSpace(.sRGB))
        NSApp.appearance = NSAppearance(named: .aqua)
        let lightened = expectation(description: "the session takes the light palette")
        lightened.assertForOverFulfill = false
        func check() {
            if let now = background(session)?.usingColorSpace(.sRGB), now.brightnessComponent > dark.brightnessComponent + 0.3 {
                lightened.fulfill()
            } else {
                DispatchQueue.main.async(execute: check)
            }
        }
        DispatchQueue.main.async(execute: check)
        wait(for: [lightened], timeout: 10)
        try assertSame(background(session), iTermShellforgeTerminalMatch.paletteColor(forKey: KEY_BACKGROUND_COLOR), "the light palette")
    }
```

Run: `tools/run_tests.expect ModernTests/ShellforgeTerminalMatchTest/testAnAppearanceChangeRecoloursASession`
Expected: FAIL, the expectation times out (the bridge still asks for the dark palette).

- [ ] **Step 6: The bridge asks for the app's appearance**

In `iTermShellforgeTerminalMatch.swift`, in `profile(forColors:keeping:)` and in `paletteColor(forKey:)`, replace `ShellforgeTerminalPalette.colors()` with `ShellforgeTerminalPalette.colors(in: NSApp.effectiveAppearance)`.

A session's own appearance change does not cover this: under the Minimal theme iTerm2 pins each session view's appearance to its background (`updateAppearanceForMinimalTheme`), so the view may never see the app change. The bridge watches the app instead. Add beside `settings`:

```swift
    /// Recolours every session when the app's appearance changes, while the match is on.
    private static var appearanceObservation: NSKeyValueObservation?
```

and in `settings`' initialiser, before `return settings`:

```swift
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { _, _ in
            MainActor.assumeIsolated { if settings.isOn { recolour() } }
        }
```

- [ ] **Step 7: Run the host tests**

Run: `tools/run_tests.expect ModernTests/ShellforgeTerminalMatchTest`
Expected: `Executed 11 tests, with 0 failures`.

- [ ] **Step 8: Commit**

```bash
git add -u Shellforge sources ModernTests
git commit -m "M12a task 4: the terminal match's light palette — a background a step lighter than the light sidebar, text and colours darkened to 4.5:1, switching with the app's appearance"
```

### Task 5: Docs, the build, every test and a check by hand

**Files:**
- Modify: `Shellforge/docs/features.md` (`## The sidebar`, the Terminal entry)
- Modify: `Shellforge/Sources/ShellforgeDesign/README.md` (the dark-only notes)

- [ ] **Step 1: features.md**

In `## The sidebar`, replace “It is always dark, even when iTerm2 is light.” with “It follows the window's appearance: light or dark, as macOS or iTerm2's Appearance setting has it.”

In the Terminal entry under `## Settings and connections`, replace “a background one step darker than the sidebar” with “a background one step off the sidebar (darker in dark mode, lighter in light mode)”, and add a line:

```markdown
  - In light mode the match uses a light palette, and it switches when the appearance does.
```

- [ ] **Step 2: The design system's README**

Run: `grep -n -i 'dark-only\|darkAqua\|always dark\|forced dark' Shellforge/Sources/ShellforgeDesign/README.md`
For each line it prints, rewrite it to say the design system follows the window's appearance and that the colours listed in Task 1 adapt; keep the rest of the README as it is.

- [ ] **Step 3: Build and run every test**

Run: `tools/build.sh` — expected `Build succeeded.`, no warning in a changed file.
Run: `cd Shellforge && scripts/swift.sh test` — expected every run `✔`.
Run: `tools/run_tests.expect ModernTests/ShellforgeHostTest ModernTests/ShellforgeSidebarLayoutTest ModernTests/ShellforgeReportsTest ModernTests/ShellforgeSidebarZoomTest ModernTests/ShellforgeTerminalMatchTest` — expected `** TEST SUCCEEDED **`.

- [ ] **Step 4: Check by hand**

Run: `make run`. With macOS in Light, then in Dark:
1. The sidebar is light, then dark; hover a row, select a row (white text on the accent in both), open a project's menu.
2. The vendor discs (Claude, Codex, Grok) and a GitHub project's mark are visible in both.
3. Open New Task and Settings: the sheets follow the appearance; the command preview block stands off the sheet.
4. Settings › Core › Terminal on: the terminal takes the light palette in Light and the dark one in Dark, a step off the sidebar.
5. iTerm2 › Settings › Appearance set to Dark while macOS is Light: the sidebar is dark.

- [ ] **Step 5: Commit**

```bash
git add Shellforge/docs/features.md Shellforge/Sources/ShellforgeDesign/README.md
git commit -m "M12a docs: the sidebar follows the appearance; the match's light palette"
```
