<div align="center">

# Shellforge

### iTerm2 with a sidebar for projects, tasks and coding agents

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

Everything iTerm2 does still works as it does in iTerm2.

## Get it

Download the latest `Shellforge-<version>.dmg` from
[Releases](https://github.com/NathanGel/shellforge/releases/latest). The
[setup guide](Shellforge/docs/setup.md) covers installing, connecting Jira, GitLab and GitHub,
agent hooks, and moving over from AiTerm. Shellforge updates itself from **Shellforge › Check for
Updates…**.

Apple silicon, macOS 13 or newer, Python 3.11 or newer.

## Docs

- [Setup guide](Shellforge/docs/setup.md)
- [Every feature](Shellforge/docs/features.md) and [the keyboard](Shellforge/docs/keyboard.md)
- [The code](Shellforge/README.md): Shellforge's own code lives in `Shellforge/`, apart from iTerm2's
- [Changes to iTerm2's own files](Shellforge/docs/upstream-hook-points.md)
- [Releasing](Shellforge/docs/releasing.md)

## Building

    Shellforge/scripts/make-app.sh      # → build/Shellforge.app

Xcode 27 and swiftly's Swift 6.4. Tests: `Shellforge/scripts/swift.sh test --package-path Shellforge`.

## Credits and license

Shellforge is built on [iTerm2](https://github.com/gnachman/iTerm2) by George Nachman and its
contributors (iTerm2's own readme is [README-iTerm2.md](README-iTerm2.md)), and ports
[AiTerm](https://github.com/dhondtlaurens/aiterm) by Laurens D'Hondt. It is free software: iTerm2's
code is under the GNU GPL version 2 or later ([LICENSE](LICENSE)), and Shellforge's own code and
the app as a whole are under the GNU GPL version 3 ([Shellforge/LICENSE](Shellforge/LICENSE)).
Shellforge is not affiliated with or endorsed by the iTerm2 project.
