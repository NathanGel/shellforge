# M1d-3 Remove Task (worktree cleanup) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A task row's "Remove Task…" removes the task as AiTerm does, in this order:
1. It asks first, offering "Also delete branch".
2. It asks again before deleting uncommitted work.
3. It closes the task's tabs.
4. It deletes the worktree and, when asked, the branch. A branch whose commits its base lacks is kept unless the person agrees to lose them.
5. It drops the row.

**Architecture:**
- **ShellforgeCore:** `TaskRemoval` ports AiTerm's `TaskWorkflow.remove` and its `Repository` worktree helpers (`hasUnsavedWork`, `removeWorktree`, the leftover clean-up, `isMerged`) onto Shellforge's `CommandLauncher` git.
- **ShellforgeUI:**
  - `TaskRemover` ports the person's half of AiTerm's `TaskRemover`.
  - It asks through a `Prompter` (`NSAlert` in the app, a fake in tests).
  - It closes tabs through a new `TerminalHost.closeTabs(ofTask:)`.
  - It shows its state on the row.
- **The app's host** closes every tab tagged with the task in every iTerm2 window.

**Tech Stack:** Swift 6 language mode, macOS 13, SwiftUI + AppKit; Swift Testing via `Shellforge/scripts/swift.sh`; ModernTests (XCTest) for the app's host.

**Spec:**
- **Shellforge PRD (Claude Doc 89fd80a8-5fcf-4423-a8d6-c62f8512a481), W7:** "worktree cleanup, as in AiTerm".
- **The user:** "exactly what aiterm is".

## Global Constraints

