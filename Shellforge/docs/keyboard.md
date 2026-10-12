# Keyboard

Shellforge's keys leave every iTerm2 key alone: they are all ⌃⌘ and a letter or bracket that
iTerm2's own main menu does not use (decided 12 October 2026, option A of PRD W9). iTerm2 keeps
⌘N (New Window), ⌘T (New Tab), ⌘R (Clear Buffer), ⌘F (Find), ⌃⌘F (Full Screen) and the ⌃⌘
arrows (move a split's divider). `ShellforgeHostTest.testShellforgesControlCommandKeysAreTheirsAlone`
checks in the running app that each key below is in the main menu once.

## Tasks menu

| Keys | Action | Acts on |
|---|---|---|
| ⌃⌘N | New Task… | The target project: the selected task's, else the window's only project. Off with several projects and no task selected. |
| ⌃⌘R | New Review… | The same target. |
| ⌃⌘P | Add Project… | — |
| ⌃⌘] / ⌃⌘[ | Next Task / Previous Task | The open projects' tasks in sidebar order, wrapping round. From no selection, the first or the last. |
| ⌃⌘⌫ | Remove Task… | The selected task; it asks first, as the row's menu does. |
| ⌃⌘A | Focus View | Opens the projects with a task waiting on you (needing input, or done and unseen), folds the rest, and shows the first such task. |
| ⌃⌘L | List View | Opens every project. |

Each acts on the key window's sidebar — a sheet of it may be key — and is off where its rule says.

A profile given a shortcut in Settings › Profiles › General gets ⌃⌘ and that key in the Profiles
menu. The Tasks and View menus come first in the menu bar, so a profile shortcut on N, R, P, A, L,
S, [ or ] is shadowed by Shellforge's item: give such a profile another key. A key mapping of your
own (Settings › Keys, or a profile's Keys) runs before any menu item, as in iTerm2.

## View menu

| Keys | Action | Notes |
|---|---|---|
| ⌘B | Backpack Mode | AiTerm's key; free in iTerm2, whose B shortcuts all carry another modifier. |
| ⌃⌘S | Hide Sidebar / Show Sidebar | The key Finder and Mail use. New windows open as the last toggle left them. |
| — | Tunnels › Start / Stop Tunnel … | No keys; Open Quickly (⇧⌘O) finds them by name. |

## The sidebar's edge

Its right edge drags it to a width, from its minimum (360 pt) to 720 pt. The terminal always keeps
at least 320 pt: in a window under 680 pt, too narrow for both, the sidebar steps aside until the
window is wider. Each window keeps its own width; the last one dragged is where new windows start.

## Sheets

⌘↩ presses the primary button; ⎋ closes an open list first, then the sheet — as in AiTerm.
