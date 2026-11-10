# Shellforge

Shellforge's own code, kept apart from iTerm2's sources so upstream merges stay small. It is a Swift
package that builds and tests with swiftly's Swift 6.4, without Xcode:

    scripts/swift.sh test

It targets macOS 13, iTerm2's deployment target, so the app can link it. Every change Shellforge
makes to iTerm2's own files is listed in [docs/upstream-hook-points.md](docs/upstream-hook-points.md).

## ShellforgeCore

**Every command finds its tools.** An app opened from the Dock gets
launchd's `PATH`, `/usr/bin:/bin:/usr/sbin:/sbin`, and none of what `~/.zprofile` and `~/.zshrc`
add. So a git hook calling `uv` from Homebrew fails with "uv: command not found", while the same
command works in a terminal tab.

- `LoginEnvironment` asks the user's login shell for its whole environment once (`-l -i -c`, after a
  marker, 15 s deadline), drops the shell's session keys and the app's launch identity, and falls
  back to the usual tool folders with a stated reason when the shell cannot answer.
- `CommandLauncher` is how every command starts: it finds the executable on that `PATH`, reads the
  environment again once on a miss, and otherwise throws `CommandNotFound`, which names the command
  and the `PATH` searched.
- `ChildProcess` is the only code that creates a `Process`. `SourceRulesTests` fails the build if
  anything else does.

`GitHookPathTests` reproduces the original bug: under launchd's `PATH` a `post-checkout` hook that
calls `uv` fails; through `CommandLauncher` it runs.

## ShellforgeDesign

AiTerm's design system: the colours, sizes and primitive views everything else is drawn from, with
the rules its tests enforce. See [Sources/ShellforgeDesign/README.md](Sources/ShellforgeDesign/README.md).

## ShellforgeUI

The sidebar at the left edge of every terminal window: the activity bar, the Sessions panel
(projects → tasks → tabs) and the Metrics panel, the metrics strip under them, and the sheets and
Settings they open. The window code reaches it through
`sources/TerminalView/iTermShellforgeSidebar.swift`. Everything it does, and how to reach it, is
in [FEATURES.md](../FEATURES.md).

## shellforged

The daemon that tracks agents' status and usage from their hooks, in `daemon/`, with the hook shims
it installs in `hooks/`. See [daemon/README.md](daemon/README.md).

## Also here

- `feedback-relay/`: the Cloudflare Worker that posts the app's feedback as GitHub issues. See
  [feedback-relay/README.md](feedback-relay/README.md).
- `scripts/`: building the app (`make-app.sh`, `make-dmg.sh`), releasing (`release.sh`,
  `changelog-notes.sh`, see [docs/releasing.md](docs/releasing.md)), the README's screenshots
  (`render-screenshots.sh`), the AiTerm importer (`import_aiterm.py`) and the pinned toolchain
  (`swift.sh`).
- `docs/`: [the keyboard](docs/keyboard.md), [releasing](docs/releasing.md) and
  [the changes to iTerm2's own files](docs/upstream-hook-points.md).
