# M6a The app holds nothing it no longer needs — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** PRD goal 7, for the app side. A closed window, a finished command and a restarted helper leave nothing behind: no objects, threads, file descriptors or tasks.

**Spec:** the PRD's goal 7 and its "Memory and resources" row.

**Findings to act on:**
- the baseline `leaks` run of 14 October 2026, which found no Shellforge objects;
- the read-only survey of the same day, which found one likely leak and four possible ones.

## Global Constraints
- Every fix is a test that failed first: a weak reference that must turn nil, a thread or descriptor count, or a continuation that must resume.
- Behaviour is unchanged otherwise.
- Tests use scratch folders and fakes only.
- macOS 13; commits by path, ending `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; never push.

## Review Focus
1. **Closing a window.** Expected: its sidebar model goes. No tick, feed or iTerm2 notification reaches it afterwards.
2. **A git command whose hook leaves a background child holding stdout.** Expected: the call returns, and its reader threads and pipes end.
3. **A helper in a crash loop.** Expected: each dead child's `Process` and log handle are released.

---

### Task 1: The ⌘B registry let a closed window's sidebar live on (likely real)
- `BackpackSheets` used a weak-to-strong `NSMapTable`, which keeps a value until it next resizes. The presenter held the window's `SidebarModel`, which kept ticking.
- Each window now carries a token whose release removes its entry.
- Tests: `aUsedSidebarModelIsReleased` and `aClosedWindowsBackpackPresenterIsReleased`.

### Task 2: A pipe held open by a grandchild pins a thread and two descriptors per call
- `ChildProcess`'s `PipeReader`: once the child has exited and the grace period is over, the read ends are closed and their readers stop.
- Test: `aBackgroundedGrandchildLeavesNoReaders`. It runs 20 calls of `sh -c 'sleep 30 &'` and checks that the thread and descriptor counts return to where they started.

### Task 3: A restarted helper's Process is released
- `terminationHandler` must not keep its child alive once it has fired.
- Test: `aFinishedChildIsReleased` (a weak `RunningChild`).

### Task 4: A second location request no longer strands the first
- `LiveLocation.request()` resumes every caller waiting on it.
- Test: `twoRequestsBothReturn`.

### Task 5: Per-project leftovers
- Remove Project clears its tasks' `.stopped` removal rows from the shared board.
- Every window's model forgets a removed project's caches on its next refresh.
- Tests:
  - `removingAProjectClearsItsRemovalRows`
  - `everyWindowForgetsARemovedProject`

### Task 6: Verify
- Build; the package and `ShellforgeHostTest` pass.
