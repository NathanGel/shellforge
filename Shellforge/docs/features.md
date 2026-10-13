# Shellforge features

Shellforge is iTerm2 with AiTerm's sidebar: projects, then tasks, then tabs, in every terminal window. This page lists everything Shellforge adds to iTerm2, and how to reach each thing. iTerm2's own features are unchanged. Keyboard detail is in [keyboard.md](keyboard.md).

## The sidebar

- **Where it is.** Every terminal window has a sidebar on its left. It is always dark, even when iTerm2 is light. iTerm2's tab bar is hidden in these windows, because the sidebar lists the tabs instead.
- **Hide and show.** Use any of these:
  - the sidebar icon in the sidebar's header;
  - ⌃⌘S;
  - View › Hide Sidebar / Show Sidebar.
- **Getting it back.** While the sidebar is hidden, the same icon sits in the window's title bar, beside the window buttons. In full screen there is no title bar, so use ⌃⌘S or the View menu.
- **New windows** open the way the last toggle left them.
- **Width.** Drag the sidebar's right edge to resize it.
  - The default width is 420 pt, the minimum 360 and the maximum 720.
  - Each window keeps its own width. The last width you dragged is the starting width for new windows.
- **Terminal space.** The terminal always keeps at least 320 pt, about 40 columns, with iTerm2's toolbelt counted. In a window too narrow for both, the sidebar steps aside.
- **Header.** PROJECTS, then four buttons:
  - Hide Sidebar;
  - Agent hooks (the bolt);
  - Settings (the gear);
  - "+", with Add Project… and Add Divider….
- **Empty state.** With no projects, the sidebar shows "Add a git repository to start." and an Add Project… button.
- **Banners** above the list show:
  - a fallback PATH;
  - problems with the helper;
  - the last error;
  - work in progress, such as "Adding X…".

## Projects

- **Add Project.** Use ⌃⌘P, the header "+" or the empty state. The folder you pick must be inside a git repository, and a project can only be added once. The project is named after its folder.
- **The workspace** lives in `~/Library/Application Support/Shellforge/workspace.json`, shared by every window.
  - Each save first keeps `workspace.json.backup`.
  - A file that won't load is set aside as `.damaged-<uuid>`, and the backup is used instead.
- **Provider mark.** GitLab, GitHub, plain git, or none, read from the `origin` remote.
- **Fold and unfold.** Click the chevron or the name. The fold is saved. A folded project shows how many of its tasks are in each status.
- **The project's "+" and right-click menu:**
  - New Task…, New Review… and New Terminal…;
  - Open in Finder and Open in VS Code (when VS Code is installed);
  - Jira Projects…, Tunnels… and SSH Host…;
  - Move Up and Move Down. A move crosses a divider.
- **Jira Projects…** links the project to Jira projects.
  - Search, add, or remove a link with ✕; nothing changes until Save.
  - The header badge shows the first project's key, which opens it, and "+n" for the rest.
  - New Task searches these projects, or every Jira project when none is linked.
- **SSH Host…** picks a `Host` from `~/.ssh/config`. New Task can then open `ssh <host>` in a pane beside the agent.
- **Not ported yet:** Remove Project and Pull Default Branch.

## Dividers

- **Add Divider.** Use ⌃⌘G, or the header's "+" › Add Divider…. The divider is added at the end of the list. A name is optional: without one it draws a plain line.
- **Right-click a divider** for Rename…, Move Up / Move Down and Remove Divider. Removing it asks nothing, because a divider holds nothing.

## Tasks and reviews

- **New Task (⌃⌘N) and New Review (⌃⌘R)** act on the selected task's or terminal's project, else the window's only project. With several projects and nothing selected, they are greyed out.
- **The New Task sheet** has three steps: Task, Agent and Prompt.
  - **Task:**
    - an optional Jira ticket, searched by text, or your open tickets when the search is empty;
    - the task name, type (feat, fix or chore), new branch and base branch.
    - A picked ticket fills in the name, type and branch.
  - **Agent:** agent, model and reasoning.
  - **Prompt:** an optional first prompt. "/" lists the agent's commands and skills.
  - **Options:** "Include Jira ticket details", and "Open ssh <host> beside the agent".
  - **Keys:** ⌘↩ is the main button. ⎋ closes an open list first, then goes back a step.
- **Agents:** Claude Code, Codex, Grok Build and PI.
  - Codex runs without approvals or sandbox, and its command preview shows that.
  - An agent whose command isn't on your login PATH can't be picked, and the sheet says why.
  - Custom agents are JSON files in `~/Library/Application Support/Shellforge/agents/`. A file with a preset's id replaces that preset.
  - Shellforge remembers the last agent per project and the last model per agent.
