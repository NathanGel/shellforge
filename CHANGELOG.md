# Changelog

What changed in each Shellforge version, newest first. Every feature is described in
[FEATURES.md](FEATURES.md). Versions follow [the release rules](Shellforge/docs/releasing.md#versions):
a patch fixes, a minor adds features, a major changes a saved setup.

Each version's section is also its GitHub release notes: `Shellforge/scripts/release.sh` publishes
it and refuses to release a version that has none.

## 1.0.0 — unreleased

### Added

- **Activity bar.** A column of icons down the sidebar's left edge switches its panel: Sessions,
  the sidebar as it was, and Metrics. Each window shows its own panel; drag the icons to reorder
  them, and every window keeps the same order after a restart. Settings is the gear at its foot.
  View › Show Sessions (⌃⌘E) and Show Metrics (⌃⌘M) switch panels from the keyboard.
  The panel keeps its width and the sidebar grows by the bar's 44 pt: a width you dragged before
  grows by 44 pt once (up to the 720 pt maximum), and a window now needs 724 pt to show the
  sidebar beside the terminal (it was 680).
- **Metrics panel.** Everything the footer showed, in full and scrolling: the selected task's
  context and token counts, the Mac's readings and Backpack Mode (click for Backpack Mode,
  right-click for Mac Settings…), and each vendor's windows with their reset times.

### Changed

- **The footer is a two-line strip; vendors you don't use are hidden.** Under every panel, in
  text a size larger than the old footer's, one line shows `cpu` and `ram` and the next each
  vendor's 5-hour and weekly windows, such as `5h 42% · wk 73%`, each amber from 80%. A window a
  vendor doesn't report is left out. The strip folds the last vendors into `+N` rather than wrap,
  and a click opens the Metrics panel. A vendor with no usage data whose CLI
  isn't installed, such as Codex on a Mac without it, no longer shows "No usage data yet".
  Claude Code counts as installed when `~/.claude` exists, even off your PATH. With no vendor
  to show, the Metrics panel leaves out its Usage group.
- **Banners show above every panel.** An error, work in progress such as "Adding demo…", a
  fallback PATH or a helper problem is pinned at the top of the sidebar, whichever panel shows.

## 0.10.0 — 2026-11-10

### Added

- **Error log.** Shellforge now keeps a log of real problems, one line each: errors the sidebar
  shows, failed removals and kept branches, a lost helper, failed updates, workspace and Project
  folder problems, and Backpack Mode failures. Help › Show Error Log shows it in Finder. It never
  holds terminal contents, commands, prompts, tokens, passwords or environment values, writes your
  home folder as `~`, and stays on your Mac. The same problem again within five minutes, such as a
  helper retried every few seconds or one event seen by every open window, is written once. The
  bug form mentions it.
- **Branch names from the ticket key.** A project’s right-click menu has a Branch Names choice.
  Type and Name is as before (`feat/abc-123-add-login-page`); Ticket Key Only names a
  task’s branch after its Jira ticket alone (`ABC-123`), for a repository whose agents expect
  that. A task with no ticket keeps the type and name, and the worktree folder keeps its readable
  name. A branch you type still wins: in a Ticket Key Only project, one typed without a type, such
  as `ABC-123-v2`, is the whole branch as typed, while one starting `fix/` picks that type. Nothing
  changes until you pick it.
- **A branch for Project folder tasks.** New Task’s Project folder option now has a Branch field. It
  starts as the branch checked out; type another and the folder switches to it before the agent
  starts. When git can’t simply switch, Shellforge asks: stash clashing changes, create a branch
  that doesn’t exist yet, use the worktree that already has the branch, or switch anyway while
  another task works in the folder. Cancel leaves the folder as it was and the sheet open.
- **Rearrange mode.** Right-click a project, divider, task, terminal or SSH row › Rearrange, then
  drag rows with the mouse. Projects and dividers move among each other, and a project’s SSH rows,
  and its tasks and terminals in any mix, move within that project; a drop the rules don’t allow
  jumps back. Done saves the order; Cancel, Esc in the sidebar, or hiding the sidebar puts it
  back. Next Task and Previous Task follow the order you set. VoiceOver offers Move Up and Move
  Down on each row while rearranging.

