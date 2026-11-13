# Releasing Shellforge

Adapted from AiTerm's release process.

## Versions

Releases are numbered `major.minor.patch`: `0.1.0` is the first.
- **patch:** fixes only.
- **minor:** new features.
- **major:** a change that breaks a saved setup.

The tag is `v<version>`. The build number is one more than the number of Shellforge releases on GitHub, so it grows
with every release. Builds from source keep iTerm2's version string, such as `3.7.dev`, and are
marked as development builds: they never offer or install an update.

## One-time setup

- **Signing certificate.**
  1. Keychain Access › Certificate Assistant › Create a Certificate…
  2. Name `Shellforge Release`, Identity Type *Self-Signed Root*, Certificate Type *Code Signing*, then Create.
  3. Export a backup: My Certificates › Shellforge Release › Export…, as a `.p12` with a password. Keep it safe.

  A release signed with another certificate cannot update installs signed with this one. Every
  release also keeps the Keychain's "Always Allow" for Shellforge's tokens.
- **GitHub CLI:** `brew install gh`, then `gh auth login`.
- **Xcode 27** and swiftly's Swift 6.4.

## Making a release

First, the changelog. `CHANGELOG.md` keeps the next version's section as `## <version> — unreleased`
while work lands. To release it, replace `unreleased` with today's date (`## 0.4.0 — 2026-10-15`),
commit and push. That section, without its heading, becomes the GitHub release notes; check it with
`Shellforge/scripts/changelog-notes.sh <version>`.

The app ships the helper's folder whole, so the release refuses while
`Shellforge/daemon/shellforged` holds files git doesn't track, such as the `__pycache__/` a test
run of the helper leaves: `git clean -ndX -- Shellforge/daemon/shellforged` lists them. Move them
out of the repository rather than deleting them; Python makes `__pycache__/` again by itself.

Then, from a clean `master` that matches `origin/master`:

    Shellforge/scripts/release.sh <version>

It:
1. checks the branch, the working tree and the helper's folder, `origin`, the tag, that the version
   is newer than the last release, its dated `CHANGELOG.md` section, `gh` and the certificate;
2. runs `Shellforge/scripts/test-all.sh`: the helper's pytest suite, the Swift package suite and the
   feedback relay's `node --test`, and stops before building if any fails. The helper's tests use
   `Shellforge/daemon/.venv` (see its README) and leave no `__pycache__/` behind;
3. builds with `make-app.sh` (iTerm2's Deployment configuration, Apple silicon), stamps the version and build number, and signs with the certificate;
4. wraps the app in `build/Shellforge-<version>.dmg` with `make-dmg.sh`, and checks it;
5. pushes the tag and publishes the GitHub release with the DMG attached and the changelog section as its notes, as a draft first, so updaters never see a release without its image.

After a release, start the next version's section at the top of `CHANGELOG.md` as
`## <next version> — unreleased`.

Running Shellforge sees the new version under **Check for Updates…**.

## If a release stops halfway

- **The tag was pushed but there is no release.** Finish it by hand:
  1. Check whether it exists: `gh release view v<version> --repo NathanGel/shellforge`.
  2. If it doesn't, create it: `gh release create v<version> build/Shellforge-<version>.dmg --repo NathanGel/shellforge --draft --verify-tag --title "Shellforge <version>" --notes-file build/Shellforge-<version>-notes.md`.
  3. If the image is missing, upload it: `gh release upload v<version> build/Shellforge-<version>.dmg --repo NathanGel/shellforge`.
  4. Publish it: `gh release edit v<version> --repo NathanGel/shellforge --draft=false`.
- **The `git push` failed.** The tag exists only locally, and a re-run refuses with "v… already exists".
  - Either retry `git push origin v<version>` and continue as above;
  - or remove the local tag with `git tag -d v<version>` and run the release again.

## Development builds

- `Shellforge/scripts/make-app.sh` alone builds `build/Shellforge.app`, marked as a development build.
- Day-to-day work uses iTerm2's Development configuration: `tools/build.sh` builds it, and `make run`
  builds and runs it.
- `make run` starts the app with `-suite shellforge-dev` (the checkout folder's name and `-dev`), so
  a dev build has its own preferences (`~/Library/Preferences/shellforge-dev.plist`) and its own
  data folder, `~/Library/Application Support/shellforge-dev/`: its workspace, agents and error log.
  The plain folder name would share the installed app's `Shellforge` folder, as macOS folder names
  ignore case. It has the installed app's bundle id, so both share the Jira, GitLab and GitHub
  settings and tokens.
- A dev build's helper is its own too. It runs with `--support-dir` set to the data folder, so its
  socket, log, `daemon.json`, `tunnels.json` and `hook-port` are there, and it listens for hooks
  on a port picked from that folder's path (between 47832 and 48831, the same on every launch)
  instead of the installed app's 47831. A dev build sets `SHELLFORGE_SUPPORT` to its folder in every
  terminal it opens (the installed app clears it), so the status-line shims, `shellforge-status`
  and `shellforge-run` in a dev build's terminal report to the dev build's helper.
- What stays shared: the agents' own settings (`~/.claude/settings.json`, `~/.codex/config.toml`,
  Grok's and PI's) are global, and their lifecycle hooks name one port. A dev build's Agent hooks
  sheet shows the installed app's hooks and leaves them alone; **Install for This Build Anyway…**
  points them at the dev build, after which the installed app shows no working or done until it
  repairs them. The user's own status lines (`statusline-original.cmd`,
  `grok-statusline-original.cmd`) are always recorded in, and read from, the installed app's folder.
- A tmux server started from a dev build's tab keeps that tab's `SHELLFORGE_SUPPORT`, so sessions
  opened through it later still report to the dev build's helper.
- A long `-suite` name can make the socket path (`…/Application Support/<suite>/shellforged.sock`)
  longer than macOS's 104-byte limit for Unix sockets, and the helper then can't start.

## README screenshots

- The README's pictures are drawn from code with invented projects, tasks and readings, never taken
  from a running app: `Shellforge/scripts/render-screenshots.sh` renders them into
  `Shellforge/docs/images/` (`<scene>-<dark|light>.png`).
- Run it after a change to the sidebar, the Metrics panel, Rearrange mode or the New Task sheet, look
  over the PNGs, and commit them with the change. The normal test run skips the renderer
  (`ReadmeScreenshots` runs only with `SHELLFORGE_RENDER_SCREENSHOTS=1`).
