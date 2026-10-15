# M12g Window fit — Implementation Plan

> Executed inline (superpowers:executing-plans), one final review. The user approved the list and
> waived per-decision sign-off.

**Goal:** the floating sidebar sits in its window as macOS 26's own sidebars do.

**Spec:** Shellforge/docs/plans/2026-10-14-m12-modern-ui-design.md, step 2 (the floating sidebar and the window).

## Measured (host-test spike, macOS 26, panel at 8,8)

| Window | Close button (x, top) | Title bar |
| --- | --- | --- |
| No toolbar (now) | 9, 9 — 1 pt inside the panel's corner | 32 |
| Empty `NSToolbar`, `.unified` | 19, 19 — 11 pt in from the panel on both axes, centred at 26 | 52 + |
| `.unifiedCompact` | 12, 13 | 40 |

Moving a button by hand is undone by the next resize, so the native toolbar is the route.

## Before and after (approved)

| | Before | After |
| --- | --- | --- |
| Window buttons | 1 pt inside the panel's corner | An empty unified toolbar: 11 pt in on both axes, as Finder's |
| Sidebar header | Its own row under a ~50 pt empty band | On the buttons' row, after the zoom button |
| Title strip | The theme's tab-bar grey, 36 pt | The terminal's background, as tall as the toolbar band (52), title centred on the buttons |
| Sidebar to terminal | 0 pt | The panel's 8 pt inset, the drag handle in that gap |
| Behind the panel | The window, see-through | The terminal's background |
| Panel corner | 16 − 8 from a hard-coded guess | The window's measured corner − 8, the guess only before measuring |
| Footer card | Content left of the rows' | Lined up with the rows |
| System row for a shell | A lone mark | No row |
| Branch field | An outline the others lack | As the other fields |

## Tasks

- [ ] **1. Gap** — host test: the terminal's left edge is the panel's right edge + the inset; the drag handle lies in that gap. `iTermLayoutCalculator` consumes `sidebar + inset`; `dragHandleFrame` spans the gap.
- [ ] **2. One surface** — host test: the strip's colour and a view behind the panel are the session's background colour in a floating window (theme colour when the session has a tab colour). `rootTerminalViewTabBarBackgroundColorIgnoringTabColor` returns the session's background for floating windows; a column view behind the panel draws it.
- [ ] **3. Buttons and strip** — host test: in a floating window, the close button sits as far in from the panel's left as from its top; the strip is 52 tall; the title's centre is the buttons' centre. An empty unified `NSToolbar` on floating windows (attached where full-size content is set); `desiredTabBarHeight` 52 for floating windows without a visible tab bar.
- [ ] **4. Header on the buttons' row** — package test: with a window-controls reserve, the header's title starts after it and the header row is centred on the band; without (full screen, sidebar not floating) as now. The host sets the reserve from the zoom button's frame.
- [ ] **5. Panel corner** — test: `panelCornerRadius(forWindowRadius:)` is radius − inset, never below 0; the host passes the detector's cached value when there is one.
- [ ] **6. Footer card and shell row** — package tests: a shell task with no readings draws no row; the card's content lines up with the rows'.
- [ ] **7. Branch field** — render the Task step, find the outline's cause, fix with a test.
- [ ] **8.** All tests, build, host classes, upstream-hook-points.md and features.md, commit.
- [ ] **9. Backpack Location** — test: a “While in use” Location answer counts as granted, as “Always” does (`LiveLocation.swift:48-50` accepted only `authorizedAlways`).