### Changed

- **Feedback says what it is for.** The sidebar note and the form now say that feedback decides
  what gets added and fixed next, and the second question asks what’s missing as well as what gets
  in your way.
- **One feedback a day.** After feedback is sent, Send waits a day, however the form was opened, so
  the issues can’t be flooded. GitHub’s own form, under your own account, stays open in the meantime.
- **Move Up and Move Down leave the menus.** A project’s and a divider’s right-click menus, and a
  divider’s VoiceOver actions, now offer Rearrange instead.
- **A new task goes to the bottom of its project,** below its terminals, as a new terminal does.

### Fixed

- **The feedback note shows up without a relaunch.** Once it is due, it now appears when you switch
  back to Shellforge, when your Mac wakes, or when you start a task or review, not only in a new
  window. How often it asks is unchanged.
- **Removing a task whose folder is still in use says which program holds it, with Try Again.**
  When a dev server or file watcher kept writing into the worktree while it was deleted, the
  removal failed with git’s bare “Directory not empty”. Now it names the programs whose folder is
  there, such as `node (4211)`, and offers Try Again; Cancel keeps the task.

### Installing

- Shellforge is signed but not notarized by Apple, so macOS refuses to open it the first time.
- Right-click Shellforge in Applications, choose Open, then Open again.
- Or run `xattr -dr com.apple.quarantine /Applications/Shellforge.app` once.

## 0.9.0 — 2026-11-09

### Added

- **Any agent.** Settings › Agents lists every agent a task can start, and Add Agent… adds your own:
  its command, how the first prompt gets in (as an argument, or typed in once the agent has settled),
  environment variables, and secrets. Secrets are kept only in the Keychain and reach the agent
  through `shellforge-run`, so no value is ever in the typed line, the scrollback or your shell
  history. Each agent’s row has Edit…, and its … menu holds Duplicate, and Remove for your own agent
  or Restore Default for a changed one. Changes reach New Task in every window at once.
- **Ready-made agents.** Aider, Amp, GitHub Copilot CLI, Gemini CLI, Goose and OpenCode come set up:
  install one and it appears in New Task and New Review. One you haven’t installed isn’t named in
  New Task’s “not installed” note. With more than four agents, the picker becomes a menu.
- **A status dot for every agent.** An agent without Shellforge hooks gets its dot guessed from its
  terminal: working while it prints, done about 30 seconds after it stops, and needs input when it
  rings the bell or posts a notification (OSC 9, or OSC 777 `notify`). Your typing doesn’t count,
  and the dot’s tooltip says the status is guessed. For an exact dot, an agent’s own hooks can run
  `shellforge-status`: the agent’s form shows the lines to add, and Test checks that a report
  arrives. OSC 777 `notify` now also posts a notification wherever OSC 9 would.

### Changed

- **Agent secrets come from the Keychain.** An agent whose file declares `secrets` now gets each one
  from the Keychain, and won’t start until each is set in Settings › Agents. A file that names its
  own Keychain entry for a secret keeps it, as long as the name starts with `agent.`: an agent can
  never be handed the Jira, GitLab or GitHub token, or the Backpack password.
- **Agent files you wrote yourself start as before.** One whose id has more than letters, digits,
  `-` and `_` still starts, as it did, but without an exact status; to give it an environment or
  secrets, give it such an id.

### Installing

- Shellforge is signed but not notarized by Apple, so macOS refuses to open it the first time.
- Right-click Shellforge in Applications, choose Open, then Open again.
- Or run `xattr -dr com.apple.quarantine /Applications/Shellforge.app` once.

## 0.8.0 — 2026-11-06

### Added

- **Feedback.** In release builds the sidebar now asks for feedback once in a while: after 14 days, then
  every 90 days after Not Now, or 180 after you send some. Don’t Ask Again, or Settings › Core, turns it
  off, and Help › Send Feedback… opens the form at any time. The form warns that feedback becomes a
  public issue, and nothing is sent until you press Send. No GitHub account is needed; if sending
  can’t get through, the form offers GitHub’s prefilled issue form instead.
