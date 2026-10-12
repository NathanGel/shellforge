# M2c Tunnels in the palette, and a project's SSH pane — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:**
- **Palette.** Every linked tunnel can be started and stopped from the command palette. In the fork, the palette is iTerm2's own Open Quickly (⇧⌘O), which already searches the main menu.
- **SSH pane.** A project can name one SSH host. New Task then offers "Open ssh <host> beside the agent", which splits the task's first tab: the agent on the left, `ssh <host>` on the right.

**Architecture:**
- **Palette:**
  - A View › Tunnels submenu lists "Start Tunnel <alias>" or "Stop Tunnel <alias>" per linked alias, by its state, and is rebuilt whenever the workspace or a tunnel's state changes.
  - Open Quickly's default search already walks the main menu (`addMenuItemsToItems`), so the items appear there with their path, and no upstream file beyond the delegate's menu set-up changes.
  - The items' titles and actions come from a tested Swift value, `TunnelMenu.items(workspace:store:)`.
- **SSH pane:**
  - `Project.sshHost: String?`, set in an "SSH Host…" sheet from the header's context menu: a `SearchPicker` over every concrete `Host` in `~/.ssh/config`.
  - `TaskDraft.openSSH`.
  - `TerminalHost.openTab(…, beside: String?)`. The app's host runs `asyncSplitVertically:before:profile:targetSession:…` on the new tab's session, with a profile typing `ssh <host>` in the task's worktree.

**Tech Stack:** Swift 6 language mode, macOS 13, SwiftUI; Objective-C for the one menu hook in `iTermApplicationDelegate.m`; Swift Testing via `Shellforge/scripts/swift.sh`.

**Spec:**
- PRD "Requirements: SSH tunnels": "Start and stop a tunnel from the sidebar and from the command palette."
- The user's request (memory `shellforge-ssh-per-project`, decided 12 October 2026): a project carries an SSH host, and a New Task checkbox opens it "on the side" as a split pane beside the agent in the task's tab.

## Global Constraints

