# M12 A native macOS look — Design

**Goal:** Shellforge looks like a current macOS app. The sidebar follows the system's light and
dark appearance, floats as a rounded glass panel inside the window on macOS 26, and every
Shellforge sheet, panel and setting uses the system's own controls and layout. Nothing about how
Shellforge works changes: every feature, shortcut, menu and setting behaves as before.

M12 is the second improvement track. It builds on M11 (the terminal match), whose palette gains a
light version here.

## Decisions taken

- **Direction:** closer to current macOS (macOS 26), not a stronger custom identity.
- **Appearance:** the sidebar follows the system's light and dark appearance; nothing is forced
  dark any more.
- **The terminal match** gets a light palette and switches with macOS.
- **Scope:** Shellforge's own UI and where it meets the window. iTerm2's Settings window, menus, tab
  bar, toolbelt and status bar stay as upstream has them.
- **Shape:** on macOS 26, a floating rounded glass sidebar inside the one window, with the window
  buttons inside its top. On macOS 12–15, the classic full-height translucent sidebar.
- **AiTerm parity:** Shellforge's look diverges from AiTerm. The `TokenParityTests` pins are retired
  for the files this redesign changes; each ported file keeps its GPL credit to AiTerm and Laurens
  D'Hondt.
- **Approach:** the design system first, then one area at a time, inside today's layout. Each step
  ships on its own and looks complete.

## Version support

The app supports macOS 12 and later; the package, macOS 13 and later. macOS 26 features (glass, the
floating panel, the full-size window style) are used behind `#available(macOS 26, *)`, with the
fallbacks below. Reduce Transparency always gets the flat fallback.

## Step 1: the design system follows light and dark

- **Nothing forced dark.** The sidebar's host view (`ShellforgeSidebar.makeView`) and the sheet
  panel (`DarkPanel`, renamed `ShellforgePanel`) no longer set `.darkAqua`; they follow the window,
  which follows macOS or iTerm2's Appearance setting. `Palette` and `IconSource` resolve colours in
  the current appearance, not dark.
- **Adaptive colours.** The eight dark-only values become one light and one dark value each, in
  `Palette`: `rowHover`, `badgeSelected`, `badgeHovered`, `badgeSelectedHovered`, `spinnerTrack`,
  `codeBackground`, `markInk` and `markPaper`. Every other colour already uses a semantic macOS
  colour and adapts by itself. Brand logos keep their vendor colours; the white GitHub and black
  OpenAI and Grok marks get a variant for each appearance.
- **`ShellforgeMaterial`** (ShellforgeDesign), the one place a surface asks for translucency:
  - macOS 26: the glass effect;
  - macOS 12–15: `NSVisualEffectView`, material `.sidebar`, blending `.behindWindow`;
  - Reduce Transparency, any version: the opaque window background colour.
- **Sizes to macOS 26.** `Metrics` is checked against macOS 26's sidebar and control sizes (row
  height, corner radii, padding, default text size) and changed there once. The sidebar text size
  (⌘+ / ⌘− from M10) keeps scaling on top.
- **Rules kept.** `DesignRulesTests` still requires colours from `Palette` and sizes from `Metrics`.
- **Tests.** Every adaptive colour resolves differently in light and dark and meets its contrast
  rule on its surface in both; `ShellforgeMaterial` picks glass, the sidebar material or the flat
  colour for each version and for Reduce Transparency.

## Step 2: the floating sidebar and the window

**macOS 26:**
- **Panel.** The sidebar is a rounded `ShellforgeMaterial` panel inset `Metrics` 8 pt from the
  window's top, left and bottom edges, its corner radius macOS 26's window radius. Its width is the
  dragged width, as today; the drag handle sits on the panel's right edge, and M11's edge line
  becomes the panel's outline.
