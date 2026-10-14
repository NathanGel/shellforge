# M12c The sidebar's content — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** the sidebar's rows, headings, badges, footer and banners read as a macOS 26 sidebar: sentence-case section headers, the system selection (accent while the window is active, grey when not), capsule badges, a footer card and inline notices.

**Architecture:** all in the Shellforge package. `SidebarHeading` loses its uppercase; `RowPill` and `Surface` learn an inactive selection from `controlActiveState`; `Badge` and `StatusCountChip` draw capsules; the footer sits on a rounded card; `SidebarBanner` gains a symbol and a tinted ground. New colours are `Palette` members. Ported files that change move to `TokenParityTests.changed` with new digests.

**Tech Stack:** SwiftUI in the Shellforge package (swift-testing), one ModernTests snapshot for looking.

**Spec:** `Shellforge/docs/plans/2026-10-14-m12-modern-ui-design.md` (step 3)

## Before and after (recorded here; the user waived per-step sign-off)

| | Before | After |
| --- | --- | --- |
| Section headers | “PROJECTS”, “OTHER TABS”, “SYSTEM”, “USAGE”: 10 pt semibold, tracked, uppercased | “Projects”, “Other Tabs”, “System”, “Usage”: 11 pt semibold, sentence case, secondary label colour |
| Divider names | Uppercased | As the user typed them, in the header style |
| Selected row | Accent pill, white ink, always | Accent pill with white ink while the window is active; the unemphasized grey selection with normal ink while it is not |
| Row pill corner | 6 pt | 8 pt (`Radius.group`), the macOS 26 sidebar selection |
| Badges and status chips | 4 pt rounded rectangles | Capsules |
| Footer | On the sidebar ground under a hairline | On a rounded card (`Radius.group`), inset `Space.base`, no top hairline |
| Banners | Coloured text only | An SF Symbol in the tone's colour, the text, the ×, on a tinted rounded ground |
| Row heights, paddings | 24 / 28 / 52 pt | Unchanged: they already match macOS's sidebar sizes and InterfaceScale/footer tests pin them |

## Global Constraints

- Colours only from `Palette`, sizes only from `Metrics`, no `Palette.x.opacity(` in views (`DesignRulesTests`).
- Ported files edited here (`SidebarHeading`, `Surface`, `Badge`, `Metrics`) join `TokenParityTests.changed`; their `baseline` digests move to the new ones.
- Every VoiceOver label, value and action listed in `features.md` § VoiceOver stays.
- `git add` new files at once. Commands: `cd Shellforge && scripts/swift.sh test`; `tools/build.sh`; `tools/run_tests.expect ModernTests/<Class>`.

## Review Focus

1. A selected row in an inactive window: its title and badges must stay readable on grey (not white on grey). (Task 2, `anInactiveSelectionKeepsNormalInk`.)
2. A divider named in lower case: shown as typed, not uppercased. (Task 1, `aHeadingIsNotUppercased`.)
3. The footer's geometry (its tests pin heights and ink positions): unchanged by the card. (Task 4, existing `SidebarFooterGeometryTests` stay green.)
4. A banner's text stays selectable and the × still dismisses. (Task 5, existing `DismissErrorTests` and `bannerKeepsItsDismiss`.)
5. Light and dark: every new wash differs between them. (Tasks 4–5 tests.)

---

### Task 1: Sentence-case headers

**Files:** `Shellforge/Sources/ShellforgeDesign/SidebarHeading.swift`, `Metrics.swift` (`Typography.sectionHeader`), `Shellforge/Sources/ShellforgeUI/ShellforgeSidebar.swift:241` (“Other Tabs”), `Shellforge/Tests/ShellforgeDesignTests/SidebarHeadingTests.swift`, `TokenParityTests.swift`.

- [ ] **Step 1: Failing test** — add to `SidebarHeadingTests`:

```swift
    /// macOS 26 section headers are sentence case: the heading draws its title as given, so a lower-
    /// case divider name is not shouted.
    @MainActor @Test func aHeadingIsNotUppercased() {
        func width(_ title: String) -> CGFloat { NSHostingView(rootView: SidebarHeading(title)).fittingSize.width }
        #expect(width("Projects") < width("PROJECTS"))
    }
```

Run: `cd Shellforge && scripts/swift.sh test --filter SidebarHeadingTests` — expected FAIL (both widths equal: the heading uppercases).

- [ ] **Step 2: Implement** — in `Metrics.swift`'s `Typography`, add after `micro`:

```swift
    /// A sidebar section header (“Projects”): macOS 26's sidebar header, sentence case.
    public static let sectionHeader = TypeStyle(size: 11, weight: .semibold)
```

