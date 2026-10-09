# M1c-3a Hook Installers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One click per agent installs, checks and repairs the hooks that make Claude Code, Codex, Grok Build and PI report to `shellforged` (port 47831), beside AiTerm's own hooks in the same files, never in their place.

**Architecture:** A port of AiTerm's four drivers (`~/aiterm/app/Sources/AiTermCore/Harnesses` and `Hooks`) into `ShellforgeCore/Hooks`, renamed to Shellforge's markers, headers, port, paths and shim names so that AiTerm's entries and Shellforge's never claim each other. `HookIntegrations` probes and installs them by preset id, off the main thread. A small sheet, opened from the sidebar, shows each agent's state and its Install or Repair button. The app bundles `Shellforge/hooks/` as it bundles the daemon.

**Tech Stack:** Swift 6 language mode, macOS 13, Foundation (`JSONSerialization`, file I/O), SwiftUI sheet; Swift Testing through `Shellforge/scripts/swift.sh`; the daemon's pytest for the renamed shims.

**Spec:** Shellforge PRD (Claude Doc 89fd80a8-5fcf-4423-a8d6-c62f8512a481): "Agent status comes from hooks"; "Nothing changes on the machine without an explicit click. Hooks … are opt-in, with backups and a remove path"; A1 (the four presets keep today's drivers and hooks). `Shellforge/daemon/README.md` "Hook receiver" is the contract the hooks must meet (routes, `X-Shellforge-Hook: 1`, `X-Shellforge-iTerm-Session`).

## Global Constraints

- Source: AiTerm (`~/aiterm`, GPLv3, Laurens D'Hondt). Ported files start with `// Ported from AiTerm (<path>), GPLv3, Laurens D'Hondt.` Nothing in `~/aiterm` or in the user's real `~` changes during development; tests use a temporary home.
- macOS 13 and Swift 6: no `Mutex`, no `@Observable`. Build and test only with `Shellforge/scripts/swift.sh` (and `daemon/.venv/bin/pytest` for the daemon).
- Only `ChildProcess.swift` creates a `Process`.
- Shellforge's names, never AiTerm's: Claude marker key `_shellforge`; header `X-Shellforge-Hook: 1` and `X-Shellforge-iTerm-Session`; Codex block `# >>> shellforge hooks >>>` / `# <<< shellforge hooks <<<` and MCP server `shellforge_hooks`; Grok hooks file `~/.grok/hooks/shellforge.json`; PI extension `~/.pi/agent/extensions/shellforge-status.ts` with marker `// Shellforge PI extension schema: 5` and placeholder `__SHELLFORGE_HOOK_PORT__`; shims `shellforge-claude-statusline.sh`, `shellforge-grok-statusline.sh`; backups `<file>.shellforge-backup`; port 47831; support folder `~/Library/Application Support/Shellforge`.
- An install happens only from the user's click. Nothing installs at launch.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Nothing is pushed without asking.

## Review Focus

1. **AiTerm's hooks already in the same files**: the user's machine today. Installing Shellforge's keeps every AiTerm entry, and Claude's and Grok's status lines chain: Shellforge's shim runs AiTerm's, which runs the user's own. Neither app's probe calls the other's entries its own. (Tests in Tasks 2, 3 and 4: `aitermsHooksStayBesideShellforges`.)
2. **A config the user hand-edited into a shape the merge cannot read**: it is refused untouched and reported, never replaced. (Ported tests in Tasks 2, 3 and 4.)
3. **Config files that are symlinks into a dotfiles repo**: they stay symlinks and their targets are merged. (Ported in Task 1.)
4. **The app moved, or run translocated from Downloads**: a moved bundle shows as outdated and Repair re-points it; a translocated one cannot install. (Ported in Tasks 2 and 5.)
5. **The port file missing or naming another port**: the shim would post nowhere, so the probe says outdated, not current. (Ported in Task 2.)

---

### Task 1: Shared plumbing — the user's files, TOML, the shim port, the original status line

**Files:**
- Rename: `Shellforge/hooks/claude-statusline-shim.sh` → `Shellforge/hooks/shellforge-claude-statusline.sh`, and `grok-statusline-shim.sh` → `shellforge-grok-statusline.sh` (`git mv`), updating every reference: `daemon/shellforged/hook_events.py`, `daemon/tests/test_statusline_shim.py`, `daemon/tests/test_grok_statusline_shim.py`, and the comment headers in the shims themselves.
- Modify: `Shellforge/Sources/ShellforgeCore/Daemon/ShellforgePaths.swift`
- Create, ported from `~/aiterm/app/Sources/AiTermCore/`: `Shellforge/Sources/ShellforgeCore/Hooks/UserConfigFile.swift` (from `Harnesses/UserConfigFile.swift`), `TOMLStatements.swift` (from `Hooks/`), `ShimPort.swift` (from `Hooks/`), `StatusLineOriginal.swift` (from `Hooks/`), `BundleLocation.swift` (from `Hooks/`)
- Create: `Shellforge/Sources/ShellforgeCore/Hooks/HookDriver.swift`
- Test, ported from `~/aiterm/app/Tests/AiTermCoreTests/`: `Shellforge/Tests/ShellforgeCoreTests/Hooks/UserConfigFileTests.swift`, `TOMLStatementsTests.swift`

**Interfaces:**
- Produces:
  - `ShellforgePaths.supportDirectory(home: URL) -> URL`, `hookPortURL(home:)` (`hook-port`), `statusLineOriginalURL(home:)` (`statusline-original.cmd`), `grokStatusLineOriginalURL(home:)` (`grok-statusline-original.cmd`); the existing `supportDirectory` becomes `supportDirectory(home: FileManager.default.homeDirectoryForCurrentUser)`.
  - `struct UserConfigFile` (as AiTerm's: `displayPath`, read, atomic write through symlinks, one-time `.shellforge-backup`, refusals).
  - `enum TOMLStatements` (as AiTerm's).
  - `enum ShimPort { static func isRecorded(_ port: Int, home: URL) -> Bool; static func record(_ port: Int, home: URL) throws }`.
  - `enum StatusLineOriginal { enum Before { case missing, ours, foreign(String) }; static func record(_ before: Before, command: URL) throws }` (no `legacy`, no `migrate`: Shellforge has no older record).
  - `enum BundleLocation { static func isTranslocated(_ path: String) -> Bool; static let translocationWarning: String }`.
  - In `HookDriver.swift`: `public enum HookState: Equatable, Sendable { case notChecked, missing, current, outdated, invalidOwned, foreign, unreadable, resourceUnavailable }` (AiTerm's `HarnessIntegrationState`); `public struct HookProbe: Equatable, Sendable { public var state: HookState; public var explanation: String? }` (AiTerm's `DriverProbe` without `checks`: the Grok context note becomes the explanation, below); `protocol HookDriver: Sendable { func probe() -> HookProbe; func install() throws }` (AiTerm's `HarnessDriver` without `test`).

- [ ] **Step 1: Rename the shims.** `git mv` both. Run `cd Shellforge/daemon && .venv/bin/pytest -q`. Expected: the shim tests fail on the old names. Update the references listed above, then run it again. Expected: all pass.
- [ ] **Step 2: Port the tests first.** Copy `UserConfigFileTests.swift` and `TOMLStatementsTests.swift`; `AiTermCore` → `ShellforgeCore`; `aiterm-backup` → `shellforge-backup`; "AiTerm" in expected messages → "Shellforge". Run `scripts/swift.sh test --filter "UserConfigFileTests|TOMLStatementsTests"`. Expected: build fails, the types do not exist.
- [ ] **Step 3: Port the sources.** Copy the five files with the origin comment. Changes: `AiTermPaths.<x>(home:)` → `ShellforgePaths.<x>(home:)`; every user-facing "AiTerm" → "Shellforge"; `aiterm-backup` → `shellforge-backup`; `StatusLineOriginal` loses `legacy` and `migrate`; `UserConfigFile.Refusal.invalidSource` says "the current Shellforge ownership marker". Add the `ShellforgePaths` functions and write `HookDriver.swift` from AiTerm's `HarnessDriver.swift`, renamed as in Interfaces, with each state's explanation reworded "Shellforge's hooks are not installed." / "… are out of date." / "Shellforge's hooks are invalid." / "A different file occupies the hooks' path." / "The hooks' file cannot be read." / "The bundled hooks are unavailable." / "The hooks were not checked.", and `HookProbe.foreign(_:)` and `.refused(_:_:)` as AiTerm's.
- [ ] **Step 4:** Run the filter. Expected: all ported tests pass (record the count: 16 in AiTerm). Run the full `scripts/swift.sh test`. Expected: all pass.
- [ ] **Step 5:** Commit: `feat(core): the plumbing hook installers share, from AiTerm, under Shellforge's names; shims renamed so AiTerm's are never taken for ours`.

### Task 2: Claude Code — HTTP hooks and the status-line shim

**Files:**
- Create, ported: `Shellforge/Sources/ShellforgeCore/Hooks/ClaudeSettings.swift`, `ClaudeHooks.swift` (from `Harnesses/ClaudeSettings.swift`, `ClaudeDriver.swift`)
- Test, ported: `Shellforge/Tests/ShellforgeCoreTests/Hooks/ClaudeHooksTests.swift` (the Claude tests of `HookConfigTests.swift`, plus the Claude cases of `StatusLineShimTests.swift` that test Swift; tests of AiTerm's legacy JSON record or of `migrate` are dropped)

**Interfaces:**
- Consumes: Task 1.
- Produces: `struct ClaudeHooks: HookDriver { init(home: URL, port: Int, shimPath: String); static let settingsPath = ".claude/settings.json" }`; `enum ClaudeSettings` as AiTerm's, with `marker = "_shellforge"`, header `X-Shellforge-Hook`, the same eight events, and the route `/hook/claude`.

- [ ] **Step 1: Port the tests first.** From `HookConfigTests.swift`, take every test whose name or body is about Claude (`testClaudeMerge…`, `claudeRepair…`, `installRecordsTheShimsPort…`, `testRetiredPreToolUseHook…`, `testInstallWritesOriginalStatusLine…`, `testAMissingOrForeignStatusLineIsDetected`, `testTheShimIsStillOurs…`, `testATranslocated…`, `symlinkedConfigFiles…`, `aDanglingSymlink…`, `mergedSettingsKeepSlashesUnescaped`, `anAlreadyCorrectFileIsNotRewritten…`, `anUnreadableSettingsFile…`, `aStatusLineNamingAShim…`, `aHooksValueThatIsNotAnObject…`, `anEventThatIsNotAnArray…`, `aMalformedElement…`, `aStatusLineThatIsNotAnObject…`, the `null` arguments test, `anEventAiTermDoesNotManage…` renamed `anEventShellforgeDoesNotManage…`, `repointingTheStatusLine…`). Rename as in Global Constraints, port 47821 → 47831, shim name → `shellforge-claude-statusline.sh`. Drop `testLegacyOwnedHeaderIsRenamed…` and `anOldJSONRecordIsMigrated…` (no Shellforge history). Add:

```swift
    /// The user's machine today: AiTerm's hooks and its shim are already in settings.json.
    /// Shellforge's go beside them, its shim keeps AiTerm's as the original it runs, and each
    /// app's entries stay the other's.
    @Test func aitermsHooksStayBesideShellforges() throws {
        let home = try temporaryHome()
        let aitermShim = "/Applications/AiTerm.app/Contents/Resources/hooks/claude-statusline-shim.sh"
        let aiterm: [String: Any] = [
            "hooks": ["Stop": [["hooks": [["type": "http", "url": "http://127.0.0.1:47821/hook/claude",
                                           "headers": ["X-AiTerm-Hook": "1"], "timeout": 3, "async": true, "_aiterm": true]]]]],
            "statusLine": ["type": "command", "command": aitermShim],
        ]
        try write(aiterm, to: home.appendingPathComponent(ClaudeHooks.settingsPath))
        let shim = "/Applications/Shellforge.app/Contents/Resources/hooks/shellforge-claude-statusline.sh"
        let hooks = ClaudeHooks(home: home, port: 47831, shimPath: shim)
        #expect(hooks.probe().state == .missing)
        try hooks.install()
        #expect(hooks.probe().state == .current)
        let settings = try read(home.appendingPathComponent(ClaudeHooks.settingsPath))
        let stop = try #require((settings["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])
        let urls = stop.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }.compactMap { $0["url"] as? String }
        #expect(Set(urls) == ["http://127.0.0.1:47821/hook/claude", "http://127.0.0.1:47831/hook/claude"])
        #expect((settings["statusLine"] as? [String: Any])?["command"] as? String == shim)
        let original = try String(contentsOf: ShellforgePaths.statusLineOriginalURL(home: home), encoding: .utf8)
        #expect(original == aitermShim)
    }
```

  (Write `temporaryHome()`, `write(_:to:)` and `read(_:)` helpers in the test file, as AiTerm's `HookConfigTests` has them; reuse theirs if present.)
- [ ] **Step 2:** Run `scripts/swift.sh test --filter ClaudeHooksTests`. Expected: build fails.
- [ ] **Step 3: Port the sources.** `ClaudeSettings.swift` as is, renamed; `ClaudeDriver` → `ClaudeHooks` (`daemonPort` → `port`; `Harness.claude.hookEndpoint` → `"/hook/claude"`; `AiTermPaths` → `ShellforgePaths`; no `legacy` argument). `isOurShim` compares file names. With Shellforge's shim named `shellforge-claude-statusline.sh`, AiTerm's `claude-statusline-shim.sh` is foreign, and so is kept as the original. That is what makes the chain.
- [ ] **Step 4:** Run the filter. Expected: all pass (record the count). Full suite. Expected: all pass.
- [ ] **Step 5:** Commit: `feat(core): Claude Code's hooks and status-line shim, from AiTerm, beside AiTerm's own`.

### Task 3: Codex — the hooks block in config.toml

**Files:**
- Create, ported: `Shellforge/Sources/ShellforgeCore/Hooks/CodexHookConfig.swift` (from `Hooks/`), `CodexHooks.swift` (from `Harnesses/CodexDriver.swift`)
- Test, ported: `Shellforge/Tests/ShellforgeCoreTests/Hooks/CodexHooksTests.swift` (the Codex tests of `HookConfigTests.swift`)

**Interfaces:**
- Consumes: Task 1 (`UserConfigFile`, `TOMLStatements`).
- Produces: `struct CodexHooks: HookDriver { init(home: URL, port: Int); static let configPath = ".codex/config.toml" }`; `enum CodexHookConfig` as AiTerm's, with `begin = "# >>> shellforge hooks >>>"`, `end = "# <<< shellforge hooks <<<"`, MCP server `shellforge_hooks` at `http://127.0.0.1:<port>/mcp` with `X-Shellforge-Hook = "1"` and `env_http_headers X-Shellforge-iTerm-Session = "ITERM_SESSION_ID"`, curl commands with the Shellforge headers, and ownership by the `shellforge_hooks` tables and the `X-Shellforge-Hook` header only.

- [ ] **Step 1: Port the tests first.** From `HookConfigTests.swift`, every Codex test (`testCodexMerge…`, `codexRepair…` ×4, `aCodexConfigThatIsNotUTF8…`, `codexContentAfterTheBlock…`, the TOML conflict argument tests, `aSubTableAfterItsArrayParent…`, the unbalanced-bracket argument test, `bracketsInStringsAndComments…`), plus `testClaudeAndCodexInstallersAreIsolatedAndIdempotent` and `testPerHarnessInstallationProbesReadOnlyTheirOwnConfiguration` (they need Task 2's `ClaudeHooks`). Rename as in Global Constraints. Add:

```swift
    /// AiTerm's block and MCP server stay as they are; Shellforge's block goes beside them, and
    /// neither is taken for the other's on a repair.
    @Test func aitermsHooksStayBesideShellforges() throws {
        let home = try temporaryHome()
        let aiterm = """
        model = "gpt-5"

        # >>> aiterm hooks >>>
        [mcp_servers.aiterm_hooks]
        url = "http://127.0.0.1:47821/mcp"

        [mcp_servers.aiterm_hooks.http_headers]
        X-AiTerm-Hook = "1"

        [[hooks.Stop]]
        type = "mcp_tool"
        server = "aiterm_hooks"
        tool = "post_codex_hook"
        # <<< aiterm hooks <<<
        """
        let url = home.appendingPathComponent(CodexHooks.configPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try aiterm.write(to: url, atomically: true, encoding: .utf8)
        let hooks = CodexHooks(home: home, port: 47831)
        #expect(hooks.probe().state == .missing)
        try hooks.install()
        try hooks.install()   // a second install changes nothing
        #expect(hooks.probe().state == .current)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains(aiterm))
        #expect(text.components(separatedBy: "# >>> shellforge hooks >>>").count == 2)
        #expect(text.contains("[mcp_servers.shellforge_hooks]") && text.contains("http://127.0.0.1:47831/mcp"))
    }
```

- [ ] **Step 2:** Run `scripts/swift.sh test --filter CodexHooksTests`. Expected: build fails.
- [ ] **Step 3: Port the sources** with the renames above; `CodexDriver` → `CodexHooks` (`daemonPort` → `port`). A comment in `CodexHookConfig` that says AiTerm's words in an unrelated command are no permission to delete a hook keeps its rule, about Shellforge's words.
- [ ] **Step 4:** Run the filter. Expected: all pass. Full suite. Expected: all pass.
- [ ] **Step 5:** Commit: `feat(core): Codex's hooks block, from AiTerm, beside AiTerm's own`.

### Task 4: Grok Build and PI

**Files:**
- Create, ported: `Shellforge/Sources/ShellforgeCore/Hooks/GrokHooksFile.swift`, `GrokStatusLineConfig.swift`, `GrokHooks.swift` (from `Harnesses/GrokDriver.swift`), `PiHooks.swift` (from `Harnesses/PiDriver.swift`)
- Test, ported: `Shellforge/Tests/ShellforgeCoreTests/Hooks/GrokHooksFileTests.swift`, `GrokStatusLineConfigTests.swift`, `GrokHooksTests.swift`, `PiHooksTests.swift`

**Interfaces:**
- Consumes: Task 1.
- Produces: `struct GrokHooks: HookDriver { init(home: URL, port: Int, shimPath: String) }` (hooks file `.grok/hooks/shellforge.json`; `[ui.status_line]` in `.grok/config.toml` pointed at `shellforge-grok-statusline.sh`); `struct PiHooks: HookDriver { init(home: URL, port: Int, source: String) }` (writes `.pi/agent/extensions/shellforge-status.ts` from the bundled `pi-shellforge-status.ts`, with `__SHELLFORGE_HOOK_PORT__` replaced by the port, owned by the line `// Shellforge PI extension schema: 5`).

- [ ] **Step 1: Port the tests first.** Copy the four AiTerm test files, renamed as in Global Constraints. AiTerm's Grok "Context" check (`DriverProbe.checks`) becomes the probe's `explanation` while the state stays `.current`: "Grok's built-in status line is on, so Shellforge cannot read context." / "Grok's status line is set in a form Shellforge cannot edit, so Shellforge cannot read context." Adjust those assertions to read `explanation`. Add to `GrokHooksTests`:

```swift
    /// AiTerm's hooks file and its status-line shim stay; Shellforge's file goes beside them and its
    /// shim keeps AiTerm's as the original.
    @Test func aitermsHooksStayBesideShellforges() throws {
        let home = try temporaryHome()
        let aitermHooks = home.appendingPathComponent(".grok/hooks/aiterm.json")
        try FileManager.default.createDirectory(at: aitermHooks.deletingLastPathComponent(), withIntermediateDirectories: true)
        let aitermText = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"curl -H 'X-AiTerm-Hook: 1' http://127.0.0.1:47821/hook/grok"}]}]}}"#
        try aitermText.write(to: aitermHooks, atomically: true, encoding: .utf8)
        let aitermShim = "/Applications/AiTerm.app/Contents/Resources/hooks/grok-statusline-shim.sh"
        let config = home.appendingPathComponent(".grok/config.toml")
        try "[ui.status_line]\ncommand = \"\(aitermShim)\"\n".write(to: config, atomically: true, encoding: .utf8)
        let shim = "/Applications/Shellforge.app/Contents/Resources/hooks/shellforge-grok-statusline.sh"
        let hooks = GrokHooks(home: home, port: 47831, shimPath: shim)
        try hooks.install()
        #expect(hooks.probe().state == .current)
        #expect(try String(contentsOf: aitermHooks, encoding: .utf8) == aitermText)
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".grok/hooks/shellforge.json").path))
        #expect(try String(contentsOf: ShellforgePaths.grokStatusLineOriginalURL(home: home), encoding: .utf8) == aitermShim)
    }
```

  And to `PiHooksTests`: `aitermsExtensionStaysBesideShellforges`. With `~/.pi/agent/extensions/aiterm-status.ts` present, an install writes `shellforge-status.ts` beside it, leaves AiTerm's byte for byte, and probes `.current`.
- [ ] **Step 2:** Run `scripts/swift.sh test --filter "GrokHooksFileTests|GrokStatusLineConfigTests|GrokHooksTests|PiHooksTests"`. Expected: build fails.
- [ ] **Step 3: Port the sources** with the renames; `shimName = "shellforge-grok-statusline.sh"`; `GrokDriver` → `GrokHooks`, `PiDriver` → `PiHooks` (`daemonPort` → `port`).
- [ ] **Step 4:** Run the filter. Expected: all pass. Full suite. Expected: all pass.
- [ ] **Step 5:** Commit: `feat(core): Grok Build's and PI's hooks, from AiTerm, beside AiTerm's own`.

### Task 5: HookIntegrations and the Agent hooks sheet

**Files:**
- Create: `Shellforge/Sources/ShellforgeCore/Hooks/HookIntegrations.swift`
- Create: `Shellforge/Sources/ShellforgeUI/AgentHooksModel.swift`, `Shellforge/Sources/ShellforgeUI/AgentHooksView.swift`
- Test: `Shellforge/Tests/ShellforgeCoreTests/Hooks/HookIntegrationsTests.swift`, `Shellforge/Tests/ShellforgeUITests/AgentHooksModelTests.swift`

**Interfaces:**
- Consumes: Tasks 1–4; `AgentPresets.all` (ids `claude`, `codex`, `grok`, `pi`; names); `BackgroundWork`.
- Produces:

```swift
/// Where the drivers' bundled files are: `<resources>/hooks/`. Installing is refused from a
/// translocated bundle, whose path changes on every launch.
public struct HookResources: Sendable {
    public let folder: URL?
    public let installationAllowed: Bool
    public let unavailableReason: String?
    public static func bundled(resourceURL: URL?) -> HookResources
}

public struct HookIntegrations: Sendable {
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, port: Int = ShellforgePaths.hookPort,
                resources: HookResources)
    /// The agents with hooks, in preset order: claude, codex, grok, pi.
    public var agents: [String] { get }
    public func probe(_ agent: String) -> HookProbe
    public func install(_ agent: String) throws
}

@MainActor public final class AgentHooksModel: ObservableObject {
    public struct Row: Identifiable, Equatable { public let id: String; public let name: String; public var probe: HookProbe; public var working: Bool }
    @Published public private(set) var rows: [Row]
    @Published public private(set) var lastError: String?
    public init(integrations: HookIntegrations, names: [String: String])
    public func refresh() async          // probes every agent off the main thread
    public func install(_ agent: String) async
}
```

  The button's title is by state: `.missing` → "Install"; `.outdated`/`.invalidOwned` → "Repair"; `.current` → "Reinstall"; `.foreign`/`.unreadable`/`.resourceUnavailable` → none (the explanation says why).

- [ ] **Step 1: Write the tests.**

```swift
// HookIntegrationsTests.swift
import Foundation
import Testing
@testable import ShellforgeCore

@Suite struct HookIntegrationsTests {
    private func home() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sf-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The package's own hooks folder, as the app bundles it.
    private var hooksFolder: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("hooks")
    }

    @Test func everyPresetIsProbedAndNothingIsInstalledUntilAsked() throws {
        let home = try home()
        let hooks = HookIntegrations(home: home, resources: HookResources(folder: hooksFolder, installationAllowed: true, unavailableReason: nil))
        #expect(hooks.agents == ["claude", "codex", "grok", "pi"])
        #expect(hooks.agents.map { hooks.probe($0).state } == [.missing, .missing, .missing, .missing])
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.path).isEmpty)
    }

    @Test func installingOneTouchesOnlyItsOwnFiles() throws {
        let home = try home()
        let hooks = HookIntegrations(home: home, resources: HookResources(folder: hooksFolder, installationAllowed: true, unavailableReason: nil))
        try hooks.install("codex")
        #expect(hooks.probe("codex").state == .current)
        #expect(hooks.probe("claude").state == .missing)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path))
    }

    @Test func aTranslocatedBundleCannotInstall() throws {
        let hooks = HookIntegrations(home: try home(), resources: .bundled(resourceURL:
            URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/Shellforge.app/Contents/Resources")))
        #expect(hooks.probe("claude").state == .resourceUnavailable)
        #expect(throws: (any Error).self) { try hooks.install("claude") }
    }
}
```

```swift
// AgentHooksModelTests.swift
import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI

@MainActor @Suite struct AgentHooksModelTests {
    private func model() throws -> (AgentHooksModel, URL) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("sf-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let hooks = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("hooks")
        let integrations = HookIntegrations(home: home, resources: HookResources(folder: hooks, installationAllowed: true, unavailableReason: nil))
        return (AgentHooksModel(integrations: integrations, names: Dictionary(uniqueKeysWithValues: AgentPresets.all.map { ($0.id, $0.name) })), home)
    }

    @Test func rowsShowEachAgentsStateAndAnInstallTurnsItCurrent() async throws {
        let (model, _) = try model()
        await model.refresh()
        #expect(model.rows.map(\.name) == ["Claude Code", "Codex", "Grok Build", "PI"])
        #expect(model.rows.allSatisfy { $0.probe.state == .missing })
        await model.install("codex")
        #expect(model.rows.first { $0.id == "codex" }?.probe.state == .current)
        #expect(model.lastError == nil)
    }

    @Test func aRefusedInstallIsSaidAndTheRowKeepsItsState() async throws {
        let (model, home) = try model()
        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "[1, 2]".write(to: settings, atomically: true, encoding: .utf8)   // not an object: refused
        await model.refresh()
        await model.install("claude")
        #expect(model.lastError != nil)
        #expect(try String(contentsOf: settings, encoding: .utf8) == "[1, 2]")
    }
}
```

- [ ] **Step 2:** Run `scripts/swift.sh test --filter "HookIntegrationsTests|AgentHooksModelTests"`. Expected: build fails.
- [ ] **Step 3: Write `HookIntegrations`.** It builds `[String: any HookDriver]` once: `claude` → `ClaudeHooks(shimPath: folder/shellforge-claude-statusline.sh)`, `codex` → `CodexHooks`, `grok` → `GrokHooks(shimPath: folder/shellforge-grok-statusline.sh)`, `pi` → `PiHooks(source: contents of folder/pi-shellforge-status.ts)`. A driver whose resource is missing, or every driver when `!installationAllowed`, probes `HookProbe(state: .resourceUnavailable, explanation: unavailableReason ?? "The bundled hooks are unavailable.")`, and `install` throws `HookIntegrationError.unavailable(reason)`. `HookResources.bundled(resourceURL:)` gives `folder = resourceURL/hooks` and `installationAllowed = !BundleLocation.isTranslocated(resourceURL.path)` (as AiTerm's `HarnessResources.bundled`).
- [ ] **Step 4: Write `AgentHooksModel`.** `refresh()` and `install(_:)` run the driver work through `BackgroundWork.run` and apply the results on the main actor. `install` sets the row's `working`, then reprobes that agent. A thrown error sets `lastError` to its `localizedDescription` (or `String(describing:)`), and success clears it.
- [ ] **Step 5: Write `AgentHooksView`.** A SwiftUI sheet, 420 pt wide, titled "Agent hooks", with one line under the title: "Shellforge changes an agent's settings only when you click its button. Each file is backed up once before the first change." Then one row per agent: name; the state as words ("Installed", "Not installed", "Out of date", "Needs repair", "Another file is in the way", "Can't be read", "Unavailable"); the explanation, in secondary text, when there is one; the button by state as in Interfaces, disabled while `working`. Then `lastError` in red, and a Done button that calls the `dismiss` closure it is given. It runs `.task { await model.refresh() }`.
- [ ] **Step 6:** Run the filter. Expected: 5 tests pass. Full suite. Expected: all pass.
- [ ] **Step 7:** Commit: `feat: Agent hooks sheet — each preset's hooks probed, installed or repaired on the user's click`.

### Task 6: The app bundles the hooks and opens the sheet

**Files:**
- Modify: `iTerm2.xcodeproj/project.pbxproj` (folder reference `Shellforge/hooks`, copied by a "Copy hooks" Copy Files phase to `Contents/Resources/hooks`, beside "Copy shellforged")
- Modify: `Shellforge/Sources/ShellforgeUI/ShellforgeSidebar.swift` (a header button that opens the sheet), `Shellforge/Sources/ShellforgeUI/SidebarModel.swift` (none, unless the sheet needs state there)
- Modify: `sources/TerminalView/iTermShellforgeSidebar.swift` (pass the app's `HookIntegrations`)
- Modify: `Shellforge/docs/upstream-hook-points.md`

**Interfaces:**
- Consumes: Task 5.
- Produces: `ShellforgeSidebar.makeView(model:chooseFolder:hooks:)`, which gains `hooks: AgentHooksModel`; the header gets a second borderless button (SF Symbol `bolt.horizontal.circle`, help "Agent hooks") that presents `AgentHooksView` as a sheet.

- [ ] **Step 1:** Add `hooks: AgentHooksModel` to `makeView` and `SidebarView`, the header button, and `.sheet(isPresented:)` with `AgentHooksView(model: hooks, dismiss: { showingHooks = false })`. Update `SidebarTests` to build the view with a model on a temporary home. Run `scripts/swift.sh test`. Expected: all pass.
- [ ] **Step 2:** In `iTermShellforgeSidebar`, add `static let hooks = AgentHooksModel(integrations: HookIntegrations(resources: .bundled(resourceURL: Bundle.main.resourceURL)), names: …AgentPresets.all…)` and pass it in `makeView(for:)`.
- [ ] **Step 3:** Add the "Copy hooks" phase with a Python script, as M1c-2b added "Copy shellforged": a `folder` file reference `Shellforge/hooks` (SOURCE_ROOT), a build file, and a `PBXCopyFilesBuildPhase` (`dstSubfolderSpec = 7`, `dstPath = hooks`) in the iTerm2 target after "Copy shellforged". Run `plutil -lint`. Build with `xcodebuild -project iTerm2.xcodeproj -scheme iTerm2 -configuration Development -skipPackagePluginValidation CODE_SIGN_IDENTITY=- build`. Expected: succeeds, and `Contents/Resources/hooks/` holds the two `shellforge-*-statusline.sh` files (executable) and `pi-shellforge-status.ts`.
- [ ] **Step 4:** Add the changed iTerm2 files to `upstream-hook-points.md`. Commit: `feat(app): bundle the hooks and open Agent hooks from the sidebar`.
- [ ] **Step 5: Verify in the app, without touching the real config.** Launch the build, open Agent hooks, and screenshot it. Expected: the four agents with their real state. On this Mac, AiTerm's hooks exist but Shellforge's do not, so each should say "Not installed", and no file in `~` has changed (compare `stat -f %m` of `~/.claude/settings.json`, `~/.codex/config.toml`, `~/.grok/config.toml` and `~/.pi/agent/extensions` before and after).
- [ ] **Step 6: The real install is the user's.** Ask the user before clicking Install on their real files. With their yes, install Claude and Codex, then check:
  - `settings.json` holds both apps' hooks;
  - the status line runs Shellforge's shim, whose original is AiTerm's;
  - a real `claude` or `codex` turn in a Shellforge task tab turns its dot blue, then green;
  - AiTerm still gets its own hooks (AiTerm's log or its sidebar).

  Record the evidence in the ledger and under "M1c-3a verified" in `upstream-hook-points.md`, and commit it.
