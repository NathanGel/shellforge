# Shellforge design system

> Ported from AiTerm's `app/Sources/AiTermUI/README.md` (GPLv3, Laurens D'Hondt). Shellforge keeps
> AiTerm's design system unchanged: the values, the rules and the components are AiTerm's.
>
> **Ported so far:** Palette, Metrics, Surface, InterfaceScale, Logos, IconSource, Badge, Hairline,
> SidebarHeading, SymbolMark, FormField, HelpText, ControlChrome, Input, SearchField,
> SegmentedControl, Select and Kbd. `FrontToBackStack` needs macOS 15 and is not ported. The view
> patterns arrive with the screens that use them; until then this file describes them as AiTerm has
> them. For macOS 13, `Input` removes its undo observers in a plain `deinit`, and `SegmentedControl`
> turns off SwiftUI's focus effect only where it exists (macOS 14 and later).

The design system, in code. This file and the Swift beside it are the source of truth — there is no
generated token file, no canvas and no build step. The page
`docs/design/design-system.html` is a human view of this, synced on request; when the two
disagree, **this wins**.

**Module boundary:** `ShellforgeDesign` depends on nothing else in this package — not `ShellforgeCore`, not
`ShellforgeUI`. It must not import either. `ShellforgeUI` depends on both `ShellforgeCore` and `ShellforgeDesign`; the
dependency only ever points that direction. `DesignRulesTests` reads the source for this, and for
both rules below: an import of either in `ShellforgeDesign` fails the build, and so does — in `ShellforgeDesign`
and the app alike, bar the app's snapshot renderer (`Snapshots/`) — a literal colour outside
`Palette.swift`, a `Palette` member's `.opacity(…)`, a system text size outside `Metrics.swift`,
or a padding, spacing, corner radius, offset or frame written as a number (zero aside). Its short
list of exceptions each carries its reason.

## The two rules