- **Source:** AiTerm (`~/aiterm`, GPLv3, Laurens D'Hondt), pinned at `c1f851e574d0c8dd45a95957449c8798d60b65f4`.
  - Ported files start `// Ported from AiTerm (app/Sources/<path>.swift), GPLv3, Laurens D'Hondt.`.
  - Nothing in `~/aiterm` changes.
- **Every git call** goes through `CommandLauncher` (`SourceRulesTests.onlyChildProcessCreatesAProcess`), never on the main actor: use `BackgroundWork.run`.
- **Deletion is git's or the leftover rule's only:**
  - A folder is deleted directly only when it sits directly under the project's `.worktrees/`, is not a symlink, and git no longer knows it.
  - A branch with commits its base lacks goes only after the person agrees to lose them.
- **Tests** use temporary repositories (`GitRepoFixture`) and read no real home, `UserDefaults.standard`, keychain or network. Hosted waits sleep (`Task.sleep`).
- **macOS 13:** no `@Observable`, no `Mutex`.
- **Commits** end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; stage by path; never push.

**Rulings carried in**, ledgered at Task 1:
- **No lock on create:** Shellforge does not lock worktrees as AiTerm's create does. Removal still unlocks a locked one first, and puts back its reason if git then refuses.
- **No action banners or toasts:** Shellforge has neither banners with buttons nor toasts.
  - AiTerm's "branch kept" banner with Keep/Delete becomes an alert asked at once: "Delete branch X?", with Delete Branch or Keep Branch.
  - A removal that stops says why in `lastError` and on its row.
  - A finished removal shows no toast: the row goes.
- **No checkout monitor:** a worktree deleted outside Shellforge (AiTerm's `CheckoutRemovals`) waits for one. Removal itself copes with a missing or half-removed worktree.
- **No ⌘⌫ shortcut:** Shellforge has no keyboard-focused rows yet, so removal is in the context menu only.
- **No reviews yet:** the review-specific branch rules wait for M1d-4 (reviews).

## Review Focus

1. **A worktree with uncommitted changes.**
   - Nothing is deleted until the person picks "Delete Changes and Remove".
   - "Keep Task" (also on ⎋) leaves the task, its tabs and its files.
   - Test: Task 3 `uncommittedChangesAskBeforeAnythingCloses`.
2. **A branch whose commits are not on its base, with "Also delete branch" ticked.**
   - The worktree goes and the branch stays until "Delete Branch" is chosen.
   - "Keep Branch" removes the task and leaves the branch.
   - Tests: Task 1 `anUnmergedBranchIsKeptAndDeletedOnlyOnRequest`; Task 3 `anUnmergedBranchAsksBeforeItsCommitsGo`.
3. **A worktree folder already gone, or half-removed by git.**
   - Remove still finishes, and never deletes a folder outside `.worktrees/`.
   - Tests: Task 1 `aRemovalGitGaveUpOnHalfwayIsFinishedByTheNext`, `aFolderOutsideTheWorktreesIsNeverDeleted`, `aMissingWorktreeIsPrunedAndTheTaskStillGoes`.
4. **Remove clicked twice, or while a removal runs.** One removal runs; the menu item is disabled meanwhile.
   - Test: Task 3 `aSecondRemoveWhileOneRunsDoesNothing`.
5. **Git refusing the removal** (a file locked, permissions).
   - The row stays, with "Not removed"; the banner says git's reason; the tabs already closed stay closed; nothing else is deleted.
   - Test: Task 3 `aRefusedRemovalKeepsTheRowAndSaysWhy`.

---

### Task 1: TaskRemoval (core)

**Files:**
- Create (port): `Shellforge/Sources/ShellforgeCore/Workspace/TaskRemoval.swift`, from:
  - `AiTermCore/Tasks/TaskWorkflow.swift:75-152`: `hasUnsavedWork`, `remove`, `deleteUnmergedBranch`;
  - `AiTermCore/Git/Repository+Worktrees.swift:97-145`: `hasUnsavedWork(at:)`, `removeWorktree`, `removeRegistered`, `deleteLeftover`;
  - `AiTermCore/Git/Repository.swift:100-108`: `isMerged`.
- Test (port): `Shellforge/Tests/ShellforgeCoreTests/Workspace/TaskRemovalTests.swift`.

**Interfaces:**
- Produces:

```swift
public enum TaskRemoval {
    public enum BranchRefusal: Equatable, Sendable { case notMerged(base: String), other(reason: String) }
    public struct Removed: Equatable, Sendable { public var branchRefusal: BranchRefusal? }
    /// git's own check: whether `git worktree remove` would refuse without --force. False for a
    /// folder git does not know as a worktree.
    public static func hasUnsavedWork(task: TaskItem, project: Project, launcher: CommandLauncher) throws -> Bool
    /// The worktree (or its leftover, or its stale registration), then the branch when asked.
    public static func remove(task: TaskItem, project: Project, deleteBranch: Bool, force: Bool,
                              launcher: CommandLauncher) throws -> Removed
    /// `git branch -D`, once the person agreed to lose the commits.
    public static func deleteUnmergedBranch(of task: TaskItem, in project: Project, launcher: CommandLauncher) throws
}
```

`git` here is `launcher.run("git", ["-C", dir] + args)`; a non-zero status throws `GitFailure(command:message:)`, as in `TaskWorktrees`.
- **Is it a registered worktree:** `git worktree list --porcelain`, matching the `worktree <path>` lines after resolving both sides with `URL(fileURLWithPath:).resolvingSymlinksInPath().path` (macOS temp paths are `/var` → `/private/var`). Also take the `locked <reason>` line that follows.
- **Not fully merged:** branch deletion refused with "not fully merged" in stderr maps to `.notMerged(base:)`. Any other failure maps to `.other(reason: stderr first line)`.

- [ ] **Step 1: Port the tests.** Each builds a task with `TaskWorktrees.create(title:in:base:launcher:)` on a `GitRepoFixture`. The AiTerm sources are `TaskWorkflowTests` 7, 58, 76, 96, 116, the `deleteUnmergedBranch` case after them, and `WorktreesTests` 163, 190, 202, renamed:
  - `anUnmergedBranchIsKeptAndDeletedOnlyOnRequest` (port of `removalRetainsUnmergedBranchAndRetryOnlyDeletesBranch`, plus `deleteUnmergedBranch` dropping it).
  - `aRefusedRemovalKeepsTheCheckoutAndItsLock`. The worktree is locked by hand with `git worktree lock --reason mine`. A dirty file without `force` makes removal throw. Expect the file kept and `locked mine` still listed.
  - `aRemovalGitGaveUpOnHalfwayIsFinishedByTheNext`.
  - `aMergedBranchGoesWhileAnotherBranchIsCheckedOut`.
  - `aBranchMissingFromItsBaseStaysWhileAnotherBranchIsCheckedOut`.
  - `aFolderOutsideTheWorktreesIsNeverDeleted`.
  - `unsavedWorkIsWhatRemoveWouldRefuse`.
  - `aMissingWorktreeIsPrunedAndTheTaskStillGoes`. The folder is deleted by hand with `rm -rf`, leaving git's record. Expect `remove` to succeed, and `git worktree list` to no longer list it.

Example, for the first:

```swift
@Test func anUnmergedBranchIsKeptAndDeletedOnlyOnRequest() throws {
    let repo = try GitRepoFixture()
    let task = try TaskWorktrees.create(title: "Fix login", in: repo.project, base: "main", launcher: repo.launcher)
    try repo.git(["commit", "-q", "--allow-empty", "-m", "work"], in: task.worktreePath)
    let result = try TaskRemoval.remove(task: task, project: repo.project, deleteBranch: true, force: true, launcher: repo.launcher)
    #expect(result.branchRefusal == .notMerged(base: "main"))
    #expect(!FileManager.default.fileExists(atPath: task.worktreePath))
    #expect(!(try repo.git("branch", "--list", task.branch)).isEmpty)
    try TaskRemoval.deleteUnmergedBranch(of: task, in: repo.project, launcher: repo.launcher)
    #expect(try repo.git("branch", "--list", task.branch).isEmpty)
    // Removing again is a finished retry, not an error.
    #expect(try TaskRemoval.remove(task: task, project: repo.project, deleteBranch: true, force: false, launcher: repo.launcher).branchRefusal == nil)
}
```

- [ ] **Step 2: Run** `--filter TaskRemovalTests`. Expected: the build fails.
- [ ] **Step 3: Port `TaskRemoval.swift`.**
- [ ] **Step 4: Run the filter.** Expected: 8 pass. Then the whole package; expected: pass.
- [ ] **Step 5: Commit:** "Removing a task's worktree and branch, as AiTerm's TaskWorkflow does".

### Task 2: Closing a task's tabs

**Files:**
- Modify: `Shellforge/Sources/ShellforgeUI/SidebarModel.swift`, `TerminalHost`. Add:
  ```swift
  /// Closes every tab tagged with the task, in every window — what removing it starts with. True
  /// once none is left open.
  func closeTabs(ofTask id: UUID) -> Bool
  ```
- Modify: `sources/TerminalView/iTermShellforgeSidebar.swift`, `iTermShellforgeHost.closeTabs(ofTask:)`:
  - For each `PseudoTerminal` in `iTermController.sharedInstance().terminals()`, and each of its `tabs()` where any pane's `ShellforgeTags.task` value equals `id.uuidString.lowercased()`, call `terminal.closeTab(tab)`.
  - Then return whether any such tab remains.
  - Read `PseudoTerminal.h` to confirm `closeTab:` closes without a confirmation sheet; if it needs `soft`, use the variant that skips the prompt, and ledger it.
- Modify: the fake hosts in the UI tests (`FakeTerminalHost`, and any other conformer: grep `: TerminalHost`). Each records the ids it was asked to close, drops those tabs, and returns `closesTabs` (default `true`).
- Test: `ModernTests/ShellforgeHostTest.swift` (existing). Add `testClosingATasksTabsLeavesTheOthers`, built the way that file's existing tests open a tagged tab:
  1. Open two tabs, one tagged with task A and one with task B.
  2. Call `closeTabs(ofTask: A)`.
  3. Expect A's gone, B's open, and the return value `true`.

- [ ] **Step 1: Write the ModernTests case**, after reading how the file's tests make a window and tag a session. Run:
  `xcodebuild test -project iTerm2.xcodeproj -scheme ModernTests -configuration Development -skipPackagePluginValidation CODE_SIGN_IDENTITY=- -only-testing:ModernTests/ShellforgeHostTest`
  Expected: compile failure (no `closeTabs`).
- [ ] **Step 2: Add the requirement, the fakes, the app's implementation.**
- [ ] **Step 3: Run the ModernTests filter.** Expected: pass. Then the package; expected: pass.
- [ ] **Step 4: Commit:** "The sidebar's host closes every tab of a task, in every window".

### Task 3: TaskRemover, the row, and the menu

**Files:**
- Create: `Shellforge/Sources/ShellforgeUI/Removal/Prompter.swift`:

```swift
/// A question the removal asks: AiTerm's `AlertPrompt`.
public struct AlertPrompt: Equatable, Sendable {
    public var message: String, detail: String, buttons: [String]
    public var checkbox: String? = nil
    /// The button ⎋ presses; AiTerm's `escape`.
    public var escape: Int? = nil
    /// The first button is destructive and the default (↩): AiTerm's `defaultDeletes`.
    public var defaultDeletes = false
}
public struct AlertAnswer: Equatable, Sendable {
    public var button: Int, checked: Bool
    public var confirmed: Bool { button == 0 }
}
@MainActor public protocol Prompter: AnyObject { func ask(_ prompt: AlertPrompt) async -> AlertAnswer }
```

- Create: `Shellforge/Sources/ShellforgeUI/Removal/AlertPrompter.swift`, the app's `Prompter`:
  - It shows an `NSAlert` as a sheet on the sidebar's window (`WindowAnchor`), with `showsSuppressionButton` for `checkbox`.
  - `hasDestructiveAction` (macOS 11+) applies when `defaultDeletes`.
  - ⎋ is mapped through the button's `keyEquivalent = "\u{1b}"` for `escape`.
  - It is untested: AppKit's alert, read by the review.
- Create (port): `Shellforge/Sources/ShellforgeUI/Removal/TaskRemover.swift`, from `AiTerm/TaskRemover.swift`'s `confirmRemove`, `removeWorktree`, `confirmDeletingUnsavedWork`, `finishRemoval` and `forget`, with the Task 1 rulings applied. The copy is verbatim from AiTerm, task wording:
  - **First question:** message `Remove task “<title>”?`, detail `Deletes the worktree and closes its tabs:\n\n<worktreePath>`. Buttons `Remove`, `Cancel`; checkbox `Also delete branch <branch>`; `defaultDeletes: true`.
    - The word "tabs" replaces AiTerm's "iTerm2 window": a Shellforge task is tabs.
  - **Unsaved work:** message `The worktree has uncommitted changes`, detail `Removing this worktree permanently deletes its uncommitted changes and untracked files.`, buttons `Keep Task`, `Delete Changes and Remove`; `escape: 0`.
  - **Not merged:** message `Delete branch <branch>?`, detail `It has commits that aren’t on <base>. Deleting the branch deletes them too.`, buttons `Delete Branch`, `Keep Branch`; `defaultDeletes: true`.
  - **Order:**
    1. Ask the first question.
    2. If `hasUnsavedWork`, ask about the changes; keeping stops here with nothing changed.
    3. `host.closeTabs(ofTask:)`; false → stop with "Not removed: its tabs did not close".
    4. `TaskRemoval.remove` off the main actor.
    5. `.notMerged` → ask; Delete runs `deleteUnmergedBranch`. `.other(reason)` → `lastError = "Branch <branch> kept: <reason>"`, and the task still goes.
    6. The row goes: `document.update { $0.tasks.removeAll { $0.id == task.id } }`.
  - **Failure:** any thrown error leaves the row, with `removals[id] = .stopped("Not removed")` and `lastError = "Couldn’t remove the task. <reason>"`.
  - **One at a time:** `removals[id] = .removing` while running; a second `confirmRemove` for the same id returns at once.
- Modify: `SidebarModel.swift`:
  - `public let remover: TaskRemover`, built with the model's `document`, `host`, `launcher` and a `prompter` init parameter (default: a `NullPrompter` that answers Cancel, which the app replaces). Its `lastError` writes through to the model's `lastError`.
  - `@Published public private(set) var removals: [UUID: RowRemoval]`, where `enum RowRemoval: Equatable { case removing, stopped(String) }`, mirrored from the remover.
- Modify: `ShellforgeSidebar.swift`:
  - The app passes `AlertPrompter(anchor:)`.
  - The task row gets `removal: model.removals[node.id]` and `remove: { Task { await model.remover.confirmRemove(taskId: node.id) } }`.
- Modify: `Sidebar/SidebarRows.swift` `TaskRowView`:
  - `.contextMenu { Button("Remove Task…", role: .destructive, action: remove).disabled(removal == .removing) }`.
  - While `removing`, the badge line becomes `RowCaption("Removing…")`. A `stopped(note)` shows `RowCaption(note, warns: true)`. Check `RowCaption`'s signature in `SidebarRowParts.swift`, and port AiTerm's if it is missing.
- Modify: `sources/TerminalView/iTermShellforgeSidebar.swift`: `ShellforgeSidebar.makeView` passes the prompter through (add the parameter).
- Test: `Shellforge/Tests/ShellforgeUITests/TaskRemoverTests.swift` (new), on a `GitRepoFixture`-style repo.
  - It uses a `ScriptedPrompter`, which answers a queue of `AlertAnswer`s and records each `AlertPrompt`.
  - It uses `FakeTerminalHost` with a tab tagged with the task.
  - Cases:
    - `removingATaskClosesItsTabsThenDeletesItsWorktreeAndRow`: answer Remove, unchecked. Expect the prompts' messages, `closeTabs` called before the worktree vanished, the worktree gone, the branch kept, the row gone.
    - `alsoDeletingTheBranchDeletesAMergedOne`: checked, nothing on the branch. Expect the branch gone.
    - `cancelChangesNothing`.
    - `uncommittedChangesAskBeforeAnythingCloses`: a dirty file. Answer Remove, then Keep Task. Expect no `closeTabs` call and the file kept. Then a second run answering Remove and `Delete Changes and Remove`: everything goes.
    - `anUnmergedBranchAsksBeforeItsCommitsGo`: a commit, checked. Answer Remove, then Keep Branch: the row is gone, the branch stays. A second task answers Delete Branch: the branch is gone.
    - `aSecondRemoveWhileOneRunsDoesNothing`: the prompter's first answer is held on a continuation. A second `confirmRemove` returns at once and asks nothing.
    - `aRefusedRemovalKeepsTheRowAndSaysWhy`:
      - Make git refuse: `chmod 0555` on the project's `.worktrees` directory, so the worktree folder cannot be unlinked. Restore it in `defer`.
      - Use `force: true` through a dirty worktree, answering Delete Changes.
      - Expect the row kept, `removals[id] == .stopped("Not removed")`, and `lastError` starting "Couldn’t remove the task.".
      - If `chmod` doesn't make git fail on this macOS, use a worktree locked twice (`git worktree lock`, then make `.git/worktrees/<name>/locked` read-only). Ledger the method.
    - `tabsThatWillNotCloseStopTheRemoval`: the fake returns `false`. Expect the worktree kept and the row's note "Not removed: its tabs did not close".

- [ ] **Step 1: Write the tests.** Run `--filter TaskRemoverTests`. Expected: the build fails.
- [ ] **Step 2: Implement as listed.**
- [ ] **Step 3: Run the filter, then the package** (with `DesignRulesTests`). Expected: pass.
- [ ] **Step 4: Commit:** "Remove Task…: tabs closed, worktree and branch removed as AiTerm removes them, asking first".

### Task 4: Verify in the app

- [ ] Build the app. Expected: `** BUILD SUCCEEDED **`.
- [ ] Run the ModernTests `ShellforgeHostTest` filter again. Expected: pass.
- [ ] The live check waits for the user: right-click a task › Remove Task…; tick "Also delete branch"; check the tabs close, `.worktrees/<slug>` is gone and the row goes.
