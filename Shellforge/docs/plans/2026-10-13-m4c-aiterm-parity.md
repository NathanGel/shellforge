# M4c The AiTerm features not yet ported — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the five things AiTerm has that Shellforge still lacks:
- New Terminal.
- Dividers.
- Rename.
- Open in Finder and Open in VS Code.
- The Dock badge.

AiTerm's behaviour, read from its code on 13 October 2026, is the spec, except where a Shellforge task is a set of tabs rather than a window.

**Architecture and the AiTerm behaviour each part follows:**

1. **Terminals** (AiTerm `TerminalItem`, `TerminalActions`):
   - `Workspace.terminals: [TerminalItem]` stores `{id, projectId, name, createdAt}` and is saved with the workspace.
   - A terminal's tabs carry the user variable `shellforge.terminal = <id>`, as a task's carry `shellforge.task`.
   - Its row sits under its project, after the tasks. It shows the agents in its tabs, or a `>_` mark, and their status.
   - Selecting it shows its first tab, or opens one in the **project folder** with no command (Shellforge's equivalent of AiTerm's Reopen Window, as for tasks).
   - New Terminal… (⌃⌘T, the "+" menu, the project's context menu) asks for a name. The default is "Terminal", then the lowest free "Terminal n" in that project.
   - Remove Terminal closes its tabs and drops the row, with no confirmation: nothing on disk is touched.
2. **Dividers** (AiTerm `SidebarDivider`, `AppState.move`):
   - `Workspace.dividers: [SidebarDivider]`, each `{id, name, position}`. `position` counts the projects above it; dividers with the same position keep their saved order.
   - A divider is drawn as a hairline, its uppercase name, then a hairline; with no name, a single hairline.
   - Add Divider… (⌃⌘D, and the sidebar header's "+") appends it at the end.
   - Rename… (an empty name is a plain rule), Move Up and Move Down, Remove Divider. No confirmation.
   - Projects gain Move Up and Move Down. A project moving one step crosses an adjacent divider instead of swapping with the next project.
   - `SidebarLayout` holds the move rules as pure functions.
3. **Rename** (AiTerm `NameSheet`, `RenameTarget`):
   - A name sheet renames a task or review, a terminal, or a divider. Projects have no Rename, as in AiTerm.
   - A task's branch and worktree keep their names.
   - An empty name keeps the old one, except for a divider, which it turns into a plain rule.
   - The copy is AiTerm's.
4. **Open in…** (AiTerm `ExternalApps`):
   - Open in Finder and Open in VS Code, in the context menus of a project (its folder), a task or review (its worktree) and a terminal (its project folder).
   - VS Code is found once by bundle id `com.microsoft.VSCode`. Without it, its items are absent, not greyed.
   - Task and terminal rows carry a plain VS Code badge. AiTerm's `+n −m` lines-changed detail is left for later.
5. **Dock badge** (AiTerm `DockBadge`):
   - The number of task and terminal rows waiting on you (needing input, or done and unseen), skipping tasks being removed — the same rows Focus View shows.
   - No badge at zero. It is set only when it changes.

**Tech Stack:** Swift 6 language mode, macOS 13, SwiftUI; Swift Testing via `Shellforge/scripts/swift.sh`; Objective-C only in `iTermApplicationDelegate.m`'s Shellforge block.

**Spec:** the PRD's goal "visually and functionally AiTerm inside an iTerm2 fork". AiTerm's code is the reference (`app/Sources/AiTerm/{TerminalActions,ProjectActions,SheetKind,ExternalApps}.swift`, `AiTermCore/{Models,Interface/DockBadge}.swift`). Ported files carry the AiTerm credit header.

## Global Constraints

- Workspace files saved before M4c load unchanged: `terminals` and `dividers` decode as empty when missing.
- No test reads the real home, `UserDefaults.standard` or launches an app. VS Code's presence is injected, and so is the Dock badge's setter.
- New keys follow M4b's rule: ⌃⌘ and a key iTerm2's main menu leaves free. ⌃⌘T and ⌃⌘D are free (iTerm2's T and D items carry ⇧). `ShellforgeHostTest` checks them.
- macOS 13; design tokens only; `Metrics.swift` stays AiTerm's. Commits by path, ending `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; never push.

## Review Focus

1. **A divider at the top or the bottom, then Move Up or Down.** Expected: greyed at the ends, and never lost. Test: Task 2 `dividersMoveAndStopAtTheEnds`.
2. **A project moved past a divider.** Expected: it crosses the divider; the divider stays put relative to the other projects. Test: Task 2 `aProjectCrossesAnAdjacentDivider`.
3. **Removing a project that has terminals.** Expected: its terminals go with it, their tabs closed. Test: Task 1 `removingAProjectTakesItsTerminals` (wherever project removal exists; otherwise a ruling).
4. **A terminal's tab closed in iTerm2.** Expected: the row stays, and selecting it opens a new tab, as a task's does. Test: Task 1 `aTerminalWithNoTabOpensOneWhenSelected`.
5. **The Dock badge with two windows.** Expected: one count for the app, not per window. Test: Task 5 `theBadgeCountsOnceForTheApp`.

---

### Task 1: Terminals
- Core:
  - `Workspace/TerminalItem.swift`: `TerminalItem`, and `suggestedName(in:)` (AiTerm's).
  - `Workspace.terminals`, decoded `?? []`.
  - `SidebarTree` gains each project's `terminals: [TerminalNode {terminal, tabs}]`, read from `ShellforgeTags.terminal`.
- UI:
  - `TerminalRowView` (AiTerm's `TerminalRowView`).
  - `SidebarRow.terminal`.
  - `SidebarModel` gains `newTerminal(name:in:)`, `select(terminal:)`, `removeTerminal(_:)` and `renameTerminal(_:to:)`.
  - `TerminalHost.openTab(in:terminalId:projectId:title:)` tags the tab.
  - `SidebarCommand.newTerminal` (⌃⌘T).
  - The "+" and context menus gain New Terminal…
- App: the host's tags and its terminal tabs.
- Tests: `TerminalsTests`
  - `aNewTerminalOpensATabInTheProjectFolder`
  - `namesAreTerminalThenTerminalN`
  - `aTerminalWithNoTabOpensOneWhenSelected`
  - `removeClosesItsTabsAndDropsTheRow`
  - `anOldWorkspaceHasNoTerminals`
  - `terminalsShowTheirAgentsAndStatus`
- Test: `TaskRemovalTests`-style `removingAProjectTakesItsTerminals`, if the workspace removes projects; otherwise a ruling.

### Task 2: Dividers and moving
- Core:
  - `Workspace/SidebarLayout.swift`: `SidebarDivider`, and `SidebarLayout.entries(projects:dividers:)` in draw order.
  - `moveProject(_:up:)`, `moveDivider(_:up:)`, `canMove…`.
  - `Workspace.dividers`, decoded `?? []`.
- UI:
  - `DividerRow` (AiTerm's).
  - `SidebarRow.divider`; `rows` interleaves the dividers.
  - `SidebarModel` gains `addDivider(name:)`, `renameDivider`, `removeDivider` and the moves.
  - The header's "+" gets Add Divider…
  - `SidebarCommand.addDivider` (⌃⌘D).
  - A project's context menu gets Move Up and Move Down.
- Tests: `SidebarLayoutTests`
  - `dividersDrawBetweenProjectsByPosition`
  - `dividersMoveAndStopAtTheEnds`
  - `aProjectCrossesAnAdjacentDivider`
  - `projectsSwapWithNoDividerBetween`
  - `anOldWorkspaceHasNoDividers`
  - `anEmptyNameIsAPlainRule`

### Task 3: Rename
- UI:
  - `Rename/NameSheet.swift` (AiTerm's `NameSheet`) is also used for New Terminal's and Add Divider's names.
  - `RenameTarget` carries AiTerm's copy.
  - `SidebarModel` gains `renameTask(_:to:)`.
  - The task, review, terminal and divider context menus get Rename…
- Tests: `RenameTests`
  - `aTaskKeepsItsBranchAndWorktree`
  - `anEmptyNameKeepsTheOld`
  - `anEmptyDividerNameIsAPlainRule`
  - `theCopyIsAiTerms`

### Task 4: Open in Finder and VS Code
- UI:
  - `Sidebar/ExternalApps.swift` (AiTerm's) takes an injected `vsCodeInstalled` and `open(folder:in:)`.
  - Context menu items go on project, task, review and terminal rows.
  - A plain VS Code badge goes on task and terminal rows when it is installed.
- Tests: `ExternalAppsTests`
  - `eachRowOpensItsOwnFolder`
  - `vsCodeItemsAreAbsentWithoutIt`

### Task 5: The Dock badge
- UI:
  - `DockBadge.label(count:)` gives nil at 0, else the number.
  - `SidebarModel.waitingOnYou` adds terminals.
- App: `iTermShellforgeSidebar` updates `NSApp.dockTile.badgeLabel` from the shared document and the link's store, only when the label changes.
- Tests: `DockBadgeTests`
  - `zeroIsNoBadge`
  - `waitingTerminalsCount`
  - `theBadgeCountsOnceForTheApp`

### Task 6: Verify
- Build; the package and the daemon pass. `ShellforgeHostTest` covers ⌃⌘T and ⌃⌘D. `keyboard.md` gets both.
- Live check, for the user:
  1. New Terminal.
  2. A divider, moved.
  3. Rename a task.
  4. Open in VS Code.
  5. The Dock badge appears when a task needs input.
