# M1d-4b New Review Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A project's "+" and context menu offer AiTerm's "New Review…". It picks one of the project's open merge requests (GitLab) or pull requests (GitHub), or just a branch. It checks that branch out in a review worktree, and starts the chosen agent there.

The row:
- wears the request's `!n` / `#n` badge;
- says "Review" in its menus;
- when removed, never deletes the branch on request. Instead it releases the local branch only when nothing would be lost, as AiTerm does.

**Architecture:**
- **ShellforgeCore:**
  - `TaskItem` gains AiTerm's `kind` (`TaskKind`) and `mr` (`MergeRequestRef`, ported in M1d-4a) with AiTerm's hand-written Codable.
  - `ReviewDraft` and `MergeRequestSearch` are ported.
  - A launcher-based `GitRepository` carries AiTerm's `Repository` helpers (`sha`, `commit`, `isAncestor`, `count`, `hasOrigin`, `fetchFromOrigin`, `fastForward`, `worktrees`).
  - On it, `addReviewWorktree` and `releaseReviewBranch` are ported.
  - `TaskRemoval.remove` takes the review rules.
- **ShellforgeUI:**
  - `NewTaskModel` becomes AiTerm's generic `CreationModel<Kind>` (a pure refactor, with `NewTaskModel` kept as the task form's name).
  - `ReviewCreation`, `NewReviewSheet` and the sidebar wiring are ported.
  - The task row gains the request badge.

**Tech Stack:** Swift 6 language mode, macOS 13, SwiftUI + AppKit; Swift Testing via `Shellforge/scripts/swift.sh`.

**Spec:**
- **Shellforge PRD (Claude Doc 89fd80a8-5fcf-4423-a8d6-c62f8512a481), W7:** "MR/PR review … as in AiTerm".
- **The user:** "exactly what aiterm is".

## Global Constraints