- **New Tab in Home Folder.** A button in the sidebar’s header, and an item in the Tasks menu, open a
  shell in your home folder that belongs to no project. It is listed under Other Tabs.
- **New Task in the project folder.** New Task’s first control now offers New worktree, Existing
  worktree and Project folder. A project-folder task runs its agent in the project’s own folder, on
  the branch checked out there, and nothing in git changes. A project can have several. Removing
  one only forgets the task, and its prompts say the folder stays as it is.
- **Removal failures are logged.** When Remove cannot delete a worktree or keeps a branch, the macOS
  log (category “removal”) now has the git command and all of its error output, not only the first
  line the banner shows.

## 0.7.2 — 2026-11-06

### Fixed

- **Lighter while you aren’t looking.** Line-change badges no longer run git for windows that are
  hidden, in the Dock or covered, nor for folded projects, and only every 30 seconds while
  Shellforge is in the background. The Mac’s CPU, memory and battery are read only while a sidebar
  shows them.
- **Less work while an agent runs.** The helper no longer rereads agents’ transcripts and Codex’s
  logs each time a tab’s title changes, which Claude Code does several times a second. A long
  transcript is read a piece at a time instead of all at once, and only recent days of Codex’s
  history are scanned.
- Windows share what they read about `~/.ssh/config` and each project’s git host, instead of
  rereading it in every window.
- **Safer with other people’s branches.** A merge request under review can no longer redirect
  where the first prompt is written with a committed `.shellforge` link. Shellforge’s hook server
  only answers requests addressed to this Mac, so a web page can’t post fake agent status to it.

## 0.7.1 — 2026-11-05

### Changed

- **iTerm2 brought up to date** with its latest development version, including its fixes for a
  crash drawing the cursor on HDR displays, garbled zoomed tmux panes, the hotkey window after a
  fast user switch, and nushell’s prompt.

### Fixed

- **A window that opens without being brought forward types into its terminal.** Keyboard focus
  went to the sidebar’s list until you clicked the terminal, and changing the window’s style
  (Window › Window Style) kept it there.
- **The sidebar no longer stops a window from shrinking.** Under iTerm2’s newer window layout, the
  sidebar’s width and the floating sidebar’s margins could become the window’s minimum size.

## 0.7.0 — 2026-10-28

### Changed

- **Closing a task’s last tab no longer deletes its worktree.** It used to open Remove Task, where
  ↩ deleted the worktree. Now Close Tab is the default: the tab closes, and the task stays in the
  sidebar with its worktree and branch, so a task in review can be reopened from its row without
  making a new branch. To clean up at the same time, tick “Also delete the worktree”, and below it
  “Also delete branch”. Remove Task is unchanged.

## 0.6.0 — 2026-10-22

### Fixed

- **Removing a task whose agent switched branch now works.** When Claude or Codex ran
  `git switch -c` in the task’s worktree, Remove refused because the worktree was no longer on
  the task’s branch, and the row stayed on “Not removed” for good. The worktree is now removed. The
  agent’s branch and its commits are kept, and Shellforge says so. The old refusal still applies
  when another task’s row points at the same folder.

## 0.5.1 — 2026-10-19

### Fixed

- **Claude usage percentages no longer flicker** in the toolbar. With three bars (Session, Week, and
  the per-model weekly limit) the labels were placed using their natural text height, which is taller
  than each row when all three fit in a standard toolbar. The overlapping NSTextFields created the
  appearance of values jumping between 17%, 38%, and ~63%. Each label is now clamped to its row's
  height so nothing spills into an adjacent row.

## 0.5.0 — 2026-10-15

### New

- **A default model and reasoning level for each agent** (Settings › Agents). New Task and New Review
  start with it, and you can still change it for a single task. As in AiTerm.

### Fixed

