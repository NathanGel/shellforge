# Changelog

What changed in each Shellforge version, newest first. Every feature is described in
[FEATURES.md](FEATURES.md). Versions follow [the release rules](Shellforge/docs/releasing.md#versions):
a patch fixes, a minor adds features, a major changes a saved setup.

Each version's section is also its GitHub release notes: `Shellforge/scripts/release.sh` publishes
it and refuses to release a version that has none.

## 0.4.0 — unreleased

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
