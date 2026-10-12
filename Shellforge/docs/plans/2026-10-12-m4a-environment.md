# M4a The environment, shown and kept current — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The environment requirements M1 left open:
- **E6:** when your login shell can't be read, a warning in the sidebar.
- **E5:** a "not found" error points at where to look.
- **E8:** Settings › Core shows the environment Shellforge runs things in — the shell, when it was read, the PATH, where git, uv, python3, node, ssh and each agent CLI were found — with a Reload button.
- **E9:** a changed `~/.zshenv`, `~/.zprofile` or `~/.zshrc` is read again without a relaunch.

**Architecture:**
- **Core:**
  - `CommandLauncher` records when it read the environment.
  - `EnvironmentReport` is a value built from a launcher and the agents: the shell or the fallback's reason, when it was read, the PATH's folders, and each tool's path or none.
  - `RCFiles` notices a changed rc file by its modification date.
- **UI:**
  - An `EnvironmentCard` in Settings › Core, driven by an `EnvironmentModel`.
  - `SidebarModel.environmentWarning`, shown by `SidebarBanners`.
- **App:** a 30 s check of the rc files; on a change, the environment is read again off the main thread, and every sidebar's warning is refreshed.

**Tech Stack:** Swift 6 language mode, macOS 13, SwiftUI; Swift Testing via `Shellforge/scripts/swift.sh`.

**Spec:** PRD "Requirements: environment", rows E5, E6, E8 and E9.

## Global Constraints

- No test runs a real login shell, or reads the real home's rc files: launchers are built with `CommandLauncher(resolve:)`, and homes are temporary folders.
- Reading the environment (a login shell, up to 15 s) never runs on the main thread.
- Tool lookups for the report use the environment as read, with no re-read per miss: E4's re-read is for launching, and a report of five misses must not run five login shells.
- macOS 13; design tokens only (`DesignRulesTests`). Commits by path, ending `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; never push.

## Review Focus

1. **The login shell times out at launch** (a slow rc file). Expected: the sidebar warns once, with the reason. Reload in Settings, or a fixed rc file, clears it. Test: Task 3 `aFallbackEnvironmentWarnsAndAReadClearsIt`.
2. **An rc file is deleted, or created where none was.** Expected: either counts as a change. Test: Task 1 `aCreatedOrDeletedFileIsAChange`.
3. **A tool is a symlink** (Homebrew's `/opt/homebrew/bin/node`). Expected: the report shows where it was found on PATH, not where it resolves. Test: Task 1 `aToolIsShownWhereItWasFound`.
4. **Reload pressed twice quickly.** Expected: one read at a time, with the button disabled while it reads. Test: Task 2 `reloadIsOneAtATime`.
5. **A very long PATH** (30+ folders). Expected: the card lists them one per line, and the sheet scrolls. This is checked visually in the live check.

---

### Task 1: The report, the rc files, and the not-found message

**Files:**
- Modify: `Shellforge/Sources/ShellforgeCore/CommandLauncher.swift`:
  - `init(resolve:clock:)`, where `clock` is `@Sendable () -> Date`, defaulting to `Date.init`.
  - `public var readAt: Date?`, set by each read.
  - `CommandNotFound.description` ends with " Settings › Core shows the environment Shellforge uses."
- Create: `Shellforge/Sources/ShellforgeCore/EnvironmentReport.swift`:
  - `struct EnvironmentReport { shell: String?; fallbackReason: String?; readAt: Date?; path: [String]; tools: [Tool] }` with `Tool { name; path: String? }`.
  - `static func make(launcher:agents:) -> EnvironmentReport` covers the tools `git`, `uv`, `python3`, `node` and `ssh`, then each agent's command once.
- Create: `Shellforge/Sources/ShellforgeCore/RCFiles.swift`: `struct RCFiles { init(home:); mutating func changed() -> Bool }`, over `.zshenv`, `.zprofile` and `.zshrc`. The first call only records, and says false.
- Tests: `Shellforge/Tests/ShellforgeCoreTests/EnvironmentReportTests.swift`:
  - `theReportSaysTheShellPathAndTools`
  - `aFallbackSaysWhy`
  - `aToolIsShownWhereItWasFound`
  - `eachAgentCommandOnce`
  - `notFoundPointsAtSettings`
  - `anEditedRCFileIsAChange`
  - `aCreatedOrDeletedFileIsAChange`
  - `theFirstLookIsNoChange`

### Task 2: Settings › Core › Environment

**Files:**
- Create: `Shellforge/Sources/ShellforgeUI/Settings/EnvironmentCard.swift`:
  - `EnvironmentModel: ObservableObject` holds `report` and `reading`, and offers `load()` and `reload()`. A read runs off the main actor, one at a time.
  - `EnvironmentCard` uses the `SettingsCard` look:
    - its status reads "Read from <shell> <relative time>", or the fallback's reason in amber;
    - the PATH folders show in the code face;
    - the tools show as "name — path" or "name — not found";
    - a Reload button.
- Modify: `SettingsPanel.swift`: the card goes after the Mac card in Core. `ShellforgeSidebar.showMacSettings` passes the model, built from `model.launcher` and `model.agents`.
- Tests: `Shellforge/Tests/ShellforgeUITests/EnvironmentCardTests.swift`:
  - `loadShowsTheReport`
  - `reloadReadsAgain`
  - `reloadIsOneAtATime`
  - `theStatusLineSaysTheShellOrWhy`

### Task 3: The sidebar's warning, and rc files read again

**Files:**
- Modify: `SidebarModel.swift`:
  - `@Published public private(set) var environmentWarning: String?`, set after the environment is first read (off the main actor, at init) and by `environmentChanged()`.
  - The text is "Your login shell's environment couldn't be read (<reason>); Shellforge is using a fallback PATH. Settings › Core shows it."
- Modify: `SidebarRows.swift` `SidebarBanners`: the warning shows as a `.warning` banner.
- Modify: `EnvironmentModel.reload()` calls an `onReloaded` hook, which the app uses to refresh every sidebar.
- Modify: `sources/TerminalView/iTermShellforgeSidebar.swift`:
  - A 30 s timer (beside the report tick) checks `RCFiles.changed()` off the main thread.
  - On a change, it runs `launcher.reload()` and calls `environmentChanged()` on every sidebar.
  - It stops at terminate, as the tick does.
- Tests: `Shellforge/Tests/ShellforgeUITests/EnvironmentWarningTests.swift`:
  - `aFallbackEnvironmentWarnsAndAReadClearsIt`
  - `aLoginShellEnvironmentWarnsNothing`

### Task 4: Verify in the app

- Build; the package and the daemon pass.
- Live check, for the user:
  1. Settings (the gear) › Core › Environment lists the shell, the PATH and the tools.
  2. Add a line to `~/.zshrc` that puts a new folder on PATH: within 30 s, Reload is not needed, and the card shows it on reopening.