- **Source:** AiTerm (`~/aiterm/app`, GPLv3, Laurens D'Hondt), pinned at `c1f851e574d0c8dd45a95957449c8798d60b65f4`.
  - Ported files start `// Ported from AiTerm (app/Sources/<path>.swift), GPLv3, Laurens D'Hondt.`.
  - Nothing in `~/aiterm` changes.
- **Git:**
  - Every git call goes through `CommandLauncher`, off the main actor (`BackgroundWork.run`).
  - Remote calls (`fetch`, `ls-remote`) run with `GIT_TERMINAL_PROMPT=0` and a timeout, as `TaskWorktrees` already does.
- **No failure path deletes a branch holding anything origin lacks**, as AiTerm. A review's branch is never deleted on request.
- **Tests:**
  - Temporary repositories only.
  - "origin" is a second temporary repository (a bare clone), never the network.
  - No real home, Keychain or `UserDefaults.standard`.
  - Hosted waits sleep.
- **macOS 13:** no `@Observable`, no `Mutex`.
- **Commits** end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; stage by path; never push.

**Rulings carried in**, ledgered at Task 1:
- **Lock reason:** review worktrees are locked with reason `shellforge review`, AiTerm's `aiterm review` renamed. Task worktrees stay unlocked (M1d-3 ruling).
- **No "open in the task that already has the branch"** (AiTerm's `TaskLauncher.openReview`, `ReviewInTaskTests`). It needs AiTerm's `WorkInFlight.reviewing`. Until then, `addReviewWorktree`'s `branchCheckedOut` refusal says where the branch is. The destination line is always "a worktree of its own".
- **No toasts:** a kept review branch's reason goes to `lastError`, as M1d-3's kept-branch reasons do.
- **No ⌘R:** Shellforge does not own iTerm2's main menu for New Review. The menu items are in the sidebar's "+" and context menus.

## Review Focus

1. **A review of a branch already checked out elsewhere** (the project folder, or another task).
   - It is refused before anything is made, with AiTerm's "is checked out at …" copy.
   - Test: Task 2 (ported checkout cases).
2. **A local review branch with commits origin lacks** when the review is removed.
   - The branch is kept, and the reason ("2 commits aren't on origin") reaches the banner.
   - With nothing lost, the branch is deleted. Origin's branch is never touched.
   - Tests: Task 2 (ported release cases), Task 5 `removingAReviewKeepsAnUnpushedBranchAndSaysWhy`.
3. **The project's GitLab remote on a host other than the configured one, no connection, or a fork's PR.**
   - The request field says why (AiTerm's `Unavailable` and fork copy), and a branch can still be typed and the review created.
   - Tests: Task 1 (ported `MergeRequestSearchTests`), Task 4 (ported `ReviewCreationModelTests` cases).
4. **Typing the branch by hand after picking a request.** The request is dropped, so the badge cannot point at another branch's request.
   - Test: Task 1 (ported `ReviewDraftTests`).
5. **The `CreationModel` refactor.** New Task behaves exactly as before.
   - Tests: Task 3 (the existing `NewTaskModelTests`, `NewTaskSheetTests`, `TicketListTests`, `CompletionPopupLayeringTests`, unchanged and green).

---

### Task 1: Reviews in the model

**Files:**
- Modify: `Shellforge/Sources/ShellforgeCore/Workspace/Workspace.swift` `TaskItem`:
  - add `TaskKind` (AiTerm `Models.swift` 226-241), `mr: MergeRequestRef?`, `kind` with `savedKind`, and `kindName`;
  - write `init(from:)` / `encode(to:)` by hand as AiTerm 281-325 does, for Shellforge's own fields (string `agent`, no `appendTicket`/`firstPrompt`/`windowId`);
  - the init gains `kind: TaskKind = .task, mr: MergeRequestRef? = nil`.
- Create (port): `Shellforge/Sources/ShellforgeCore/Workspace/ReviewDraft.swift` (`AiTermCore/Tasks/ReviewDraft.swift`), with Shellforge's `agentId: String` for `agent: AgentKind`, and no `initial(state:)` (the sidebar builds the draft as `makeNewTaskModel` does).
- Create (port): `Shellforge/Sources/ShellforgeCore/Workspace/MergeRequestSearch.swift` (`AiTermCore/Tasks/MergeRequestSearch.swift`).
- Test (port):
  - `Shellforge/Tests/ShellforgeCoreTests/Workspace/TaskKindTests.swift`: `ModelsTests` 207, 315, 327 (kind round trip, an unknown kind reads as task and is written back, mr round trip).
  - `ReviewDraftTests.swift` (6, `testReviewWorktreeDirectoryIsPrefixed` against `BranchNaming.reviewSlug`).
  - `MergeRequestSearchTests.swift` (4).

- [ ] **Step 1: Port the tests.** Run `--filter "TaskKindTests|ReviewDraftTests|MergeRequestSearchTests"`. Expected: the build fails.
- [ ] **Step 2: Port as listed.**
- [ ] **Step 3: Run the filter, then the package.** Expected: 13 pass; the package is green (old workspaces still load: `WorkspaceStoreTests`).
- [ ] **Step 4: Commit:** "A task can be a review, of a merge request, as AiTerm's".

### Task 2: Review worktrees and their branches (core)

**Files:**
- Create: `Shellforge/Sources/ShellforgeCore/Workspace/GitRepository.swift`, a struct over a project path and a `CommandLauncher`. It ports the private helpers of AiTerm's `Repository.swift` 110-159 and `Repository+Worktrees.swift` 1-30 (`worktrees()` with each worktree's path, branch and lock reason).
  - `run(_:)` throws `GitFailure` on a non-zero status.
  - `ask(_:none:)` returns nil for the listed exit codes.
  - `runRemote(_:)` runs with `GIT_TERMINAL_PROMPT=0`, timeout 30.
- Create (port): `Shellforge/Sources/ShellforgeCore/Workspace/ReviewWorktrees.swift`, on `GitRepository`:
  - `addReviewWorktree(slug:branch:)` (`Repository+Worktrees.swift` 55-97), lock reason `shellforge review`, path `<project>/.worktrees/<slug>` with the `.worktrees/` exclude as `TaskWorktrees` writes it;
  - `releaseReviewBranch(_:target:)` with `ReviewBranchRelease` (`Repository+ReviewBranch.swift` 1-101);
  - the review cases of `WorktreeError` (`WorktreeError.swift` 6-10, 27-32) as `ReviewRefusal`;
  - `ReviewWorktrees.create(draft:in:launcher:) throws -> TaskItem` (`TaskCreator.swift` 99-112).
- Create (port): `Kept.note(branch:)` (`AiTerm/BranchOutcomeCopy.swift` 30-47) in the same file.
- Modify: `Shellforge/Sources/ShellforgeCore/Workspace/TaskRemoval.swift`.
  - `Removed` gains `keptBranch: ReviewBranchRelease.Kept?`.
  - For `task.kind == .review`, `remove` never deletes the branch on request. After the worktree goes it runs `releaseReviewBranch(task.branch, target: task.baseBranch)`, as AiTerm's `TaskWorkflow.remove` 83-104 does.
- Test (port), in `Shellforge/Tests/ShellforgeCoreTests/Workspace/`:
  - `ReviewWorktreesTests.swift`: the `WorktreesTests` review cases (checkout 327, 350, 368, 408, 418, 430, 447, 479, 487, 637; release 497, 516, 532, 547, 563, 578, 592, 601, 617, 629; lock reason 648, 662, 677), on a `GitRepoFixture` with an origin.
  - The `TaskCreatorTests` review cases (241-286).
  - `TaskWorkflowTests` 171 and 182 (`ReviewRemovalFixture`) into `TaskRemovalTests`.
  - `BranchOutcomeCopyTests.aKeptReviewBranchSaysWhy`.
  - `GitRepoFixture` gains `withOrigin()`: a bare clone set as `origin`, and pushing `main`.
  - Port AiTerm's fixture helpers as needed.

- [ ] **Step 1: Port the tests.** Run `--filter "ReviewWorktreesTests|TaskRemovalTests"`. Expected: the build fails.
- [ ] **Step 2: Port as listed.**
- [ ] **Step 3: Run the filter, then the package.** Expected: pass.
- [ ] **Step 4: Commit:** "A review's worktree on its merge request's branch, and its local branch let go only when nothing is lost, as AiTerm's".

### Task 3: CreationModel (refactor)

**Files:**
- Modify (rename by `git mv`): `Shellforge/Sources/ShellforgeUI/NewTask/NewTaskModel.swift` → `CreationModel.swift`.
  - Generic `CreationModel<Kind: CreationKind>` as AiTerm's `CreationModel.swift` 20-296 shapes it. `protocol CreationKind` carries `Draft`, `Item` (the search's), `slug`, `composedPrompt`, `draftChanged` and `confirmBeforeSubmit`, keeping what Shellforge's model does now.
  - `TaskCreation` holds what is task-only: the Jira search, the ticket placeholder, `jiraSearcher`.
  - `public typealias NewTaskModel = CreationModel<TaskCreation>`.
  - `AgentDraft` (a protocol for `agentId`, `model`, `reasoning`, `promptText`) is what the agent step reads; `TaskDraft` and `ReviewDraft` conform.
- Modify: `NewTaskSheet.swift`, `AgentStep.swift`, `PromptStep.swift`, `SidebarModel.swift`, only as the generic needs.

No new tests. Every existing test is the gate.

- [ ] **Step 1: Refactor.** Run the whole package. Expected: every existing test passes, unchanged; `git diff --stat` touches no test file.
- [ ] **Step 2: Commit:** "New Task's model becomes AiTerm's CreationModel, ready for New Review".

### Task 4: New Review

**Files:**
- Create (port): `Shellforge/Sources/ShellforgeUI/NewReview/ReviewCreation.swift` (`AiTerm/ReviewCreationModel.swift` 1-186, without `owningTask`/`loadCheckouts`, per the carried ruling).
- Create (port): `NewReview/CodeHost+Review.swift` (`AiTerm/Views/CodeHost+Review.swift` 1-12).
- Create (port): `NewReview/NewReviewSheet.swift` (`AiTerm/Views/NewReviewSheet.swift` 1-165) on Shellforge's `SheetLayout`/`StepBar`/`CreationFooter`. The MR list draws over the fields below with `.zIndex(1)`, and closes on a background tap, ⎋ and leaving step 1, as the ticket list now does.
- Modify: `Shellforge/Sources/ShellforgeUI/SidebarModel.swift`:
  - `makeReviewModel(for:)` reads the remote (`git remote get-url origin` → `ProviderDetector.detect`), the GitLab and GitHub settings through its readers, and `MergeRequestSearch.source`, off the main actor.
  - `newReview(draft:in:)` runs `ReviewWorktrees.create`, saves the task, and opens its tab with the agent and the typed prompt (no ticket), as `newTask` does.
- Modify: `Sidebar/SidebarRows.swift`:
  - The project "+" and context menu gain "New Review…", disabled when the project's provider is `.none` (AiTerm `SidebarRows.swift` 175-181).
  - The task row's badge line gains the request badge (`.brand(mr.host.brand)`, `mr.reference`, opening `mr.url` through `ExternalLink.open`), after the ticket's (AiTerm 364-367).
  - The context menu says "Remove \(kindName)…".
- Modify: `Removal/TaskRemover.swift`, with AiTerm's review copy (`TaskRemover.swift` 137-160, 269):
  - no "Also delete branch" checkbox for a review;
  - the review alert detail;
  - "Keep Review";
  - a kept review branch's `note(branch:)` in `lastError`.
- Modify: `ShellforgeSidebar.swift`: `showNewReview(in:)` in the `PanelSlot`.
- Test (port), in `Shellforge/Tests/ShellforgeUITests/`:
  - `ReviewCreationModelTests.swift`: AiTerm's 21 cases except those about the owning task, which are ledgered by name.
  - `NewReviewSheetTests.swift`: the 14, except owning-task ones.
  - `CodeHostReviewCopyTests.swift` (1).
  - In `ProjectJiraBadgeTests`, `aGitHubReviewWearsAHashNumber` (BadgeDetailsTests).
  - In `TaskRemoverTests`, `aReviewIsNeverOfferedItsBranch` and `removingAReviewKeepsAnUnpushedBranchAndSaysWhy`.

- [ ] **Step 1: Port and write the tests.** Run the filter. Expected: the build fails.
- [ ] **Step 2: Port and wire as listed.**
- [ ] **Step 3: Run the filter, then the package, `DesignRulesTests` included.** Expected: pass.
- [ ] **Step 4: Commit:** "New Review…: a merge request's or pull request's branch in a worktree of its own, as AiTerm reviews".

### Task 5: Verify in the app

- [ ] Build the app. Expected: `** BUILD SUCCEEDED **`.
- [ ] The live check waits for the user:
  1. With GitLab or GitHub connected, open New Review… on a project.
  2. Pick an open request; the review opens on its branch.
  3. Remove it; the branch is kept or released with a reason.
