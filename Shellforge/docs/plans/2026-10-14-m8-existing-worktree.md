# M8 Continue in an existing worktree — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:**
- New Task can continue in a worktree that already exists, instead of making a new one.
- Adding a project offers to import its worktrees as tasks, as AiTerm does.

**Spec:**
- The user's choices of 14 October 2026: inside New Task, as a New/Existing choice; and AiTerm's import offer when a project is added.
- AiTerm's `ProjectActions.importWorktrees` and `Worktree.importedKind`.

## Global Constraints
- Picking an existing worktree changes nothing in git: no branch, no checkout, no lock.
- **Offered:** every worktree of the project's repository that is on a branch, still on disk, and not already a task's.
- **Not offered:** the project's own checkout.
- **Kind:** a review's worktree (locked with `ReviewWorktrees.reviewLockReason`, or in a `review-` folder) becomes a review, never a task, so its merge request's branch is never offered for deletion.
- **Import copy (AiTerm's):** "Import N worktree(s)?", "Adds existing worktrees as tasks without starting agents.", buttons Import / Skip; ⎋ skips.
- macOS 13; design tokens; commits by path, ending `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; never push without a release.

## Review Focus
1. **A worktree taken by a task between the sheet opening and Create.** Expected: refused, with nothing changed.
2. **A worktree folder deleted on disk.** Expected: not offered; if picked before it went, refused at Create.
3. **Symlinked paths**, such as `/tmp` and `/private/tmp`. Expected: a worktree already a task's is never offered again.

---

### Task 1: Core `ExistingWorktrees`
- `ExistingWorktree { path, branch, kind, lastCommit }`.
- `ExistingWorktrees.list(project:taken:launcher:)`, newest commit first.
- `ExistingWorktrees.adopt(draft:in:launcher:)` returns the task.
- `ExistingWorktrees.imported(_:project:baseBranch:agent:model:reasoning:)` makes the import's tasks.
- `TaskDraft.useExisting` and `existing`: picking one names the task after its branch, unless the name was typed.
- Tests (`ExistingWorktreesTests`, real repositories):
  - `offersOnlyBranchesOnDiskThatAreNotTasks`
  - `newestFirst`
  - `aReviewsWorktreeImportsAsAReview`
  - `adoptingChangesNothingInGit`
  - `aWorktreeGoneOrTakenIsRefused`
  - `pathsAreComparedResolved`
  - `aPickedWorktreeNamesTheTask`

### Task 2: New Task and Add Project
- New Task's first step gets a New worktree / Existing worktree choice. Existing shows a list of the worktrees, with branch, folder and age, and an empty state. The branch fields hide, and the destination line names the folder.
- `newTask` adopts the worktree when one is picked.
- `addProject` offers the import.
- Tests:
  - `anExistingWorktreeBecomesATaskWithItsAgent`
  - `stepOneNeedsAPickedWorktree`
  - `addingAProjectOffersItsWorktrees`
  - `skippingImportsNothing`
  - `noWorktreesAsksNothing`

### Task 3: Verify
- Build; the package and `ShellforgeHostTest` pass; `features.md` says it.