- **Worktree and branch.**
  - A task works in `<project>/.worktrees/<slug>`, with `.worktrees/` excluded from git.
  - Its branch is `<type>/<key>-<slug>`.
  - A long first prompt goes to `.shellforge/first-prompt.md` in the worktree.
  - If creating the worktree fails, nothing is saved and the sheet keeps what you typed.
- **The New Review sheet** has three steps: Branch, Agent and Prompt.
  - An optional merge request (GitLab `!n`) or pull request (GitHub `#n`), plus the review name and the branch.
  - The worktree is `.worktrees/review-<slug>`, locked in git.
  - A pull request from a fork is refused.
  - If the local branch is behind, it is fast-forwarded. If it is ahead, it is kept. If it has diverged, the review is refused.
- **Creating a task** opens a tab in its worktree that runs the agent with your prompt.
  - The command runs once, so ⌘D and ⌘T in that tab give a plain shell.
  - A folded project unfolds.
- **Clicking a task** shows its tab. If it has no tab open, a shell opens in its worktree; the agent does not run again.
- **Rename…** changes only the task's title. The branch and worktree keep their names.
- **Remove Task… (⌃⌘⌫, or right-click) asks first.** The question shows the worktree, with "Also delete branch" ticked by default.
  - Uncommitted changes ask Keep, or Delete Changes and Remove.
  - The task's tabs close first, in every window, through iTerm2's own close.
  - A branch with commits its base lacks asks whether to keep it.
  - A review's branch goes only when nothing would be lost.
  - While it runs, the row reads "Removing…", or why it stopped.
- **Status dot:**
  - idle: a ring;
  - working: a spinning arc, or a still one under Reduce Motion;
  - needs input: amber;
  - done: green, until you look at the task.
