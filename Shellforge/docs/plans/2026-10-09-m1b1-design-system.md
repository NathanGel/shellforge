# M1b-1 Design System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Shellforge gets AiTerm's design system unchanged — every colour, size, type style, surface, logo and badge, with the rules that keep views from inventing their own — as a `ShellforgeDesign` module the sidebar is rebuilt on in M1b-2.

**Architecture:** A port of `~/aiterm/app/Sources/AiTermUI` (the parts the sidebar uses: tokens, surfaces, interface scale, icons and logos, badge, hairline, heading, symbol mark, form field and help text) into a new package target `ShellforgeDesign`, which depends on nothing but SwiftUI and AppKit, with AiTerm's tests for those parts. `ShellforgeUI` depends on it. AiTerm's README — the system's spec — comes along, renamed, as `Sources/ShellforgeDesign/README.md`.

**Tech Stack:** Swift 6 language mode, swift-tools 6.0, macOS 13; SwiftUI and AppKit only; Swift Testing via `Shellforge/scripts/swift.sh`.

**Spec:** Shellforge PRD (Claude Doc 89fd80a8-5fcf-4423-a8d6-c62f8512a481) W8: "Every sidebar view keeps using AiTermUI and the rules in its README; no new colours or sizes outside Palette.swift and Metrics.swift." The user: "visually and functionally it should be exactly what AiTerm is, but inside an iTerm fork." AiTerm's `app/Sources/AiTermUI/README.md` is the design spec this ports.

## Global Constraints