- `~/.ssh/config` is only read. The pane's command is `ssh <alias>`, the alias passed through `AgentCommand.shellWord`, with nothing else added.
- Upstream iTerm2 files change only in `iTermApplicationDelegate.m`'s Shellforge block, beside Backpack Mode.
- Tests read no real home or `~/.ssh`; the config comes from a temporary file (`SSHConfigSource`).
- macOS 13; design tokens only (`DesignRulesTests`).
- Commits by path, ending `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; never push.

## Review Focus

1. **The same alias is linked in two projects.** Expected: one menu item, not two; the action is the same tunnel. Test: Task 1 `anAliasInTwoProjectsIsOneItem`.
2. **No window is open** (the app is running with every window closed). Expected: the items show but are disabled, so nothing crashes. Test: Task 1 `itemsNeedASidebarToAct`.
3. **The project's SSH host left the config.** Expected: New Task does not offer the pane, and the header's sheet says the host is gone. Test: Task 3 `aGoneHostIsNotOffered`.
4. **The tab could not be split** (iTerm2 refuses: a tmux tab, a window too small). Expected: the task still opens, and the sidebar says the pane could not open. Test: Task 3 `aRefusedSplitIsSaid` (the fake host refuses).
5. **A host alias with shell metacharacters** (`db*`, `a;b` cannot be a Host, but `db*` can be in a config). Expected: it is quoted. Test: Task 3 `thePaneCommandQuotesTheAlias`.

---

### Task 1: Tunnels in the palette

**Files:**
- Create: `Shellforge/Sources/ShellforgeUI/Tunnels/TunnelMenu.swift`:
  - `struct TunnelMenuItem { alias, title, starts: Bool }`.
  - `static func items(projects:store:) -> [TunnelMenuItem]`: each linked alias once, in project then tunnel order. The title is "Stop Tunnel <alias>" while it is connecting or up, and "Start Tunnel <alias>" otherwise.
- Modify: `sources/TerminalView/iTermShellforgeSidebar.swift`:
  - `@objc static func tunnelsMenu() -> NSMenu`: a menu kept current by observing the document and `DaemonLink.store`.
  - Each item's action goes to the first live sidebar model's `startTunnel` / `stopTunnel`, and is disabled when there is none.
- Modify: `sources/AppKit/iTermApplicationDelegate.m`: a "Tunnels" item with that submenu in the View menu, after Backpack Mode.
- Test: `Shellforge/Tests/ShellforgeUITests/TunnelMenuTests.swift`:
  - `eachLinkedAliasIsOneItemByItsState`
  - `anAliasInTwoProjectsIsOneItem`
  - `itemsNeedASidebarToAct` (the enabling rule as a static).

- [ ] Tests; run; fail.
- [ ] Implement; package passes; app builds.
- [ ] Commit: "Tunnels start and stop from the View menu, and so from Open Quickly".

### Task 2: A project's SSH host

**Files:**
- Modify: `Shellforge/Sources/ShellforgeCore/Workspace/Project.swift` (where `Project` lives): `sshHost: String?`, decoded with `decodeIfPresent`.
- Create: `Shellforge/Sources/ShellforgeUI/Tunnels/SSHHostSheet.swift`:
  - "SSH host for <project>": the current host as a `PickedItemField` with ✕, or a `SearchPicker` over every host alias, with Save and Cancel.
  - The statuses: "Reading ~/.ssh/config…", "No hosts in ~/.ssh/config.", and "<alias> is no longer in ~/.ssh/config."
- Modify: `SidebarModel+Tunnels.swift`: `setSSHHost(_:on:)`.
- Modify: `SidebarRows.swift` and `ShellforgeSidebar.swift`: "SSH Host…" in the header's context menu.
- Test: `Shellforge/Tests/ShellforgeUITests/SSHHostTests.swift`:
  - `settingTheHostSavesIt`
  - `clearingTheHostRemovesIt`
  - `theSheetOffersEveryConcreteHost`
  - `anOldProjectHasNoHost`

- [ ] Tests; run; fail.
- [ ] Implement; pass.
- [ ] Commit: "A project can name its SSH host".

### Task 3: The pane beside the agent

**Files:**
- Modify: `TaskDraft` gains `openSSH: Bool = true`. It is not saved with the task; it is remembered per project in `Workspace.lastOpenSSHByProject` (decoded `?? [:]`).
- Modify: `NewTaskSheet.swift`: on the prompt step, a checkbox "Open ssh <host> beside the agent", shown when the project's host is in the config.
- Modify: `TerminalHost.openTab(in:taskId:projectId:title:command:environment:beside:)`, where `beside: String?` is the pane's command. The fake host records it, and can refuse.
- Modify: `SidebarModel.newTask`: passes `beside` when the draft asks and the host is in the config. A refused split sets `lastError` = "The ssh pane couldn't open beside <task>."; the host reports a refusal through a new `onSplitRefused` callback.
- Modify: the app's host. After `launchBookmark`, its `didMakeSession` splits the new session vertically (after it, on the right) with a profile like the task tab's, in the same worktree, typing `ssh <alias>`. `canSplitPaneVertically:withBookmark:` is checked first.
- Test: `Shellforge/Tests/ShellforgeUITests/SSHPaneTests.swift`:
  - `aNewTaskOpensTheHostBesideTheAgent`
  - `untickedItOpensAlone`
  - `aGoneHostIsNotOffered`
  - `aRefusedSplitIsSaid`
  - `thePaneCommandQuotesTheAlias`
  - `theChoiceIsRememberedPerProject`

- [ ] Tests; run; fail.
- [ ] Implement; pass; app builds.
- [ ] Commit: "New Task can open the project's SSH host in a pane beside the agent".

### Task 4: Verify in the app

- [ ] Build (`** BUILD SUCCEEDED **`); package and daemon suites pass.
- [ ] Live check, for the user:
  1. ⇧⌘O, type "elastic": "Start Tunnel elastic-dev" or "Stop Tunnel elastic-dev" is listed; choose it, and the row changes.
  2. Right-click a project › SSH Host…, and pick a host.
  3. New Task with the box ticked: the task's tab has the agent on the left and `ssh <host>` on the right.
