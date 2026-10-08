# Shellforge

Shellforge's own code, kept apart from iTerm2's sources so upstream merges stay small. It is a Swift
package that builds and tests with swiftly's Swift 6.4, without Xcode:

    scripts/swift.sh test

It targets macOS 13, iTerm2's deployment target, so the app can link it.

## ShellforgeCore

**Every command finds its tools** (PRD requirements E1 to E7). An app opened from the Dock gets
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
