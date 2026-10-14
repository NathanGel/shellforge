# M4l Lines changed on the VS Code badge — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** A task row's VS Code badge shows AiTerm's `+n −m`: the lines its worktree adds and removes against its base branch.

**Spec:** AiTerm's code, read on 14 October 2026:
- `AiTermCore/Git/DiffStatResolver.swift`
- `BaseDiff` in `AiTermCore/Sidebar/SidebarModel.swift`
- `Badge.Diff` and `SidebarRows`' editor badge

M4c deferred this detail. The user asked for it on 14 October 2026.

## Global Constraints
- **What is counted:** everything since the worktree left its base — commits, uncommitted edits and untracked files. Ignored and binary files don't count.
- **Untracked files:** capped at 2,000 files and 20 MB, and a file over 1 MB is skipped.
- **Cost:**
  - an answer is kept for 5 s per worktree;
  - the merge-base is kept until a ref it depends on moves;
  - an untracked file is read again only when its `lstat` changes;
  - a git timeout keeps the last answer and leaves the worktree alone for 30 s.
- **Display:** a task with nothing changed, no base, or no answer yet shows the plain badge. The tooltip reads "Open in VS Code — 12 added, 3 removed against main".
- **Tests:** they touch only scratch repositories, never the network.
- macOS 13; design tokens; AiTerm's copy; commits by path, ending `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; never push.

## Review Focus
1. **A local base behind origin's.** Expected: the later merge-base wins, so work already merged upstream isn't counted. Test: `aStaleLocalBaseUsesOrigins`.
2. **A worktree folder deleted on disk.** Expected: no answer and no error banner; the badge goes plain.
3. **Many windows over one workspace.** Expected: one git run per worktree per 5 s, however many windows ask.

---

### Task 1: Core `DiffStats`
- `DiffStat { added, removed }`.
- `DiffStats(git:now:ttl:cap:)`:
  - `diff(for:base:)` and `diffs(for tasks:)`;
  - a shared instance, `DiffStats.shared(launcher:)`.
- Tests (`DiffStatsTests`, real scratch repositories):
  - `committedAndUncommittedLinesCount`
  - `untrackedFilesCountTheirLines`
  - `binaryAndIgnoredFilesDoNotCount`
  - `anAnswerIsKeptForItsTime`
  - `aStaleLocalBaseUsesOrigins`
  - `noBaseIsNoAnswer`
  - `lineCountMatchesGit`

### Task 2: The sidebar
- `SidebarModel.diffs: [UUID: DiffStat]`, published only when changed.
- `refreshDiffs()` runs off the main actor, one run at a time.
- The app's 1 s tick calls it for every sidebar.
- `TaskRow` hands `VSCodeBadge` a `Badge.Diff` and AiTerm's help text.
- Tests:
  - `diffsAreReadForEachTask`
  - `anUnchangedDiffRedrawsNothing`
  - `theBadgeHelpNamesTheBase`

### Task 3: Verify
- Build; the package and `ShellforgeHostTest` pass; features.md says it.