(Use the initialiser the other `Typography` members use.) In `SidebarHeading.swift`, the body becomes `Text(title).font(Typography.sectionHeader).foregroundStyle(Palette.muted)` — no `.kerning`, no `.textCase(.uppercase)`; delete `tracking` if nothing else uses it, and update the doc comment to “sentence case, as macOS 26's sidebar”. In `ShellforgeSidebar.swift`, `SidebarHeading("Other tabs")` → `SidebarHeading("Other Tabs")`.

- [ ] **Step 3: Parity** — run `scripts/swift.sh test --filter TokenParityTests`; add `"SidebarHeading"` and `"Metrics"` to `changed` and set their `baseline` digests to the printed ones.

- [ ] **Step 4: Run** `scripts/swift.sh test` — every run `✔`. Commit: `M12c task 1: sentence-case section headers — Projects, Other Tabs, System, Usage, and divider names as typed`.

### Task 2: The system selection, active and inactive

**Files:** `Surface.swift` (a `.inactiveSelection` case), `Shellforge/Sources/ShellforgeUI/Sidebar/SidebarRowParts.swift` (`RowPill`, `SelectableRow`), tests `SurfaceTests.swift`, `SidebarRowGeometryTests.swift`.

- [ ] **Step 1: Failing tests** — add to `SurfaceTests`:

```swift
    @MainActor @Test func anInactiveSelectionKeepsNormalInk() {
        #expect(ColorProbe.hex(Surface.inactiveSelection.ink, in: .aqua) == ColorProbe.hex(Palette.text, in: .aqua))
        #expect(ColorProbe.hex(Surface.inactiveSelection.ground ?? .clear, in: .aqua) == ColorProbe.hex(Palette.controlActive, in: .aqua))
    }
```

and to `SidebarRowGeometryTests` (or a new `RowPillTests` in ShellforgeUITests):

```swift
    @Test func aSelectedRowIsAccentWhileActiveAndGreyWhileNot() {
        #expect(RowPill.surface(selected: true, hovered: false, windowActive: true) == .accent)
        #expect(RowPill.surface(selected: true, hovered: false, windowActive: false) == .inactiveSelection)
        #expect(RowPill.surface(selected: false, hovered: true, windowActive: false) == .hover)
    }
```

Run them — expected build errors (`inactiveSelection`, `RowPill.surface(selected:hovered:windowActive:)` missing).

- [ ] **Step 2: Implement**
  - `Surface`: add `case inactiveSelection` — `ink`/`secondaryInk` as `.sidebar`'s (`Palette.text`/`Palette.muted`), `badgeWash`/`badgeWashHovered` as `.sidebar`'s, `isOnAccent == false`, its ground (`occludingBackground`) `Palette.controlActive`. Every `switch` over `Surface` gets the case (the compiler lists them). If `Surface` has no `ground` property, expose the selection ground the test reads as `occludingBackground` and adjust the test to it.
  - `RowPill`: `static func surface(selected:hovered:windowActive:) -> Surface` returns `.accent` when selected and active, `.inactiveSelection` when selected and not active, `.hover` when hovered, else `.sidebar`; the fill uses the surface's ground (`Palette.selection`, `Palette.controlActive`, `Palette.rowHover`, clear); the corner is `scale(Radius.group)`.
  - `SelectableRow`/`RowPill` read `@Environment(\.controlActiveState)`; `windowActive` is `controlActiveState == .key || controlActiveState == .active`.

- [ ] **Step 3: Parity, run, commit** — `Surface` joins `changed`; `scripts/swift.sh test` green (update `selectionAndHoverPaintTheSamePill` only if it compares radius, and ledger it). Commit: `M12c task 2: the system selection — accent while the window is active, unemphasized grey with normal ink while not; 8 pt corners`.

### Task 3: Capsule badges and chips

**Files:** `Badge.swift`, `Shellforge/Sources/ShellforgeUI/Sidebar/StatusCountChips.swift`, `BadgeTests.swift`.

- [ ] **Step 1: Failing test** — add to `BadgeTests`:

```swift
    @Test func aBadgeIsACapsule() {
        #expect(Badge.isCapsule)
    }
```

(A static flag the shape reads, so the test is direct and the drawing uses the same answer.) Run — build error.