- Source: AiTerm (`~/aiterm`, GPLv3, Laurens D'Hondt). Every ported file starts `// Ported from AiTerm (app/…/<file>.swift), GPLv3, Laurens D'Hondt.` (`SourceRulesTests.everyPortedFileCreditsAiTerm` checks it). Nothing in `~/aiterm` changes.
- Values are AiTerm's, unchanged: no colour, size, radius, spacing or type style is added, removed or altered in this plan. A port that will not compile on macOS 13 changes its code, never its value, and is ledgered.
- `ShellforgeDesign` imports only SwiftUI, AppKit and Foundation; nothing in the package imports it but `ShellforgeUI` and its tests.
- macOS 13 and Swift 6: no `@Observable`, no macOS 14+ API (`focusEffectDisabled`, `onKeyPress`, two-argument `onChange`, `selectionDisabled` …). Build and test only with `Shellforge/scripts/swift.sh`.
- Dark-only, as AiTerm: colours resolve under `.darkAqua`.
- Out of scope here (they arrive with their features): Input, SearchField, SegmentedControl, Select, Kbd, ControlChrome, FrontToBackStack (sheets), and every sidebar view (M1b-2).
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Nothing is pushed without asking.

## Review Focus

1. **A value that drifted in the port** — a token whose number, colour or weight differs from AiTerm's would make the rebuilt sidebar subtly wrong everywhere. (Task 1 test: `everyTokenMatchesAiTerms`, comparing the ported files' token lines with AiTerm's, names swapped.)
2. **The interface's light/dark appearance**: iTerm2 can run in a light appearance; a semantic `NSColor` resolved under it gives light-mode colours. Tokens that must be dark resolve under `.darkAqua` whatever the app's appearance. (Ported `PaletteTests` under both appearances.)
3. **A view that writes its own literal** — the design rules must catch it in `ShellforgeDesign` now and in `ShellforgeUI` from M1b-2 on. (Task 3: `DesignRulesTests` scans both modules; `ShellforgeUI`'s existing literals are listed as exceptions with the reason "replaced in M1b-2", so the list shrinks to nothing there.)
4. **Logos that fail to rasterise** on macOS 13's `NSImage(data:)` SVG support — a blank vendor mark. (Ported `LogosTests`/`IconSourceTests` render each brand and assert non-empty pixels.)
5. **Interface scale rounding** — a token scaled ×1.15 must land on whole points, or hairlines blur. (Ported `InterfaceScaleTests`.)

---

### Task 1: The ShellforgeDesign target and its tokens

**Files:**
- Modify: `Shellforge/Package.swift` (add `.target(name: "ShellforgeDesign", path: "Sources/ShellforgeDesign", exclude: ["README.md"])`, `.testTarget(name: "ShellforgeDesignTests", dependencies: ["ShellforgeDesign"], path: "Tests/ShellforgeDesignTests")`; `ShellforgeUI` depends on `ShellforgeDesign`; a library product `ShellforgeDesign` is not needed — the app links it through `ShellforgeUI`)
- Create, ported from `~/aiterm/app/Sources/AiTermUI/`: `Shellforge/Sources/ShellforgeDesign/Palette.swift`, `Metrics.swift`, `Surface.swift`, `InterfaceScale.swift`, `README.md` (renamed: AiTermUI → ShellforgeDesign, AiTermCore/AiTerm → ShellforgeCore/ShellforgeUI, AiTerm → Shellforge where it names the app; the inventory lists only what this plan ports, and says the sheet primitives arrive with the sheets)
- Test, ported: `Shellforge/Tests/ShellforgeDesignTests/TestSupport.swift`, `ColorProbe.swift`, `PaletteTests.swift`, `PaletteDistinctionTests.swift`, `SurfaceTests.swift`, `InterfaceScaleTests.swift`
- Test, new: `Shellforge/Tests/ShellforgeDesignTests/TokenParityTests.swift`

**Interfaces:**
- Produces (public, as AiTerm's): `Palette` (every member, `Brand` and its members), `Space`, `Radius`, `Size`, `TypeStyle`, `Typography`, `Sheet`, `View.font(_: TypeStyle)`, `Surface` and `View.surface(_:)`, `InterfaceScale` and its environment key and `View.interfaceScale(…)`, as AiTerm names them.

- [ ] **Step 1: The parity test first.**

```swift
import Foundation
import Testing

/// The tokens are AiTerm's, unchanged: each ported token file, with AiTerm's names swapped for
/// Shellforge's, declares exactly the `static let` lines AiTerm's does. A value changed in the port
/// fails here before it reaches a pixel.
@Suite struct TokenParityTests {
    private static let ours = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/ShellforgeDesign")
    private static let aiterm = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("aiterm/app/Sources/AiTermUI")

    private func declarations(_ url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("public static let") || $0.hasPrefix("static let") || $0.hasPrefix("case ") }
            .map { $0.replacingOccurrences(of: "AiTerm", with: "Shellforge") }
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: TokenParityTests.aiterm.path)), arguments: ["Palette.swift", "Metrics.swift", "Surface.swift", "InterfaceScale.swift"])
    func everyTokenMatchesAiTerms(file: String) throws {
        #expect(try declarations(Self.ours.appendingPathComponent(file)) == declarations(Self.aiterm.appendingPathComponent(file)))
    }
}
```

- [ ] **Step 2:** Add the targets to `Package.swift`, an empty `Sources/ShellforgeDesign/Placeholder.swift` (`import SwiftUI`) so the target builds, and run `scripts/swift.sh test --filter TokenParityTests`. Expected: 4 failures (the files do not exist yet).
- [ ] **Step 3: Port the tests.** Copy `TestSupport.swift`, `ColorProbe.swift`, `PaletteTests.swift`, `PaletteDistinctionTests.swift`, `SurfaceTests.swift`, `InterfaceScaleTests.swift` with the credit line, `@testable import AiTermUI` → `@testable import ShellforgeDesign`, and AiTerm's paths in any source-reading test → `Sources/ShellforgeDesign`. Run `scripts/swift.sh test --filter ShellforgeDesignTests`. Expected: build fails (types missing).
- [ ] **Step 4: Port the four sources and the README**, deleting `Placeholder.swift`. Change only what macOS 13 or the names require; ledger each such change. Keep the hand-expanded `State(initialValue:)` form where AiTerm uses it.
- [ ] **Step 5:** Run `scripts/swift.sh test --filter ShellforgeDesignTests`. Expected: all pass, including the 4 parity cases. Full suite. Expected: all pass.
- [ ] **Step 6:** Commit: `feat(design): ShellforgeDesign — AiTerm's palette, metrics, surfaces and interface scale, unchanged`.

