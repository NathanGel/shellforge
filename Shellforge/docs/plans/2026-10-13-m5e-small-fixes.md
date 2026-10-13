# M5e The 13 deferred minors — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the PRD's three lists of deferred minors (From M5a, From M5b, From M4d to M5c). Each fix is RED then GREEN where code can show it.

**Spec:** the PRD lists, rev 70. The user asked on 13 October 2026: "do the 13 small fixes".

## Global Constraints

- Behaviour elsewhere is unchanged; every existing test stays green.
- Tests touch no real home, `~/.ssh`, `UserDefaults.standard`, login shell or network.
- macOS 13; design tokens; commits by path, ending `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; never push.

## Review Focus

1. **The kqueue exit watch** (Task 3). An ssh that exits before the watch is registered must still be seen. The watch must leave no file descriptor or reader behind on stop or cancel.
2. **The one-shot initial text held outside the profile** (Task 2). The agent's tab must still get its command once: after a slow shell, and after full screen.

---

### Task 1: Sidebar
- (M5a 1) A terminal or task shown with a done tab and a working one marks the done sessions seen. The status gate becomes "has a done session".
  - Tests: `aShownTerminalMarksItsDoneTabsSeenWhileAnotherWorks`, `aShownTaskMarksItsDoneTabsSeenWhileAnotherWorks`.
- (M5a 2) The drag handle reaches over the terminal by no more than the terminal's side margin. Test: `theHandleStaysWithinTheMargin`.
- (M5a 3) Add Divider is greyed out with no project, so a divider can't be made that nothing would draw. Test: `addDividerNeedsAProject`.
- (M5b 1) Selecting the selected task, or showing it again, assigns nothing. Test: `reselectingATaskRedrawsNothing`.

### Task 2: Closing tabs and the agent's command
- (M4d–M5c 1) A refused close of a window's only tab closes the fresh tab it opened. Test: `aRefusedCloseTakesItsFreshTabAway`.
- (M4d–M5c 2) The tab being closed is selected again before its close asks, so iTerm2's alert is about the tab in front. Test: `theClosedTabIsInFrontWhenItAsks`.
- (M4d–M5c 3) Close Pane on a task's last tagged pane, in a tab shared with another task's, asks Remove. The removal then closes that pane, not the tab. Tests:
  - `aTasksLastPaneInASharedTabAsks`
  - `aRemoveFromClosePaneClosesOnlyThePane`
- (M4d–M5c 4) A session whose profile carries `Shellforge Initial Text Once` keeps the text in the session itself, outside its profile, from the moment the profile is set.
  - ⌘T and ⌘D, at any time, copy no command.
  - The earlier clear-on-send is replaced.
  - Test: `ShellforgeHostTest` (the flag); a live check.

### Task 3: Tunnels
- (M4d–M5c 5) A tunnel refusal that is no `DaemonError` reads "the helper's connection dropped". Test: `aDroppedConnectionIsSaidPlainly`.
- (M5b 2) An ssh's exit is watched with kqueue's `NOTE_EXIT` on the event loop, not a thread blocked in `wait`. This covers the supervisor's ssh and adopted ones, and replaces the 1 s `kill(0)` poll. Quitting leaves nothing waiting.
  - Tests:
    - `test_an_exit_is_watched_without_a_thread`
    - `test_an_adopted_tunnel_s_end_is_seen_without_polling`
  - All `test_tunnel*.py` stay green.

### Task 4: Tests
- (M5a 4) `onLaunchIsAskedOncePerAppAcrossWindows` waits for the second window's config read, not 400 ms.
- (M5b 3) `test_an_exit_is_seen_without_polling` forbids `Popen.poll` in the steady state.
- (M4d–M5c 6) `test_the_sampler_ends_with_only_a_held_tunnel_up` waits up to 5 s.

### Task 5: Verify
- Build; the package, the daemon and `ShellforgeHostTest` pass.
- The PRD ticks all 13.
