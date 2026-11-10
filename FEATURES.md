# Shellforge features

Shellforge is iTerm2 with AiTerm's sidebar: projects, then tasks, then tabs, in every terminal window. This page lists everything Shellforge adds to iTerm2, and how to reach each thing. iTerm2's own features are unchanged. Every shortcut is in [the keyboard table](Shellforge/docs/keyboard.md); what changed in each version is in [CHANGELOG.md](CHANGELOG.md).

## Contents

- [The sidebar](#the-sidebar)
- [Activity bar](#activity-bar)
- [Projects](#projects)
- [Dividers](#dividers)
- [Tasks and reviews](#tasks-and-reviews)
- [Agents](#agents)
- [Tabs and panes](#tabs-and-panes)
- [Terminals](#terminals)
- [Metrics](#metrics)
- [Dock badge](#dock-badge)
- [Backpack Mode](#backpack-mode)
- [Tunnels](#tunnels)
- [Environment](#environment)
- [Settings and connections](#settings-and-connections)
- [Keyboard](#keyboard)
- [VoiceOver](#voiceover)
- [The helper (shellforged)](#the-helper-shellforged)
- [Check for Updates…](#check-for-updates)
- [Reporting a bug](#reporting-a-bug)
- [Error log](#error-log)
- [Feedback](#feedback)

## The sidebar

- **Where it is.** Every terminal window has a sidebar on its left. It follows the window's appearance: light or dark, as macOS or iTerm2's Appearance setting has it. iTerm2's tab bar is hidden in these windows, because the sidebar lists the tabs instead.
- **On macOS 26 and later** the sidebar floats: a rounded glass panel 10 pt inside the window and 10 pt from the terminal (in full screen too), on the terminal's own colour, with the window buttons in its top corner and the Projects header on their row. The window's title sits over the terminal on the same row. Earlier macOS versions keep the full-height sidebar.
  - With Match the terminal to Shellforge on, the window keeps its own title bar and buttons; only the colours change.
  - The sidebar button sits just after the window buttons and stays there open or closed. In full screen it has its own row at the top of the panel, above Projects; with the sidebar closed, a slim bar in the terminal's colour keeps the button in the same place; click it to open the sidebar, or move the pointer to the screen's left edge and it slides in over the terminal, and away again when you leave it.
- **Hide and show.** Use any of these:
  - the sidebar icon in the sidebar's header;
  - ⌃⌘S;
  - View › Hide Sidebar / Show Sidebar.
- **Getting it back.** While the sidebar is hidden, the same icon sits in the window's title bar, beside the window buttons. In full screen there is no title bar, so use ⌃⌘S or the View menu.
- **New windows** open the way the last toggle left them.
- **Width.** Drag the sidebar's right edge, marked by a thin line, to resize it.
  - The default width is 464 pt, the minimum 404 and the maximum 720. Both include the 44 pt activity bar, so the panel beside it opens at 420 pt and narrows to 360.
  - Each window keeps its own width. The last width you dragged is the starting width for new windows.
- **Text size.** Click anywhere in the sidebar, then use ⌘+ / ⌘− to make its text bigger or smaller, and ⌘0 for normal size.
  - There are three sizes: normal (13 pt), large (15 pt) and extra large (17 pt).
  - The keys act on the sidebar until you click in the terminal again; then they size the terminal's font, as in iTerm2. Clicking a task or tab row counts as a click in the sidebar, though your typing goes to its terminal.
  - Every window's sidebar uses the same size, and it is kept after a restart. Sheets and menus stay at normal size. The sidebar's width does not change with it.
- **Terminal space.** The terminal always keeps at least 320 pt, about 40 columns, with iTerm2's toolbelt counted.
  - While the sidebar shows, the window can't be dragged narrower than both minimums together: 724 pt, plus the toolbelt's width when it is open. The sidebar shrinks to its minimum, then the window stops, rather than the sidebar jumping away.
  - A window sized some other way, such as tiling or a smaller screen, can still end up too narrow. There the sidebar steps aside.
- **Selection.** The selected row uses the system's selection: the accent while the window is active, grey while it is not.
- **Banners** are inline notices with an icon; an error stays until you click its ×.
- **Header.** Projects, then five buttons, left to right:
  - Agent hooks (the bolt);
  - Settings (the gear);
  - New Tab in Home Folder (the terminal icon), which opens a shell in `~` that belongs to no project;
  - "+", with Add Project… and Add Divider…;
  - Hide Sidebar, at the far right.
- **Empty state.** With no projects, the sidebar shows "Add a git repository to start." and an Add Project… button.
- **Banners** above the list show:
  - a fallback PATH;
  - problems with the helper;
  - the last error, until you click its × or a later action succeeds;
  - work in progress, such as "Adding X…".

## Activity bar

- **Where it is.** A narrow column of icons down the sidebar's left edge, VS Code's way. Each icon shows one panel beside it:
  - Sessions (the stack of cards): projects, tasks, terminals and tabs, as the sidebar has always shown them;
  - Metrics (the gauge): see [Metrics](#metrics).
- **Switching.** Click an icon. The selected one has an accent edge. Each window shows its own panel; Sessions keeps its scroll position and selection while another panel shows, and the Tasks menu's commands work whatever the panel.
- **Panel order.** Drag an icon up or down the bar to reorder the panels. Every window's bar follows the same order, and it is kept after a restart.
- **Settings** is the gear at the bottom of the bar.
- **Rearrange mode** keeps its Done / Cancel bar at the top whichever panel shows.

## Projects

- **Add Project.** Use ⌃⌘P, the header "+" or the empty state. The folder you pick must be inside a git repository, and a project can only be added once. The project is named after its folder.
  - When the repository already has worktrees, Shellforge asks "Import N worktrees?": Import adds each as a task named after its branch, without starting an agent. A review's worktree comes in as a review.
- **The workspace** lives in `~/Library/Application Support/Shellforge/workspace.json`, shared by every window.
  - Each save first keeps `workspace.json.backup`.
  - A file that won't load is set aside as `.damaged-<uuid>`, and the backup is used instead.
- **Provider mark.** GitLab, GitHub, plain git, or none, read from the `origin` remote.
- **Fold and unfold.** Click the chevron or the name. The fold is saved. A folded project shows how many of its tasks are in each status.
- **The project's "+" and right-click menu:**
  - New Task…, New Review… and New Terminal…;
  - Open in Finder and Open in VS Code (when VS Code is installed);
  - Jira Projects…, Tunnels… and SSH Host…, then Open ssh <host> when the host is in `~/.ssh/config`;
  - Branch Names, a submenu: Type and Name or Ticket Key Only (see Worktree and branch). VoiceOver offers each as an action, the one in use marked “(current)”;
  - Pull <default branch>, for a GitLab or GitHub project;
  - Rearrange (see [Rearranging the sidebar](#rearranging-the-sidebar));
  - Remove Project….
- **Jira Projects…** links the project to Jira projects.
  - Search, add, or remove a link with ✕; nothing changes until Save.
  - The header badge shows the first project's key, which opens it, and "+n" for the rest.
  - New Task searches these projects, or every Jira project when none is linked.
- **SSH Host…** picks a `Host` from `~/.ssh/config` as the project's machine.
  - Once set, the menu item reads **SSH Host: <host>…**, and the project's name shows it on hover.
  - **Open ssh <host>** opens it in a tab of its own.
  - New Task offers "Open ssh <host> beside the agent", a pane next to the agent.
- **Pull <default branch>** (such as "Pull main") brings the project's default branch up to date with origin's, fast-forward only.
  - Where the branch is checked out, it is merged there, so the files move too. Git refuses if that would overwrite uncommitted changes. Checked out nowhere, only the branch moves.
  - With local commits and nothing new on origin, it is left as it is. If both have new commits, it is refused and says how many each has: nothing is merged, rebased or pushed.
  - The outcome shows under the sidebar for 6 seconds; a refusal shows as the error. Pull is greyed while one is running for that project.
- **Remove Project… asks first**, listing the worktrees it keeps. It only removes the project from Shellforge:
  - Its tasks and terminals leave the sidebar. No git command runs, and files and worktrees stay on disk.
  - Its tabs stay open and move under Other Tabs.
  - A divider below it moves up with the projects.
  - While a task is being created or removed in the project, it says the project "can't be removed yet".

## Dividers

- **Add Divider.** Use ⌃⌘G, or the header's "+" › Add Divider…. The divider is added at the end of the list. A name is optional: without one it draws a plain line.
- **Right-click a divider** for Rename…, Rearrange and Remove Divider. Removing it asks nothing, because a divider holds nothing.

## Rearranging the sidebar

- **Rearrange.** Right-click a project, divider, task, terminal or SSH row › Rearrange. The header reads Rearranging, with Cancel and an accent Done button.
  - Each row gets a handle. Drag a row with the mouse and a line shows where it goes.
  - Projects and dividers move among each other; a project brings its rows along. A project or divider dropped among a project's rows lands after that project.
  - A project's SSH rows move among themselves, and its tasks and terminals move among themselves, in any mix. Nothing leaves its project, and no task or terminal goes above the SSH rows. A drop the rules don't allow jumps back.
  - Tabs and Other Tabs are hidden, and clicks, menus and banner buttons wait until you are done. A project's chevron still folds and unfolds it.
  - Rearrange takes the keyboard into the sidebar, so Esc works at once; Done and Cancel give it back.
- **Done** saves the new order. **Cancel** puts everything back, as does Esc while the keyboard is in the sidebar; Return and Esc typed in the terminal stay the terminal's. Hiding the sidebar with ⌃⌘S or the window's sidebar toggle cancels too.
- **One window at a time.** While one window is rearranging, Rearrange is greyed in the others.
- **The order counts elsewhere too.** Next Task and Previous Task (⌃⌘] / ⌃⌘[) step through the tasks in the order you set. A new task or terminal goes to the bottom of its project.

## Tasks and reviews

- **New Task (⌃⌘N) and New Review (⌃⌘R)** act on the selected task's or terminal's project, else the window's only project. With several projects and nothing selected, they are greyed out.
- **The New Task sheet** has three steps: Task, Agent and Prompt.
  - **Task:**
    - **New worktree**, **Existing worktree** or **Project folder**;
    - an optional Jira ticket, searched by text, or your open tickets when the search is empty;
    - the task name;
    - for a new worktree: type (feat, fix or chore), new branch and base branch. A picked ticket fills in the name, type and branch.
    - for an existing worktree: which one, newest commit first, from the project's worktrees that are on a branch and not a task yet (made by Shellforge, AiTerm, an agent or by hand). The task is named after its branch unless you type a name. Nothing in git changes: the task continues on that branch as it is.
    - for the project folder: the task runs in the project’s own folder, and a project can have several such tasks. Its **Branch** field starts as the branch checked out there; left as it is, nothing in git changes. Another branch is checked out first, and uncommitted changes come along unless they clash with it. When git can’t simply switch, Shellforge asks: **Stash and Switch** for clashing changes (stashed as “Shellforge: before “<task>””), **Create Branch** for a branch that doesn’t exist yet (made from the one checked out), **Use That Worktree** for a branch another worktree has checked out, and **Switch Anyway** when another task is working in the folder. Cancel leaves the folder as it was and the sheet open.
  - **Agent:** agent, model and reasoning. The model and reasoning start at the agent's default from Settings › Agents, else the model last used with that agent and that model's own reasoning level.
  - **Prompt:** an optional first prompt. "/" lists the agent's commands and skills.
  - **Options:** "Include Jira ticket details", and "Open ssh <host> beside the agent".
  - **Keys:** ⌘↩ is the main button. ⎋ closes an open list first, then goes back a step.
- **Agents:** Claude Code, Codex, Grok Build and PI are built in; six ready-made agents and your own are in [Agents](#agents).
  - Codex runs without approvals or sandbox, and its command preview shows that. It acts on whatever it reads without asking: a Jira ticket’s text (with “Include Jira ticket details”) or a reviewed merge request’s files and `AGENTS.md`. Someone who can edit those can make it run commands as you. To keep its approvals, replace the preset with a custom agent of the same id.
  - An agent whose command isn't on your login PATH can't be picked, and the sheet says why.
  - Custom agents are JSON files in `~/Library/Application Support/Shellforge/agents/`, which Settings › Agents writes for you. A file with a preset's id replaces that preset.
  - Beyond four agents, the picker is a menu instead of segments.
  - Shellforge remembers the last agent per project and the last model per agent.
- **Worktree and branch.** (A project-folder task has neither: it uses the project’s own folder and its checked-out branch.)
  - A task works in `<project>/.worktrees/<slug>`, with `.worktrees/` excluded from git.
  - Its branch is `<type>/<key>-<slug>`. A project set to Branch Names › Ticket Key Only names it after the picked ticket alone instead (`ABC-123`); with no ticket it is `<type>/<slug>` as usual, and the Type select is hidden while the key is the branch. A branch you type still wins: typed in place of the key without a type, such as `ABC-123-v2`, it is the whole branch exactly as typed and the Type select stays hidden; typed with a type, such as `fix/alarms`, it picks that type. A project using Type and Name works as before. The worktree folder stays `<key>-<slug>`.
  - A long first prompt goes to `.shellforge/first-prompt.md` in the worktree.
  - If creating the worktree fails, nothing is saved and the sheet keeps what you typed.
  - While it creates, the sheet is locked and says what it is doing — fetching the base, making the worktree, or running the repository's own checkout hook (a pre-commit `uv sync` can take a while). Cancel, or ⎋, stops it: the command and everything it started end, the half-made worktree and branch are removed, and nothing is saved.
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
  - For a project-folder task, Remove only forgets the task: the folder and its branch stay as they are, and nothing is deleted.
  - A failed removal, and a branch that stays, are logged in full — each git command and all of its stderr — to the macOS log: `log show --last 1h --predicate 'subsystem == "io.github.nathangel.shellforge" AND category == "removal"'`.
  - Uncommitted changes ask Keep, or Delete Changes and Remove.
  - The task's tabs close first, in every window, through iTerm2's own close.
  - A branch with commits its base lacks asks whether to keep it.
  - A review's branch goes only when nothing would be lost.
  - A task continued in a worktree outside the project's `.worktrees/` folder is only forgotten: its tabs close, and the worktree and its branch stay where they are. The question says so.
  - While it runs, the row reads "Removing…", or why it stopped.
  - When something still writes into the worktree as it is deleted, such as a dev server, the removal stops and says which program holds the folder (“node (4211)”), with Try Again and Cancel. Cancel keeps the task and its row.
- **Status dot:**
  - idle: a ring;
  - working: a spinning arc, or a still one under Reduce Motion;
  - needs input: amber;
  - done: green, until you look at the task.
- **The task row** shows the agents, the title, the Jira and MR/PR badges, VS Code and the branch.
- **Lines changed.** A task's VS Code badge shows how far its worktree has moved from its base branch, such as `+12 −3`.
  - It counts commits, uncommitted edits and new untracked files, but not ignored or binary files.
  - Hover it to see the base: "Open in VS Code — 12 added, 3 removed against main".
  - A task with nothing changed shows the plain badge. The counts update within about 5 seconds.
- **Moving between tasks.**
  - ⌃⌘] and ⌃⌘[ step through the open projects' tasks, wrapping round. They never open a tab.
  - **Focus View (⌃⌘A)** opens the projects with a task or terminal waiting on you, folds the rest, and shows the first one.
  - **List View (⌃⌘L)** opens every project.

## Agents

Any coding agent that runs in a terminal can start a task, not only the four built in.

- **Settings › Agents** lists every agent, in three kinds:
  - **built in:** Claude Code, Codex, Grok Build and PI, with their own hooks (the bolt) as before;
  - **ready-made:** Aider, Amp, GitHub Copilot CLI, Gemini CLI, Goose and OpenCode, shipped with Shellforge and offered once installed. One that isn’t installed stays out of New Task’s “not installed” note;
  - **your own:** added with **Add Agent…**.
  - Each row shows the agent’s mark and name, whether it is installed and how its status is read (“Installed · Exact status”), **Edit…**, and a **…** menu with **Duplicate**, and **Remove** for your own agent or **Restore Default** for a changed built-in or ready-made one.
  - Changes to agents are saved at once, not on Settings’ Save. They reach New Task and New Review in every window straight away.
- **The form** (Add Agent… or Edit…) has:
  - **Name**;
  - **Command:** the program, then its fixed arguments. `{model}`, `{reasoning}` and `{cwd}` are filled in when a task starts. An agent with no models of its own skips Model and Reasoning in New Task;
  - **How the first prompt gets in:** As an argument, Typed in after it starts, or None;
  - **Environment variables** and **Secrets**;
  - **Status:** Automatic or Exact (not for a built-in agent, whose hooks report).
  - Problems show as you type: a missing name or one already taken, an unclosed quote, a command that isn’t on your login PATH, an argument prompt with no `{prompt}`, a variable set twice. A preview shows the line a task will type.
- **How the prompt gets in.**
  - **As an argument:** where `{prompt}` stands, for example `-p {prompt}`. A long or awkward prompt goes through `.shellforge/first-prompt.md`, as for the built-in agents.
  - **Typed in after it starts:** Shellforge starts the agent, waits until the agent itself is running (not `shellforge-run` still fetching its settings) and has printed and gone quiet, or for 8 seconds of it running, then pastes the prompt once and presses Return. It types only into the agent: while another program is in front it waits, and after 30 seconds without the agent it gives up. If `shellforge-run` fails or the agent exits first, nothing is typed into the shell left behind; when the agent exited, the sidebar says so.
  - **None:** the agent starts with no prompt.
- **Environment and secrets.**
  - A secret’s value is kept only in the Keychain, never in the agent’s file. A variable whose name looks like a secret (`TOKEN`, `API_KEY`, `PASSWORD`…) must be a secret.
  - Every agent that isn’t built in, and a built-in one with an environment of its own, starts through `shellforge-run` in the app bundle. It takes the environment from Shellforge’s helper just before the agent starts, so no value is in the typed line, the scrollback or your shell history.
  - A secret with no value stops New Task with a sentence naming it.
  - A secret’s Keychain entry is `agent.<id>.<VARIABLE>`, as the form writes it; an agent file you wrote yourself may name its own entry, starting with `agent.`, and the form keeps that name until you rename the secret or type a new value. Any other name is read as `agent.<id>.<VARIABLE>`, so an agent can’t be handed Shellforge’s own Jira, GitLab or GitHub token or Backpack password.
  - An agent file you wrote yourself whose id has more than letters, digits, `-` and `_` starts as it did before, unwrapped; it can’t have an environment or secrets until its id is one of those.
- **Status.** Any agent’s tab gets the status dot, in two ways:
  - **Automatic:** guessed from the agent’s terminal, with nothing to set up. The dot goes **working** while the agent prints steadily, **done** about 30 seconds after it stops, and **needs input** when it rings the bell or posts a notification (OSC 9, or OSC 777 `notify`). Your typing, and the terminal echoing it, doesn’t count, though an agent that redraws its screen on every key can look working while you type. A guessed dot’s tooltip says “Status guessed from the terminal”.
  - **Exact:** the agent’s own hooks run `shellforge-status working`, `needs-input` or `done`. The form shows the lines to add, with the full path into the app, or a snippet for the agent’s settings file where Shellforge knows it (Gemini CLI, GitHub Copilot CLI), and **Copy**. **Test** waits for a report from a task with this agent. While macOS runs Shellforge from a temporary copy, the form warns instead of showing a path that would be gone after it quits.
  - **Which tabs get a dot:** a task’s tab reports the task’s own agent while that agent, or `shellforge-run` starting it, is the program running in it; a shell, an editor or a build there gets no guessed dot. A tab of no task gets a dot when the program running in it is the command of exactly one agent that isn’t built in. The built-in agents keep reporting through their own hooks.
- **Restore Default** (a changed built-in or ready-made agent) asks, then removes your changes to its command, environment and secrets.
- **Remove** (your own agent) asks first and names the tasks that use it. They stay in the sidebar but can’t start it again. Its secrets are deleted from the Keychain.

## Tabs and panes

- **New Tab in Home Folder.** Use the header's terminal button or Tasks › New Tab in Home Folder (no key: ⌘T is iTerm2's). It opens and selects a shell in your home folder, listed under **Other Tabs**. It works whenever a terminal window is in front, with or without a project.
- **A task's tabs** are listed under it when it is selected and has more than one. Tabs of no task are listed under **Other Tabs**.
- **Closing from the sidebar.** Right-click a tab row, or a task row, for **Close Tab**. On a tab split with ⌘D, the item reads **Close Pane** and closes only the focused pane.
  - Anything running asks first, as ⌘W does.
  - A task row brings its tab to the front before closing a pane of it.
- **A task's last pane.** Closing it asks first, with **Close Tab** as the default. The task stays in the sidebar with its worktree and branch, and clicking its row opens a shell there again. Tick **Also delete the worktree** to remove the task as well, and **Also delete branch** under it to delete its branch. A review is never offered its branch. Cancel keeps both the pane and the task. For a project-folder task, or a worktree outside `.worktrees/`, the box reads “Also remove the task from Shellforge” and nothing on disk is deleted.
- **Panes join their task.** A pane split off a task's tab, a project's tab or a terminal's tab joins it. Closing the agent's pane first leaves the task its other pane.
- **The window stays open.** When a close would leave the window with no tab, a fresh shell tab opens first, in the default folder. This applies to Close Tab, Remove Task and Remove Terminal.

## Terminals

- **New Terminal.** Use ⌃⌘T or the project's "+". It adds a named row under the project, and a plain shell tab in the project's folder. The name is "Terminal", or the next free "Terminal n".
- **Right-click a terminal row** for:
  - Rename…, which renames the row, not the tabs;
  - Open in;
  - Rearrange;
  - Remove Terminal, which closes its tabs and asks nothing, because nothing on disk is touched.

## Metrics

- **The strip.** One line pinned at the bottom of every panel: the Mac's `cpu` and `ram`, then each vendor's mark with its first window (`wk` when it reports one) as a ring and a percent, such as `cpu ◔ 23%  ram ◔ 61%  Ⓒ ◔ 84%`.
  - It never wraps: when the sidebar is too narrow, the last vendors fold into `+1`, `+2`….
  - Hover a reading for its words. Click the strip to open the Metrics panel.
- **The Metrics panel** shows everything in full, scrolling when the window is short:
  - **System**: the selected task's or tab's agent, with its context ring and percent and its token counts, such as `in 936k · out 5.6k`, with exact figures in the tooltip;
  - **Mac**: `cpu` and `ram`, plus `bat` on battery, sampled every 5 s. A reading turns amber only when macOS warns. Click it for Backpack Mode, or right-click for Mac Settings…. While Backpack Mode is on or switching, a line below says so;
  - **Usage**: one row per vendor (Claude, Codex) with the weekly (`wk`) and 5-hour (`5h`) windows and their reset times.
- **Rings** turn amber at 80%.
- **Vendors you don't use are hidden.** A vendor with no usage data whose CLI isn't installed gets no row and no gauge. Once installed, it reads "No usage data yet" until its first report.
- Claude reads "Usage disconnected" (amber) until its status-line shim is installed (Agent hooks).

## Dock badge

- The Dock icon counts the task and terminal rows waiting on you, the same rows Focus View shows. Each row counts once, however many windows show it. There is no badge at zero.

## Backpack Mode

- **Turning it on.** Use View › Backpack Mode (⌘B), or click the Mac row in the Metrics panel. Both open its sheet; with the mode on, they turn it off.
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
  - **Core:** the Mac card (Backpack setup), the Environment card and the Feedback switch.
  - **Agents:** every agent, built in, ready-made and your own, to add, edit, duplicate or remove ([Agents](#agents)); then one row per installed agent, with its **Default model** and **Default reasoning**.
  - **Services:** Jira (site, email, API token), GitLab (host, token) and GitHub (token).
- **Connections.**
  - Tokens are kept only in the Keychain, and URLs must be https.
  - Connections are tested when Settings opens and when you stop typing.
  - Disconnect takes effect on Save.
- **Agent hooks (the bolt)** have one row per agent, with its state and one button: Install, Repair or Reinstall. ⌘↩ or ⎋ closes the sheet.
  - Files change only when you click, and each is backed up once as `.shellforge-backup`.
  - The files are `~/.claude/settings.json`, `~/.codex/config.toml`, `~/.grok/config.toml` and `~/.pi/agent/extensions/shellforge-status.ts`.
- **Default model and reasoning.** Settings › Agents sets what New Task and New Review start each agent with; you can still change it per task.
  - Until you pick one, a row shows what the sheets would use now: the model last used with that agent, else the first in its list, at that model's own reasoning level.
  - Only a row you change is saved, on Save. A saved default stays when you start a task with something else.
  - If a saved model is no longer offered, the row says so and the sheets ask you to choose a current model instead of quietly starting another.
- **Settings looks like System Settings:** Core, Agents and Services are each one grouped box, one row per setting or service.
- **Feedback.** Settings › Core › Ask for feedback now and then, a switch, on by default, takes effect on Save. Turning it back on waits 90 days before the next note. Help › Send Feedback… works either way.
- **Terminal.** Settings › Core › Match the terminal to Shellforge, a switch, off by default, takes effect on Save.
  - Every terminal, including tabs opened later, uses Shellforge's colours: a background one step off the sidebar (darker in dark mode, lighter in light mode), the sidebar's text and selection colours, the macOS accent colour for the cursor, and macOS's system colours for the 16 terminal colours, each readable on the background.
  - iTerm2 uses its Minimal theme, so the title bar and window edges match. Settings › Appearance's Theme is greyed out while it is on.
  - Your profiles and your theme setting are not changed. Switching it off brings them back at once.
  - A colour set for one tab (Edit Session, the Python API) still wins.
  - In light mode the match uses a light palette, and it switches when the appearance does.

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
| ⌘+ / ⌘− / ⌘0 | Sidebar text bigger / smaller / normal, after a click in the sidebar |

- They act on the key window's sidebar.
- iTerm2's own keys are unchanged.
- ⌃⌘D, ⌃⌘Q and ⌃⌘Space belong to macOS, so Shellforge does not use them.

## VoiceOver

- **Rows** read their title and status.
- **Named actions:**
  - tab rows: Close;
  - terminal rows: Rename, Rearrange and Remove Terminal;
  - dividers: Rename, Rearrange and Remove Divider;
  - project, task and SSH rows: Rearrange (greyed menus aside, it is left out while another window is rearranging);
  - in Rearrange mode, every row: Move Up / Move Down (while possible), one step within its own list, and a project's Fold / Unfold.
- **Labels:** tunnel rows read their state, the Metrics panel's Mac row reads its readings, and the metrics strip reads all of its readings and opens the panel.

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

## Check for Updates…

- **Where.** Shellforge › Check for Updates…, or Check For Updates in the status bar menu.
- **Where updates come from.** Shellforge's own releases on GitHub (`NathanGel/shellforge`), read without a token. iTerm2's update feed is never used, and Sparkle never checks on its own.
- **What it says.**
  - “You’re on the latest version (x.y.z).”
  - “Shellforge x.y.z is available.” with Update and Later. ⎋ is Later.
  - Otherwise one line on what stopped it, such as no network, GitHub's rate limit, or a release without its image.
- **Update.** Shellforge checks that it may replace itself, downloads `Shellforge-x.y.z.dmg` behind a small progress window, and checks the app inside. It must be Shellforge, be that version, and be signed like the running app. Shellforge then quits, the new version moves into place, and it opens.
  - The old version is kept in `~/Library/Caches/io.github.nathangel.shellforge/Updates/previous/` until the next launch clears that folder.
  - If the swap fails, the old version comes back, and the next launch says why.
- **When it doesn't update.**
  - A Development build says it is one, and never asks GitHub. So does a build whose version is not `x.y.z`, such as `3.7.dev`; only the release script stamps one.
  - A copy run from Downloads or a disk image is asked to move to Applications first.
  - Drafts and prereleases are never offered, and nor is a version older than the one running.
- The menu item is disabled while a check or an update is under way.

## Reporting a bug

- **Shellforge › About Shellforge › Report a bug** opens Shellforge's bug form on GitHub with the version and macOS filled in. [CONTRIBUTING.md](CONTRIBUTING.md) says how requests are handled.
- **After a crash**, the next launch offers to report it. **Copy and Report…** copies the report — the crash log, your settings, and your name and email in its message — and opens the bug form, where you paste it. Nothing is sent by itself; GitHub issues are public, so delete what you do not want to share. **Discard** forgets that crash.
- Error messages that ask you to report a bug, and the AI usage item's **Report a Bug**, lead to the same form.
- The bug form mentions the error log (Help › Show Error Log), so you can paste the lines that apply. Nothing from it is attached by itself.

## Error log

- **What it is.** A plain text file with one line for each real problem: an error the sidebar shows, a task or review whose removal failed or whose branch was kept and why, the helper not starting or its connection lost, an update that didn't check, download, verify or install, the workspace file that couldn't be read or saved, a Project folder that couldn't switch branch, and Backpack Mode steps that failed.
- **Where it lives.** `logs/errors.log` in Shellforge's data folder, `~/Library/Application Support/Shellforge/logs/` for the installed app; a dev build keeps its own. Past about 1 MB it becomes `errors.1.log`, replacing the older one, and a new file starts.
- **Each line** is the time with its offset, the version, the part of Shellforge, and what happened: `2026-11-10T09:14:11+01:00 · 0.9.1 · removal · Branch fix/login kept: not merged into main`. A message of several lines becomes one, with ⏎ where each break was, and one longer than 4,096 characters is cut, ending in “…”.
- **One problem, one line.** The same part and message again within five minutes is not written again: a helper that stays down, retried every few seconds, or one event that every open window's sidebar sees. The helper not starting is written from its second try on, and a failed connection to it once until a connection holds again.
- **What it never holds:** terminal contents, typed commands, prompts, tokens, passwords or environment values. Paths in your home folder are written with `~`, and a URL's user and password are left out. It stays on your Mac and is never sent anywhere.
- **Help › Show Error Log** shows the file in Finder, an empty one if nothing has gone wrong yet.

## Feedback

Feedback is how Shellforge learns what to add and what to fix: without it, nobody sees what people need. The note and the form both say so.

- **A note in the sidebar.** In a release build, 14 days after you first use Shellforge, a note at the top of the sidebar, under the header, asks what you think. It shows in every window at once. A Development build never shows it.
  - Once it is due, it appears in the next window you open, when you switch back to Shellforge, when your Mac wakes, or when you start a task or review. No relaunch is needed.
  - **Give Feedback** opens the form. **Not Now** hides the note in every window and asks again in 90 days. **Don’t Ask Again** turns the note off; Settings › Core › Ask for feedback now and then turns it back on.
  - Closing the form without sending counts as Not Now. After you send, the next ask is 180 days away.
- **Help › Send Feedback…** opens the same form whenever you like, with the note on or off. With no terminal window open, it offers GitHub’s feedback form instead.
- **Once a day.** After feedback is sent, Send waits a day, however the form was opened, and the form says from when you can send more. GitHub’s own form, posted under your own account, stays available in the meantime.
- **The form** asks how Shellforge is for you (a rating from 1 to 5, optional), what is working well, and what is missing or gets in your way. It says first that feedback becomes a public issue on github.com/NathanGel/shellforge, so leave out names, client details, commands, output, paths and passwords.
  - Sent through Shellforge, the issue is posted anonymously by a bot, and you can’t edit or delete it yourself. With it go your rating, your two texts, Shellforge’s version and your macOS version. Your IP address is used only for a one-minute rate limit and is not kept.
  - **If sending can’t get through**, or the build has no relay, the form offers GitHub’s prefilled feedback form in your browser instead, and that issue is posted under your own GitHub account. A long text is cut to fit the link, and the whole of it is copied to the clipboard.
- **Nothing is sent by itself.** Nothing leaves your Mac until you press Send, and what you type is never saved to disk.
