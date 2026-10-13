# M5a The deferred review items — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the PRD's "Final pass" checklist. Every item the M2 and M4 reviews deferred is fixed or ruled on here, each fix with a test that failed first where code can show it. Performance (M5b), code structure (M5c) and the upstream rebase (M5d) are separate milestones.

**Spec:** the PRD's section "Final pass: performance, code quality and conventions", its checklist (rev 60), and the ledgers' deferred lines.

## Global Constraints

- Every fix is RED then GREEN, with the whole package, daemon suite and app build green after each task.
- Tests touch no real home, `~/.ssh`, `UserDefaults.standard`, login shell or network (source rules enforce two of these).
- macOS 13; design tokens; `Metrics.swift` stays AiTerm's. Commits by path, ending `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; never push.
- At the end, the PRD checklist marks each item done, or names the ruling that keeps it.

## Review Focus

1. A daemon change to the tunnel run loop (stop/start races) must not regress the M2b ledger tests. All of `test_tunnel*.py` stay green.
2. Parser changes to `~/.ssh/config` reading must not drop hosts that parse today. The existing `SSHConfigTests` stay green.
3. Marking a terminal seen must not mark a task seen, and the reverse. Test: Task 6 `seeingATerminalMarksOnlyItsTabs`.

---

### Task 1: Tunnel daemon details
- Stop then quick start: `stop()` broadcasts `stopped` only while the tunnel is still the alias's (a newer start may have replaced it). Test `aStopFollowedByAStartEndsConnecting`.
- Ledger write:
  - The temp file is removed when `json.dump` or `os.replace` fails.
  - `flush` and `fsync` run before the replace.
  - Test `aFailedLedgerWriteLeavesNoTempFile` (an unwritable target).
- "Permission denied (publickey)" alone is not `needsInput`: a tab cannot help without a key. Test `aMissingKeyNeedsNoTab`.
- `LocalForward` parsing:
  - A trailing `# comment` is dropped.
  - The `host/port` form is read.
  - A port outside 1–65535 drops that forward.
  - Tests in `SSHConfigTests`.

### Task 2: Tunnel UI details
- Tunnels menu actions go to the key window's sidebar (as the Tasks menu does), else the first.
- A menu item's action reads the tunnel's current state, so a stale item started from Open Quickly toggles correctly.
- On-launch starts are requested once per app: the set lives with the workspace document, as `RemovalBoard` does. Test `onLaunchIsAskedOncePerAppAcrossWindows`.
- Start before the config was read reads it first, rather than saying "isn't in ~/.ssh/config". Test `startingBeforeTheConfigIsReadReadsIt`.
- A folded project whose only rows are tunnels can unfold: `collapses` counts tunnels.
- The ports tooltip shows only while connecting or up. Test on `TunnelRowView.portsHelp` returning nil otherwise.
- The uptime line uses `.everyMinute` and is drawn only when there is a line.
- Answer in Tab on a host with no forward says "<alias> forwards no local port to watch." Test.
- Environment names that collide (`db-prod`, `db.prod`): both are left out, and the row's tooltip says why. Test `collidingNamesAreLeftOut`. Each extra forward gets `_PORT_2`, `_PORT_3`. Test.

### Task 3: Environment details
- A not-found re-read in `CommandLauncher.run` calls `onReload`, which the app wires to every sidebar's `environmentChanged()`. Test `aNotFoundReReadTellsTheSidebars`.
- The rc files watched follow the login shell:
  - zsh: `$ZDOTDIR` or `~` for `.zshenv`, `.zprofile`, `.zshrc`;
  - bash: `.bash_profile`, `.bash_login`, `.profile`, `.bashrc`;
  - fish: `~/.config/fish/config.fish`;
  - all of them: `/etc/paths` and `/etc/paths.d`.
  - Tests in `EnvironmentReportTests`.
- `EnvironmentReport` reads the environment and its read time in one locked snapshot (`CommandLauncher.snapshot`). Test.
- An agent given by absolute path shows its file name as the tool's name.
- `gitRunsOffTheMainThread` checks `addProject`'s read again, after `init`'s has finished.

### Task 4: Keys and sidebar layout details
- Hiding the sidebar while it holds keyboard focus gives the focus to the current session.
- The View menu's Hide Sidebar item is built from `SidebarCommandMenu.toggleSidebar`.
- The drag handle sits on the sidebar's border, half outside it, clear of its list's scroller.
- The terminal-minimum check subtracts the toolbelt's width when the toolbelt shows.
- Rulings, kept:
  - Focus and List View refold every window (AiTerm's semantics).
  - Restored windows take the global hidden flag.
  - ⌃⌘[ and ⌃⌘] on AZERTY: checked live by the user.

### Task 5: Menus, VoiceOver, empty states and docs
- The project menu order is AiTerm's: new items, Open in, then Jira Projects…, Tunnels… and SSH Host…, then Move Up and Move Down.
- A terminal row's menu has a separator between Rename… and Open in.
- VoiceOver actions on divider rows (Rename, Move Up, Move Down, Remove Divider, as each is enabled) and terminal rows (Rename, Remove Terminal).
- Open in is absent for an empty folder.
- With no projects, dividers are not drawn under the empty state.
- The rows builder computes the layout once per redraw and derives each divider's ends from its index.
- Stale docs: the `SidebarRows.swift` header; `keyboard.md`'s shadowed profile keys gain T and D.

### Task 6: Terminals seen, orphan tabs, and the Dock badge's setter
- Showing a done terminal marks its tabs' sessions seen (a `sessions.markSeen` by session ids, added to the daemon beside the task form). Tests:
  - daemon `test_mark_seen_by_sessions`;
  - Swift `seeingATerminalMarksOnlyItsTabs`.
- A tab tagged with a terminal whose project is gone falls back to "Other tabs". Test in `SidebarTree`.
- The Dock badge's change-only setter moves into `DockBadge.Setter(set:)`, tested with an injected setter.

### Task 7: Verify and close the checklist
- Build; the package, the daemon and `ShellforgeHostTest` pass.
- The PRD checklist marks each item done, or names its ruling.
