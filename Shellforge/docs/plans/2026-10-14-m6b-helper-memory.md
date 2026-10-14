# M6b The helper holds nothing it no longer needs — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** PRD goal 7, for `shellforged`. What it keeps does not grow with time.

**Findings:** the read-only survey of 14 October 2026.

## Global Constraints
- Every fix is a test that failed first. Tests use `tmp_path` and fakes only, never the network.
- commits by path, ending `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; never push.

## Review Focus
1. **A tab with hundreds of `/clear`s over a week.** Expected: the resolver keeps one pin for it.
2. **A check failing on every 2 s tick for a day.** Expected: the log grows by one line every five minutes.
3. **Codex used outside Shellforge for months.** Expected: the lineage cache holds only the days a running thread can still need.

---

### Task 1: Retention
- `SessionResolver.bind` keeps one pin per agent per tab.
- `CodexSessionFiles.retain` drops lineage from before the earliest running thread's day.
- `RepeatFilter` (new): an identical log message gets through once per 5 minutes, and the next one through says how many were held back. It sits on the helper's own log handler only.
- Tests (`tests/test_retention.py`):
  - `test_a_tabs_pins_do_not_grow_with_its_conversations`
  - `test_rollouts_no_thread_runs_are_forgotten`
  - `test_a_repeated_failure_is_logged_once_a_while`

### Task 2: Two tunnel tests found red on 14 October
- macOS checks a newly written executable on its first run, which takes about 0.6 s. That is longer than the tests' 0.2 s `up_after`, so a fake `ssh` that fails at once read as up.
- The fixture now runs the fake once before the test. The supervisor is unchanged: the real `ssh` is never a new file.

### Task 3: Verify
- The daemon suite passes.

Ruled out:
- Stopped tunnels and status children are kept for the life of their alias or tab, so they stay bounded.
- A dead child's `Process` is already released (M6a).
