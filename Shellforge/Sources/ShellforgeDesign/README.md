# Shellforge design system

> Ported from AiTerm's `app/Sources/AiTermUI/README.md` (GPLv3, Laurens D'Hondt). Shellforge keeps
> AiTerm's design system: the values, the rules and the components are AiTerm's.
> `TokenParityTests` holds every ported file to a reviewed baseline and, where an AiTerm checkout
> is at hand, to AiTerm's own; the files changed on purpose are ledgered there.
>
> **Ported:** Palette, Metrics, Surface, InterfaceScale, Logos, IconSource, Badge, Hairline,
> SidebarHeading, SymbolMark, FormField, HelpText, ControlChrome, Input, SearchField,
> SegmentedControl, Select and Kbd. `FrontToBackStack` needs macOS 15 and is not ported. For
> macOS 13, `Input` removes its undo observers in a plain `deinit`, and `SegmentedControl` turns
> off SwiftUI's focus effect only where it exists (macOS 14 and later).
>
> **Shellforge's own:** `ShellforgeMaterial` (the sidebar's glass on macOS 26, the system sidebar
> material before it, opaque under Reduce Transparency) and `TerminalPalette` (the colours Match the
> terminal to Shellforge gives every terminal).

The design system, in code. This file and the Swift beside it are the source of truth — there is no
generated token file, no canvas and no build step.

**Module boundary:** `ShellforgeDesign` depends on nothing else in this package — not `ShellforgeCore`, not
`ShellforgeUI`. It must not import either. `ShellforgeUI` depends on both `ShellforgeCore` and `ShellforgeDesign`; the
dependency only ever points that direction. `DesignRulesTests` reads the source for this, and for
both rules below: an import of either in `ShellforgeDesign` fails the build, and so does — in
`ShellforgeDesign` and `ShellforgeUI` alike — a literal colour outside
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

Only the sidebar is scaled; its sheets, in panels of their own, stay at `.standard`. AppKit's pop-up and push-button
bezels stop at 28 pt (`.extraLarge` draws `.large` on macOS 26), so a sheet — full of them — keeps
Apple's sizes. Of the primitives, `Badge` scales, `SidebarHeading` and `HelpText` (under the empty
sidebar's line) scale through their one token (a `Typography` style) and `Hairline` is a stroke; the
rest are only drawn in sheets and read their tokens at ×1. A primitive that moves into the sidebar must first read its tokens through `scale`.
`Select` can never scale: it is a native bezel.

The person picks the step with ⌘+ / ⌘− / ⌘0 after a click in the sidebar (`SidebarZoom`), one size
for every window, kept by `SidebarLayoutSettings.scale`.

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
   test under `Tests/ShellforgeDesignTests/` — the one surviving design guard in this repo *is* a test.

   If the primitive is a `public struct`, also add a `public init`. Swift's memberwise init on a
   `public` type is only `internal`, so without one nothing outside `ShellforgeDesign` can construct it.
   Every promotion on this branch needed one.

