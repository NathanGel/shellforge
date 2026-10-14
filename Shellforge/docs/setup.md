# Setting up Shellforge

Shellforge is iTerm2 with a sidebar for projects, tasks and agents. This guide takes a Mac from
nothing to a working setup, and covers moving over from AiTerm.

## What you need

- **A Mac with Apple silicon**, on macOS 13 or newer. Releases are built for Apple silicon only.
- **Python 3.11 or newer** on your `PATH`, for Shellforge's helper. The `python3` that comes with
  macOS is too old. Install it with Homebrew (`brew install python`) or from python.org.
- **git**, from the Xcode Command Line Tools (`xcode-select --install`) or Homebrew.
- **The agents you use**, such as Claude Code, Codex, Grok or PI, installed and working in a
  terminal.

## 1. Install

1. Download `Shellforge-<version>.dmg` from the latest release:
   https://github.com/NathanGel/shellforge/releases/latest
2. Open it and drag **Shellforge** onto **Applications**.
3. The first time, **right-click Shellforge in Applications › Open**, then **Open** again. Shellforge
   is signed with its own certificate, not an Apple-issued one, so macOS asks once. From then on it
   opens normally, and updates install without asking.

If macOS still refuses ("damaged" or "can't be opened"), run this once in Terminal, then open it
again: `xattr -dr com.apple.quarantine /Applications/Shellforge.app`

## 2. First launch

- Every window has the sidebar on its left. **⌃⌘S** hides and shows it.
- A yellow banner about a "fallback PATH" means your login shell could not be read. Settings ›
  Core › Environment shows where each tool was found, and **Reload** reads it again.
- Shellforge asks for **Location** only if you use Backpack Mode, which needs it to name Wi-Fi
  networks.

## 3. Projects

- **Add a project** with **⌃⌘P**, the header's **+**, or the empty sidebar's button. Pick any folder
  inside a git repository.
- **Right-click a project** for New Task, New Review, New Terminal, Jira Projects…, Tunnels…, SSH
  Host…, Pull <default branch>, the moves, and Remove Project….
- `Shellforge/docs/features.md` lists every feature.

## 4. Connect Jira, GitLab and GitHub

Click the sidebar's **gear** to open Settings, then **Services**.

- **Jira:** your site (`https://<company>.atlassian.net`), your email and an API token from
  https://id.atlassian.com/manage-profile/security/api-tokens
- **GitLab:** your server and a personal access token with `read_api`.
- **GitHub:** a token with access to the repositories you review.

Each connection is tested as you type. Click **Save**.

## 5. Agent hooks

Click the sidebar's **bolt** and **Install** the hook for each agent you use. That is how the
sidebar knows when an agent is working, waiting on you or done. Each file Shellforge changes is
backed up once as `.shellforge-backup`.

## Coming from AiTerm

1. Connect Jira, GitLab and GitHub as in step 4. Tokens live in the Keychain and are not copied
   between apps.
2. Quit Shellforge, then run the importer from a clone of this repository:

       Shellforge/scripts/import_aiterm.py --dry-run   # shows what it would do
       Shellforge/scripts/import_aiterm.py

   It brings over:
   - your projects in AiTerm's order, with their Jira links;
   - the dividers, terminals and tasks (a task whose worktree is gone is left out);
   - the agent and model each project last used.

   A folder Shellforge already has keeps its own settings. Your workspace as it was is kept beside
   it. Running it again adds nothing.
3. Open Shellforge.

## Where your setup is kept, and why a reinstall keeps it

Nothing of your setup is inside the app, so deleting it, reinstalling or updating changes none of
this:

| What | Where |
|---|---|
| Projects, tasks, terminals, dividers, tunnels | `~/Library/Application Support/Shellforge/workspace.json` (a backup beside it on every save) |
| Jira site and email, GitLab host | `~/Library/Preferences/io.github.nathangel.shellforge.plist` |
| iTerm2's own preferences and profiles, the sidebar's width and visibility | `~/Library/Preferences/Shellforge.plist` |
| Jira, GitLab and GitHub tokens | the Keychain, service `io.github.nathangel.shellforge` |

To move to another Mac, quit Shellforge on both. Then:
1. Copy `~/Library/Application Support/Shellforge/` and the two preference files above to the same places on the new Mac.
2. Open Shellforge there and enter your tokens again in Settings › Services.

## Updates

**Shellforge › Check for Updates…** looks at this repository's latest release. If it is newer, it
downloads it, checks its signature, replaces the app and relaunches. Your setup stays, as above.
Builds made from source are marked as development builds and do not update themselves.

## Building from source

    git clone https://github.com/NathanGel/shellforge.git
    cd shellforge
    Shellforge/scripts/make-app.sh      # → build/Shellforge.app

You need Xcode 27 and swiftly's Swift 6.4 (`Shellforge/scripts/swift.sh` checks). Making a release
is described in `Shellforge/docs/releasing.md`.