### Task 2: Icons, logos, badge, hairline, heading, symbol mark, form field

**Files:**
- Create, ported: `Shellforge/Sources/ShellforgeDesign/IconSource.swift`, `Logos.swift`, `Badge.swift`, `Hairline.swift`, `SidebarHeading.swift`, `SymbolMark.swift`, `FormField.swift`
- Test, ported: `Shellforge/Tests/ShellforgeDesignTests/IconSourceTests.swift`, `LogosTests.swift`, `BadgeTests.swift`, `HairlineTests.swift`, `SidebarHeadingTests.swift`, `SymbolMarkTests.swift`, `HelpTextTests.swift`

**Interfaces:**
- Consumes: Task 1's tokens and `Surface`.
- Produces (public, as AiTerm's): `IconSource` (`.symbol`, `.brand`, `.artwork`, `.gitlabTanuki`, `.piBadge`), `Icon`, `LogoGlyph`, `Badge` (`.boxed`/`.quiet`, action and menu forms, `Diff`), `Hairline`, `SidebarHeading`, `SymbolMark` (`.quiet`/`.paper`), `FormField`, `HelpText`.

- [ ] **Step 1: Port the tests first** (credit line, imports renamed). Extend the parity test's arguments with `"IconSource.swift"`, `"Badge.swift"`. Run `scripts/swift.sh test --filter ShellforgeDesignTests`. Expected: build fails.
- [ ] **Step 2: Port the seven sources.** Logos stay SVG path strings rasterised through `NSImage(data:)`; if macOS 13's SVG decoding renders any brand blank (`LogosTests` says which), ledger it and keep the path — never swap in a different drawing.
- [ ] **Step 3:** Run the filter. Expected: all pass. Full suite. Expected: all pass.
- [ ] **Step 4:** Commit: `feat(design): AiTerm's icons, logos, badge, hairline, heading, symbol mark and help text`.

### Task 3: The design rules, enforced on both modules

**Files:**
- Test, ported: `Shellforge/Tests/ShellforgeDesignTests/DesignRulesTests.swift` (from `~/aiterm/app/Tests/AiTermUITests/DesignRulesTests.swift`)

**Interfaces:**
- Consumes: Tasks 1–2.

- [ ] **Step 1: Port the test** with its scope changed: it scans `Sources/ShellforgeDesign` and `Sources/ShellforgeUI` (AiTerm's scanned `AiTermUI` and the app's `Views`); the foreign-import rule forbids `ShellforgeCore` and `ShellforgeUI` inside `ShellforgeDesign`; AiTerm's exceptions keep their reasons, with paths renamed. Run it. Expected: it fails, listing `ShellforgeUI`'s current literals (the placeholder sidebar's `.orange`, `.blue`, `.green`, `8`, `12`, `16`, `240`, `.headline`, `.caption` …).
- [ ] **Step 2:** Add one exception per failing line in `ShellforgeUI`, each with the reason `"the placeholder sidebar, rebuilt on ShellforgeDesign in M1b-2"`. Run it. Expected: passes. (M1b-2's last task deletes these exceptions; the test's own stale-exception check then proves none is left.)
- [ ] **Step 3:** Full suite. Expected: all pass. Commit: `test(design): AiTerm's design rules, on ShellforgeDesign and ShellforgeUI`.

### Task 4: The app builds with the module

**Files:**
- Modify: `Shellforge/docs/upstream-hook-points.md` (only if the Xcode project needs a change)

- [ ] **Step 1:** Build the app: `xcodebuild -project iTerm2.xcodeproj -scheme iTerm2 -configuration Development -skipPackagePluginValidation CODE_SIGN_IDENTITY=- build`. Expected: succeeds — `ShellforgeDesign` comes in through `ShellforgeUI`'s dependency, with no project change. If the link fails on missing `ShellforgeDesign` symbols, add the product to `iTermSwiftPackages` as M1a added `ShellforgeCore`, ledger it, and list the change in `upstream-hook-points.md`.
- [ ] **Step 2:** Commit any change: `build: link ShellforgeDesign into the app`.
