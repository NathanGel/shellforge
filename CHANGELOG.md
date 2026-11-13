# Changelog

What changed in each Shellforge version, newest first. Every feature is described in
[FEATURES.md](FEATURES.md). Versions follow [the release rules](Shellforge/docs/releasing.md#versions):
a patch fixes, a minor adds features, a major changes a saved setup.

Each version's section is also its GitHub release notes: `Shellforge/scripts/release.sh` publishes
it and refuses to release a version that has none.

## 1.0.0 — 2026-11-13

### Added

- **Activity bar.** A column of icons down the sidebar's left edge switches its panel: Sessions,
  the sidebar as it was; Metrics; Files; and Git. Each window shows its own panel; drag the icons to reorder
  them (VoiceOver offers Move Up and Move Down), and every window keeps the same order after a
  restart. Settings is the gear at its foot.
  View › Show Sessions (⌃⌘E), Show Metrics (⌃⌘M), Show Files (⌃⌘I) and Show Git (no key) switch panels.
  The panel keeps its width and the sidebar grows by the bar's 44 pt: a width you dragged before
  grows by 44 pt once (up to the 720 pt maximum), and a window now needs 724 pt to show the
  sidebar beside the terminal (it was 680).
- **Metrics panel.** Everything the footer showed, in full and scrolling: the selected task's
  context and token counts, the Mac's readings and Backpack Mode (click for Backpack Mode,
  right-click for Mac Settings…), and each vendor's windows with their reset times.
- **Files panel.** A third panel in the activity bar (the folder) lists every project's files,
  in the order of Sessions, one foldable section each. In a repository it shows what git sees,
  tracked and untracked files but not ignored ones; elsewhere, the folder itself. Click a file to
  open it in a new tab in the project's folder, in your terminal editor; quitting the editor
  closes the tab. The editor is Settings › Core › Terminal editor, else `$EDITOR`, else `vi`.
  Right-click a file for Open in Terminal Editor, Reveal in Finder and Open in VS Code, or a
  folder for Reveal in Finder, Open in Finder and Open in VS Code. View › Show Files (⌃⌘I) shows the panel.
- **Git panel.** A fourth panel (the branch) shows each project's repository, and under it each
  task's worktree with something to commit or push: the branch and how far it is ahead of and behind its upstream
  (`main ↑2 ↓1`), a commit message field of up to five lines, and the Merge Changes, Staged Changes and Changes
  lists. Stage, unstage or discard a file (an untracked file goes to the Trash), Stage All or
  Unstage All, and commit with ⌘↩: with nothing staged, Commit takes every change, new files
  included, and it waits until merge conflicts are resolved. Pull (fast-forward only), Push, or
  Publish Branch for a branch with no upstream.
  Switch Branch… on a project picks from a searchable list, remote branches included (picking
  `origin/feature/login-page` gives a local branch tracking it), and asks what New Task asks for a
  Project folder task. Click a file to see its diff in a new tab. The panel reads nothing until it
  is first shown, then follows each repository as it changes. View › Show Git shows it.
- **SSH panel.** A fifth panel (the server rack) lists the hosts in `~/.ssh/config`: each
  project's SSH host and tunnels under the project, then every other host under Other hosts.
  Open in Terminal opens `ssh <host>` in a new tab, in the project's folder or, for Other hosts, your home
  folder; a tunnel host's row starts and stops it as in Sessions. A host a project names that the config
  no longer has is dimmed with “Not in ~/.ssh/config”. Right-click a project for Tunnels… and SSH
  Host…. The config is read when the panel first shows and again whenever `~/.ssh` changes.
  View › Show SSH (⌃⌘H) shows it.
- **Add Host.** The SSH panel's + button adds a host to `~/.ssh/config`: a name, an address,
  and optionally a user, a port and an identity file, and the project it is for. The file is
  copied to `config.shellforge-backup` first and the new `Host` block is appended; nothing else in
  it changes. It accepts only what ssh can read, and refuses a name already in the config. A
  missing `~/.ssh` or config is created, private to you.
- **Themes.** Ten themes: Shellforge (light and dark, as before), Dark Modern, Light Modern, One
  Dark, Dracula, GitHub Dark, GitHub Light, Solarized Dark, Solarized Light and Nord. A theme
  colours everything Shellforge draws: the sidebar, the activity bar, the panels, the sheets and the
  metrics strip; its accent takes the place of the Mac's in Shellforge, focus rings and Settings'
  switches included. The terminal takes the theme only with Match Terminal on. Settings › Core ›
  Theme picks one, or, with Follow Mac Appearance on (the default), a light one and a dark one that
  follow the Mac. A single light or dark theme holds Shellforge to its appearance. Match Terminal
  lays the theme's colours over every terminal, as Match the terminal to Shellforge did; your
  profiles are not changed. Until you pick a theme, Shellforge looks as it did.
- **Gear menu.** The gear at the foot of the activity bar is a menu now, like VS Code's Manage
  menu: Settings…; Theme, with the themes (or Light Theme and Dark Theme while following the
  Mac), Follow Mac Appearance and Match Terminal, each applied at once; and Customize.
- **Hide panels.** Gear › Customize has one Show item per panel, such as Show Metrics. Untick
  one and the panel leaves the activity bar and the View menu, and its ⌃⌘ key does nothing; a
  window that showed it switches to the first panel left. The last shown panel can't be hidden.
  The choice is this Mac's and every window follows it.

### Changed

