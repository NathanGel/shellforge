# M11 Match the terminal to Shellforge — Design

**Goal:** one optional switch that makes the whole window read as Shellforge: the terminal in
Shellforge's colours and iTerm2's window parts in its Minimal theme, so the sidebar, title bar and
terminal are one dark surface. Off by default. The user's profiles and theme setting are never
written; switching off shows them again at once.

M11 is the first of two improvement tracks. The second, a UI modernization pass, gets its own
design after this one ships.

## What the user sees

- **Switch.** Shellforge Settings (the sidebar header's gear), Core section, a Terminal card:
  “Match the terminal to Shellforge”, off by default, with one line of help: “Uses Shellforge's
  colours and iTerm2's Minimal theme. Your profiles are not changed.”
- **On.**
  - Every session in every window, including tabs opened later, draws in Shellforge's colours.
  - iTerm2's theme is Minimal, whose title bar and window edges follow the terminal's background.
  - Settings › Appearance's Theme control is greyed out with the note “Shellforge's terminal match
    uses the Minimal theme.”
  - Settings › Profiles still shows each profile's own colours.
- **Off.** Every open session reloads its profile's colours; the theme is the user's own again.
  No restart.

## The palette

Built from the macOS colours the sidebar already uses (`Palette`), resolved under `.darkAqua`
whenever it is applied, so it follows the macOS accent colour and Increase Contrast.

| iTerm2 key | Source |
| --- | --- |
| Background | the sidebar's surface (`windowBackgroundColor`) |
| Foreground, Bold | `labelColor` |
| Cursor | `controlAccentColor` |
| Cursor Text | the background |
| Selection | `selectedContentBackgroundColor` |
| Selected Text | `labelColor` |
| Ansi 0 / 8 (black) | `underPageBackgroundColor` / `tertiaryLabelColor` |
| Ansi 1 / 9 (red) | `systemRed`, then 20 % lighter |
| Ansi 2 / 10 (green) | `systemGreen`, then 20 % lighter |
| Ansi 3 / 11 (yellow) | `systemYellow`, then 20 % lighter |
| Ansi 4 / 12 (blue) | `systemBlue`, then 20 % lighter |
| Ansi 5 / 13 (magenta) | `systemPurple`, then 20 % lighter |
| Ansi 6 / 14 (cyan) | `systemTeal`, then 20 % lighter |
| Ansi 7 / 15 (white) | `secondaryLabelColor` / `labelColor` |

23 keys. “20 % lighter” mixes 20 % white into the sRGB value. Contrast against the background is at
least 4.5:1 for Foreground, Bold, Ansi 1–7 and 9–15. Ansi 0 and 8 are meant to be dim and are
exempt. A colour that falls short is lightened in 5 % steps until it passes.

Each key is written in both its light and dark variant (`iTermAmendedColorKey`), so a profile that
uses separate light and dark colours is matched too.

## Parts

- **`ShellforgeTerminalPalette`** (ShellforgeDesign). Pure: the 23 keys to sRGB components,
  resolved from `NSColor`s under a given appearance, and the contrast check. No iTerm2 types.
- **`TerminalMatchSettings`** (ShellforgeUI). The saved switch, `ShellforgeMatchTerminal`, in the
  same defaults as `SidebarLayoutSettings`, so a `-suite` run keeps its own. An `ObservableObject`
  for the card, with an `onChange` the app sets.
- **`TerminalMatchCard`** (ShellforgeUI/Settings). The Settings card with the switch.
- **`iTermShellforgeTerminalMatch`** (`sources/TerminalView`, Swift, `@objc`). Answers the hooks:
  - `profileForColors(_ profile:, keeping overridden: Set<String>) -> Profile`: the profile
    unchanged when off; when on, a copy with the palette's keys laid over it, except the keys in
    `overridden`.
  - `overridesTheme -> Bool`.
  - On a change of the switch, the accent colour or Increase Contrast: every open session runs
    `loadColorsFromProfile:` with its own profile, then `iTermPreferenceDidChangeNotification` is
    posted for the theme key, which `iTermApplicationDelegate` already answers with
    `updateAppearance` and `kRefreshTerminalNotification`.

## Hooks in iTerm2's files

Each one line, listed in `upstream-hook-points.md`:

| File | Change |
| --- | --- |
| `sources/PTYSession/PTYSession.m` (`loadColorsFromProfile:`) | `aDict = [iTermShellforgeTerminalMatch profileForColors:aDict keeping:_overriddenFields];` first |
| `sources/Settings/iTermPreferences.m` (`computedTabStyle`) | Minimal while `overridesTheme` |
| `sources/Settings/AppearancePreferencesViewController.m` (the `_tabStyle` control) | Disabled while `overridesTheme`, with the note beside it |

## Behaviour to keep

- **The profile is never written.** The override is applied to the dictionary a session loads
  colours from, not to `ProfileModel`.
- **Per-session overrides stay on top.** Colours set for one session (Edit Session, the Python API,
  an escape sequence) are written into that session's copy of its profile and recorded in its
  `_overriddenFields`. The match skips those keys, so they still win.
- **A colour edited in Settings › Profiles while on** is saved to the profile; the match still wins
  until it is switched off.
- **Untouched:** transparency, blur, background images, fonts, minimum contrast, and the tab colour.

## Testing

- Package (`scripts/swift.sh test`):
  - the palette has all 23 keys, and each meets its contrast rule against the background;
  - the lightening step stops at the first passing value;
  - `TerminalMatchSettings` is off by default and reads back what was saved.
- Host (ModernTests, `TerminalWindowTestFixture`):
  - on: a session's background and Ansi 1 equal the palette's; `ProfileModel`'s profile is
    unchanged;
  - on: a session whose background was set for that session alone keeps it;
  - on: `computedTabStyle` is Minimal; off: the saved theme;
  - off after on: an open session's background is its profile's again.
- By hand (`make run`): switch on and off in light and dark macOS appearance, with a second window
  open, and with the accent colour changed while on.

## Out of scope

- Writing Shellforge's colours into profiles, or an iTerm2 colour preset.
- A light version of the palette: the sidebar is always dark, so the match is too.
- The UI modernization pass (next design).
