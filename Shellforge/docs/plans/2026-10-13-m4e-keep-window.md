# M4e Closing a window's last tab keeps the window — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Closing tabs from the sidebar never closes the window. iTerm2 closes a window with its last tab, and the sidebar goes with it.

**Spec:** the user, 13 October 2026: Close Tab on a window's only tab "should just keep Shellforge open but close the iTerm tab". A window cannot hold no tab, so a plain shell tab opens first. Task tabs keep M4d's rule: Remove Task is asked only for a task's only tab.

## Global Constraints

- The fresh tab is iTerm2's own new tab: the default profile, in its default folder, untagged. It shows under Other tabs.
- It opens only when every tab of this window is about to close. A closing that is refused leaves the extra tab, which is harmless.
- macOS 13; commits by path, ending `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; never push.

## Review Focus

1. **The only tab is a task's.** Expected: Remove confirmed, then a shell tab opens and the window stays. Test: `removingTheWindowsOnlyTabKeepsTheWindow`.
2. **A terminal row whose tabs are all the window's.** Expected: the same. Test: `removingATerminalWithTheOnlyTabKeepsTheWindow`.
3. **Several tabs.** Expected: no extra tab. Test: `aTabAmongOthersOpensNoShell`.

---

### Task 1: Keep the window
- `TerminalHost.openShellTab()`: iTerm2's new tab in this window, selected.
- `SidebarModel.keepingWindow(closing:)` opens one before `close(tab:)`, `closeTabs(ofTask:)` (removal) or `closeTabs(ofTerminal:)` when the tabs about to close are all of this window's.
- Tests (`CloseTabTests`):
  - `closingTheWindowsOnlyTabOpensAShellFirst`
  - `aTabAmongOthersOpensNoShell`
  - `removingTheWindowsOnlyTabKeepsTheWindow`
  - `removingATerminalWithTheOnlyTabKeepsTheWindow`

### Task 2: Verify
- Build; the package and `ShellforgeHostTest` pass.
- Live check: ⌘T in a window with only that tab, Close Tab: the window stays, with a fresh shell.
