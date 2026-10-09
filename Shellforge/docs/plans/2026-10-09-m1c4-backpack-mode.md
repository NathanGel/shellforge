# M1c-4 Backpack Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** AiTerm's Backpack Mode in Shellforge. With the lid shut, the Mac stays awake and online through the iPhone's hotspot while agents work. It ends itself at a low battery or once the agents have stopped. It has:
- AiTerm's sheet to choose the hotspot and connect;
- the Mac card's one-time "Allow…" (a sudoers rule for `pmset`, plus Location access for Wi-Fi names);
- ⌘B in the View menu;
- the footer's `● backpack enabled` line, its click (⌘B) and its right-click ("Mac Settings…").

**Architecture:**
- **Core:** AiTerm's `AiTermCore/Backpack` (state machine, ports, live ports, sleep rule) and its Keychain `SecretStore` are ported into `ShellforgeCore/Backpack`.
  - `Synchronization.Mutex` (macOS 15) → Shellforge's `Locked`.
  - AiTerm's `ProcessRunner` → Shellforge's `ChildProcess`.
- **ShellforgeUI:** AiTerm's `BackpackController`, `BackpackSheet`, `MacSettingsCard` (with the minimal `SettingsCard` pieces it needs), `MacModeRow` and `ToneDot`. `@Observable` → `ObservableObject`.
- **Owner:** the iTerm2 host owns one controller for the app. It starts it at launch and shuts it down at quit, through the same hooks as the helper, and adds the ⌘B item to iTerm2's View menu.
- **The Mac card:** Shellforge has no Settings window yet, so it opens in its own dark panel. That is the footer's "Mac Settings…", and a Mac button beside the Agent hooks bolt.

**Tech Stack:** Swift 6 language mode, macOS 13, SwiftUI + AppKit, CoreWLAN, CoreLocation, IOKit, `ShellforgeDesign`; Swift Testing via `Shellforge/scripts/swift.sh`; Objective-C for the iTerm2 menu item; the iTerm2 app built with `xcodebuild` for the live check.

**Spec:**
- **The user:** "I do want backpack mode for shellforge" (2026-10-09), and "visually and functionally it should be exactly what AiTerm is."
- **AiTerm's own description:** `~/aiterm/docs/architecture.md:101-122, 230-232`, `README.md:60-63, 75-76`, `docs/keyboard.md:22`. Its 2026-10-05 spec is cited in comments but not in the repository.
- **Shellforge PRD** (Claude Doc 89fd80a8-…) W8 (design system) and W9: "Keyboard shortcuts … keep working and do not clash with iTerm2's." ⌘B is unbound in `sources/MainMenu/MainMenu.xib`; ⇧⌘B, ⌥⌘B and ⌥⇧⌘B are iTerm2's.

## Global Constraints

