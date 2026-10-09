# M1c-3c Sidebar Footer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The sidebar ends in AiTerm's footer: SYSTEM, then USAGE.
- **SYSTEM** shows the selected task's or tab's agent with `ctx ◔ 84%` and `in 936k · out 5.6k`, then the Mac's `cpu ◔ · ram ◔ · bat ◔`.
- **USAGE** shows one row each for Claude and Codex with their `wk` and `5h` windows and reset times.

All of it is drawn as AiTerm draws it, from what Shellforge's daemon already sends.

**Architecture:**
- **No daemon changes:** `shellforged` already sends `contextPercent`, `tokens` and `usage{claude,codex}`, and `SessionStore` keeps them.
- **ShellforgeCore** gets AiTerm's presentation values (`UsageLine`, `UsageVendorRow`, `UsageTaskRow` and the rules that build them), its per-row context memory (`SessionContexts`) and its Mac readings (`MachineSensor`, `MachineReadings`, `PowerSource`).
- **ShellforgeUI** gets the footer views (`SidebarFooter`, `UsageRing`) and the sampler (`MachineMonitor`, an `ObservableObject`).
- **`SidebarModel`** works out the footer's task row from Shellforge's selection: a task, or a tab outside any task.

**Tech Stack:** Swift 6 language mode, macOS 13, SwiftUI + AppKit, `ShellforgeDesign`; Swift Testing via `Shellforge/scripts/swift.sh`; the iTerm2 app built with `xcodebuild` for the live check.

**Spec:** Shellforge PRD (Claude Doc 89fd80a8-5fcf-4423-a8d6-c62f8512a481):
- **W6:** "Agent status, usage and attention come from the existing hook receiver, unchanged."
- **W8:** the design system.
- **A1:** "… models, skills and dials unchanged."
- **A5:** "dials hide or say 'not reported' rather than showing zero."

The user: "The context and usage dials stay"; "visually and functionally it should be exactly what AiTerm is." `Shellforge/Sources/ShellforgeDesign/README.md` governs every view.

## Global Constraints