1. **Every colour comes from `Palette.swift`.** Never a literal, never a `Color(red:…)`, never
   `.white` or `.black`: ink on the accent is `Palette.onAccent` (or the surface's own `ink`), and a
   vendor mark's white and black are `markPaper` and `markInk`. GitHub's mark is `Palette.github`,
   white for the dark ground, and tinted `markInk` on the white `markPaper` disc of its Integrations
   mark. `Palette.swift` is the one file that writes a literal colour — bar a shadow's black, below.

   That includes a colour derived from another: a wash, a dimmed ink, a pressed state. A view never
   writes `Palette.x.opacity(…)`; the derived colour is a named `Palette` member (`accentPressed`,
   `faint`, `keycapFill`), used by one component or by ten. Named, it is in
   `PaletteDistinctionTests`' manifest, so a wash that happens to resolve to the ground it is
   painted on fails the build instead of drawing a halo. `Brand.wash` is the one derivation off a
   token, because it is one rule for every vendor.
2. **Every height, radius, spacing and text size comes from `Metrics.swift`** — `Space`, `Radius`,
   `Size`, `Typography`, `Sheet`.

Where macOS publishes a scale, `Metrics` uses that number: the system text styles for `Typography`,
AppKit's control sizes for `Size`, AppKit's corner radii for `Radius` (4 small, 6 regular, 8 large,
10 for anything that floats). `Space` is the one house scale — a 4-point rhythm with three named
steps off it (`hairline`, `snug`, `inset`) for the places — chip interiors, control tracks, field
interiors — where the rhythm's own steps are the wrong size.

If no existing member fits, you may add one — with a doc comment saying what it is for, and **say so
in your summary**. Do not add one silently, and do not pick a number because it looked right beside
its neighbour.

One-off geometry may stay in its component: a number only that view measures by — a column fitted
to its content (`NewTaskSheet.ticketKeyWidth`), a glyph's optical size inside its tile
(`ProviderIcon.glyphSize`) — can be a `private static let` there, with a doc comment saying what it
measures and why no token fits. It is not a token and nothing else reads it; the moment a second
file needs the same number for the same reason, it moves into `Metrics` (as `Size.pickerLogo` did).

Kerning and shadows (a black at its own blur radius, offset and opacity) are deliberately not
tokenised — they are one-off optical corrections on a single element, not a scale anything else draws
from. Their absence from `Metrics` and `Palette` is a decision, not an oversight.

`Palette` has a third rule enforced by a test: every distinctly-written token resolves to a distinct
colour. Where two roles share a value, declare it as an alias in the source (`sidebar = surface`) —
the test reads the aliases from there, so that declaration is all it takes.
`PaletteDistinctionTests` fails the build otherwise — it exists because a hover wash once resolved
to the surface it was painted over and drew a visible halo around every hovered avatar.

`Metrics` has no equivalent rule, on purpose. Two `Palette` tokens resolving alike is a rendering
hazard — a wash disappearing into the surface behind it, as above. Two `Size` (or `Space`, `Radius`)
members sharing a number is normal: `Size.chip` and `Size.vendorMark` are both 16 today, and that is
fine — the names exist so one can grow without the other, not because 16 must never repeat.

## Scale

Every number in `Metrics` is a size at ×1. It becomes points where a view reads it, at the
environment's `InterfaceScale` (`standard` ×1, `large` ×1.15, `extraLarge` ×1.3):

- `Typography` scales by itself — `View.font(TypeStyle)` reads the environment. Unrounded, so text
  never outgrows the layout around it.
- `Space`, `Radius`, `Size`: read them through `scale(…)` — `@Environment(\.interfaceScale)
  private var scale`, then `.padding(scale(Space.base))`. Whole points; ×1 is the identity.
- A `size:` parameter is points on screen: the caller scales the token it passes, and the view
  never scales its own parameters. A view's *own* token reads it scales itself.
- Strokes do not scale: hairlines, borders, outline rings, the focus ring. (A drawn ring whose
  stroke is a fraction of its diameter — `StatusMark`, `UsageRing` — is a mark, not a stroke, and
  scales with the size it is given.)

Only the sidebar is scaled; `SidebarSheet` resets to `.standard`. AppKit's pop-up and push-button
bezels stop at 28 pt (`.extraLarge` draws `.large` on macOS 26), so a sheet — full of them — keeps
Apple's sizes. Of the primitives, `Badge` scales, `SidebarHeading` and `HelpText` (under the empty
sidebar's line) scale through their one token (a `Typography` style) and `Hairline` is a stroke; the
rest are only drawn in sheets and read their tokens at ×1. A primitive that moves into the sidebar must first read its tokens through `scale`.
`Select` can never scale: it is a native bezel.

The person picks the step as `InterfaceSize` (`ShellforgeCore`, Settings › Interface › Sidebar size,
or View › Zoom In / Zoom Out / Actual Size); the app maps it onto `InterfaceScale`.

## Two tiers

**Primitives** live here, in `Sources/ShellforgeDesign/`. They take standard names and **no Shellforge type
appears in their signature**. A primitive that knows what a task is has stopped being a primitive.

**Patterns** live in `Sources/ShellforgeUI/`. They keep Shellforge names, carry Shellforge concepts, and
are composed only from primitives.

## Reuse before new

Stop at the first rung that fits:

1. **A new variant or content case on an existing primitive.** `Badge` absorbed three bespoke types
   this way.
2. **A pattern** — existing primitives arranged. Shellforge name, `Views/`, not here.
3. **A genuinely new primitive.** It owes: a standard name, every measurement from `Metrics`, every
   colour from `Palette`, a declared variant × state matrix, a line in the inventory below, and a
   test under `app/Tests/ShellforgeDesignTests/` — the one surviving design guard in this repo *is* a test.

   If the primitive is a `public struct`, also add a `public init`. Swift's memberwise init on a
   `public` type is only `internal`, so without one nothing outside `ShellforgeDesign` can construct it.
   Every promotion on this branch needed one.

Promote a pattern to a primitive only when it is used in two or more files *and* carries no Shellforge
type *and* it is not app-shell composition — a sheet's own anatomy, a window's chrome — which stays
in `Views/` regardless of reuse, because it encodes this app's layout decisions rather than a
reusable part. `SheetLayout` (nav above content above actions, plus `isSnapshot`, an affordance that
exists solely for Shellforge's snapshot harness) and `SheetFooter` (where *this app* puts a sheet's secondary
and primary actions, and what ⎋ means) both clear the first two conditions and stay patterns on this one.

## Surface, not a `selected` flag

A component reads the ground it sits on from the environment — `@Environment(\.surface)`, set with
`.surface(_:)` — instead of taking `selected: Bool`. `Surface.sidebar`, `.hover`, `.accent`,
`.sheet` each publish their own `ink`, `secondaryInk`, `badgeWash`, `badgeWashHovered` and
`occludingBackground`, so a badge inside a newly selected row turns white by itself rather than
every call site re-deriving the same colours.

The container that draws the ground declares it, and only it knows whether it is on: `RowPill`
for a sidebar row, `menuRowHighlight` for a dropdown's — so `PickerResultRow` and the completion
popup's rows are handed no flag — and `SegmentedControl` for a segment, whose label it inks itself.

`Surface` is not a component and gets no card — it is a rule the components assume.

## Light and dark

Shellforge follows its window's appearance, light or dark. Most colours are macOS's semantic ones and adapt by themselves; the few that cannot (`rowHover`, `rowHoverSolid`, `badgeHovered`, `codeBackground`) have a value for each appearance through `Palette.adaptive(light:dark:)`. `Icon` resolves a tint in the appearance it draws in. A test that needs a fixed appearance names it (`ColorProbe.hex(_:in:)`).

## States are a matrix

Default, hover, pressed, disabled, focused, selected. Declare them up front rather than discovering
them. When a target does not exist, the control is **absent, not disabled**. Reduce Motion is
honoured: `StatusMark` keeps its arc and drops the rotation.

## Inventory

Every name here is a type under `app/Sources/`. Nothing aspirational.

### Primitives — `Sources/ShellforgeDesign/`

| Type | What it is |
|---|---|
| `Badge` | the one chip: a Jira key, an editor mark (extended with a `+12 −3` `diff`), a `+n` count, a Settings check (with `iconTint`); `style: .quiet` drops the box at rest, for the sidebar rows; `action` makes it a button, `menu` a menu — a project header's `+n` of Jira projects — the same chip with the same hover, and `accessibilityLabel` says what a bare count cannot |
| `Icon` | every mark, at a size: an SF Symbol (its glyph's own width, in the surface's ink unless tinted), a vendor `Brand` (a `size` square, in its colour unless tinted), or a full-colour artwork that carries its own fallback (`.gitlabTanuki`, `.piBadge`). The one way the app draws a logo — no fill travels as a hex string |
| `FormField` | a label above its control; what the control hangs out of itself — a dropdown's results — draws over the lines after it |
| `FrontToBackStack` | a `VStack` whose earlier children draw over its later ones, so an overhang (a picker's results, the completion popup) needs no `zIndex` at any level of a sheet. `FormField` is one; a sheet's fields and steps go in another |
| `HelpText` | subordinate caption copy under a control, in a `tone`: `.secondary` (the default) or `.warning` — it inks itself, so colour it by tone, never by an outer `foregroundStyle` |
| `Input` | a real `NSTextField` in the house field chrome, with its focus ring; `secure: true` (an `NSSecureTextField`) for a token; `caretAtEnd: true` puts the insertion point after a value filled in as if typed, where AppKit would select it all on focus (the Backpack sheet's saved password). AppKit sizes it: SwiftUI's `TextField` read its height from a cache that could hand it another font's |
| `Select` | a real `NSPopUpButton` that fills its column |
| `SegmentedControl` | a hand-built segmented control that can carry a logo. `style: .neutral` (a grey selection and the focus ring) or `.accent` (an accent selection on `.surface(.accent)`, no ring — the Settings tab bar); a segment `isSelectable` rejects is dimmed and disabled. It inks each label for its ground — the selection in the surface's ink, the rest in its secondary ink — so a label is plain `Text` |
| `Kbd` | keycaps for a shortcut, inked for the surface it sits on: on `.accent` — `SheetPrimaryButton`'s label declares it — white on the keycap washes; anywhere else the surface's ink on its badge wash, edged in the hairline (Settings › Interface's keyboard section). It takes no style: the ground decides |
| `SearchField` | a single-line field that hands navigation keys to an open popup first |
| `SidebarHeading` | `PROJECTS` and a divider's name: micro, uppercase, tracked, secondary ink |
| `SymbolMark` | a round mark for what is not a vendor: an SF Symbol at half the disc's size, in one of two styles — `.quiet` (the default) in `Palette.text` on a `Palette.controlActive` disc, `IntegrationMark`'s family, with `tint` for a muted glyph; `.paper` in `Palette.markInk` on a `Palette.markPaper` disc, the vendor discs' recipe, so a mark beside Claude's and Codex's reads as one of them. `size` is points on screen — the Mac card passes `Size.control`, the footer's Mac readings row `scale(Size.vendorMark)` |
| `Hairline` | every 1 pt rule, in one weight: `border` on a filled rectangle, the same stroke as a control's outline — the sidebar's rules, the step bar, a sheet's header and footer edges, under a card's header, between the Interface tab's rows. Never a bare `Divider()` |

### Foundations — not components, no card

`Palette`, `Metrics` (`Space`/`Radius`/`Size`/`Typography`/`Sheet`/`TypeStyle`), `Brand`, `Surface`,
`InterfaceScale`, `IconSource`, and the view modifiers in `ControlChrome.swift`: `focusRing`,
`fieldChrome` (a single-line field: padding, height and `fieldBox`), `fieldBox` (the field's fill,
hairline and focus ring alone, for the prompt editor), `menuChrome` (the panel a dropdown hangs in), `menuRowHighlight` (a dropdown row on
the accent, declaring `.surface(.accent)`) and `groupChrome` (a `SettingsGroup`'s or a segmented
track's box).
`Logos` (the bundled SVG data and its image cache) and `LogoGlyph` are internal to this module.
`TypeStyle` is the type `Typography`'s members are declared as and the `View.font(_:)` overload
takes; `Brand` is what `Icon(.brand(…))` and `Badge(icon: .brand(…))` consume. An agent adding a text size or a
vendor needs both.

### Patterns — `Sources/ShellforgeUI/`

`SheetLayout`, `SheetSubtitle`, `SheetFooter`, `SheetPrimaryButton`, `DestinationLine`, `CreationSheet`, `CreationFooter`,
`AgentSegmented`, `CommandBlock`, `StatusMark`, `StatusCountChips`, `AvatarGroupView`, `VendorMark`,
`BranchLabelView`, `StepBar`, `ToastView`, `ProviderIcon`, `CompletionPopup`,
`NativeRowHighlight`, `RowMenuAnchor`, `SidebarFooter`, `UsageRing`, `ToneDot` (with `SettingsTone`), `MacMode` (with `MacModeLine` and
`MacModePresentation`, in `MacModeRow.swift`), `BackpackSheet`, `SearchPicker`, `DropdownList`, `DropdownKeys`,
`PickerResultRow`,
`PickedItemField`, `LaneChip`, `AgentStep`, `PromptStep`, `CompletionHint`,
`PromptEditor`, `SidebarView`, `SidebarScrollFollower`, `SidebarBanners`, `SidebarBanner`, `SidebarToast`,
`SidebarSheetPresenter`, `SidebarSheet`, `SidebarHeader`, `SidebarEmptyState`,
`ProjectHeaderRow`, `SelectableRow`, `RowPill`, `RowTitle`, `RowCaption`, `TaskRowView`, `TerminalRowView`, `DividerRow`,
`JiraProjectSheet`, `SettingsView`, `SettingsCard`, `ServiceCard`, `ItermSettingsCard`, `SettingsGroup`,
`SettingsSwitch`, `SettingsSection`, `NumberedSteps`, `MacSettingsCard`, `IntegrationMark`, `HarnessSettingsPane`,
`InterfaceSettingsPane`, `KeyboardSettingsPane`, `NameSheet`, `NewTaskSheet`, `NewReviewSheet`.

**Backpack Mode.** The sidebar's foot (`SidebarFooter`) is two groups under a `Hairline`, on the
list's grid: SYSTEM, then USAGE. SYSTEM is the selected task's or terminal's `ctx` row (its active
tab's mark, the `UsageRing` and the percentage, then that tab's spend, `in 936k · out 5.6k`, from
`TokenTally.short`: labels muted, numbers in `Palette.text`, no ring and never amber, its subagents and
background workers included; a shell draws its mark alone), then the Mac's rows,
always there (proposal 1A · 2A · 3A, 6 Oct 2026). The first is its readings, under a `SymbolMark` in
`.paper` style at `Size.vendorMark` with `macbook`: `cpu ◔ 23% · ram ◔ 61%`, and `bat ◔ 64%` while the
Mac runs on its battery, drawn by the same renderer as `ctx` and the vendor windows. `MachineMonitor`
samples them every 5 s through a `MachineSensor` — Mach host statistics, `thermalState` and the
memory-pressure sysctl, in-process — and `MachineReadings` turns two samples and the battery into
`UsageLine`s. A reading turns amber only on macOS's own warning: the CPU when the Mac throttles for
heat, memory under pressure, the battery within five points of Backpack Mode's cutoff. While the mode
is on or switching, a second row follows: a `ToneDot` at `Size.statusMarkSmall`, centred in the marks'
column, then the words in its `SettingsTone` — `backpack turning on…` and `backpack turning off…` idle,
`backpack enabled` ready, `backpack needs you` attention. That is the one colour in the footer that is
not ink or amber, and a Settings card's voice: the task list keeps `StatusMark` to itself. At the desk
there is no such row. A click on either Mac row opens the sheet at the desk and turns the mode off in
the backpack; a right-click offers Mac Settings…; ⌘B does what the click does. The words, tooltip and
VoiceOver sentence come from `MacModePresentation.line`, decided by `MacMode` apart from the view.

Turning on is `BackpackSheet`, one `SheetLayout` with a `SheetSubtitle`, laid out in the order it
is used. While a permission is missing, “This Mac” leads with `NumberedSteps` and an Allow… button.
Then Hotspot, a `Select` of the networks one scan finds now — the remembered hotspot first and chosen
once it shows up, scanned again every 5 s while no connect runs — beside a secure `Input` for the
password, filled with the saved one as if typed (`caretAtEnd`) for the remembered hotspot and empty
for any other; a `HelpText` under them, led by a `.working` `StatusMark` (“Looking for hotspots…”)
while nothing is chosen. “On the iPhone” follows as their help: three `NumberedSteps`, `receded`
(text in `Palette.muted`) once a hotspot is chosen, full again while a connect waits for it.
Connect (⌘↩) is disabled until both permissions are granted and a hotspot is chosen; it runs in
place, the fields disabled, Cancel the only action, and two live checks appear under the steps — a
`StatusMark` in a `Size.slot` column beside a `Typography.caption` line, amber on the one that
failed. A failure leaves the fields live and Connect retries; there is no Back. Once the Mac has
joined and is held awake the body becomes a `Size.control` accent disc with a checkmark, “Safe to
close the lid.”, the checks, and Done on ⌘↩; the mode stays on. Closing the lid dismisses the sheet.
Its words are `BackpackSheetPresentation`'s, its state `BackpackSheetModel`'s. The Backpack toasts
wear `BackpackController.symbol`, `iphone`.

**A sheet's anatomy.** The band under a sheet's title holds a `StepBar` (New Task, New Review), a
tab bar (Settings), or — on every other sheet — one `SheetSubtitle`: a sentence saying what the
sheet does, never a path. Every sheet that opens a window ends its content with one
`DestinationLine`, in one format: `Opens in iTerm2 · <project>/<worktree path in it> · <branch>` —
the project alone for New terminal, `task “<title>”` in place of the path for a review that opens in
the task that has its branch. New Task and New Review draw it on steps 1 and 3 (`Destination`),
New terminal under its field; nothing else writes where a window opens.

`CreationSheet` is the frame New Task and New Review share — step bar, command preview, destination
line, footer and its keys, the loads on appear — generic over the sheet's `CreationKind`; each
sheet hands it values and keeps its own first step. A failed create shows its error as a sentence in
the footer — git's failure lines through `GitError.sentence`, as the banner has them — with git's
whole output in the tooltip (`CreationFailure`).

`NameSheet` is every sheet whose one question is a name: New terminal (`NameSheet.newTerminal`), Add divider, and Rename for a
task or review, a terminal (from its row's context menu or VoiceOver actions: "Rename terminal",
"Terminal name") and a divider — each rename's title, field and sentence from `RenameTarget`. A
terminal's name is its row's; its iTerm2 tabs keep their branch titles. `JiraProjectSheet` is
reached only from a project's context menu: Add Project… has no sheet, the folder chooser adds the
project at once, and a folder inside a repository adds that repository with a toast saying so.

A project header wears **one** quiet Jira `Badge` beside its name, however many Jira projects it
links (proposal E2, 8 Oct 2026): the first linked project's key, which opens that project, and —
when it links more — `Space.snug` after it a boxed `+n` `Badge`, as `BranchLabelView` counts a
window's other branches. The `+n` opens a menu of every project, the first included — `KEY — Name`
in the order they were linked, each opening its own — then "Jira Projects…", greyed while the
workspace is locked (Shellforge has no lock yet, so it is always enabled). The `+n` stays when
Settings › Interface turns the project key off, since it is not a key (Shellforge has no Interface
tab yet; the key always shows); its tooltip names every project and VoiceOver the rest ("2 more Jira projects: PAY and
WEB"). `ProjectJiraBadge` decides all of it, tested without rendering; `ProjectJiraBadgeView` draws
it. One mark per row, so linking projects takes little of the name's room.

**Alerts** are `NSAlert`s, described by an `AlertPrompt`: one default button, on ↩, blue — or red
(`defaultDeletes`, `hasDestructiveAction`) when it deletes files or commits — and every other
button the plain grey one, a destructive button that is not the default included. ⎋ answers the
safe choice (`escapeButton`). The table is in `docs/keyboard.md`. `PickerResultRow`, `PickedItemField` and `LaneChip` (a result row, the
pick drawn in the field's place, a lane on its service's wash) carry no Shellforge type and are drawn
from three sheets, but promotion's conditions are necessary, not a mandate: their one consumer is
`SearchPicker`, itself a pattern, so they stay beside it as patterns too.

`SelectableRow` is a task's or terminal's row — its indent, the click that activates it — and owns
its row's hover, so the pointer redraws one row. `RowPill` is the one pill every selectable sidebar
row is drawn in, a project header's included: the selection fill on `Surface.accent`, else the hover
wash. It declares the row's `Surface`, and `RowTitle` and `RowCaption` — a row's title, and a line
under it — read that rather than a `selected` flag, as a header's chevron, name, provider glyph and
"+" do; `RowCaption(warns:)` is amber off the accent only. Which row is selected — a project header,
a task or a terminal; never a divider — is `RowFocus`'s (`controller.focus`), an owner beside the
controller, not a view. A row reads whether it alone is selected (`focus.isSelected(id)`), as a task
row reads its own removal (`controller.removal(of:)`) and missing checkout
(`checkouts.isMissing(_:)`): each a `PerRow` cell, so an arrow key redraws the row it leaves and the
row it reaches, and a removal its own row, and no other — `SidebarRowRedrawTests` counts them. Only
`SidebarScrollFollower` — not `SidebarView`'s body — follows the selection whole, so the list's
model is not redrawn either.

`CompletionHint` is the line `PromptStep` draws under the prompt editor, saying what `/` opens —
the one trigger for every agent; a Codex skill picked there is written as its `$` mention.
`SheetFooter` is the foot of every sheet — Cancel (or Back), a `SheetPrimaryButton` and optional
status text — and owns what ⎋ means: an open list closes first (`closeList`), and only then is it
Cancel, on a hidden button of its own so that *clicking* Cancel still cancels. An action a sheet does
not offer at that moment is passed as nil and is absent, key and all: the Backpack sheet has Cancel
alone while it connects and Done alone once it is safe, where ⎋ does nothing. `SheetPrimaryButton`
is a sheet's prominent action; it answers ⌘↩ only, the keycaps it shows. No sheet restates either.

`DropdownList` is the panel every dropdown hangs in — `menuChrome`, `Size.menuRow` rows, the accent
behind the highlighted one (the keyboard's or the pointer's), dimmed while pressed — and
`DropdownKeys` its key contract (arrows wrap, ↩ accepts, ⎋ closes only the popup, everything else is
the field's). `SearchPicker`'s results and `PromptEditor`'s completion popup are both drawn and
keyed through them.

`SettingsView` has three tabs — Agents, Integrations, Interface — picked from the tab bar or
with ⌘1–⌘3, and none opens with an intro line. It opens on Integrations while iTerm2 is not connected or a
saved service's last test failed (`ServiceTestRecord`), and on Agents otherwise; that is decided
once, as the sheet opens, and a test answering afterwards never switches the tab.

`SettingsCard` is one row of a Settings section, drawn in the section's box with none of its own — a harness on Agents; iTerm2
(`ItermSettingsCard`), the Mac (`MacSettingsCard`), then Jira, GitLab and GitHub (`ServiceCard`) on Integrations: a `Size.control` mark,
a title with optional check chips, a status line in one of three tones (`SettingsTone`: ready, attention, idle, led by its `ToneDot` — the dot the footer's backpack line draws too)
and with no full stop (`SettingsStatus` drops the one an error's own sentence ends with),
trailing actions at `.controlSize(.large)`, fields under the header. Cards carry no Test button:
Settings tests every card when it opens (and a service again once its fields stop changing), and
the answer replaces that card's status line rather than landing in the sheet footer. A harness
card's one action is named by the card's state and runs the same code whatever it says: Install
while the CLI or the driver is missing, Repair while a check is amber, Reinstall when the card is
Ready; a card whose only amber check is one Install cannot fix (Grok's Context, when its status line
is the built-in or one Shellforge must not edit) shows no action at all. Over a missing CLI it runs the
vendor's own installer and then the driver; over a present one it writes the driver whether or not
it is already installed, so it can be overwritten. A Jira, GitLab or GitHub card holding saved
credentials trails a Disconnect, which empties its fields and marks the service for removal: Save
removes the saved site or host and the Keychain token, Cancel keeps everything. Save is all or
nothing: it checks every card before it writes any, so while one card cannot save (a mistyped URL)
nothing is written at all — a Disconnect or a new connection on another card is not applied either —
and the sheet stays open saying why. A write the Keychain refuses puts back the ones this Save made
before it, and the footer names any service the Keychain would not let it put back. The iTerm2 card
has no fields: below its divider it lists the numbered steps that mend the first broken link to
iTerm2, or one line of `HelpText` when nothing is broken. Its status line is
`ItermConnection.status`, and the banner above the sidebar opens with the same words — grey, or
amber while iTerm2 refuses the connection. It stays a pattern: Settings is its only user and its
layout is this app's.

Integrations sets its rows in two `SettingsSection`s, Core (the Mac, Environment, the terminal match)
and Services (Jira, GitLab, GitHub), as macOS's grouped form draws a section: a heading in
`Typography.bodyEmphasis` lined up with the rows' marks, then one box of `Palette.groupFill` (a veil
measured against the native grouped form's: darker in light, lighter in dark), its rows divided by a
`SettingsRowDivider` inset past the marks. The terminal match is a row whose action is a
`SettingsSwitch`.
`MacSettingsCard` is a harness card's anatomy for the Mac: `macbook` in a `.paper` `SymbolMark`, the
chips “Lid sleep” and “Network discovery”, one action named by its state — Allow… while something is
missing, Remove once both are granted — and, under its header, `NumberedSteps` for what is missing or one
line of `HelpText` when nothing is. A missing permission does not move the tab Settings opens on.
`NumberedSteps` is also the iTerm2 card's mending steps and the Backpack sheet's phone steps.

`SettingsGroup(title:help:rows:)` is a group that connects and tests nothing — Sidebar size,
Sidebar badges, each keyboard group: a box of its own (`groupChrome`) and a rule, without a row's
mark, status line or actions. A heading over one line of `HelpText`, a `Hairline`, then the rows, one heading gap
(`Space.gap`) either side of the rule and between rows; rows split themselves with a `Hairline`.
The terminal-background row is not one: it has no heading of its own, only a swatch, a title and
a switch, in the same `groupChrome` box.

`InterfaceSettingsPane` draws its preferences outside cards: the terminal-background row, a
"Sidebar size" group (a `SegmentedControl` of `InterfaceSize`, applied to the sidebar behind the
sheet as it is picked and put back by Cancel, where the rest of the tab waits for Save), and a "Sidebar badges" group whose rows preview the real `Badge` beside a switch that drops
that badge's detail (`BadgeDetails`) and keeps its mark, click and tooltip. A section's step
(`Space.section`) below them comes `KeyboardSettingsPane`.

`KeyboardSettingsPane` is that tab's "Keyboard shortcuts" section, not a tab of its own: a heading
over one line of help, "Shortcuts can’t be changed yet.", then every key read-only, one
`SettingsGroup` per `KeyBindingGroup`, rows with the action in body text and its keys in `Kbd`. The
groups run from the widest reach to the narrowest — macOS's ⌘⇥, anywhere in Shellforge, the sidebar,
sheets, lists and the prompt — and the table (`KeyBindings.all`) is written by hand, so a key added
to the app goes there too; `KeyboardSettingsTests` fails if the menu bar's keys and the list
disagree.

`SidebarEmptyState` is what sits under `PROJECTS` while there are none: a `Typography.body` line,
a `HelpText` line, and an "Add Project…" push button that runs the header's own action. Its text
starts where the heading's does, and its spacing reads `scale`; the button is an AppKit bezel, so
it steps from `.regular` at ×1 to `.large` above it rather than scaling.

`UsageRing` is the ladder's first rung working as intended: a progress ring carries no Shellforge type
and would make a fine primitive, but only the footer draws one, so it stays a pattern until a second
file needs it. It is drawn to `StatusMark`'s recipe — same diameter, same `size * 0.15` stroke, same
round cap — so the sidebar's two round marks read as one family.

Every window in the footer — its label, ring, number and reset — has one tooltip and one VoiceOver
label in words (`UsageLine.help`): “Weekly limit, 61 % used, resets Friday 23:33”, “Context 84 %
full”, “CPU 87 % busy, slowed by heat”. A vendor's or the context's reading turns amber at 80 % or
more; the Mac's, on macOS's warnings above.
The token counts are one element with one sentence (`TokenTally.help`): “Input 936,018 tokens, 99 % from
cache · output 5,625 tokens · subagents included”.

## The artifact

One HTML page, `docs/design/design-system.html`, for humans. It is synced from this code on
request by the `design-system` skill. It is not a gate and not a source of truth — you never need it to write
correct Swift.

It has three tabs. **Foundations** and **Components** describe what ships and are transcribed from
the Swift. **Proposals** holds what does not ship yet: a visual change drawn at real size from the
current tokens, its options side by side with a recommendation, so it can be chosen before any
Swift is written. A proposal obeys the same two rules as the code — every colour and number it
draws comes from `Palette` and `Metrics`, or it says which new member it would add.

When a proposal is implemented, the Swift changes first, then its entry is deleted from the
Proposals tab and the other two tabs are synced to the code. **The tab stays**, empty or not; with
nothing on it, it keeps only its "How this tab works" intro. A proposal on the page is never a
reason to write Swift on its own — only a pick is.

The three-artifact design canvas this replaced was retired on 2026-09-21. Doc comments across this
package that still say "design canvas" are historical provenance for a decision (what a value is,
or why it was chosen) — not a pointer to a document you can open. Leave them; do not chase them down
to delete unless one names a specific file or approval a reader might actually try to open.
