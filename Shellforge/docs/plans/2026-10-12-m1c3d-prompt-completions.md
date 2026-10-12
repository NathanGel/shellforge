# M1c-3d Prompt Completions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In New Task's prompt step, typing `/` at the start of a word opens AiTerm's popup of the chosen agent's installed slash commands and skills. ↑/↓ move through it, ↩ accepts, and ⎋ closes it (before ⎋ leaves the step). Accepting writes the item as that agent runs it: `/brainstorming`, or Codex's `$imagegen` for a skill.

**Architecture:**
- **ShellforgeCore** gets AiTerm's `SkillCatalog` (discovery, frontmatter, matching, trigger, invocation) and the file-stamp cache it uses.
  - AiTerm's `Harness.skillRoots` and `skillSigil` become a `SkillRoots.for(agentId:)` table keyed by `AgentDefinition.id`.
  - A custom agent has no roots, and so no completions.
- **ShellforgeUI** gets AiTerm's `PromptCompletions` (as an `ObservableObject`), the editor's completion code, `CompletionPopup`, `CompletionHint`, and `DropdownList`/`DropdownKeys`.
  - `NewTaskModel` fills the completions when it loads an agent's models.
  - The sheet's ⎋ closes the popup first.

**Tech Stack:** Swift 6 language mode, macOS 13, SwiftUI + AppKit (TextKit 1 `NSTextView`), `ShellforgeDesign`; Swift Testing via `Shellforge/scripts/swift.sh`.

**Spec:**
- **Shellforge PRD A1:** "Claude Code, Codex, Grok Build and PI ship as presets with today's drivers, hooks, models, skills and dials unchanged."
- **W8:** the design system.
- **The user:** "exactly what AiTerm is."

## Global Constraints

