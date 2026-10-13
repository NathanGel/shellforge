# M5b Performance: idle CPU, wakeups and redraws — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Shellforge cheap to keep open all day. When nothing changes, nothing should wake, redraw or cross the socket. Each change is a test that failed first: a count of wakeups, sends or redraws.

**Spec:** the PRD's "Final pass" table, Performance row. It checks idle CPU and energy, every timer and poll, work on the main thread, and redraws of the sidebar and footer. The survey of 13 October 2026 (ledger) lists each source with its file and line.

**Tech Stack:** Swift 6 language mode, macOS 13, SwiftUI and Combine; Python 3 asyncio daemon; Swift Testing and pytest.

## Global Constraints

- Behaviour stays as it is: the same states, at most one tick later. No interval grows past what a person would notice: a tunnel's end within 1 s, a session's state within its hook, Codex usage within 10 s.
- Tests touch no real home, `~/.ssh`, `UserDefaults.standard`, login shell or network.
- macOS 13; design tokens; commits by path, ending `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; never push.

## Review Focus

1. **A tunnel's ssh exits while the daemon waits on it.** Expected: `connecting`, then a restart, or `failed`, exactly as the poll did. Test: Task 1's existing `test_tunnel*.py` plus `test_an_exit_is_seen_without_polling`.
2. **A stop while the wait runs.** Expected: the waiter ends; no thread or zombie is left. Test: `test_stop_while_waiting_leaves_no_child`.
3. **Several title changes in one run-loop turn.** Expected: one refresh and one report, and the last title wins. Test: Task 3 `titleBurstsCoalesce`.
4. **A store equal to the last one.** Expected: no `objectWillChange`. Test: Task 4 `anEqualStoreRedrawsNothing`.
5. **The daemon with no agent sessions.** Expected: it polls every 10 s; a hook or a `sessions.update` still ticks at once. Test: Task 2.

---

### Task 1: Tunnel wakeups in the daemon
- A running ssh's exit is awaited, not polled every 50 ms:
  - `popen.wait` runs on a daemon thread (`offload.run_detached`).
  - "Up" is a `loop.call_later(up_after)`, cancelled on exit or stop.
  - A stop ends the wait, because killing the group ends `wait`.
- The hold probe runs every `probe_every` until the hold is up, then every `probe_up_every` (5 s).
- The traffic sampler's loop ends when no tunnel is up, and `_set(..., "up")` starts it again.
- Tests:
  - `test_an_exit_is_seen_without_polling`: `POLL` is unused, monkeypatched to raise.
  - `test_stop_while_waiting_leaves_no_child`.
  - `test_the_sampler_stops_with_the_last_up_tunnel`.
  - `test_an_up_hold_probes_less_often`.
  - All `test_tunnel*.py` stay green.

### Task 2: The daemon's idle poll
- `_poll_forever` sleeps `POLL_SECONDS` (2 s) while any session runs an agent (`agent != "shell"`), else `IDLE_POLL_SECONDS` (10 s).
- A hook or a `sessions.update` still ticks at once (they do today).
- Test: `test_an_idle_daemon_polls_every_ten_seconds`, which measures the sleep asked for through an injected sleep.

### Task 3: Coalescing the host's notifications
- `iTermShellforgeHost` turns every burst of notifications in one main run-loop turn into one `onChange` and one `reportsMayHaveChanged`: a pending flag, cleared when it fires.
- The coalescer is a ShellforgeUI type, `ChangeCoalescer(schedule:fire:)`, so a test drives its schedule by hand.
- Test: `titleBurstsCoalesce` (three signals, one fire; a signal after the fire schedules again).

### Task 4: Redraw only on a real change
- `SidebarModel` assigns `tree`, `sessions`, `selectedTaskId`, `selectedTerminalId` and `providers` only when they differ (a `setIfChanged` helper). `@Published` announces every assignment, equal or not.
- `take(store)` skips the footer-context work when the store is equal.
- `BackpackController.tick` assigns `state` and `power` only when they changed.
- Tests:
  - `anEqualStoreRedrawsNothing`, which counts `objectWillChange`.
  - `anEqualRefreshRedrawsNothing`.
  - `anUnchangedBackpackTickRedrawsNothing`.

### Task 5: Timer tolerance
- The app's 1 s tick and 30 s rc check get a tolerance: 0.5 s and 5 s, so macOS can batch their wakeups.
- App-only, no test seam. Ruling: verified by build and reading.

### Task 6: Verify
- Build; the package, the daemon and `ShellforgeHostTest` pass.
- The PRD's Performance row says what was done, and what was ruled out:
  - the spinner stays a SwiftUI animation (AiTerm's look);
  - offload stays thread-per-call (a stuck stat must not block the next);
  - the machine sample stays 5 s and unrounded (the footer shows it).