- **Source:** AiTerm (`~/aiterm`, GPLv3, Laurens D'Hondt), pinned at `c1f851e574d0c8dd45a95957449c8798d60b65f4`.
  - Each ported file starts `// Ported from AiTerm (app/Sources/<path>.swift), GPLv3, Laurens D'Hondt.`, with "GPLv3, Laurens D'Hondt." on one line. Ported tests credit `app/Tests/<path>`.
  - Nothing in `~/aiterm` changes.
- **Design tokens:** every colour, size, radius, spacing and type style comes from `ShellforgeDesign`. `DesignRulesTests` scans `ShellforgeUI`. A literal AiTerm also waives is ported with its exception line; no new exceptions.
- **macOS 13:**
  - No `@Observable` (use `ObservableObject`/`@Published`).
  - No `Synchronization.Mutex` (use `ShellforgeCore`'s `Locked`).
  - No two-argument `onChange`, `focusEffectDisabled`, `FrontToBackStack`, `isolated deinit`.
  - `TimelineView(.everyMinute)` is available on 12+.
- **Dark only:** the footer is inside the sidebar's `.darkAqua` host. Never `.preferredColorScheme` or `NSApp.appearance`.
- **Agents:** presets are keyed by `SessionAgent` (`claude`, `codex`, `grok`, `pi`, `shell`) where AiTerm keyed by `AgentKind`.
  - USAGE has rows for Claude and Codex only. PI and Grok have no account-quota source, as in AiTerm.
- **Out of scope, each with its milestone:**
  - Backpack Mode: its `● backpack enabled` line, the click on the Mac's rows (⌘B) and the right-click to Mac Settings. The user wants Backpack Mode; it is the next milestone, **M1c-4** (about 720 lines of AiTerm core: lid sleep, Wi-Fi, the sleep rule). That milestone adds the line and the clicks back to this footer, so the footer's ported body keeps AiTerm's structure around where they go.
  - Settings › Agents with each agent's default model and reasoning (a Settings milestone of its own).
  - Terminal rows. Shellforge's equivalent is a tab outside any task, handled here.
- **Commits** end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
  - Stage paths by name and never use `commit -a`: the app build rewrites checked-in framework binaries.
  - Nothing is pushed without asking.

## Review Focus

1. **A window whose reset time has passed while the sidebar stayed open.**
   - The segment disappears at the next minute and is never drawn stale.
   - With all of a vendor's windows reset, the row says "No usage data reported".
   - Test: Task 1 `testAWindowPastItsResetIsDroppedNotRedrawn`; Task 5 `theFooterRedrawsOnTheMinute`.
2. **Switching between a task running Claude, one running Codex, a shell tab outside any task, and nothing selected.**
   - `ctx` and the counts are always the shown row's own, never the previous one's.
   - A shell shows only its mark; nothing selected shows the Mac alone.
   - Test: Task 5 `theFooterFollowsTheSelection`.
3. **A task whose tab closed, or whose agent just started.**
   - The last known `ctx` stays for that task.
   - An agent that has reported nothing reads "No context yet", never `ctx 0%` or `in 0 · out 0` (PRD A5).
   - Test: Task 2 `aTasksContextFollowsWhatItsTabsReport`; Task 1 `aTallyOfNothingInAndNothingOutHasNoCounts`; Task 5 `aClosedTasksContextStays`.
4. **Claude's status line not installed by Shellforge.**
   - The Claude row says "Usage disconnected" in amber, not a silent "No usage data yet".
   - Test: Task 5 `aMissingStatusLineSaysUsageIsDisconnected`.
5. **The narrowest sidebar and every interface scale.**
   - A two-window row with reset times fits `Size.sidebarMinWidth` without clipping.
   - Test: Task 4 `theTwoWindowTelemetryFitsTheMinimumSidebarWidth` (ported, every `InterfaceScale`).

---

### Task 1: AiTerm's usage values and their rules

**Files:**
- Create (port): `Shellforge/Sources/ShellforgeCore/Usage/UsageRows.swift`.
  - From `AiTermCore/Sidebar/SidebarModel.swift`: lines 113–198 (`UsageLine`, `UsageVendorRow`, `UsageTaskRow`) and 405–496 (`warningThreshold`, `usageVendorRows`, `usageTaskRow`/`usageTerminalRow`/`usageRow`, `fmtReset`, `formatReset`), with the doc comments around them.
  - They go into `public enum UsageRows` instead of `SidebarModel`.
- Create (port): `Shellforge/Sources/ShellforgeCore/Usage/TokenCounts.swift` from `AiTermCore/Sidebar/TokenCounts.swift`.
- Test (port): `Shellforge/Tests/ShellforgeCoreTests/Usage/TokenCountsTests.swift` (AiTerm's `TokenCountsTests.swift`).
- Test (port): `Shellforge/Tests/ShellforgeCoreTests/Usage/UsageRowsTests.swift`. These are AiTerm's `SidebarModelTests` cases:
  - `testUsageVendorRowsPutFiveHourFirstWhenAvailable`, `testAWindowPastItsResetIsDroppedNotRedrawn`, `testASilentVendorsWindowsAreDrawnLikeFreshOnes`, `testVendorRowsAreClaudeAndCodexOnly`, `grokGetsAContextRowAndNoVendorRow`
  - `theCountsAreTheActiveTabsOwn`, `aShellTabHasNoCounts`, `aTallyOfNothingInAndNothingOutHasNoCounts`
  - `testAnActiveShellTabShowsTheShellWithoutContext`, `testAnAgentWithoutContextHasNoFill`, `testContextWarnsAtTheSameThresholdAsAWindow`
  - `resetTimesFormatCorrectlyFromManyThreadsAtOnce`, and any other case in that file that calls `usageVendorRows`, `usageTaskRow`, `usageTerminalRow` or `fmtReset` (`grep -n "usageVendorRows\|usageTaskRow\|usageTerminalRow\|fmtReset" ~/aiterm/app/Tests/AiTermCoreTests/SidebarModelTests.swift`).

**Interfaces:**
- Consumes: `SessionInfo` (`sessionId`, `tabIndex`, `active`, `agent`, `tokens`), `TokenTally`, `UsageSnapshot`, `UsageWindow`, `SessionAgent`, `Locked` (all in `ShellforgeCore/Daemon`).
- Produces:
  - `public struct UsageLine: Equatable, Sendable`:
    - Nested `enum Window { context, weekly, fiveHour, cpu, ram, battery }` with `shortLabel` and `name`.
    - Fields: `window`, `percent`, `reset`, `warning`, `resetInFull`, `help`.
  - `public struct UsageVendorRow: Equatable, Sendable { vendor: SessionAgent; lines: [UsageLine]; note: String?; warning: Bool }`.
  - `public struct UsageTaskRow: Equatable, Sendable { agent: SessionAgent; context: UsageLine?; tokens: TokenTally? }`.
  - `public enum UsageRows`:
    - `static let warningThreshold = 80`
    - `static let statusLineMissingNote: String` (AiTerm's, verbatim)
    - `static func vendorRows(_ snap: UsageSnapshot, now: Date, calendar: Calendar, claudeStatusLineInstalled: Bool = true) -> [UsageVendorRow]`
    - `static func taskRow(sessions own: [SessionInfo], fallback: SessionAgent, contexts: [SessionAgent: Int]) -> UsageTaskRow`
    - `static func fmtReset(_ resetsAt: Int, now: Date, calendar: Calendar, inFull: Bool = false) -> String`
  - The `TokenTally` extension: `inputLabel`, `outputLabel`, `short(_:)`, `help`, `grouped(_:)`.

Ported changes, each ledgered:
- **Agent keys:** `AgentKind` → `SessionAgent`. `vendor` is `.claude`/`.codex`; `contexts` is keyed by `SessionAgent`; `agent.agentKind` becomes "the agent unless `.shell`".
- **One row function:** AiTerm's `usageTaskRow` and `usageTerminalRow` filtered the sessions themselves. Here the caller passes the row's own sessions (Task 5 does the filtering), so both become one `taskRow(sessions:fallback:contexts:)`.
- **Tokens:** they are read from each `SessionInfo.tokens`, not from a separate `[String: TokenTally]` map. Shellforge's store keeps them on the session.
- **Formatter cache:** `Mutex` → `Locked`.
- **Battery help:** `UsageLine.help` says `"Battery \(percent) %" + (warning ? ", running low" : "")`. AiTerm's "backpack mode turns off at …" names a feature Shellforge does not have.

- [ ] **Step 1: Port the tests** with the changes above, mapping AiTerm call sites:
  - `SidebarModel.usageVendorRows(…)` → `UsageRows.vendorRows(…)`
  - `SidebarModel.usageTaskRow(taskId:agent:sessions:contexts:tokens:)` → `UsageRows.taskRow(sessions: sessions.filter { $0.taskUUID == taskId }, fallback: agent, contexts:)`, with the test's `tokens` map folded into its `SessionInfo`s' `tokens`
  - `SidebarModel.warningThreshold` → `UsageRows.warningThreshold`
  - Keep every assertion. Ledger any case dropped and why: only cases about AiTerm terminals by `windowId` may go, and their rule is covered by Task 5.
  - Run: `Shellforge/scripts/swift.sh test --package-path Shellforge --filter "UsageRowsTests|TokenCountsTests"`
  - Expected: build fails (`cannot find 'UsageRows' in scope`).
- [ ] **Step 2: Port the two files** with the changes above. `taskRow`:

```swift
/// The footer's first row for the sessions of one row — a task's, or one tab's: whatever runs in
/// its active tab, that agent's last-known fill from `contexts`, and that tab's own counts. Until
/// the daemon has said which tab is current, the first tab stands in for it; with no session at
/// all, `fallback` (a task's own agent, or a shell).
public static func taskRow(sessions own: [SessionInfo], fallback: SessionAgent, contexts: [SessionAgent: Int]) -> UsageTaskRow {
    let tab = own.first(where: \.active) ?? own.min { $0.tabIndex < $1.tabIndex }
    let agent = tab?.agent ?? fallback
    let fill = agent == .shell ? nil : contexts[agent]
    return UsageTaskRow(agent: agent, context: fill.map {
        UsageLine(window: .context, percent: $0, reset: nil, warning: $0 >= warningThreshold)
    }, tokens: agent == .shell ? nil : tab?.tokens.flatMap {
        // Nothing in and nothing out (PI's tally from a session's start) is no counts yet, never
        // `in 0 · out 0`. Dropped here, not by the daemon: a PI /new's zeros still replace an old tally.
        $0.input == 0 && $0.output == 0 ? nil : $0
    })
}
```

- [ ] **Step 3: Run the step-1 filter.** Expected: all pass.
- [ ] **Step 4: Commit**

```bash
git add Shellforge/Sources/ShellforgeCore/Usage Shellforge/Tests/ShellforgeCoreTests/Usage
git commit -m "AiTerm's usage values: context, vendor windows and token counts, and the rules that build them

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 2: Each row's last-known context

**Files:**
- Create (port): `Shellforge/Sources/ShellforgeCore/Usage/SessionContexts.swift` from `AiTermCore/Sidebar/SessionContexts.swift`.
- Test (port): `Shellforge/Tests/ShellforgeCoreTests/Usage/SessionContextsTests.swift` (AiTerm's `SessionContextsTests.swift`).

**Interfaces:**
- Consumes: `SessionInfo`, `SessionAgent`.
- Produces:
  - `public enum FooterRow: Hashable, Sendable { case task(UUID), tab(String) }`. A tab is keyed by its `TabSnapshot.id`, the session id of its focused pane.
  - `public struct SessionContexts: Equatable, Sendable`:
    - `func percents(forRow: FooterRow) -> [SessionAgent: Int]`
    - `mutating func prune(keeping live: Set<FooterRow>)`
    - `mutating func seed(from sessions: [SessionInfo], row: (SessionInfo) -> FooterRow?)`
    - `mutating func remember(_ session: SessionInfo, replacing old: SessionInfo?, row: (SessionInfo) -> FooterRow?)`

Ported changes, each ledgered:
- **Row keys:** AiTerm keyed rows by task or terminal `UUID` and resolved them through `AppState`. Here the caller passes the resolver, and a row is a `FooterRow`.
  - A session with a `taskUUID` belongs to `.task` of it.
  - Otherwise it belongs to `.tab` of the sidebar tab whose sessions include it (Task 5 supplies this).
- **`prune`** takes the set of live rows.
- **Agent keys:** `AgentKind.allCases` → `[SessionAgent.claude, .codex, .grok, .pi]`.

- [ ] **Step 1: Port the tests.**
  - `AppState` fixtures become a resolver closure built from the same tasks: `{ s in s.taskUUID.map(FooterRow.task) ?? (s.windowId == "w2" ? .tab("s9") : nil) }`, with the ids the test uses.
  - `aTerminalsContextIsMatchedOnItsWindow` becomes `aTabsContextIsMatchedThroughItsResolver`, with the same assertion shape.
  - Run: `Shellforge/scripts/swift.sh test --package-path Shellforge --filter SessionContextsTests`
  - Expected: build fails.
- [ ] **Step 2: Port `SessionContexts`** with the changes above.
- [ ] **Step 3: Run the filter.** Expected: pass.
- [ ] **Step 4: Commit**

```bash
git add Shellforge/Sources/ShellforgeCore/Usage/SessionContexts.swift Shellforge/Tests/ShellforgeCoreTests/Usage/SessionContextsTests.swift
git commit -m "Remember each task's and tab's last context fill per agent, as AiTerm does

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 3: The Mac's readings

**Files:**
- Create (port), in `Shellforge/Sources/ShellforgeCore/Machine/`:
  - `MachineSensor.swift` and `LiveMachineSensor.swift` from `AiTermCore/Machine/`.
  - `Power.swift`: from `AiTermCore/Backpack/BackpackPorts.swift`, `PowerReading` and `PowerSource` only; from `AiTermCore/Backpack/LivePower.swift`, `IOKitPowerSource`.
- Create (port): `Shellforge/Sources/ShellforgeUI/MachineMonitor.swift` from `AiTerm/MachineMonitor.swift`.
- Test (port): `Shellforge/Tests/ShellforgeCoreTests/Machine/MachineReadingsTests.swift` and `Shellforge/Tests/ShellforgeUITests/MachineMonitorTests.swift`.

**Interfaces:**
- Consumes: `UsageLine` (Task 1), `BackgroundWork.run`.
- Produces:
  - `MachineSample`, `CPUTicks`, `MemoryUse`, `protocol MachineSensor`, `InertMachineSensor`, `LiveMachineSensor`, `enum MachineReadings { static func lines(previous:current:power:) -> [UsageLine] }`.
  - `struct PowerReading { level: Int?; onBattery: Bool; static let mains; var nearCutoff: Bool }`, `protocol PowerSource`, `IOKitPowerSource`.
  - `@MainActor public final class MachineMonitor: ObservableObject`:
    - `@Published public private(set) var lines: [UsageLine]`
    - `init(sensor:power:interval:)`, `start()`, `stop()`, `sample() async -> Duration`

Ported changes, each ledgered:
- **`PowerReading.nearCutoff`:** `level <= 15`, written as `static let lowBattery = 15`. This is AiTerm's `BackpackSettings.cutoff + 5`; Backpack itself is not ported.
- **`MachineMonitor`:** `@Observable` → `ObservableObject` with `@Published lines`, and `ThreadWork.run` → `BackgroundWork.run`. The equal-write guard stays: `@Published` notifies on every write too.

- [ ] **Step 1: Port both test files.**
  - Drop only Backpack cases, if any; ledger them.
  - `theLiveSensorReadsThisMac` stays: it reads this Mac's real counters.
  - Run: `Shellforge/scripts/swift.sh test --package-path Shellforge --filter "MachineReadingsTests|MachineMonitorTests"`
  - Expected: build fails.
- [ ] **Step 2: Port the files** with the changes above.
- [ ] **Step 3: Run the filter.** Expected: pass.
- [ ] **Step 4: Commit**

```bash
git add Shellforge/Sources/ShellforgeCore/Machine Shellforge/Sources/ShellforgeUI/MachineMonitor.swift Shellforge/Tests/ShellforgeCoreTests/Machine Shellforge/Tests/ShellforgeUITests/MachineMonitorTests.swift
git commit -m "The Mac's cpu, ram and battery readings, sampled as AiTerm samples them

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 4: AiTerm's footer, drawn

**Files:**
- Create (port): `Shellforge/Sources/ShellforgeUI/Sidebar/SidebarFooter.swift` from `AiTerm/Views/SidebarFooter.swift` (`SidebarFooter` and `UsageRing`).
- Test (port): `Shellforge/Tests/ShellforgeUITests/SidebarFooterGeometryTests.swift` (AiTerm's, 284 lines).
- Modify: `Shellforge/Tests/ShellforgeDesignTests/DesignRulesTests.swift`, only for AiTerm's own exceptions for `SidebarFooter.swift` (copy from `~/aiterm/app/Tests/AiTermUITests/DesignRulesTests.swift` if listed).

**Interfaces:**
- Consumes: Tasks 1 and 3's values; `VendorMark`, `SidebarHeading`, `Hairline`, `SymbolMark`, `InterfaceScale`.
- Produces: `struct SidebarFooter: View`:
  - `init(task: UsageTaskRow?, rows: [UsageVendorRow], machine: [UsageLine] = [])`
  - `static let systemHeading = "System"`, `static let macSymbol = "macbook"`
  - `static func readingsLabel(_:) -> String`, `static func noteInk(_:) -> Color`
  - `struct UsageRing: View` with `static func fill(_:)`.

Ported changes, each ledgered:
- **No Backpack yet (M1c-4 adds it back):** `mac: MacModeLine`, `toggleMac`, `openMacSettings`, `backpackLine` and `macControl` are removed. The readings row is drawn as AiTerm draws it at the desk (`mac` = `.desk`): the `macbook` mark and the readings, with no click.
- **Tests:** in `SidebarFooterGeometryTests`, the `MacMode`-argument test (line 261) is dropped. Any other test that builds a `MacModeLine` passes nothing for it.

- [ ] **Step 1: Port the tests** with the changes above.
  - Use `ShellforgeUITests`' existing host helpers. Add AiTerm's helper to this test file if one is missing.
  - Run: `Shellforge/scripts/swift.sh test --package-path Shellforge --filter SidebarFooterGeometryTests`
  - Expected: build fails.
- [ ] **Step 2: Port the view** with the changes above.
- [ ] **Step 3: Run the filter, then the rules:** `Shellforge/scripts/swift.sh test --package-path Shellforge --filter "SidebarFooterGeometryTests|DesignRulesTests|SourceRulesTests"`. Expected: pass.
- [ ] **Step 4: Commit**

```bash
git add Shellforge/Sources/ShellforgeUI/Sidebar/SidebarFooter.swift Shellforge/Tests/ShellforgeUITests/SidebarFooterGeometryTests.swift Shellforge/Tests/ShellforgeDesignTests/DesignRulesTests.swift
git commit -m "AiTerm's sidebar footer: SYSTEM with the context, counts and Mac readings, USAGE with each vendor's windows

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 5: The footer under the sidebar, following the selection

**Files:**
- Modify: `Shellforge/Sources/ShellforgeUI/SidebarModel.swift`:
  - `@Published public private(set) var contexts = SessionContexts()`, kept in step with `sessions`.
  - `public var footerRow: UsageTaskRow?`
  - `public func vendorRows(now: Date, calendar: Calendar, claudeStatusLineInstalled: Bool) -> [UsageVendorRow]`
- Modify: `Shellforge/Sources/ShellforgeUI/AgentHooksModel.swift`: `public var claudeStatusLineInstalled: Bool`.
- Modify: `Shellforge/Sources/ShellforgeUI/ShellforgeSidebar.swift`:
  - `makeView(model:chooseFolder:hooks:machine:)`.
  - `SidebarView` draws `SidebarFooterHost` under the list.
  - `SidebarFooterHost` is `TimelineView(.everyMinute)` → `SidebarFooter`, with AiTerm's `\.footerClock` environment key for tests.
- Modify: `sources/TerminalView/iTermShellforgeSidebar.swift`:
  - One app-wide `static let machine = MachineMonitor(sensor: LiveMachineSensor(), power: IOKitPowerSource())`, started in `startHelper()` and stopped with the helper. Skipped under XCTest, as the helper is.
  - It is passed to `makeView`.
- Test: `Shellforge/Tests/ShellforgeUITests/SidebarFooterTests.swift`. Modify `SidebarTests` for the new `makeView` parameter.

**Interfaces:**
- Consumes: Tasks 1–4; `SessionStore.sessions(ofTask:)`, `sessions(ofTab:)`, `usage`; `TaskItem.agent`.
- Produces: what the view reads, nothing for later tasks.

The footer's row follows Shellforge's selection: AiTerm's `usageRow(for: selection)` for a task, and for a tab outside any task.

```swift
/// The footer's first row: the selected task's, else the selected tab's when it belongs to no task
/// (AiTerm's terminal row); nothing when neither — SYSTEM then holds the Mac alone.
public var footerRow: UsageTaskRow? {
    if let id = selectedTaskId {
        let task = document.workspace.tasks.first { $0.id == id }
        let fallback = task?.agent.flatMap(SessionAgent.init(rawValue:)) ?? .shell
        return UsageRows.taskRow(sessions: sessions.sessions(ofTask: id), fallback: fallback,
                                 contexts: contexts.percents(forRow: .task(id)))
    }
    guard let tab = host.selectedTabId, tree.otherTabs.contains(where: { $0.id == tab }) else { return nil }
    return UsageRows.taskRow(sessions: sessions.sessions(ofTab: tab), fallback: .shell,
                             contexts: contexts.percents(forRow: .tab(tab)))
}
```

`contexts` is updated in the feed's store subscription.
- **Before each store update:** with the old store, call `contexts.remember(new, replacing: old[new.sessionId], row: resolver)` for every session in the new store.
- **On the first store, or after a reconnect:** call `contexts.seed(from: Array(store.sessions.values), row: resolver)`.
- **The resolver:** `{ $0.taskUUID.map(FooterRow.task) ?? self.tabRow(of: $0) }`, where `tabRow` finds the `tree.otherTabs` entry whose `sessions.sessions(ofTab:)` contains the session.
- **Pruning:** in `refresh`, call `contexts.prune(keeping:)` with the live task ids and other-tab ids.

`AgentHooksModel.claudeStatusLineInstalled` is true unless Claude's row is `.missing`, `.foreign` or `.invalidOwned`. A row not yet checked counts as installed, so the footer never flashes amber at launch.

- [ ] **Step 1: Write the failing tests.**

```swift
import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI

@MainActor @Suite struct SidebarFooterTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shellforge-footer-\(UUID().uuidString)")

    /// A sidebar with one project and two tasks, one tab each, and a tab of no task.
    private func sidebar() async throws -> (SidebarModel, FakeTerminalHost, FakeFeed, alpha: UUID, beta: UUID) {
        let repo = try GitRepoForUI()
        let host = FakeTerminalHost(), feed = FakeFeed()
        let model = SidebarModel(host: host, document: WorkspaceDocument(store: WorkspaceStore(folder: folder)),
                                 launcher: repo.launcher, feed: feed)
        await model.addProject(folder: repo.path)
        let project = try #require(model.tree.projects.first).id
        await model.newTask(title: "Alpha", in: project)
        await model.newTask(title: "Beta", in: project)
        let tasks = try #require(model.tree.projects.first).tasks.map(\.id)
        return (model, host, feed, tasks[0], tasks[1])
    }

    private func session(_ id: String, task: UUID?, agent: SessionAgent, context: Int?, tokens: TokenTally? = nil,
                         window: String = "w", tab: Int = 0) -> SessionInfo {
        var s = SessionInfo(sessionId: id, windowId: window, tabIndex: tab, taskId: task?.uuidString.lowercased(), projectId: nil,
                            agent: agent, model: nil, state: .idle, title: "t", cwd: "/wt")
        s.active = true; s.contextPercent = context; s.tokens = tokens
        return s
    }

    private func say(_ feed: FakeFeed, _ sessions: [SessionInfo], usage: UsageSnapshot = .empty) {
        var store = SessionStore()
        store.apply(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true, sessions: sessions, usage: usage)))
        feed.store = store
    }

    @Test func theFooterFollowsTheSelection() async throws {
        let (model, host, feed, alpha, beta) = try await sidebar()
        host.tabs.append(TabSnapshot(id: "s9", tabId: 9, title: "zsh", taskId: nil, projectId: nil))
        say(feed, [session("a", task: alpha, agent: .claude, context: 84, tokens: TokenTally(input: 936_000, cached: nil, output: 5_600)),
                   session("b", task: beta, agent: .codex, context: 12),
                   session("s9", task: nil, agent: .shell, context: nil, window: "w2")])
        model.select(task: alpha)
        #expect(model.footerRow?.agent == .claude && model.footerRow?.context?.percent == 84 && model.footerRow?.context?.warning == true)
        #expect(model.footerRow?.tokens?.input == 936_000)
        model.select(task: beta)
        #expect(model.footerRow?.agent == .codex && model.footerRow?.context?.percent == 12 && model.footerRow?.tokens == nil)
        host.userSwitched(to: "s9")
        #expect(model.footerRow == UsageTaskRow(agent: .shell, context: nil, tokens: nil))
    }

    @Test func nothingSelectedShowsTheMacAlone() async throws {
        let (model, host, _, _, _) = try await sidebar()
        host.tabs.removeAll(); host.selectedTabId = nil; host.onChange?()
        #expect(model.footerRow == nil)
    }

    @Test func aClosedTasksContextStays() async throws {
        let (model, _, feed, alpha, _) = try await sidebar()
        say(feed, [session("a", task: alpha, agent: .claude, context: 40)])
        say(feed, [])
        model.select(task: alpha)
        #expect(model.footerRow?.agent == .claude, "the task's own agent stands in for its closed tab")
        #expect(model.footerRow?.context?.percent == 40, "its last fill stays")
    }

    @Test func anAgentThatReportedNothingHasNoFillAndNoCounts() async throws {
        let (model, _, feed, alpha, _) = try await sidebar()
        say(feed, [session("a", task: alpha, agent: .pi, context: nil, tokens: TokenTally(input: 0, cached: nil, output: 0))])
        model.select(task: alpha)
        #expect(model.footerRow == UsageTaskRow(agent: .pi, context: nil, tokens: nil))
    }

    @Test func aMissingStatusLineSaysUsageIsDisconnected() async throws {
        let (model, _, _, _, _) = try await sidebar()
        let rows = model.vendorRows(now: Date(), calendar: .current, claudeStatusLineInstalled: false)
        #expect(rows.map(\.vendor) == [.claude, .codex])
        #expect(rows[0].note == UsageRows.statusLineMissingNote && rows[0].warning)
        #expect(rows[1].note == "No usage data yet" && !rows[1].warning)
    }

    @Test func theFooterRedrawsOnTheMinute() async throws {
        let (model, _, feed, _, _) = try await sidebar()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let window = UsageWindow(usedPercent: 50, resetsAt: Int(now.timeIntervalSince1970) + 30)
        say(feed, [], usage: UsageSnapshot(claude: Usage(fiveHour: window, sevenDay: nil, spend: nil, plan: nil, updatedAt: nil), codex: nil))
        #expect(model.vendorRows(now: now, calendar: .current, claudeStatusLineInstalled: true)[0].lines.map(\.window) == [.fiveHour])
        #expect(model.vendorRows(now: now.addingTimeInterval(60), calendar: .current, claudeStatusLineInstalled: true)[0].note
                == "No usage data reported", "a window past its reset is dropped at the next minute")
    }
}
```

  - Check `Usage`'s and `UsageSnapshot`'s memberwise initialisers in `DaemonTypes.swift` and use their real labels. Ledger the change.
  - Run: `Shellforge/scripts/swift.sh test --package-path Shellforge --filter SidebarFooterTests`
  - Expected: build fails (`footerRow` and `vendorRows` missing).
- [ ] **Step 2: Implement** `contexts`, `footerRow`, `vendorRows` and `claudeStatusLineInstalled` as above. Then the view:

```swift
/// AiTerm's `SidebarFooterHost`: the vendor rows recomputed on the minute — a window that has reset
/// is dropped, and a reset time gains its weekday across midnight — and the selected row's context.
struct SidebarFooterHost: View {
    @ObservedObject var model: SidebarModel
    @ObservedObject var hooks: AgentHooksModel
    @ObservedObject var machine: MachineMonitor
    @Environment(\.footerClock) private var footerClock

    var body: some View {
        TimelineView(.everyMinute) { context in
            SidebarFooter(task: model.footerRow,
                          rows: model.vendorRows(now: footerClock?.now ?? context.date, calendar: footerClock?.calendar ?? .current,
                                                 claudeStatusLineInstalled: hooks.claudeStatusLineInstalled),
                          machine: machine.lines)
        }
    }
}
```

  - Port AiTerm's `FooterClock` environment key from `AiTerm/Views/SidebarView.swift:8-20` beside it.
  - In `SidebarView.body`, the footer goes after the `List`: `VStack(spacing: 0) { SidebarBanners…; List…; SidebarFooterHost(model: model, hooks: hooks, machine: machine) }`. AiTerm's sidebar draws its footer the same way, under the scrolling list with the scroll-edge hairline above it.
  - Check `AiTerm/Views/SidebarView.swift` around the footer for the exact hairline and padding, and port them.
- [ ] **Step 3: Run** `Shellforge/scripts/swift.sh test --package-path Shellforge` (the whole package) and `(cd Shellforge/daemon && .venv/bin/pytest -q)`. Expected: all pass.
- [ ] **Step 4: Commit**

```bash
git add Shellforge/Sources Shellforge/Tests sources/TerminalView/iTermShellforgeSidebar.swift
git commit -m "The footer under the sidebar, following the selected task or tab, the vendor rows on the minute

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 6: Verify in the app

- [ ] **Step 1: Build:** `xcodebuild -project iTerm2.xcodeproj -scheme iTerm2 -configuration Development -skipPackagePluginValidation CODE_SIGN_IDENTITY=- build`. Expected: `** BUILD SUCCEEDED **`.
- [ ] **Step 2: Restart Shellforge with the user's ok.** Quit it by its bundle id `io.github.nathangel.shellforge`, never `com.googlecode.iterm2`, then `open` the built app.
- [ ] **Step 3: Ask the user to check:**
  - a task running Claude shows `ctx` and `in · out`;
  - a shell tab shows only its mark;
  - the Mac row shows `cpu · ram`, and `bat` on battery;
  - USAGE shows Claude's and Codex's windows with reset times.

  Compare with AiTerm's footer. Do not click on the user's screen.
- [ ] **Step 4: Ledger what was seen.**
