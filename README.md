<div align="center">

# Shellforge

### iTerm2 with a sidebar for projects, tasks and coding agents

[![Latest release](https://img.shields.io/github/v/release/NathanGel/shellforge)](https://github.com/NathanGel/shellforge/releases/latest)
[![License: GPL v3](https://img.shields.io/badge/license-GPLv3-blue)](Shellforge/LICENSE)
![macOS 13+ on Apple silicon](https://img.shields.io/badge/macOS-13%2B%20%C2%B7%20Apple%20silicon-lightgrey)

</div>

Shellforge is a fork of [iTerm2](https://iterm2.com) that puts [AiTerm](https://github.com/dhondtlaurens/aiterm)'s
sidebar inside every terminal window:

- **Projects → tasks → tabs.** A task is a git worktree with an agent (Claude Code, Codex, Grok,
  PI) running in its tab; a review is one for a merge request.
- **Live status** from the agents' own hooks: working, waiting on you, done.
- **Jira, GitLab and GitHub:** tickets in New Task, merge requests in New Review, `+n −m` on every
  task.
- **SSH tunnels** per project, started and stopped from the sidebar, and a project's SSH host
  beside its agent.
- **Usage** of each agent's plan in the footer, and **Backpack Mode** for a Mac that keeps working
  with its lid closed.
- **At home on macOS 26:** a floating glass sidebar that follows light and dark, and an optional
  switch to match the terminal's colours to Shellforge.

Everything iTerm2 does still works as it does in iTerm2.

Shellforge follows iTerm2: we merge upstream iTerm2 into Shellforge whenever it is needed for a
security fix or a new feature, so a fix in iTerm2 reaches Shellforge too. Shellforge's own code is
kept apart in `Shellforge/` so these merges stay small.

## Get it

Download the latest `Shellforge-<version>.dmg` from
[Releases](https://github.com/NathanGel/shellforge/releases/latest). The
[setup guide](SETUP.md) covers installing, connecting Jira, GitLab and GitHub,
agent hooks, and moving over from AiTerm. Shellforge updates itself from **Shellforge › Check for
Updates…**.

**Requirements:** a Mac with Apple silicon on macOS 13 or newer, and Python 3.11 or newer.

## Docs

- [SETUP.md](SETUP.md): installing, connecting Jira, GitLab and GitHub, agent hooks, coming from
  AiTerm
- [FEATURES.md](FEATURES.md): every feature and how to reach it, and
  [the keyboard](Shellforge/docs/keyboard.md)
- [CHANGELOG.md](CHANGELOG.md): what changed in each version
- [CONTRIBUTING.md](CONTRIBUTING.md): asking for a change
- [The code](Shellforge/README.md): Shellforge's own code lives in `Shellforge/`, apart from iTerm2's
- [Changes to iTerm2's own files](Shellforge/docs/upstream-hook-points.md)
- [Releasing](Shellforge/docs/releasing.md)

## Building

    Shellforge/scripts/make-app.sh      # → build/Shellforge.app

Xcode 27 and swiftly's Swift 6.4. Tests: `Shellforge/scripts/swift.sh test --package-path Shellforge`.

## Contributing

Shellforge takes **change requests, not pull requests**: open a
[change request or bug report](https://github.com/NathanGel/shellforge/issues/new/choose) on
GitHub. Pull requests are closed without review. [CONTRIBUTING.md](CONTRIBUTING.md) has the details.

## Credits and license

Shellforge is built on [iTerm2](https://github.com/gnachman/iTerm2) by George Nachman and its
contributors (iTerm2's own readme is [README-iTerm2.md](README-iTerm2.md)), and ports
[AiTerm](https://github.com/dhondtlaurens/aiterm) by Laurens D'Hondt. It is free software: iTerm2's
code is under the GNU GPL version 2 or later ([LICENSE](LICENSE)), and Shellforge's own code and
the app as a whole are under the GNU GPL version 3 ([Shellforge/LICENSE](Shellforge/LICENSE)).
Shellforge is not affiliated with or endorsed by the iTerm2 project.