Promote a pattern to a primitive only when it is used in two or more files *and* carries no Shellforge
type *and* it is not app-shell composition — a sheet's own anatomy, a window's chrome — which stays
in `Views/` regardless of reuse, because it encodes this app's layout decisions rather than a
reusable part. `SheetLayout` (nav above content above actions) and `SheetFooter` (where *this app* puts a sheet's secondary
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

Shellforge follows its window's appearance, light or dark. Most colours are macOS's semantic ones and adapt by themselves; the few that cannot (`rowHover`, `rowHoverSolid`, `badgeHovered`, `codeBackground`) have a value for each appearance through `Palette.adaptive(light:dark:)`. `Icon` resolves a tint in the appearance it draws in. A test that needs a fixed appearance names it (`ColorProbe.hex(_:in:)`). Under any theme but Shellforge, each token resolves to the active theme's colour instead (`ThemeRuntime`), derived in `Palette.swift` by family; a view redraws in a new theme under `.themed()`.

## States are a matrix

Default, hover, pressed, disabled, focused, selected. Declare them up front rather than discovering
them. When a target does not exist, the control is **absent, not disabled**. Reduce Motion is
honoured: `StatusMark` keeps its arc and drops the rotation.

## Inventory

Every name here is a type under `Sources/`. Nothing aspirational.

### Primitives — `Sources/ShellforgeDesign/`

| Type | What it is |
|---|---|
| `Badge` | the one chip: a Jira key, an editor mark (extended with a `+12 −3` `diff`), a `+n` count, a Settings check (with `iconTint`); `style: .quiet` drops the box at rest, for the sidebar rows; `action` makes it a button, `menu` a menu — a project header's `+n` of Jira projects — the same chip with the same hover, and `accessibilityLabel` says what a bare count cannot |
| `Icon` | every mark, at a size: an SF Symbol (its glyph's own width, in the surface's ink unless tinted), a vendor `Brand` (a `size` square, in its colour unless tinted), or a full-colour artwork that carries its own fallback (`.gitlabTanuki`, `.piBadge`). The one way the app draws a logo — no fill travels as a hex string |
| `FormField` | a label above its control; what the control hangs out of itself — a dropdown's results — draws over the lines after it |
| `HelpText` | subordinate caption copy under a control, in a `tone`: `.secondary` (the default) or `.warning` — it inks itself, so colour it by tone, never by an outer `foregroundStyle` |
| `Input` | a real `NSTextField` in the house field chrome, with its focus ring; `secure: true` (an `NSSecureTextField`) for a token; `caretAtEnd: true` puts the insertion point after a value filled in as if typed, where AppKit would select it all on focus (the Backpack sheet's saved password). AppKit sizes it: SwiftUI's `TextField` read its height from a cache that could hand it another font's |
| `Select` | a real `NSPopUpButton` that fills its column |
| `SegmentedControl` | a hand-built segmented control that can carry a logo. `style: .neutral` (a grey selection and the focus ring) or `.accent` (an accent selection on `.surface(.accent)`, no ring — the Settings tab bar); a segment `isSelectable` rejects is dimmed and disabled. It inks each label for its ground — the selection in the surface's ink, the rest in its secondary ink — so a label is plain `Text` |
| `Kbd` | keycaps for a shortcut, inked for the surface it sits on: on `.accent` — `SheetPrimaryButton`'s label declares it — white on the keycap washes; anywhere else the surface's ink on its badge wash, edged in the hairline. It takes no style: the ground decides |
| `SearchField` | a single-line field that hands navigation keys to an open popup first |
| `SidebarHeading` | `PROJECTS` and a divider's name: micro, uppercase, tracked, secondary ink |
| `SymbolMark` | a round mark for what is not a vendor: an SF Symbol at half the disc's size, in one of two styles — `.quiet` (the default) in `Palette.text` on a `Palette.controlActive` disc, `IntegrationMark`'s family, with `tint` for a muted glyph; `.paper` in `Palette.markInk` on a `Palette.markPaper` disc, the vendor discs' recipe, so a mark beside Claude's and Codex's reads as one of them. `size` is points on screen — the Mac card passes `Size.control`, the Metrics panel's Mac readings row `scale(Size.vendorMark)` |
| `Hairline` | every 1 pt rule, in one weight: `border` on a filled rectangle, the same stroke as a control's outline — the sidebar's rules, the step bar, a sheet's header and footer edges, under a card's header, between a Settings section's rows (`SettingsRowDivider`). Never a bare `Divider()` |

### Foundations — not components, no card

`Palette`, `Metrics` (`Space`/`Radius`/`Size`/`Typography`/`Sheet`/`TypeStyle`), `Brand`, `Surface`,
`InterfaceScale`, `IconSource`, and the view modifiers in `ControlChrome.swift`: `focusRing`,
`fieldChrome` (a single-line field: padding, height and `fieldBox`), `fieldBox` (the field's fill,
hairline and focus ring alone, for the prompt editor), `menuChrome` (the panel a dropdown hangs in), `menuRowHighlight` (a dropdown row on
the accent, declaring `.surface(.accent)`) and `groupChrome` (a `SettingsGroup`'s or a segmented
track's box), and `ShellforgeMaterial` and `TerminalPalette`, Shellforge's own.
`Logos` (the bundled SVG data and its image cache) and `LogoGlyph` are internal to this module.
`TypeStyle` is the type `Typography`'s members are declared as and the `View.font(_:)` overload
takes; `Brand` is what `Icon(.brand(…))` and `Badge(icon: .brand(…))` consume. An agent adding a text size or a
vendor needs both.

### Patterns — `Sources/ShellforgeUI/`

`SheetLayout`, `SheetSubtitle`, `SheetFooter`, `SheetPrimaryButton`, `DestinationLine`, `CreationFooter`,
`AgentSegmented`, `CommandBlock`, `StatusMark`, `StatusCountChips`, `AvatarGroupView`, `VendorMark`,
`BranchLabelView`, `StepBar`, `ProviderIcon`, `CompletionPopup`,
`NativeRowHighlight`, `SidebarFooter`, `UsageRing`, `ToneDot` (with `SettingsTone`), `MacMode` (with `MacModeLine` and
`MacModePresentation`, in `MacModeRow.swift`), `BackpackSheet`, `SearchPicker`, `DropdownList`, `DropdownKeys`,
`PickerResultRow`,
`PickedItemField`, `LaneChip`, `AgentStep`, `PromptStep`, `CompletionHint`,
`PromptEditor`, `SidebarView`, `SidebarBanners`, `SidebarBanner`,
`SidebarHeader`, `SidebarEmptyState`, `ActivityBar`, `MetricsPanel`, `MetricsStrip`, `RearrangeBar`,
`ProjectHeaderRow`, `SelectableRow`, `RowPill`, `RowTitle`, `RowCaption`, `TaskRowView`, `TerminalRowView`, `DividerRow`,
`JiraProjectSheet`, `SettingsPanel`, `SettingsCard`, `ServiceCard`, `SettingsGroup`,
`SettingsSwitch`, `SettingsSection`, `SettingsRowDivider`, `NumberedSteps`, `MacSettingsCard`, `IntegrationMark`,
`FeedbackBanner`, `FeedbackSheet`, `NameSheet`, `NewTaskSheet`, `NewReviewSheet`.

**Backpack Mode.** The Metrics panel's content (`SidebarFooter`, the foot of AiTerm's sidebar) is
two groups under a `Hairline`, on the list's grid: SYSTEM, then USAGE. SYSTEM is the selected task's or terminal's `ctx` row (its active
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
`backpack enabled` ready, `backpack needs you` attention. That is the one colour in the panel that is
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

**A sheet's anatomy.** The band under a sheet's title holds a `StepBar` (New Task, New Review) or —
on every other sheet, Settings included — one `SheetSubtitle`: a sentence saying what the
sheet does, never a path. Every sheet that opens a window ends its content with one
`DestinationLine`, in one format: `Opens in Shellforge · <project>/<worktree path in it> · <branch>` —
the project alone for New terminal, `task “<title>”` in place of the path for a review that opens in
the task that has its branch. New Task and New Review draw it on steps 1 and 3 (`Destination`),
New terminal under its field; nothing else writes where a window opens.

New Task and New Review share `CreationModel`, generic over the sheet's `CreationKind`, and
`CreationFooter` — Back or Cancel, Continue or the create button, and the failure; each sheet keeps
its own first step. A failed create shows its error as a sentence in the footer — git's failure
lines as one sentence, as the banner has them — with git's whole output in the tooltip
(`CreationFailure`).

`NameSheet` is every sheet whose one question is a name: New terminal (`NameSheet.newTerminal`), Add divider, and Rename for a
task or review, a terminal (from its row's context menu or VoiceOver actions: "Rename terminal",
"Terminal name") and a divider — each rename's title, field and sentence from `RenameCopy`. A
terminal's name is its row's; its iTerm2 tabs keep their branch titles. `JiraProjectSheet` is
reached only from a project's context menu: Add Project… has no sheet, the folder chooser adds the
project at once, and a folder inside a repository adds that repository with a toast saying so.

A project header wears **one** quiet Jira `Badge` beside its name, however many Jira projects it
links (proposal E2, 8 Oct 2026): the first linked project's key, which opens that project, and —
when it links more — `Space.snug` after it a boxed `+n` `Badge`, as `BranchLabelView` counts a
window's other branches. The `+n` opens a menu of every project, the first included — `KEY — Name`
in the order they were linked, each opening its own — then "Jira Projects…". Its tooltip names
every project and VoiceOver the rest ("2 more Jira projects: PAY and WEB"). `ProjectJiraBadge` decides all of it, tested without rendering; `ProjectJiraBadgeView` draws
it. One mark per row, so linking projects takes little of the name's room.

**Alerts** are `NSAlert`s, described by an `AlertPrompt`: one default button, on ↩, blue — or red
(`defaultDeletes`, `hasDestructiveAction`) when it deletes files or commits — and every other
button the plain grey one, a destructive button that is not the default included. ⎋ answers the
safe choice (`escapeButton`). `PickerResultRow`, `PickedItemField` and `LaneChip` (a result row, the
pick drawn in the field's place, a lane on its service's wash) carry no Shellforge type and are drawn
from three sheets, but promotion's conditions are necessary, not a mandate: their one consumer is
`SearchPicker`, itself a pattern, so they stay beside it as patterns too.

`SelectableRow` is a task's or terminal's row — its indent, the click that activates it — and owns
its row's hover, so the pointer redraws one row. `RowPill` is the one pill every selectable sidebar
row is drawn in, a project header's included: the selection fill on `Surface.accent`, else the hover
wash. It declares the row's `Surface`, and `RowTitle` and `RowCaption` — a row's title, and a line
under it — read that rather than a `selected` flag, as a header's chevron, name, provider glyph and
"+" do; `RowCaption(warns:)` is amber off the accent only. Which task or terminal is selected —
never a divider — is the `SidebarModel`'s (`selectedTaskId`, `selectedTerminalId`); a task row's
removal is the `RemovalBoard`'s, shared by every window. `RedrawTests` checks that an update that
changes nothing redraws nothing.

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

`SettingsPanel` is one sheet, not AiTerm's tabbed window: three `SettingsSection`s — Core (the
Mac, Environment, Match the terminal, Feedback), Agents (the agent list, then each installed
agent's default model and reasoning) and Services (Jira, GitLab, GitHub) — under one
`SheetSubtitle`, with Cancel and Save. A section is drawn as macOS's grouped form draws one: a
heading in `Typography.bodyEmphasis` lined up with the rows' marks, then one box of
`Palette.groupFill` (a veil measured against the native grouped form's: darker in light, lighter in
dark), its rows divided by a `SettingsRowDivider` inset past the marks. An agent's form opens in the
panel in place of the sections, with its own Cancel and Save.

`SettingsCard` is one row of a section, drawn in the section's box with none of its own: a
`Size.control` mark, a title with optional check chips, a status line in one of three tones
(`SettingsTone`: ready, attention, idle, led by its `ToneDot` — the dot the Mac mode line draws too)
and with no full stop (`SettingsStatus` drops the one an error's own sentence ends with), trailing
actions at `.controlSize(.large)`, fields under the header. A row whose action is a switch (Match the
terminal, Feedback) trails a `SettingsSwitch`. Cards carry no Test button: Settings tests every
service when it opens, and again once its fields stop changing, and the answer replaces that card's
status line rather than landing in the sheet footer. A Jira, GitLab or GitHub card (`ServiceCard`)
holding saved credentials trails a Disconnect, which empties its fields and marks the service for
removal: Save removes the saved site or host and the Keychain token, Cancel keeps everything. Save
is all or nothing: it checks every card before it writes any, so while one card cannot save (a
mistyped URL) nothing is written at all — a Disconnect or a new connection on another card is not
applied either — and the sheet stays open saying why. A write the Keychain refuses puts back the
ones this Save made before it, and the footer names any service the Keychain would not let it put
back.

`MacSettingsCard` is a card's anatomy for the Mac: `macbook` in a `.paper` `SymbolMark`, the chips
“Lid sleep” and “Network discovery”, one action named by its state — Allow… while something is
missing, Remove once both are granted — and, under its header, `NumberedSteps` for what is missing
or one line of `HelpText` when nothing is. `NumberedSteps` is also the Backpack sheet's phone steps.

`SettingsGroup(title:help:rows:)`, AiTerm's group that connects and tests nothing (a box of its own,
`groupChrome`, a heading over one line of `HelpText`, a `Hairline`, then the rows), is ported but
not drawn yet: Shellforge has none of AiTerm's Interface tab, where it is used.

The agents' hooks are not a Settings tab here but the Agent hooks sheet (`AgentHooksView`, the
header's bolt): one row per built-in agent with its state and one action, named by that state —
Install, Repair or Reinstall.

`SidebarEmptyState` is what sits under `PROJECTS` while there are none: a `Typography.body` line,
a `HelpText` line, and an "Add Project…" push button that runs the header's own action. Its text
starts where the heading's does, and its spacing reads `scale`; the button is an AppKit bezel, so
it steps from `.regular` at ×1 to `.large` above it rather than scaling.

`UsageRing` is a progress ring that carries no Shellforge type. It stays a pattern beside the
sidebar's other marks, though the Metrics panel (`SidebarFooter`) and the metrics strip both draw it. It is drawn to `StatusMark`'s recipe — same diameter, same `size * 0.15` stroke, same
round cap — so the sidebar's two round marks read as one family.

Every window in the Metrics panel and the strip — its label, ring, number and reset — has one tooltip and one VoiceOver
label in words (`UsageLine.help`): “Weekly limit, 61 % used, resets Friday 23:33”, “Context 84 %
full”, “CPU 87 % busy, slowed by heat”. A vendor's or the context's reading turns amber at 80 % or
more; the Mac's, on macOS's warnings above.
The token counts are one element with one sentence (`TokenTally.help`): “Input 936,018 tokens, 99 % from
cache · output 5,625 tokens · subagents included”.

## AiTerm's design page

AiTerm keeps a human view of this system, `docs/design/design-system.html`, with a Proposals tab
for changes not yet made. Shellforge has no copy: this file and the Swift beside it are the only
description. Doc comments that still say "design canvas" or name a proposal are historical
provenance for a decision (what a value is, or why it was chosen), not a pointer to a document in
this repository.
