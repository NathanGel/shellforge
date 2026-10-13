# M4d Closing tabs from the sidebar, and Add Divider's key — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close tabs from the sidebar, and give Add Divider a key that works.

**Spec:** the user's requests of 13 October 2026.
- Tabs under Other tabs, and a task's last tab, cannot be closed from the sidebar. They should close, and a task left with no tab closes too. The user chose "Remove Task, asking first".
- ⌃⌘D (Add Divider) does nothing at all.

## Global Constraints

- A tab closes through iTerm2's own `closeTabIfConfirmed:`, so a running job asks as ⌘W does.
- Nothing on disk goes without the Remove Task confirmation.
- macOS 13; design tokens; AiTerm's menu copy style ("Close Tab"); commits by path, ending `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; never push.

## Review Focus

1. **A task's last tab, with another of its tabs in a second window.** Expected: that tab is not its last; it closes plainly. Test: `aTaskTabWithAnotherElsewhereJustCloses`.
2. **Remove Task cancelled after Close Tab on the last tab.** Expected: the tab stays open, and so does the task. Test: `theLastTabAsksToRemoveTheTask` (only the request is sent; nothing is closed).
3. **A running job refuses the close.** Expected: the tab stays (iTerm2 asks). Covered by `closeTabIfConfirmed:` in the app; ruling.

---

### Task 1: Add Divider moves to ⌃⌘G
- macOS takes ⌃⌘D (Look Up) before any app's menu, so the key never reached Shellforge.
- `SidebarCommandMenu.systemReserved` lists macOS's own ⌃⌘ keys: D (Look Up), Q (Lock Screen) and Space (Character Viewer).
- Test `noKeyIsOneMacOSKeeps`.
- Add Divider moves to ⌃⌘G (free in iTerm2's main menu: `ShellforgeHostTest`).
- `keyboard.md` follows.

### Task 2: Close Tab
- `TerminalHost.close(tab:) -> Bool` closes one tab through iTerm2's confirmation.
- `TerminalHost.hasTab(ofTask:) -> Bool` looks in every window.
- `SidebarModel.closeTab(_ id: String)`:
  - a tab of no task, or a task's tab while it has another anywhere, closes;
  - a task's last tab sends `.removeTask(task)`, the Remove Task confirmation.
- `SidebarModel.closeCurrentTab(ofTask:)`: the task row's Close Tab. It closes the task's selected tab, else its first.
- UI:
  - tab rows get Close Tab in their context menu and a VoiceOver action;
  - task rows with a tab get Close Tab before Remove Task….
- Tests (`CloseTabTests`):
  - `anOtherTabCloses`
  - `aTaskTabWithAnotherCloses`
  - `theLastTabAsksToRemoveTheTask`
  - `aTaskTabWithAnotherElsewhereJustCloses`
  - `theTaskRowClosesItsCurrentTab`

### Task 3: Verify
- Build; the package, the daemon and `ShellforgeHostTest` pass.
- Live check: Close Tab on an Other tab; on a two-tab task; on a one-tab task (asks to remove); ⌃⌘G.
