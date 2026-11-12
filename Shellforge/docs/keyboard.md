# Keyboard

Shellforge's keys leave every iTerm2 key alone: apart from ⌘B, they are all ⌃⌘ and a letter or
bracket that iTerm2's own main menu does not use. iTerm2 keeps
⌘N (New Window), ⌘T (New Tab), ⌘R (Clear Buffer), ⌘F (Find), ⌃⌘F (Full Screen) and the ⌃⌘
arrows (move a split's divider). `ShellforgeHostTest.testShellforgesControlCommandKeysAreTheirsAlone`
checks in the running app that each key below is in the main menu once.

## Tasks menu

| Keys | Action | Acts on |
|---|---|---|
| ⌃⌘N | New Task… | The target project: the selected task's, else the window's only project. Off with several projects and no task selected. |
| ⌃⌘R | New Review… | The same target. |
| ⌃⌘T | New Terminal… | The same target: a plain shell row under the project. |
| — | New Tab in Home Folder | No key: ⌘T is iTerm2's New Tab. A shell in `~` that belongs to no project, listed under Other Tabs. Works whenever a terminal window is in front. Also the header's terminal button. |
| ⌃⌘P | Add Project… | — |
| ⌃⌘G | Add Divider… | A named rule at the end of the project list. (Not ⌃⌘D: macOS keeps it for Look Up.) |
| ⌃⌘] / ⌃⌘[ | Next Task / Previous Task | The open projects' tasks in sidebar order, wrapping round. From no selection, the first or the last. |
| ⌃⌘⌫ | Remove Task… | The selected task; it asks first, as the row's menu does. |
| ⌃⌘A | Focus View | Opens the projects with a task or terminal waiting on you (needing input, or done and unseen), folds the rest, and shows the first such task, else the first such terminal. |
| ⌃⌘L | List View | Opens every project. |

Each acts on the key window's sidebar — a sheet of it may be key — and is off where its rule says.

A profile given a shortcut in Settings › Profiles › General gets ⌃⌘ and that key in the Profiles
menu. The View and Tasks menus come before Profiles in the menu bar, so a profile shortcut on N, R,
T, P, G, A, L, S, E, M, I, H, [ or ] is shadowed by Shellforge's item: give such a profile another key. A
key mapping of your own (Settings › Keys, or a profile's Keys) runs before any menu item, as in
iTerm2.

## View menu

| Keys | Action | Notes |
|---|---|---|
| ⌘B | Backpack Mode | AiTerm's key; free in iTerm2, whose B shortcuts all carry another modifier. |
| ⌃⌘S | Hide Sidebar / Show Sidebar | The key Finder and Mail use. Also the sidebar icon in the sidebar's header, and, while hidden, in the window's title bar. New windows open as the last toggle left them. |
| ⌃⌘E | Show Sessions | The key window's sidebar shows its Sessions panel, opening the sidebar if it is hidden. E, as S is Hide Sidebar's. |
| ⌃⌘M | Show Metrics | The same, for the Metrics panel. |
| ⌃⌘I | Show Files | The same, for the Files panel. I, as F is iTerm2's Full Screen. |
| — | Show Git | The same, for the Git panel. No key: every ⌃⌘ letter of its name is taken (G is Add Divider, I Show Files, T New Terminal). |
| ⌃⌘H | Show SSH | The same, for the SSH panel. H, as S is Hide Sidebar's. |
| — | Tunnels › Start / Stop Tunnel … | No keys; Open Quickly (⇧⌘O) finds them by name. |

## The sidebar's edge

Its right edge drags it to a width, from its minimum (404 pt, the 44 pt activity bar included) to
720 pt; it starts at 464 pt. The terminal always keeps at least 320 pt, so a window with the
sidebar showing can't be dragged narrower than 724 pt; one made narrower another way has its
sidebar step aside until the window is wider. Each window keeps its own width; the last one
dragged is where new windows start.

## Git panel

⌘↩ in a section's commit message field commits that section; ↩ adds a line. The field keeps ⌘↩
while it has the keyboard, so it never reaches the main menu, even while Commit is off.

## SSH panel

The panel has no keys of its own beyond View › Show SSH (⌃⌘H). In Add Host, ⌘↩ adds the host and
⎋ cancels, as in every sheet.

## Sheets

⌘↩ presses the primary button; ⎋ closes an open list first, then the sheet — or, on New Task's
and New Review's later steps, goes back a step — as in AiTerm.