- **The task row** shows the agents, the title, the Jira and MR/PR badges, VS Code and the branch.
- **Moving between tasks.**
  - ⌃⌘] and ⌃⌘[ step through the open projects' tasks, wrapping round. They never open a tab.
  - **Focus View (⌃⌘A)** opens the projects with a task or terminal waiting on you, folds the rest, and shows the first one.
  - **List View (⌃⌘L)** opens every project.

## Tabs and panes

- **A task's tabs** are listed under it when it is selected and has more than one. Tabs of no task are listed under **Other tabs**.
- **Closing from the sidebar.** Right-click a tab row, or a task row, for **Close Tab**. On a tab split with ⌘D, the item reads **Close Pane** and closes only the focused pane.
  - Anything running asks first, as ⌘W does.
  - A task row brings its tab to the front before closing a pane of it.
- **A task's last pane.** Closing it asks Remove Task's question first. Cancel keeps both the pane and the task.
- **Panes join their task.** A pane split off a task's tab, a project's tab or a terminal's tab joins it. Closing the agent's pane first leaves the task its other pane.
- **The window stays open.** When a close would leave the window with no tab, a fresh shell tab opens first, in the default folder. This applies to Close Tab, Remove Task and Remove Terminal.

## Terminals

- **New Terminal.** Use ⌃⌘T or the project's "+". It adds a named row under the project, and a plain shell tab in the project's folder. The name is "Terminal", or the next free "Terminal n".
- **Right-click a terminal row** for:
  - Rename…, which renames the row, not the tabs;
  - Open in;
  - Remove Terminal, which closes its tabs and asks nothing, because nothing on disk is touched.

## Footer

- **SYSTEM** shows the selected task's or tab's agent:
  - its context ring and percent;
  - its token counts, such as `in 936k · out 5.6k`, with exact figures in the tooltip.
- **Mac** shows `cpu` and `ram`, plus `bat` on battery, sampled every 5 s.
  - A reading turns amber only when macOS warns.
  - Click it for Backpack Mode, or right-click for Mac Settings….
- **USAGE** has one row per vendor (Claude, Codex) with the weekly (`wk`) and 5-hour (`5h`) windows and their reset times.
  - Rings turn amber at 80%.
  - Claude reads "Usage disconnected" until its status-line shim is installed (Agent hooks).

## Dock badge

- The Dock icon counts the task and terminal rows waiting on you, the same rows Focus View shows. Each row counts once, however many windows show it. There is no badge at zero.

## Backpack Mode

- **Turning it on.** Use View › Backpack Mode (⌘B), or click the footer's Mac row. Both open its sheet; with the mode on, they turn it off.
- **The sheet:**
  - setup checks for this Mac;
  - the iPhone hotspot and its password, kept in the Keychain once joined;
  - Connect.
  - It ends with "Safe to close the lid."
- **It ends by itself:**
  - 120 s after no agent is working with the lid shut;
  - or at 10% battery. It won't start at 10% or below.
  - A dropped hotspot is rejoined, waiting longer after each failed attempt.
  - After it ends, the Mac rejoins a Wi-Fi network you prefer.
- **Setup (Allow…).**
  - It installs `/etc/sudoers.d/shellforge`, checked by `visudo`, with one admin prompt. The rule allows only two `pmset disablesleep` commands.
  - It asks for Location access, for Wi-Fi scans.
  - **Remove** takes the rule out again.
- **Sleep is always restored:**
  - a watchdog restores sleep if Shellforge crashes;
  - a marker restores it at the next launch;
  - quitting restores it first.

## Tunnels

- **Tunnels… (project menu)** links `~/.ssh/config` hosts that have `LocalForward` lines.
  - Each tunnel starts Never, When Shellforge opens, or When a task opens.
  - "Keep running after Shellforge quits" is a choice per tunnel.
  - The ports are always read from the ssh config, never copied.
- **Rows under the project:**
  - the state: stopped, connecting (amber), up (green), or failed (red, with ssh's last line);
  - the ports, the keep-running mark, and Start / Stop;
  - when up, its uptime and traffic.
- **How it runs.**
  - `ssh -N <alias>` in batch mode.
  - A drop after it was up restarts, waiting longer after each failure.
  - An early failure is not restarted.
  - Keep-running tunnels survive quitting and are picked up at the next launch.
- **Answer in Tab.** When ssh needs a host key, a passphrase or a code, the row offers to run it in a tab where you can answer.
- **Ports in a task's shell.** `SHELLFORGE_TUNNEL_<ALIAS>_PORT` is set for each running tunnel, and `_PORT_2` and so on for extra forwards.
- **View › Tunnels** has Start or Stop for each linked tunnel. Open Quickly (⇧⌘O) finds them by name.

## Environment

- **Commands run with your login shell's environment**, so your PATH and tools are found.
  - If the login shell fails, a fallback PATH is used and a banner says so.
  - A command that isn't found makes Shellforge read the environment again, once.
  - Your shell's rc files and `/etc/paths(.d)` are checked every 30 s; a change re-reads the environment.
  - zsh (including `$ZDOTDIR`), bash and fish are covered.
- **Settings › Core › Environment** shows:
  - the shell and when it was read;
  - where each tool was found: git, uv, python3, node, ssh and the agents;
  - the PATH folders;
  - Reload.

## Settings and connections

- **Opening Settings.** Click the sidebar's gear, or right-click the Mac row › Mac Settings….
  - **Core:** the Mac card (Backpack setup) and the Environment card.
  - **Services:** Jira (site, email, API token), GitLab (host, token) and GitHub (token).
- **Connections.**
  - Tokens are kept only in the Keychain, and URLs must be https.
  - Connections are tested when Settings opens and when you stop typing.
  - Disconnect takes effect on Save.
- **Agent hooks (the bolt)** have one row per agent, with its state and one button: Install, Repair or Reinstall.
  - Files change only when you click, and each is backed up once as `.shellforge-backup`.
  - The files are `~/.claude/settings.json`, `~/.codex/config.toml`, `~/.grok/config.toml` and `~/.pi/agent/extensions/shellforge-status.ts`.

## Keyboard

| Key | Does |
|---|---|
| ⌃⌘N / ⌃⌘R / ⌃⌘T | New Task / New Review / New Terminal |
| ⌃⌘P / ⌃⌘G | Add Project / Add Divider |
| ⌃⌘] / ⌃⌘[ | Next / Previous Task |
| ⌃⌘⌫ | Remove Task |
| ⌃⌘A / ⌃⌘L | Focus View / List View |
| ⌃⌘S | Hide / Show Sidebar |
| ⌘B | Backpack Mode |

- They act on the key window's sidebar.
- iTerm2's own keys are unchanged.
- ⌃⌘D, ⌃⌘Q and ⌃⌘Space belong to macOS, so Shellforge does not use them.

## VoiceOver

- **Rows** read their title and status.
- **Named actions:**
  - tab rows: Close;
  - terminal rows: Rename and Remove Terminal;
  - dividers: Rename, Move Up / Move Down (while possible) and Remove Divider.
- **Labels:** tunnel rows read their state, and the footer's Mac row reads its readings.

## The helper (shellforged)

- **What it is.** A small Python process that tracks each tab's agent, status, model, context and tokens, reads usage, and runs tunnels.
  - Agents report to it through their hooks, on `127.0.0.1:47831`.
  - The app tells it which sessions are open.
- **When it runs.** It starts with Shellforge and needs Python 3.11 or newer on your login PATH. It restarts after a crash, waiting longer each time. One left running from before is picked up. It stops when Shellforge quits.
- **Its files** are in `~/Library/Application Support/Shellforge/`: the socket, `shellforged.log`, `daemon.json`, `tunnels.json` and `hook-port`.
- **Messages it can cause:**
  - starting or reconnecting;
  - Python missing or too old;
  - the helper missing from the app;
  - the helper keeps stopping, with where its log is;
  - "Shellforge's helper is from another version": quit Shellforge, wait a minute, open it again.