- [ ] **Step 2: Implement** — in `Badge`, `static let isCapsule = true` and the wash and outline use `Capsule()` (keep the quiet style's negative horizontal padding); in `StatusCountChip`, `RoundedRectangle(cornerRadius: Radius.chip)` → `Capsule()` for fill and stroke. Badge joins `changed`.

- [ ] **Step 3: Run, commit** — `M12c task 3: capsule badges and status chips`.

### Task 4: The footer card

**Files:** `Palette.swift` (`footerCard`), `SidebarFooter.swift`, tests `AdaptivePaletteTests.swift`.

- [ ] **Step 1: Failing test** — add `"footerCard": Palette.footerCard` to `AdaptivePaletteTests.colors` and to `theColourDiffersInLightAndDark`'s arguments. Run — build error.

- [ ] **Step 2: Implement**
  - `Palette.footerCard = adaptive(light: NSColor(white: 0, alpha: 0.04), dark: NSColor(white: 1, alpha: 0.05))`, documented as the footer card's ground.
  - `SidebarFooter`: replace `.overlay(alignment: .top) { Hairline() }` with `.background { RoundedRectangle(cornerRadius: scale(Radius.group), style: .continuous).fill(Palette.footerCard).padding(.horizontal, scale(Space.base)).padding(.bottom, scale(Space.base)) }` — the card sits inside the footer's existing frame, so its geometry (and `SidebarFooterGeometryTests`) is unchanged.

- [ ] **Step 3: Run** `scripts/swift.sh test --filter 'SidebarFooter|AdaptivePalette'` then all. Commit: `M12c task 4: the footer on a rounded card`.

### Task 5: Inline notices

**Files:** `Palette.swift` (`noticeError`, `noticeWarning`, `noticeInfo`), `SidebarRows.swift` (`SidebarBanner`), test `Shellforge/Tests/ShellforgeUITests/SidebarBannerTests.swift`.

- [ ] **Step 1: Failing tests**

```swift
import SwiftUI
import Testing
@testable import ShellforgeDesign
@testable import ShellforgeUI

/// Banners are inline notices: a symbol in the tone's colour, the text, and for errors the ×.
@MainActor @Suite struct SidebarBannerTests {
    @Test func eachToneHasItsSymbol() {
        #expect(SidebarBanner.symbol(for: .error) == "xmark.octagon.fill")
        #expect(SidebarBanner.symbol(for: .warning) == "exclamationmark.triangle.fill")
        #expect(SidebarBanner.symbol(for: .info) == "info.circle.fill")
    }

    @Test func eachToneHasAGround() {
        #expect(SidebarBanner.ground(for: .error) == Palette.noticeError)
        #expect(SidebarBanner.ground(for: .warning) == Palette.noticeWarning)
        #expect(SidebarBanner.ground(for: .info) == Palette.noticeInfo)
    }

    @Test func bannerKeepsItsDismiss() {
        var dismissed = false
        let banner = SidebarBanner(text: "x", tone: .error, dismiss: { dismissed = true })
        banner.dismiss?()
        #expect(dismissed)
    }
}
```

Run — build errors.

- [ ] **Step 2: Implement**
  - `Palette`: `noticeError = destructive.opacity(0.12)`, `noticeWarning = amber.opacity(0.14)`, `noticeInfo = muted.opacity(0.10)` — written in `Palette.swift`, where derived washes may live.
  - `SidebarBanner`: `static func symbol(for:)` and `static func ground(for:)`; the body is `HStack(alignment: .firstTextBaseline, spacing: scale(Space.snug)) { Image(systemName: Self.symbol(for: tone)).font(Typography.help).foregroundStyle(symbolInk); Text…(unchanged); × (unchanged) }` with `.padding(.horizontal, scale(Space.base)).padding(.vertical, scale(Space.snug))` inside `.background(RoundedRectangle(cornerRadius: scale(Radius.group), style: .continuous).fill(Self.ground(for: tone)))`, the whole notice then padded by the old outer insets so it lines up with the rows. `symbolInk`: error `Palette.destructive`, warning `Palette.amber`, info `Palette.muted`.

- [ ] **Step 3: Run, commit** — `M12c task 5: banners as inline notices — a symbol, the text, the ×, on a tinted ground`.

### Task 6: Look, every test, docs

- [ ] Render `ModernTests/ShellforgeSnapshotTest` (`TEST_RUNNER_SHELLFORGE_SNAPSHOT_DIR=…`), look at light and dark; fix what the table above does not show.
- [ ] `tools/build.sh`; `scripts/swift.sh test`; `tools/run_tests.expect ModernTests` (only `TriggerTimeoutDescriptionTests` may fail).
- [ ] `features.md`: PROJECTS → Projects, SYSTEM → System, USAGE → Usage (lines 25, 152, 158); a line under The sidebar: “Rows use the system's selection: the accent while the window is active, grey while it is not.” Commit: `M12c docs`.