- **Source:** AiTerm (`~/aiterm`, GPLv3, Laurens D'Hondt), pinned at `c1f851e574d0c8dd45a95957449c8798d60b65f4`.
  - Each ported file starts `// Ported from AiTerm (app/Sources/<path>.swift), GPLv3, Laurens D'Hondt.`, with "GPLv3, Laurens D'Hondt." on one line. Tests credit `app/Tests/<path>`.
  - Nothing in `~/aiterm` changes.
- **System changes happen only on the user's click, through macOS's own password prompt.**
  - The sudoers rule is written only by "Allow…", through `osascript … with administrator privileges`, after `visudo -cf` passes. It is removed only by "Remove".
  - Never at launch, never in a test.
  - Tests use fakes only (`BackpackPorts.inert` and the ported `BackpackFakes`). No test calls `pmset`, `sudo`, `osascript`, `networksetup`, CoreWLAN's `associate` or CoreLocation's request.
- **Names:** the rule's path is `/etc/sudoers.d/shellforge`. Its comment reads `# Installed by Shellforge for backpack mode. Remove with the Mac card's Remove.` The rule line itself (`<user> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1`) is AiTerm's, unchanged.
- **Storage:**
  - The hotspot's password goes to the Keychain only, under service `io.github.nathangel.shellforge` and account `backpack.password`.
  - The UserDefaults keys stay AiTerm's: `backpack.network` and `backpack.engaged`.
- **macOS 13:**
  - No `Synchronization`/`Mutex` (use `Locked`).
  - No `@Observable` (use `ObservableObject`).
  - No two-argument `onChange` (use the one-argument form). No `focusEffectDisabled`, `FrontToBackStack` or `isolated deinit`.
- **Design and appearance:** dark only (`PanelSlot` for every panel). Every colour, size and type style comes from `ShellforgeDesign`, and `DesignRulesTests` scans `ShellforgeUI`.
- **Location strings:** `plists/iTerm2.plist`'s `NSLocationUsageDescription` and `NSLocationWhenInUseUsageDescription` become AiTerm's sentence with Shellforge's name: "Shellforge reads the names of nearby Wi-Fi networks so Backpack Mode can join the one you chose. It never reads your location." The entitlement `com.apple.security.personal-information.location` is already present.
- **Commits** end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
  - Stage paths by name and never use `commit -a`: the app build rewrites checked-in framework binaries.
  - Nothing is pushed without asking.

## Review Focus

1. **Quitting or crashing while Backpack Mode is on.**
   - On quit, `disablesleep 0` runs before the app exits.
   - After a crash, the next launch finds `backpack.engaged` and restores lid sleep.
   - The Mac must never be left unable to sleep.
   - Tests: Task 2 (ported `BackpackModeTests` recovery cases); Task 5 `quittingTurnsBackpackModeOff`.
2. **"Allow…" with a user name that is not plain ASCII, a failed `visudo` check, or a cancelled password prompt.**
   - Nothing is written, and the card says why.
   - "Remove" while the mode is engaged is refused.
   - Tests: Task 1 `SleepRuleTests` (ported); Task 3 (ported `BackpackControllerTests` setup/remove cases).
3. **The hotspot not in range, or a locked iPhone.**
   - Connect retries at 5/10/20/30 s until Cancel. A join that fails says so.
   - The lid closing mid-connect closes the sheet.
   - Tests: Task 3 and Task 4 (ported controller and sheet cases).
4. **The battery at or under 10 %, or agents stopped for 120 s with the lid closed.**
   - The mode ends itself, and puts the Mac to sleep if the lid is shut.
   - The footer turns amber within 5 points of the cutoff.
   - Tests: Task 2 (ported tick cases); Task 4 `MacModeTests`.
5. **⌘B and the footer.**
   - ⌘B toggles from any window: off → the sheet; on → off.
   - It is ignored while switching.
   - The menu item shows a checkmark while on and does not clash with iTerm2's ⇧⌘B/⌥⌘B.
   - Tests: Task 5 `commandBIsFreeInTheMainMenu` (ModernTests) and `theFooterClickIsCommandB`.

---

### Task 1: Core values — the sleep rule, the state, the settings, the Keychain

**Files:**
- Create (port), in `Shellforge/Sources/ShellforgeCore/Backpack/`:
  - `SleepRule.swift`, `BackpackState.swift`, `BackpackSettings.swift`, from `~/aiterm/app/Sources/AiTermCore/Backpack/`.
  - `SecretStore.swift`, from `AiTermCore/Keychain.swift`: `SecretStore`, `KeychainSecretStore` and `MemorySecretStore` only.
- Modify: `Shellforge/Sources/ShellforgeCore/Machine/Power.swift`: `PowerReading.nearCutoff` reads `BackpackSettings.cutoff + 5`, and `lowBattery` goes. Ledger it as the M1c-3c stand-in retired.
- Test (port): `Shellforge/Tests/ShellforgeCoreTests/Backpack/{SleepRuleTests,BackpackStateTests,BackpackSettingsTests}.swift`.

**Interfaces:**
- Produces, exactly as AiTerm declares them:
  - `enum SleepRule { path, commands, text(user:), installCommand(user:), removeCommand, appleScript(running:) }`
  - `BackpackSetup`, `BackpackStatus`, `BackpackState`, `BackpackRefusal`, `BackpackEnding`, `BackpackTick`
  - `final class BackpackSettings { static let cutoff = 10; password; setPassword; network; engaged }`
  - `protocol SecretStore`, `KeychainSecretStore(service:)`, `MemorySecretStore`

Ported changes, each ledgered:
- `SleepRule.path` is `/etc/sudoers.d/shellforge`, and the comment line uses Shellforge's wording (Global Constraints). Its test's expected strings change to match, and nothing else does.
- `Mutex` → `Locked`.
- `KeychainSecretStore`'s service is `io.github.nathangel.shellforge`.

- [ ] **Step 1: Port the three test files.**
  - Run: `Shellforge/scripts/swift.sh test --package-path Shellforge --filter "SleepRuleTests|BackpackStateTests|BackpackSettingsTests"`
  - Expected: build fails.
- [ ] **Step 2: Port the four sources** with the changes above.
- [ ] **Step 3: Run the filter, then the whole package.** Expected: pass. `MachineReadingsTests` still pass: 15 is still the amber line.
- [ ] **Step 4: Commit**

```bash
git add Shellforge/Sources/ShellforgeCore/Backpack Shellforge/Sources/ShellforgeCore/Machine/Power.swift Shellforge/Tests/ShellforgeCoreTests/Backpack
git commit -m "Backpack Mode's values: the sleep rule, its states, its settings and the Keychain store

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 2: The mode and its live ports

**Files:**
- Create (port), in `Shellforge/Sources/ShellforgeCore/Backpack/`:
  - `BackpackPorts.swift`: the protocols `LidSleepControl`, `WiFiControl`, `LocationAccess`, `SleepRuleInstaller`, `LidSensor`, plus `BackpackPorts` and `.inert`.
  - `BackpackMode.swift`.
  - `LiveLidSensor.swift`, `LiveLidSleep.swift`, `LiveLocation.swift`, `LiveWiFi.swift`.
- Create (port): `Shellforge/Tests/ShellforgeTestSupport/BackpackFakes.swift` (AiTerm's, minus `FakePower` if `ShellforgeTestSupport` already has one).
- Test (port): `Shellforge/Tests/ShellforgeCoreTests/Backpack/{BackpackModeTests,BackpackLivePortsTests}.swift`.

**Interfaces:**
- Consumes: Task 1; `PowerReading`/`PowerSource` (Machine/Power.swift); `ChildProcess.run(_:_:environment:directory:timeout:) -> ChildOutput`; `Locked`.
- Produces, as AiTerm declares them:
  - `final class BackpackMode` with `init(ports:settings:now:)`, `state`, `setup()`, `turnOn(onJoined:)`, `turnOff()`, `close()`, `recoverAtLaunch()`, `tick(agentsWorking:)`, `rejoinPreferred(leaving:)`, `idleGrace`.
  - `BackpackPorts.live()`, which the host calls.

Ported changes, each ledgered:
- `Mutex` → `Locked`.
- `ProcessRunner.run(...)` → `ChildProcess.run(executable, args, environment: ProcessInfo.processInfo.environment, directory: nil, timeout: …)`, keeping AiTerm's timeouts. `osascript` keeps AiTerm's "no timeout": pass a day.
- `Log.backpack` → `os.Logger(subsystem: "io.github.nathangel.shellforge", category: "backpack")`.
- `ThreadWork` → `BackgroundWork` where the live ports used it.
- **No other change.** In particular, `associate` stays CoreWLAN-first with the `networksetup` fallback, as AiTerm's.

- [ ] **Step 1: Port the fakes and the two test files.** All 37 `BackpackModeTests` and 6 `BackpackLivePortsTests`. Ledger any case dropped (none expected).
  - Run: `Shellforge/scripts/swift.sh test --package-path Shellforge --filter "BackpackModeTests|BackpackLivePortsTests"`
  - Expected: build fails.
- [ ] **Step 2: Port the six sources** with the changes above.
  - Add `CoreWLAN` and `CoreLocation` to `ShellforgeCore`'s linker settings in `Package.swift` if the build asks for them (`linkerSettings: [.linkedFramework("CoreWLAN"), .linkedFramework("CoreLocation")]`).
  - Check that the iTerm2 target links both: `grep -n "CoreWLAN\|CoreLocation" iTerm2.xcodeproj/project.pbxproj`. Ledger what was added.
- [ ] **Step 3: Run the filter.** Expected: pass.
- [ ] **Step 4: Commit**

```bash
git add Shellforge/Package.swift Shellforge/Sources/ShellforgeCore/Backpack Shellforge/Tests/ShellforgeTestSupport/BackpackFakes.swift Shellforge/Tests/ShellforgeCoreTests/Backpack
git commit -m "Backpack Mode itself: lid sleep through the sudoers rule, the hotspot through CoreWLAN, the battery and idle ends

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 3: The controller

**Files:**
- Create (port): `Shellforge/Sources/ShellforgeUI/Backpack/BackpackController.swift` from `AiTerm/BackpackController.swift`.
- Test (port): `Shellforge/Tests/ShellforgeUITests/BackpackControllerTests.swift` (all 37 cases).

**Interfaces:**
- Consumes: Task 2.
- Produces: `@MainActor public final class BackpackController: ObservableObject`:
  - `@Published` fields: `state`, `setup`, `power`, `busy`, `transition`, `phase`, `currentNetwork`.
  - Methods: `connect`, `cancelConnect`, `finishWithoutSheet`, `turnOff`, `setUp`, `removeSetup`, `refreshSetup`, `networksInRange`, `tick`, `lidCloses`, `launch`, `recoverAtLaunch`, `shutdown`.
  - Its init takes AiTerm's closures (`agentsWorking`, `toast`, `openLocationSettings`, …), unchanged in meaning.

Ported changes, each ledgered:
- **`@Observable` → `ObservableObject`:** the observed fields become `@Published`. Fields that were `@ObservationIgnored` become plain `private var`.
- **Equal writes:** where AiTerm relied on Observation skipping equal writes, guard with `if new != old`. `@Published` publishes every write.
- **Toasts:** Shellforge has no toast, so they go through the `toast` closure. The host turns it into the sidebar's `lastError` banner (Task 5); ledger it.
- **`preview`:** dropped (AiTerm's snapshot harness).

- [ ] **Step 1: Port the tests.**
  - `withObservationTracking` checks become `objectWillChange` sinks, as in M1c-3c's `MachineMonitorTests`.
  - Run: `Shellforge/scripts/swift.sh test --package-path Shellforge --filter BackpackControllerTests`
  - Expected: build fails.
- [ ] **Step 2: Port the controller.**
- [ ] **Step 3: Run the filter.** Expected: pass.
- [ ] **Step 4: Commit**

```bash
git add Shellforge/Sources/ShellforgeUI/Backpack/BackpackController.swift Shellforge/Tests/ShellforgeUITests/BackpackControllerTests.swift
git commit -m "Backpack Mode's controller: connect, retry, end, set up and remove, as AiTerm's

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 4: The views — the footer's line, the sheet, the Mac card

**Files:**
- Create (port), in `Shellforge/Sources/ShellforgeUI/Backpack/`:
  - `MacModeRow.swift` and `ToneDot.swift`.
  - `BackpackSheet.swift`: `BackpackSheetPresentation`, `BackpackSheetModel` as an `ObservableObject`, and `BackpackSheet`.
  - `MacSettingsCard.swift`.
  - `SettingsCard.swift`: AiTerm's `SettingsCard`, `SettingsStatus` and `NumberedSteps` only, from `AiTerm/Views/SettingsCard.swift`.
- Modify: `Shellforge/Sources/ShellforgeUI/Sidebar/SidebarFooter.swift`. Put back AiTerm's `mac: MacModeLine`, `toggleMac`, `openMacSettings`, `backpackLine` and `macControl`, exactly as AiTerm has them, with their defaults.
- Modify: `Shellforge/Tests/ShellforgeUITests/SidebarFooterGeometryTests.swift`. Put back the `mode` argument and `theBackpackLineAddsOneRow`, as AiTerm has them.
- Test (port): `Shellforge/Tests/ShellforgeUITests/{MacModeTests,BackpackSheetTests,MacSettingsCardTests}.swift`.

**Interfaces:**
- Consumes: Task 3.
- Produces:
  - `MacMode(state:transition:)`, `MacModePresentation.line(mode:hotspot:wifi:) -> MacModeLine`, `ToneDot`, `SettingsTone`.
  - `BackpackSheet(model:dismiss:)`, which takes the panel's dismiss closure, as `NewTaskSheet` does.
  - `MacSettingsCard(controller:)`.

Ported changes, each ledgered:
- **macOS 13:**
  - `.onChange(of: x) { _, new in … }` → `.onChange(of: x) { new in … }`.
  - `@Observable BackpackSheetModel` → `ObservableObject`.
  - `@Environment(\.dismiss)` and `afterThisEvent` → the passed `dismiss`, run a turn later.
- **Settings references:** the card's "also in Settings" line and any "Settings › Integrations" words name the Mac card ("Mac Settings…").
- **Footer:** with these parts back, `SidebarFooter.swift` is AiTerm's file again. Its body should differ from AiTerm's only in imports and its credit line; diff it to check.

- [ ] **Step 1: Port the three test files, and put back the geometry test's Backpack case.**
  - Run: `Shellforge/scripts/swift.sh test --package-path Shellforge --filter "MacModeTests|BackpackSheetTests|MacSettingsCardTests|SidebarFooterGeometryTests"`
  - Expected: build fails.
- [ ] **Step 2: Port the views** and put back the footer's parts.
- [ ] **Step 3: Run the filter, then** `--filter "DesignRulesTests|SourceRulesTests"`. Expected: pass. Literals AiTerm waives get AiTerm's exception lines; no new exceptions.
- [ ] **Step 4: Commit**

```bash
git add Shellforge/Sources/ShellforgeUI/Backpack Shellforge/Sources/ShellforgeUI/Sidebar/SidebarFooter.swift Shellforge/Tests/ShellforgeUITests Shellforge/Tests/ShellforgeDesignTests/DesignRulesTests.swift
git commit -m "Backpack Mode's views: the footer's line and clicks, the connect sheet, the Mac card

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 5: Wired into Shellforge — the owner, ⌘B, the footer, the Mac panel

**Files:**
- Modify: `sources/TerminalView/iTermShellforgeSidebar.swift`:
  - `static let backpack = BackpackController(...)`, built from `BackpackPorts.live()` and `BackpackSettings(defaults: .standard, secrets: KeychainSecretStore(service: "io.github.nathangel.shellforge"))`.
  - `agentsWorking`: any session in any window's `SidebarModel.sessions` is `.working`. Read it from `link`'s current store, so one source serves every window.
  - `launch()` / `recoverAtLaunch()` in `startHelper()`, and `shutdown()` at `iTermApplicationWillTerminate`, before the helper stops. Both are skipped under XCTest, as the helper is.
  - `@objc static func toggleBackpack(_ sender: Any?)` and `@objc static func backpackIsOn() -> Bool` for the menu.
- Modify: `sources/AppKit/iTermApplicationDelegate.m`:
  - Near line 374 (`[viewMenu addItem:…]`), add the item "Backpack Mode", key equivalent `b` with ⌘, whose action calls `[iTermShellforgeSidebar toggleBackpack:]`.
  - Validate it with a checkmark while `backpackIsOn`.
- Modify: `plists/iTerm2.plist`: the two Location strings (Global Constraints).
- Modify: `Shellforge/Sources/ShellforgeUI/ShellforgeSidebar.swift`:
  - `makeView(…, backpack: BackpackController)`.
  - `SidebarFooterHost` passes `mac: MacModePresentation.line(mode: MacMode(state: backpack.state, transition: backpack.transition), hotspot: backpack.settingsNetwork, wifi: backpack.currentNetwork)`, `toggleMac: toggle` and `openMacSettings: showMacSettings`.
  - `toggle` is AiTerm's `toggleBackpack`: ignored while `busy` or `transition != nil`; `turnOff()` when on; otherwise present `BackpackSheet` through the sidebar's `PanelSlot`.
  - `showMacSettings` presents `MacSettingsCard` in a `PanelSlot` panel with a Done footer.
- Modify: `Shellforge/Sources/ShellforgeUI/Sidebar/SidebarRows.swift`. `SidebarHeader` gains a `macbook` `SymbolMark` button beside the bolt, with help "Mac Settings…", that calls `showMacSettings`.
- Test: `Shellforge/Tests/ShellforgeUITests/BackpackWiringTests.swift`. ModernTests: `ModernTests/ShellforgeHostTest.swift`.

**Interfaces:**
- Consumes: Tasks 1–4.
- Produces: nothing later tasks use.

- [ ] **Step 1: Write the failing tests.**

```swift
import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

@MainActor @Suite struct BackpackWiringTests {
    private func controller(_ fake: FakeBackpack = FakeBackpack()) -> BackpackController {
        BackpackController.forTesting(ports: fake.ports)   // the ported tests' own factory; use its real name
    }

    /// The footer's click is ⌘B: off → the sheet; on → off; nothing while switching.
    @Test func theFooterClickIsCommandB() async throws {
        var sheets = 0
        let backpack = controller()
        let toggle = BackpackToggle(backpack: backpack, presentSheet: { sheets += 1 })
        toggle.run()
        #expect(sheets == 1)
        await backpack.preparedOn()        // the ported tests' helper that puts the fake mode on; use its real name
        toggle.run()
        await eventually { backpack.state == .off }
        backpack.forceTransition(.turningOn)   // likewise
        toggle.run()
        #expect(sheets == 1, "switching ignores the click")
    }

    /// Quitting with the mode on turns lid sleep back on before the app goes.
    @Test func quittingTurnsBackpackModeOff() async throws {
        let fake = FakeBackpack()
        let backpack = controller(fake)
        await backpack.preparedOn()
        backpack.shutdown()
        #expect(fake.lid.disabled == false)
    }
}
```

  - `BackpackToggle` is a small struct in ShellforgeUI holding AiTerm's `toggleBackpack` rule, so the menu and the footer share it. Use the ported controller tests' helpers for "on" and "transition" by their real names, and ledger them.
  - ModernTests:

```swift
func testCommandBIsFreeInTheMainMenu() {
    let main = NSApp.mainMenu!
    let commandB = main.items.flatMap { $0.submenu?.items ?? [] }
        .filter { $0.keyEquivalent == "b" && $0.keyEquivalentModifierMask == [.command] }
    XCTAssertEqual(commandB.map(\.title), ["Backpack Mode"])
}
```

  - Run: `Shellforge/scripts/swift.sh test --package-path Shellforge --filter BackpackWiringTests`. Expected: build fails.
- [ ] **Step 2: Implement** as listed under Files. `BackpackToggle`:

```swift
/// AiTerm's `toggleBackpack`: the menu's ⌘B and the footer's click.
@MainActor
public struct BackpackToggle {
    public let backpack: BackpackController
    public let presentSheet: @MainActor () -> Void

    public init(backpack: BackpackController, presentSheet: @escaping @MainActor () -> Void) {
        self.backpack = backpack; self.presentSheet = presentSheet
    }

    public func run() {
        guard !backpack.busy, backpack.transition == nil else { return }
        if case .on = backpack.state { Task { await backpack.turnOff() } } else { presentSheet() }
    }
}
```

  - The menu's toggle presents the sheet on the key window's sidebar. The host keeps a weak map from each window controller to its sidebar's present function; the key window's entry is used. If none is found, `NSApp.keyWindow` gets the panel.
- [ ] **Step 3: Run**
  - `Shellforge/scripts/swift.sh test --package-path Shellforge`
  - `(cd Shellforge/daemon && .venv/bin/pytest -q)`
  - `xcodebuild test … -only-testing:ModernTests/ShellforgeHostTest`

  Expected: all pass.
- [ ] **Step 4: Commit**

```bash
git add Shellforge/Sources Shellforge/Tests sources/TerminalView/iTermShellforgeSidebar.swift sources/AppKit/iTermApplicationDelegate.m plists/iTerm2.plist ModernTests/ShellforgeHostTest.swift
git commit -m "Backpack Mode in Shellforge: ⌘B in the View menu, the footer's line and clicks, the Mac card, started and stopped with the app

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 6: Verify in the app

- [ ] **Step 1: Build:** `xcodebuild -project iTerm2.xcodeproj -scheme iTerm2 -configuration Development -skipPackagePluginValidation CODE_SIGN_IDENTITY=- build`. Expected: `** BUILD SUCCEEDED **`.
- [ ] **Step 2: Restart Shellforge with the user's ok.** Quit it by `io.github.nathangel.shellforge`, never `com.googlecode.iterm2`.
- [ ] **Step 3: Ask the user to check:**
  - the Mac button and "Mac Settings…" open the card;
  - ⌘B with nothing set up opens the sheet, and says what is missing;
  - **"Allow…" is the user's own click.** macOS asks for their password. Afterwards `sudo -n -l /usr/bin/pmset -a disablesleep 1` succeeds and `/etc/sudoers.d/shellforge` holds the two lines;
  - choosing the hotspot and connecting shows `● backpack enabled` in the footer;
  - ⌘B again turns it off, and `pmset -g | grep SleepDisabled` reads 0.

  Do not click on the user's screen, and do not run the Allow or connect yourself.
- [ ] **Step 4: Ledger what was seen.**