- **The footer is a two-line strip; vendors you don't use are hidden.** Under every panel, in
  text a size larger than the old footer's, one line shows `cpu` and `ram` and the next each
  vendor's 5-hour and weekly windows, such as `5h 42% · wk 73%`, each amber from 80%. A window a
  vendor doesn't report is left out. The strip folds the last vendors into `+N` rather than wrap,
  and a click opens the Metrics panel. A vendor with no usage data whose CLI
  isn't installed, such as Codex on a Mac without it, no longer shows "No usage data yet".
  Claude Code counts as installed when `~/.claude` exists, even off your PATH. With no vendor
  to show, the Metrics panel leaves out its Usage group.
- **Settings › Core's Match terminal card became the Theme card.** Match Terminal is its last
  switch, under the theme choice, and keeps the choice you made. As before, iTerm2 uses its Minimal
  theme only while it is on.
- **Settings sections look like macOS 26's own grouped boxes.** Each section's box is set off
  from the sheet as far as the system's, with rounder 12 pt corners and no outline.
- **The Sessions header no longer has a Settings gear.** Settings is the gear at the foot of the
  activity bar; Mac Settings… is on the Metrics panel's Mac row (right-click).
- **Banners show above every panel.** An error, work in progress such as "Adding demo…", a
  fallback PATH, a helper problem or the feedback note is pinned at the top of the sidebar,
  whichever panel shows, and so is Rearrange mode's Cancel and Done.
- **Panels list the tabs they open.** A tab opened from the SSH, Files or Git panel is listed in
  that panel, no longer under Sessions’ Other Tabs: an ssh session under its host, a file open in
  the editor under the file (or its project, while the file’s folder is closed), and a diff, or
  a file opened in the editor from Git, under its file (or its repository, once the file has no
  changes left). Click the line to bring the tab
  forward, or its × to close it, which asks first only when ⌘W would. The tabs are found again
  after a restart. When the host, project or task a tab belongs to is gone, it moves back under
  Other Tabs. Other Tabs keeps every other tab of no task, such as New Tab in Home Folder’s.
- **One row per SSH host, with one-click Start/Stop and Open in Terminal.** A host that is also a
  project’s tunnel is a single row, with the tunnel’s Start or Stop beside Open in Terminal (the
  old Connect), so starting `db-tunnel` or opening `ssh staging` is one click. Clicking the row
  itself opens nothing.
- **Sidebar questions use iTermWarning.** Removing a task, importing worktrees, switching a
  branch and the sidebar's other questions are iTerm2's own alerts now, so they can be answered
  from iTerm2 Buddy on your phone as well as at the Mac.
- **One Keychain password prompt after an update instead of one per secret; each old item moves
  in, with one last prompt, the first time it is needed.** Every secret, iTerm2 Buddy's pairing
  keys and the AI API keys included, now lives in Shellforge's one Keychain item, read once as the
  app starts. Deleting an old item once it has moved in may ask too.
- **A working agent’s spinner no longer redraws the sidebar.** A tab whose title no row shows,
  such as a task’s only tab, can retitle itself several times a second without the sidebar
  drawing again, and the `+n −m` line counts are read at a lower priority than your own work.
- **Jira, GitLab, Backpack and default-model settings are kept in Shellforge's own settings.**
  The Jira site and email, the GitLab host, Backpack Mode's network and Settings › Agents' default
  models used to be stored apart from the rest. They are copied over once, at the first launch of
  this version, and are now included when you reset Shellforge's settings or keep them in a custom
  folder. A development build no longer shares them with the installed app.
- **Settings no longer waits for your login shell, and nothing freezes on a Keychain prompt.**
  Settings opens without waiting for the installed agents, which fill in when they are found.
  Settings and New Task read their saved connections in the background, so the app keeps
  responding while a Keychain prompt is up.

### Fixed

- **New Task no longer follows a `.worktrees` link out of the project.** A repository that
  commits `.worktrees` as a link to another folder is refused instead of having the task's
  checkout made wherever the link leads. A New Task or New Review that fails or is cancelled
  halfway takes back the folder and branch it made, so trying again with the same name works.
- **Stash and Switch puts back only its own stash.** Switching branches no longer pops a stash
  you made yourself.
- **Removing a task keeps a folder git doesn't list.** If git has no record of the task's
  folder and nothing shows it was a worktree, Remove leaves it in place and says so, rather
  than deleting it.
- **A workspace file that can't be read is no longer replaced.** If `workspace.json` is there
  but unreadable (its permissions, a disk error), Shellforge no longer starts with no projects and
  saves that over it. The backup is replaced in one step, so a save that fails never loses it.
- **Secrets are kept when two copies of Shellforge are open.** With an installed and a
  development build open at once, saving a token or password in one no longer drops one the
  other had just saved.
- **The helper answers only the Shellforge that started it.** Another program of your account
  can no longer send it a tab list or arm an agent's launch; when Shellforge finds a helper
  from an earlier version still running after an update, it replaces it with its own.
- **A helper that can't start no longer runs Shellforge out of open files.** Each attempt to
  start a helper that couldn't be launched (its Python gone, say) kept a file open for good, so
  after enough retries Shellforge could no longer run git or start anything else until you
  quit it.

### Installing

- Shellforge is signed but not notarized by Apple, so macOS refuses to open it the first time.
- Right-click Shellforge in Applications, choose Open, then Open again.
- Or run `xattr -dr com.apple.quarantine /Applications/Shellforge.app` once.

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