- **The Dock icon no longer has green “Shellforge” text** over it. iTerm2 labels a test copy that runs
  with a settings suite, and Shellforge always uses its own suite. For the same reason the Settings
  window was titled “Settings: Shellforge”; it is now just “Settings”.
- An agent that isn’t installed now says how to fix it: install it, then click Reload in
  Settings › Core › Environment. It used to point to a Settings page that doesn’t install agents.

## 0.4.0 — 2026-10-15

### New

- **A modern look on macOS 26.** The sidebar floats as a rounded glass panel inside the window, on
  the terminal's own colour, with the window buttons in its corner and the Projects header on
  their row. Earlier macOS versions keep the full-height sidebar.
- **Light and dark.** The sidebar, its sheets and the folder picker follow the window's
  appearance.
- **One sidebar button, in one place.** It sits just after the window buttons, open or closed. In
  full screen a closed sidebar leaves a slim bar holding the button; moving the pointer to the
  screen's left edge slides the sidebar in.
- **Match the terminal to Shellforge** (Settings › Core › Terminal): an optional switch that draws
  every terminal in Shellforge's colours and iTerm2's Minimal theme, over each profile's own.
- **Sidebar text size** with ⌘+, ⌘− and ⌘0, after a click in the sidebar.
- **An error banner stays until you close it** with its ×.
- **Creating a task or review shows what it is doing:** fetching, creating the worktree or running
  the repository's checkout hook. The form locks while it runs, and **Cancel** (or ⎋) stops it
  and takes back the half-made worktree.
- **Restyled sheets and Settings:** macOS 26 fields and buttons, Settings as a grouped form with one
  box per section, sentence-case headers, capsule badges and a footer card in the sidebar.
- **iTerm2 brought up to date** with its latest development version, including its fixes since
  3.7.4.

### Fixed

- **The app's process is called Shellforge**, not iTerm2, in Activity Monitor, `ps` and crash logs;
  so a crash of stock iTerm2 is never offered as Shellforge's.
- **Bug reports go to Shellforge**, not iTerm2: About › Report a bug, error messages and the AI usage
  report open Shellforge's GitHub bug form. After a crash, **Copy and Report…** copies the report and
  opens that form; crash reports are no longer posted to iterm2.com.
- Reopening a hidden sidebar no longer makes the sidebar jump; a floating window widens to fit it,
  within its screen.
- Cancelling a review after its worktree was made saves nothing and removes the worktree.
- Two Settings windows no longer share one unsaved terminal-match switch.
- The full-screen sidebar keeps its rounded corners.

## 0.3.0 — 2026-10-14

### New

- Shellforge's own app icon.

## 0.2.0 — 2026-10-14

### New

- **Continue in an existing worktree:** New Task can pick a worktree that is already there and
  make it a task, instead of creating a new one.

## 0.1.0 — 2026-10-14

The first release: iTerm2 with [AiTerm](https://github.com/dhondtlaurens/aiterm)'s sidebar in every
terminal window.

### New

- **Projects → tasks → tabs.** A task is a git worktree with an agent (Claude Code, Codex, Grok,
  PI) running in its tab; a review is one for a merge request or pull request.
- **New Task and New Review** sheets, with `/` completions for the agent's commands and skills.
- **Live status** from the agents' own hooks, through the bundled helper `shellforged`: working,
  waiting on you, done; and the Dock badge.
- **Jira, GitLab and GitHub:** tickets in New Task, merge requests in New Review, a project's Jira
  projects, and lines changed on every task.
- **Remove Task** and **Remove Project**, which never lose unpushed work; **Pull** a project's
  default branch.
- **SSH tunnels** per project, started and stopped from the sidebar, and a project's SSH host
  beside its agent.
- **The footer:** context, counts, the Mac's CPU, memory and battery, and each agent plan's usage.
- **Backpack Mode** for a Mac that keeps working with its lid closed.
- **Dividers, New Terminal, Rename, Open in Finder and VS Code**, and keyboard shortcuts that leave
  iTerm2's alone.
- **Check for Updates…** from GitHub releases, and an importer for an AiTerm setup.