- **Window buttons inside the panel.** A window with the sidebar uses the full-size content style
  iTerm2's compact windows already use (`NSWindowStyleMaskFullSizeContentView`, transparent title
  bar): one hook in `PseudoTerminal+WindowStyle.m`. The window buttons sit inside the panel's top
  left; the sidebar's header row is pushed down to clear them.
- **Above the terminal.** A strip the height of a title bar holds the window's title, centred over
  the terminal area, and drags the window. The terminal starts below it.
- **The gap.** The window's background shows around the panel. With the terminal match on, that is
  the terminal's background.
- **Hidden sidebar (⌃⌘S).** The window returns to its ordinary title bar; the Show Sidebar button
  stays beside the window buttons.
- **Full screen.** No title bar; the panel keeps its gap and corners.

**macOS 12–15:** the window keeps its normal title bar; the sidebar is flush below it, from the left
edge to the bottom, in `ShellforgeMaterial`, with M11's edge line. The window's style is unchanged.

**Tests.** `iTermLayoutCalculator` tests for the panel's frame (inset, at the dragged width) and the
terminal's frame (below the strip on macOS 26, below the title bar before), shown, hidden and full
screen; a host test that a sidebar window has the full-size content style only on macOS 26.

## Step 3: the sidebar's content

- **Rows:** the macOS 26 sidebar row: a rounded selection in the system selection colour (accent
  while the sidebar has focus, unemphasized otherwise), heights and padding from `Metrics`, icons as
  SF Symbols in hierarchical rendering.
- **Status dots** stay, drawn in system colours that read in both appearances.
- **Headings:** “PROJECTS” and “OTHER TABS” become section headers in sentence case, “Projects”
  and “Other Tabs”, in the secondary label colour.
- **Badges** (VS Code, diff counts, chips): small capsules with an adaptive fill.
- **Footer** (usage, the Mac's readings, Backpack): one compact card at the bottom of the panel.
- **Banners:** inline notices with an SF Symbol (warning or info), the message and M10's ×.

## Step 4: sheets and panels

New Task, New Review, Backpack, Tunnels, Agent hooks, Remove Task and the other prompts:
- open as real sheets on the window (`beginSheet`), with the system's sheet look (glass on
  macOS 26), instead of the custom panel attached to the sidebar;
- use standard controls: the primary button prominent, others bordered, system text fields,
  pop-ups and toggles, and grouped sections in the System Settings style;
- keep their Cancel and Save, and every check they make, exactly as now.

## Step 5: Settings

The gear's Settings becomes a grouped form in the System Settings style: sections Core and
Services, one row per setting, each service's status and actions in its row. Save and Cancel stay.

## Step 6: the terminal match's light palette

In light mode the match uses a light palette, switching with macOS:
- **Background:** a step lighter than the light sidebar (`SRGB.lightened(by:
  ShellforgeTerminalPalette.backgroundStep)`), so the reading area is brighter than the side panel.
- **Text and the 16 colours:** the same `TerminalSource` colours, resolved in light, darkened in
  5 % steps where needed to reach 4.5:1 on the background (the mirror of the dark palette's
  lightening).
- The match recolours open sessions when macOS's appearance changes, as it already does for the
  accent colour.

**Tests:** the light palette's 23 keys, its contrast rules, and its step from the light sidebar; a
host test that an appearance change recolours a session.

## Each step

- Gets its own implementation plan (M12a for step 1, M12b for step 2, and so on), written when the
  step before it has shipped, so each plan is drawn from the code as it then is.
- Starts with a short before-and-after list for its area, which the user agrees to before it is
  built.
- Keeps every existing package and host test green, and adds tests for its own rules.
- Ends with a check by hand (`make run`) in light and dark, and on macOS 26 and an earlier macOS
  where the step differs by version.
- Records any new change to iTerm2's files in `upstream-hook-points.md` and updates `features.md`.

## Out of scope

- iTerm2's own Settings window, menus, tab bar, toolbelt and status bar.
- New features, or any change to how Shellforge behaves.
- A Shellforge setting to keep the sidebar dark in light mode.