- **Source:** AiTerm (`~/aiterm`, GPLv3, Laurens D'Hondt), pinned at `c1f851e574d0c8dd45a95957449c8798d60b65f4`.
  - Each ported file starts `// Ported from AiTerm (app/Sources/<path>.swift), GPLv3, Laurens D'Hondt.` Tests credit `app/Tests/<path>`.
  - Nothing in `~/aiterm` changes.
- **macOS 13:**
  - No `Synchronization`/`Mutex` (use `Locked`).
  - No `@Observable` (use `ObservableObject`).
  - No `FrontToBackStack` (macOS 15): layering is explicit `.zIndex`, as Shellforge's `FormField` already does.
- **Tests read no real home:** every `discover` passes a temporary `home:`.
- **Design tokens:** every colour, size and type style comes from `ShellforgeDesign`, and `DesignRulesTests` scans `ShellforgeUI`. AiTerm has no exceptions for these files, so none are added.
- **Commits** end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Stage paths by name; never `commit -a`. Nothing is pushed.

## Review Focus

1. **A skill directory with a symlink loop, a huge `SKILL.md`, a plugin with two versions, or a `user-invocable: false` skill.**
   - Discovery ends, the newest version wins, and hidden skills stay hidden.
   - Tests: Task 1 (the 23 ported `SkillCatalogTests`).
2. **Typing `/` mid-word, after a space, or with a non-ASCII prompt before the caret.**
   - The popup opens only at the start of a word.
   - Accepting replaces exactly the typed token. The caret's UTF-16 offset differs from its Character offset.
   - Tests: Task 1 trigger cases; Task 3 `acceptReplacesExactlyTheTypedToken`.
3. **⎋ with the popup open.** It closes the popup and nothing else, and the next ⎋ goes back a step.
   - Test: Task 3 `escapeClosesThePopupBeforeTheStep`.
4. **Switching agent while the popup is open.**
   - The list becomes the new agent's, and the popup closes.
   - A Codex skill is written `$name`, everyone else's `/name`.
   - Tests: Task 3 `switchingAgentReloadsAndClosesTheCompletions`; ported `aCodexSkillPickedFromSlashIsWrittenAsItsMention`.
5. **The popup near the field's right edge or bottom.**
   - It stays inside the field horizontally and draws over the command preview below.
   - Tests: ported `popupOpenedNearTheRightEdgeStaysInsideTheField`; Task 3 `thePopupDrawsOverTheCommandPreview`.

---

### Task 1: The skill catalogue

**Files:**
- Create (port), in `Shellforge/Sources/ShellforgeCore/Agents/Skills/`:
  - `SkillCatalog.swift` (`AiTermCore/Agents/SkillCatalog.swift`).
  - `FileStamps.swift`: `FileStamps` and `KeyedStates`, from `AiTermCore/Git/WatchedFileCache.swift:107-180`.
- Create: `Shellforge/Sources/ShellforgeCore/Agents/Skills/SkillRoots.swift`. It holds `SkillRoot` (from `AiTermCore/Harnesses/Harness.swift:107-125`) and the per-agent table from `Harness+Agents.swift` (claude 14-25, codex 41-55, grok 67-81, pi 94-106).
- Test (port): `Shellforge/Tests/ShellforgeCoreTests/Agents/SkillCatalogTests.swift` (all 23).

**Interfaces:**
- Produces:
  - `AgentCompletion`, `CompletionTrigger`.
  - `enum SkillCatalog` with `discover(agentId: String, projectPath: String?, home: URL) -> [AgentCompletion]`, `matches`, `trigger(in:caret:)`, `invocation(of:agentId:)`, `matchLimit`, `frontmatterValue`.
  - `enum SkillRoots`:
    - `static func roots(agentId: String, home: URL, project: URL?) -> [SkillRoot]`
    - `static func sigil(agentId: String) -> Character`, which is `$` for codex and `/` otherwise.

Ported changes, each ledgered:
- `AgentKind` → `agentId: String`; `agent.harness.skillRoots` → `SkillRoots.roots(agentId:…)`; `skillSigil` → `SkillRoots.sigil(agentId:)`.
- `Mutex` → `Locked`.
- An unknown id has no roots and gives an empty list.

- [ ] **Step 1: Port the tests** (the agent arguments become ids).
  - Run: `Shellforge/scripts/swift.sh test --package-path Shellforge --filter SkillCatalogTests`
  - Expected: build fails.
- [ ] **Step 2: Port the three files.**
- [ ] **Step 3: Run the filter.** Expected: 23 pass.
- [ ] **Step 4: Commit** (`git add` the three sources and the test): "The skill catalogue: each preset's commands and skills, found as AiTerm finds them".

### Task 2: Dropdowns

**Files:**
- Create (port): `Shellforge/Sources/ShellforgeUI/NewTask/Dropdown.swift` (`AiTerm/Views/Dropdown.swift`).
- Test (port): `Shellforge/Tests/ShellforgeUITests/DropdownKeysTests.swift`, from AiTerm's `SearchPickerTests.swift:7-40` (its 4 `DropdownKeys` tests).

**Interfaces:** Produces `DropdownKeys.handle(selector:count:index:open:) -> DropdownKeys.Outcome` and `DropdownList<Item, Row>`.

- [ ] **Step 1: Port the tests.** Run `--filter DropdownKeysTests`. Expected: build fails.
- [ ] **Step 2: Port `Dropdown.swift`.**
- [ ] **Step 3: Run the filter.** Expected: pass. Then run `DesignRulesTests`. Expected: pass.
- [ ] **Step 4: Commit:** "AiTerm's dropdown list and its keys".

### Task 3: The popup in the prompt step

**Files:**
- Modify: `Shellforge/Sources/ShellforgeUI/NewTask/PromptEditor.swift`.
  - Put back AiTerm's `PromptCompletions` as an `ObservableObject`. `visible`, `index`, `anchor` and `fieldWidth` are `@Published`; writes are guarded so an equal write publishes nothing; `close()` does nothing when already closed.
  - Put back the editor's `completions` and `agentId` parameters, the Coordinator's `refresh`, `accept`, `currentTrigger`, `caretAnchor` and `doCommandBy`.
  - Port `CompletionPopup` and `CompletionHint`.
- Modify: `PromptStep.swift`: the popup overlay, the hint, and `.zIndex(1)` on the field so the popup draws over the hint.
- Modify: `NewTaskSheet.swift`:
  - `.zIndex(1)` on the step, so the popup draws over `CommandBlock`.
  - `closeList` closes the popup on step 3 and says so.
- Modify: `NewTaskModel.swift`:
  - `public let completions = PromptCompletions()`.
  - `loadCatalogue` also runs `SkillCatalog.discover(agentId:projectPath: project.path, home: home)` off the main actor, then sets `completions.all` and closes the popup.
  - `home` is a new init parameter, defaulting to the user's home; tests pass a temporary one.
- Test (port): `Shellforge/Tests/ShellforgeUITests/PromptEditorTests.swift`, the six completion cases from AiTerm's `PromptEditorTests.swift` (`closingAClosedPopupRedrawsNothing`, `popupOpenedNearTheRightEdgeStaysInsideTheField`, `onlyReturnAcceptsASuggestion`, `thePopupAnswersItsKeysAsEveryDropdownDoes`, `aCodexSkillPickedFromSlashIsWrittenAsItsMention`, `popupKeepsItsCaretPositionWhenItFits`), plus the hint test from `PromptCompletionTests.swift`.
- Test: the new cases below, in the same file.

```swift
@Test func acceptReplacesExactlyTheTypedToken() {
    // "é /bra" with the caret after "bra": the token is "/bra" by Characters, at a different UTF-16 offset.
    let text = "é /bra"
    let trigger = try #require(SkillCatalog.trigger(in: text, caret: text.count))
    #expect(trigger.query == "bra" && trigger.range == 2..<6)
}

@Test func escapeClosesThePopupBeforeTheStep() {
    let completions = PromptCompletions()
    completions.all = [AgentCompletion(name: "brainstorming", kind: .skill, detail: nil, source: .user)]
    completions.visible = completions.all
    #expect(NewTaskSheet.closeList(step: 3, completions: completions) == true)
    #expect(!completions.isOpen)
    #expect(NewTaskSheet.closeList(step: 3, completions: completions) == false, "the next ⎋ goes back a step")
}

@MainActor @Test func switchingAgentReloadsAndClosesTheCompletions() async throws {
    // A home with one Claude skill and one Codex skill; the model loads Claude's, then Codex's.
    let home = try tempHome(claudeSkill: "brainstorming", codexSkill: "imagegen")
    let model = NewTaskModel(…, home: home)        // use the existing test factory's other arguments
    await model.loadCatalogue()
    #expect(model.completions.all.map(\.name) == ["brainstorming"])
    model.completions.visible = model.completions.all
    model.selectAgent("codex")
    await model.loadCatalogue()
    #expect(model.completions.all.map(\.name) == ["imagegen"] && !model.completions.isOpen)
}
```

`thePopupDrawsOverTheCommandPreview` is a port of AiTerm's `CompletionPopupLayeringTests` (hosted sheet on step 3 with an open popup; the pixel under the popup's first row is the popup's fill, not the command block's).

- [ ] **Step 1: Port and write the tests.** Run `--filter "PromptEditorTests|NewTaskSheetTests|NewTaskModelTests"`. Expected: build fails.
- [ ] **Step 2: Implement as listed.**
- [ ] **Step 3: Run the whole package.** Expected: pass.
- [ ] **Step 4: Commit:** "Typing / in New Task's prompt lists the agent's own commands and skills, as AiTerm does".

### Task 4: Verify in the app

- [ ] Build the app (`xcodebuild … build`). Expected: `** BUILD SUCCEEDED **`.
- [ ] The live check (type `/` on the prompt step with Claude, then Codex) waits for the user. List it with the other deferred checks.
