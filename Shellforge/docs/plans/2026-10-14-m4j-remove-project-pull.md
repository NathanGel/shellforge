# M4j Remove Project and Pull Default Branch — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the last two project-menu items AiTerm has and Shellforge lacks: Remove Project…, and Pull <default branch>.

**Spec:** AiTerm's code, read on 14 October 2026:
- `ProjectActions.confirmRemove(project:)` and `pullDefault(project:)`;
- `Repository.pullDefaultBranch()`;
- `BranchOutcomeCopy`;
- `WorktreeError`.

The user chose these as next on 14 October 2026.

## Global Constraints

- **Remove Project** only forgets the project: no git command runs, and files, worktrees and tabs stay. Its tabs fall under Other tabs.
- **Pull** is fast-forward only: no merge, rebase or reset. Uncommitted changes in the checkout make git refuse it, and nothing is pushed.
- Shellforge has no toasts. A pull's outcome is an info banner that clears after 6 s; a refusal is the error banner.
- macOS 13; design tokens; AiTerm's copy; commits by path, ending `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; never push.

## Review Focus

1. **Removing a project while one of its tasks is being created or removed.** Expected: refused with AiTerm's "can't be removed yet".
2. **A project between two dividers removed.** Expected: the dividers keep their places relative to the other projects.
3. **Pull with local commits, or diverged.** Expected: "ahead, nothing to pull", or "has diverged", and the branch is left as it was.

---

### Task 1: Remove Project
- `SidebarModel.confirmRemove(project:)`:
  - AiTerm's alert: the worktrees it keeps listed, Remove / Cancel.
  - After a yes, it re-checks that nothing is busy. Busy means a task being created in the project (`working`), or one of its tasks being removed (`removals`).
  - It removes the project, its tasks and its terminals. Dividers below it move up one.
- The project menu ends with a separator and **Remove Project…**.
- Tests (`RemoveProjectTests`):
  - `removingAProjectForgetsItAndItsTasksAndTerminals`
  - `theAlertListsTheWorktreesKept`
  - `cancelKeepsEverything`
  - `aBusyProjectIsNotRemoved`
  - `dividersKeepTheirPlace`

### Task 2: Pull Default Branch
- Core:
  - `GitRepository.pullDefaultBranch(_ branch:) -> DefaultBranchPull` (`upToDate`, `fastForwarded(commits:)`, `ahead(commits:)`).
  - `DefaultBranchError`: `noOrigin`, `noLocalBranch`, `diverged(local:remote:)`, with AiTerm's words.
- Model:
  - `defaultBranches[projectId]` is read with the provider.
  - `pullDefault(project:)` runs off the main actor, one per project at a time.
  - It sets `notice` with AiTerm's toast words, cleared after 6 s; a failure sets `lastError`.
- UI:
  - **Pull <branch>** in the menu of a GitLab or GitHub project, greyed while pulling.
  - The banner gains `notice` (info).
- Tests:
  - `PullDefaultBranchTests` (Core, real repos with a local bare origin):
    - `aBehindBranchFastForwards`
    - `upToDateSaysSo`
    - `localCommitsAreLeft`
    - `divergedIsRefused`
    - `uncommittedChangesInTheCheckoutAreRefused`
  - `pullSaysItsOutcome` (UI).

### Task 3: Verify
- Build; the package and `ShellforgeHostTest` pass; features.md gains both items.
