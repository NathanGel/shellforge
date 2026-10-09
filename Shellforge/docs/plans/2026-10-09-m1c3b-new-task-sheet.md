# M1c-3b New Task Sheet Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** "New Task…" opens AiTerm's three-step New Task sheet (Task → Agent → Prompt) in a dark panel. It creates the worktree on a typed branch from a chosen base branch, and opens the task's tab already running the chosen agent, model and reasoning level, with the first prompt.

**Architecture:** AiTerm's sheet (`~/aiterm/app/Sources/AiTerm/Views/{NewTaskSheet,SheetChrome,CreationSheet,DestinationLine,PromptEditor}.swift`, `Views/Steps/*`) is ported into `ShellforgeUI`. Its form primitives (`Input`, `Select`, `SegmentedControl`, `Kbd`) are ported into `ShellforgeDesign`. The draft, branch naming, model catalogues and command building (`AiTermCore` `TaskDraft`, `BranchNaming`, `BranchType`, `ModelFiles`, `GrokModelCatalog`, `PiModelCatalog`, `AgentCommand`) are ported into `ShellforgeCore`. Two things change:
- **Agents:** they are `AgentDefinition`s from the registry, not AiTerm's `AgentKind` enum.
- **git:** it runs through `CommandLauncher` (the login shell's environment).

The sheet's state is one `ObservableObject` (`NewTaskModel`), since `@Observable` needs macOS 14. iTerm2 runs the agent by sending the command as the new tab's initial text.

**Tech Stack:** Swift 6 language mode, macOS 13, SwiftUI + AppKit, `ShellforgeDesign`; Swift Testing via `Shellforge/scripts/swift.sh`; the iTerm2 app built with `xcodebuild` for the live check; ModernTests for the iTerm2-side profile.

**Spec:** Shellforge PRD (Claude Doc 89fd80a8-5fcf-4423-a8d6-c62f8512a481):
- **W7:** "Jira-backed New Task … behave as in AiTerm today." This plan covers the sheet; Jira arrives in M1d.
- **W8:** the design system.
- **A1:** "Claude Code, Codex, Grok Build and PI ship as presets with today's drivers, hooks, models, skills and dials unchanged."
- **E1–E7:** every command gets the login shell's environment.

The user: "visually and functionally it should be exactly what AiTerm is, but inside an iTerm fork." `Shellforge/Sources/ShellforgeDesign/README.md` governs every view.

## Global Constraints

- **Source:** AiTerm (`~/aiterm`, GPLv3, Laurens D'Hondt), pinned at `c1f851e574d0c8dd45a95957449c8798d60b65f4`.
  - Each ported file starts `// Ported from AiTerm (app/Sources/<path>.swift), GPLv3, Laurens D'Hondt.`, with "GPLv3, Laurens D'Hondt." on one line.
  - Nothing in `~/aiterm` changes.
- **Design tokens:** every colour, size, radius, spacing and type style comes from `ShellforgeDesign`. `DesignRulesTests` scans it. A literal AiTerm also waives is ported with its exception line; no new exceptions.
- **Dark only, inside iTerm2:**
  - The sheet is presented with `PanelSlot` (`.darkAqua` panel and host).
  - Never `.preferredColorScheme`, never `NSApp.appearance`.
- **macOS 13:** none of `@Observable`/`@Bindable`, `.onKeyPress`, two-argument `onChange`, `focusEffectDisabled`, `FrontToBackStack` (macOS 15), `isolated deinit`, `allowsWindowActivationEvents`.
  - A ported line that uses one is changed and ledgered.
  - `focusEffectDisabled` goes behind `if #available(macOS 14, *)`.
- **git and agent CLIs:** they run through `CommandLauncher` (login-shell `PATH` and environment), never a bare `Process`.
- **Agent identity:** an agent is an `AgentDefinition` (`AgentPresets.all` for M1; the registry's saved agents arrive in M3). Code keys by `AgentDefinition.id` (`"claude"`, `"codex"`, `"grok"`, `"pi"`), never by display name.
- **First prompt:**
  - Typed inline when the whole command is ≤ 1000 bytes and holds no control character except `\n`.
  - Otherwise written to `<worktree>/.shellforge/first-prompt.md` and passed as `"$(cat .shellforge/first-prompt.md)"`.
  - `.shellforge/` is added to the repository's `info/exclude`.
- **Out of scope**, each arriving with its milestone:
  - Jira ticket search and the "Include Jira ticket details" checkbox (M1d).
  - `/` command and skill completions in the prompt editor, `SkillCatalog` and `CompletionHint` (M1c-3d).
  - Settings' app-wide model defaults (M1c-3c).
  - New Review (M1d).
  - Custom agents' `stdin`/`typed` prompt delivery (M3).
- **Commits** end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Nothing is pushed without asking.

## Review Focus

1. **A first prompt with quotes, backslashes, `\(`, `$`, a newline, a tab or ESC, or over 1000 bytes.**
   - The agent receives exactly the text typed, and nothing runs in the shell.
   - iTerm2 evaluates a profile's initial text as an interpolated string, so a `\(` must not be evaluated.
   - Tests: Task 4 `aPromptWithEveryHazardIsTypedVerbatim`; Task 7 `theInitialTextKeepsBackslashes`.
2. **An agent whose CLI is not installed, or none installed.**
   - Its segment is disabled, with "… isn't installed" help.
   - The note names the missing ones, Continue on the agent step is disabled, and nothing is created.
   - Test: Task 5 `aMissingAgentCannotBePickedOrCreated`.
3. **A model catalogue that is missing, malformed or slow.**
   - A fresh Claude install offers the four aliases.
   - PI not signed in shows its "No models" explanation.
   - A PI that hangs is killed after 5 s, and the step says why.
   - Tests: Task 2 `aFreshClaudeOffersTheAliases`, `aSilentPiTimesOut`.
4. **A branch or worktree that already exists, or an invalid branch name** (spaces, `..`, a leading `-`).
   - The destination line names the unused directory (`login-2`).
   - An invalid name puts git's reason in the footer, and the sheet stays open with the draft intact.
   - Tests: Task 3 `aTakenWorktreeGetsTheNextFreeName`; Task 5 `anInvalidBranchKeepsTheSheetOpenWithTheReason`.
5. **Pressing Create twice, ⎋ on each step, or opening "New Task…" twice.**
   - One task, one tab.
   - ⎋ goes back a step, and cancels on the first.
   - A second open brings back the same sheet.
   - Tests: Task 5 `createRunsOnceWhilePressedTwice`; Task 6 `escapeGoesBackThenCancels`; existing `aSlotPresentsOnePanelAtATime`.

---

### Task 1: AiTerm's form primitives in ShellforgeDesign

**Files:**
- Create (port): `Shellforge/Sources/ShellforgeDesign/{Input,Select,SegmentedControl,Kbd}.swift` from `~/aiterm/app/Sources/AiTermUI/`.
- Create (port): `Shellforge/Tests/ShellforgeDesignTests/{InputTests,InputCaretTests,SelectTests,SegmentedControlTests,KbdTests}.swift` from `~/aiterm/app/Tests/AiTermUITests/`.
- Modify: `Shellforge/Tests/ShellforgeDesignTests/TokenParityTests.swift` (baseline digests and AiTerm comparison list), `DesignRulesTests.swift` (AiTerm's exceptions for these four files, if any), `Shellforge/Sources/ShellforgeDesign/README.md` (port list).

**Interfaces:**
- Produces, exactly as AiTerm declares them:
  - `public struct Input: View` with `init(placeholder: String, text: Binding<String>, monospaced: Bool = false, secure: Bool = false, caretAtEnd: Bool = false)`.
  - `public struct Select<Value: Hashable>: View` with `init(values:selection:label:detail:monospaced:)`.
  - `public struct SegmentedControl<Value: Hashable, Content: View>: View` with `init(values:selection:style:isSelectable:help:content:)`.
  - `public struct Kbd: View` with `init(_ keys: String...)`.

- [ ] **Step 1: Port the five test files first.**
  - Credit line on each; `AiTermUI` → `ShellforgeDesign`; host helpers from `TestSupport.swift`.
  - Drop only cases that need a type outside this task, and ledger each.
  - Run: `Shellforge/scripts/swift.sh test --package-path Shellforge --filter "InputTests|InputCaretTests|SelectTests|SegmentedControlTests|KbdTests"`
  - Expected: build fails (`cannot find 'Input' in scope`).
- [ ] **Step 2: Port the four files.** Changes allowed, each ledgered:
  - `isolated deinit` in `Input.Coordinator`: replace with `nonisolated(unsafe) private var undoObservers` and a plain `deinit` that removes them.
  - `.focusEffectDisabled()` in `SegmentedControl`: apply it only under `if #available(macOS 14, *)`, through a private `ViewModifier`.
  - Nothing else changes: values, comments and literals stay AiTerm's.
- [ ] **Step 3: Run the step-1 filter.** Expected: all pass.
- [ ] **Step 4: Parity and rules.**
  - Add the four files to `TokenParityTests`' AiTerm comparison and baseline. The digest comes from the failing run's message.
  - Add AiTerm's `DesignRulesTests` exceptions for these files (copy from `~/aiterm/app/Tests/AiTermUITests/DesignRulesTests.swift`, keyed by rule as ours are). Extend the README's port list.
  - Run: `Shellforge/scripts/swift.sh test --package-path Shellforge --filter "TokenParityTests|DesignRulesTests"`. Expected: pass.
- [ ] **Step 5: Commit**

```bash
git add Shellforge/Sources/ShellforgeDesign Shellforge/Tests/ShellforgeDesignTests
git commit -m "Port AiTerm's Input, Select, SegmentedControl and Kbd into ShellforgeDesign

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 2: Every preset's model list

**Files:**
- Create (port): `Shellforge/Sources/ShellforgeCore/Agents/Models/AgentModel.swift` (`AiTermCore/Agents/AgentModel.swift`), `ModelFiles.swift` (`AiTermCore/Harnesses/ModelFiles.swift`), `GrokModelCatalog.swift`, `PiModelCatalog.swift`.
- Create: `Shellforge/Sources/ShellforgeCore/Agents/Models/ModelCatalogue.swift`, `ModelPreference.swift`.
- Test (port): `Shellforge/Tests/ShellforgeCoreTests/Agents/{ModelFilesTests,GrokModelCatalogTests,PiModelCatalogTests}.swift`, from AiTerm's tests of the same names under `~/aiterm/app/Tests/AiTermCoreTests/`.
- Test: `Shellforge/Tests/ShellforgeCoreTests/Agents/ModelCatalogueTests.swift`.

**Interfaces:**
- Consumes:
  - `AgentDefinition` (`id`, `models: ModelSource`, `reasoningLevels`, `defaultReasoning`), `AgentPresets`.
  - `CommandLauncher.locate(_:)`, and `CommandLauncher.run(_:_:directory:extra:timeout:) -> ChildOutput` (`status`, `stdout`, `stderr`, `timedOut`).
  - `TOMLStatements` (ported in M1c-3a).
- Produces:
  - `public struct AgentModel: Equatable, Hashable, Identifiable, Sendable { id, label, detail, efforts, defaultEffort }`.
  - `public struct ModelCatalogue: Sendable`:
    - `init(home: URL, launcher: CommandLauncher)`
    - `func models(for agent: AgentDefinition) throws -> [AgentModel]` — blocking; call it off the main actor.
  - `public enum PiModelCatalogError: Error, Equatable, Sendable, LocalizedError`.
  - `public struct ModelPreference: Equatable, Sendable { model: String; reasoning: String? }`:
    - `mutating func select(_ model: AgentModel)`
    - `static func resolve(catalog: [AgentModel], remembered: String?) -> ModelPreference`

Ported changes, each ledgered:
- `Harness.claude.defaultEffort` → `AgentPresets.claude.defaultReasoning!`, and likewise for codex, grok and pi.
- `HarnessCommandRunner` → `CommandLauncher`. PI's discover becomes:
  ```swift
  static func discover(executable: String, launcher: CommandLauncher) throws -> [AgentModel] {
      let result: ChildOutput
      do { result = try launcher.run(executable, ["--offline", "--list-models"], extra: ["PI_OFFLINE": "1"], timeout: 5) }
      catch { throw PiModelCatalogError.unavailable }
      guard !result.timedOut, result.status == 0 else {
          throw PiModelCatalogError.failed(result.status, result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
      }
      return try parse(result.stdout)
  }
  ```
- `ModelCatalogue` is not AiTerm's file-stamp cache. Each sheet reads the list once per agent pick, off the main actor. Ruling: the stamp cache is a speed-up, not behaviour; it comes back if a sheet is slow to fill.

- [ ] **Step 1: Port the three test files, and write `ModelCatalogueTests`.**

```swift
import Foundation
import Testing
@testable import ShellforgeCore

@Suite struct ModelCatalogueTests {
    private func home() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shellforge-models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A launcher whose PATH holds only `bin`: no test reaches the developer's own CLIs.
    private func launcher(bin: URL) -> CommandLauncher {
        CommandLauncher(resolve: { ResolvedEnvironment(variables: ["PATH": bin.path, "HOME": bin.deletingLastPathComponent().path], source: .fallback) })
    }

    private func script(_ name: String, in bin: URL, _ body: String) throws {
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let file = bin.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body).write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }

    @Test func aFreshClaudeOffersTheAliases() throws {
        let home = try home()
        let models = try ModelCatalogue(home: home, launcher: launcher(bin: home.appendingPathComponent("bin"))).models(for: AgentPresets.claude)
        #expect(models.map(\.id) == ["opus", "sonnet", "fable", "haiku"])
    }

    @Test func codexWithNoCacheOffersItsConfiguredModel() throws {
        let home = try home()
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try "model = \"gpt-5.7\"\n".write(to: home.appendingPathComponent(".codex/config.toml"), atomically: true, encoding: .utf8)
        let models = try ModelCatalogue(home: home, launcher: launcher(bin: home.appendingPathComponent("bin"))).models(for: AgentPresets.codex)
        #expect(models.map(\.id) == ["gpt-5.7"])
    }

    @Test func piIsListedByItsCLI() throws {
        let home = try home(), bin = home.appendingPathComponent("bin")
        try script("pi", in: bin, """
        echo 'provider  model   context  max-out  thinking  images'
        echo 'anthropic claude-x 200K    64K      yes       yes'
        """)
        let models = try ModelCatalogue(home: home, launcher: launcher(bin: bin)).models(for: AgentPresets.pi)
        #expect(models.map(\.id) == ["anthropic/claude-x"])
    }

    @Test func piNotInstalledSaysItCannotBeLaunched() throws {
        let home = try home()
        #expect(throws: PiModelCatalogError.unavailable) {
            try ModelCatalogue(home: home, launcher: launcher(bin: home.appendingPathComponent("bin"))).models(for: AgentPresets.pi)
        }
    }

    @Test(.timeLimit(.minutes(1))) func aSilentPiTimesOut() throws {
        let home = try home(), bin = home.appendingPathComponent("bin")
        try script("pi", in: bin, "sleep 30\n")
        let started = Date()
        #expect(throws: PiModelCatalogError.self) {
            try ModelCatalogue(home: home, launcher: launcher(bin: bin)).models(for: AgentPresets.pi)
        }
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func anAgentWithAFixedListOffersIt() throws {
        let home = try home()
        let agent = AgentDefinition(id: "local", name: "Local", command: "local", models: .fixed(["a", "b"]),
                                    reasoningLevels: ["low", "high"], defaultReasoning: "high")
        let models = try ModelCatalogue(home: home, launcher: launcher(bin: home.appendingPathComponent("bin"))).models(for: agent)
        #expect(models == [AgentModel(id: "a", label: "a", detail: nil, efforts: ["low", "high"], defaultEffort: "high"),
                           AgentModel(id: "b", label: "b", detail: nil, efforts: ["low", "high"], defaultEffort: "high")])
    }

    @Test func theRememberedModelWinsElseTheFirst() {
        let a = AgentModel(id: "a", label: "A", detail: nil, efforts: ["low", "high"], defaultEffort: "high")
        let b = AgentModel(id: "b", label: "B", detail: nil, efforts: [], defaultEffort: nil)
        #expect(ModelPreference.resolve(catalog: [a, b], remembered: "b") == ModelPreference(model: "b", reasoning: nil))
        #expect(ModelPreference.resolve(catalog: [a, b], remembered: "gone") == ModelPreference(model: "a", reasoning: "high"))
        #expect(ModelPreference.resolve(catalog: [], remembered: "a") == ModelPreference(model: "", reasoning: nil))
    }
}
```

  - Check `ResolvedEnvironment`'s initialiser and `.fallback` case against `LoginEnvironment.swift` before running. Use the real names and ledger the change.
  - Run: `Shellforge/scripts/swift.sh test --package-path Shellforge --filter "ModelCatalogueTests|ModelFilesTests|GrokModelCatalogTests|PiModelCatalogTests"`
  - Expected: build fails (`cannot find 'ModelCatalogue' in scope`).

- [ ] **Step 2: Port the four files with the changes above, then write `ModelCatalogue` and `ModelPreference`.**

```swift
import Foundation

/// Every agent's model list, for the New Task sheet: a preset's from the files its CLI keeps (PI's
/// from a launch of it), anyone else's from its definition. Blocking — call it off the main actor.
public struct ModelCatalogue: Sendable {
    public let home: URL
    private let launcher: CommandLauncher

    public init(home: URL, launcher: CommandLauncher) {
        self.home = home
        self.launcher = launcher
    }

    public func models(for agent: AgentDefinition) throws -> [AgentModel] {
        switch agent.id {
        case AgentPresets.claude.id: return ModelFiles.claudeModels(home: home)
        case AgentPresets.codex.id: return ModelFiles.codexModels(home: home)
        case AgentPresets.grok.id: return GrokModelCatalog.models(home: home)
        case AgentPresets.pi.id:
            guard let executable = launcher.locate(agent.command) else { throw PiModelCatalogError.unavailable }
            return try PiModelCatalog.discover(executable: executable, launcher: launcher)
        default:
            switch agent.models {
            case .fixed(let ids): return ids.map { model($0, of: agent) }
            case .command(let words):
                guard let command = words.first else { return [] }
                let out = try launcher.run(command, Array(words.dropFirst()), timeout: 5)
                guard out.status == 0, !out.timedOut else { return [] }
                return out.stdout.split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { model($0, of: agent) }
            }
        }
    }

    private func model(_ id: String, of agent: AgentDefinition) -> AgentModel {
        AgentModel(id: id, label: id, detail: nil, efforts: agent.reasoningLevels, defaultEffort: agent.defaultReasoning)
    }
}
```

```swift
import Foundation

/// The model and reasoning level a draft opens with.
public struct ModelPreference: Equatable, Sendable {
    public var model: String
    public var reasoning: String?

    public init(model: String, reasoning: String?) {
        self.model = model
        self.reasoning = reasoning
    }

    /// Keep a supported effort when changing models; otherwise use the new model's default.
    public mutating func select(_ model: AgentModel) {
        self.model = model.id
        if let reasoning, model.efforts.contains(reasoning) { return }
        reasoning = model.defaultEffort.flatMap { model.efforts.contains($0) ? $0 : nil } ?? model.efforts.first
    }

    /// The last model used with the agent while the catalogue still offers it, else the catalogue's
    /// first; nothing when the catalogue is empty. (AiTerm's Settings default comes first; it arrives
    /// with Settings › Models.)
    public static func resolve(catalog: [AgentModel], remembered: String?) -> ModelPreference {
        guard let model = catalog.first(where: { $0.id == remembered }) ?? catalog.first else {
            return ModelPreference(model: "", reasoning: nil)
        }
        var preference = ModelPreference(model: model.id, reasoning: nil)
        preference.select(model)
        return preference
    }
}
```

- [ ] **Step 3: Run the step-1 filter.** Expected: all pass.
- [ ] **Step 4: Commit**

```bash
git add Shellforge/Sources/ShellforgeCore/Agents/Models Shellforge/Tests/ShellforgeCoreTests/Agents
git commit -m "Read each preset's models as AiTerm does: Claude's and Codex's caches, Grok's catalogue, PI's list

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 3: The task draft, its branch and its worktree

**Files:**
- Create (port): `Shellforge/Sources/ShellforgeCore/Workspace/BranchType.swift` (verbatim), `BranchNaming.swift` (`AiTermCore/Git/BranchNaming.swift`).
- Create: `Shellforge/Sources/ShellforgeCore/Workspace/TaskDraft.swift`, `Repository.swift`.
- Modify:
  - `Shellforge/Sources/ShellforgeCore/Workspace/TaskWorktrees.swift`: add `create(draft:in:launcher:)`, and keep `create(title:…)` for its existing callers until Task 7 removes the inline field.
  - `Workspace.swift`: `TaskItem.agent/model/reasoning`; `Workspace.lastAgentByProject/lastModelByAgent`, each decoded with a default.
- Test (port): `BranchTypeTests`, `BranchNamingTests`, and AiTerm's `TaskDraft` cases from `~/aiterm/app/Tests/AiTermCoreTests/TaskDraftTests.swift` except ticket ones.
- Test: `Shellforge/Tests/ShellforgeCoreTests/Workspace/{RepositoryTests,DraftWorktreeTests}.swift`.

**Interfaces:**
- Consumes: `CommandLauncher.run`, `TaskWorktrees.slug`/`exclude` (exclude becomes `static func exclude(_:worktreeOrRepo:launcher:)`, internal), `GitFailure`.
- Produces:
  - `public enum BranchType: String, CaseIterable { case feat, fix, chore }` with `summary` and `split(_:)`.
  - `public enum BranchNaming`: `slug`, `branchSlug(key:summary:)`, `worktreeSlug(branch:)`, `unused(_:in:)`, and `isValid(_ name: String, launcher: CommandLauncher) -> Bool`.
  - `public struct TaskDraft: Equatable, Sendable`:
    - Stored: `title`, `branchType`, `branchName`, `baseBranch`, `agentId: String`, `model`, `reasoning`, `promptText`.
    - `branch`, `worktreeSlug`; `setTitle`, `setBranch`, `setBranchType`, `setModel(_:catalog:efforts:)`.
  - `public enum Repository`: `defaultBranch(of: String, launcher:) -> String` and `branches(of: String, launcher:) -> [String]`.
  - `TaskWorktrees.create(draft: TaskDraft, in: Project, launcher:) throws -> TaskItem`.
  - `TaskItem.agent: String?`, `model: String?`, `reasoning: String?`.
  - `Workspace.lastAgentByProject: [UUID: String]`, `lastModelByAgent: [String: String]`, and `mutating func remember(_ draft: TaskDraft, projectId: UUID)`.

Ported changes, each ledgered:
- `BranchNaming.isValid` runs `git check-ref-format --branch <name>` through the launcher and is valid when the status is 0.
- `Worktree.directoryName` → `".worktrees"`.
- `TaskDraft` drops `ticket`, `appendTicket` and `apply(ticket:)`; `branchSlug(key: nil, summary:)`. `agent: AgentKind` → `agentId: String`.
- `setModel(_:catalog:)` takes the agent's fallback efforts. `Harness.efforts(for:)` was `model?.efforts ?? fallbackEfforts`; here `efforts` is `AgentDefinition.reasoningLevels`.

- [ ] **Step 1: Port the tests, and write the new ones.**

```swift
import Foundation
import Testing
@testable import ShellforgeCore

@Suite struct DraftWorktreeTests {
    @Test func aTakenWorktreeGetsTheNextFreeName() throws {
        let repo = try GitRepo()   // ShellforgeCoreTests' helper: a repository with one commit on main
        try FileManager.default.createDirectory(atPath: repo.path + "/.worktrees/login", withIntermediateDirectories: true)
        var draft = TaskDraft(baseBranch: "main", agentId: "claude", model: "opus", reasoning: "high")
        draft.setTitle("Login")
        #expect(draft.branch == "feat/login")
        #expect(BranchNaming.unused(draft.worktreeSlug, in: repo.path) == "login-2")
        let task = try TaskWorktrees.create(draft: draft, in: repo.project, launcher: repo.launcher)
        #expect(task.worktreePath == repo.path + "/.worktrees/login-2")
        #expect(task.branch == "feat/login")
        #expect(task.baseBranch == "main")
        #expect(task.agent == "claude" && task.model == "opus" && task.reasoning == "high")
        #expect(try repo.git("rev-parse", "--abbrev-ref", "HEAD", in: task.worktreePath) == "feat/login")
    }

    @Test func anInvalidBranchIsRefusedBeforeGitRuns() throws {
        let repo = try GitRepo()
        var draft = TaskDraft(baseBranch: "main", agentId: "claude", model: "opus", reasoning: nil)
        draft.setTitle("x")
        draft.setBranch("bad..name")
        #expect(throws: TaskWorktrees.Refusal.invalidBranch("feat/bad..name")) {
            try TaskWorktrees.create(draft: draft, in: repo.project, launcher: repo.launcher)
        }
        #expect(!FileManager.default.fileExists(atPath: repo.path + "/.worktrees"))
    }

    @Test func anOldWorkspaceFileReadsWithNoRememberedChoices() throws {
        let json = #"{"version":1,"projects":[],"tasks":[]}"#
        let workspace = try JSONDecoder().decode(Workspace.self, from: Data(json.utf8))
        #expect(workspace.lastAgentByProject.isEmpty && workspace.lastModelByAgent.isEmpty)
    }
}

@Suite struct RepositoryTests {
    @Test func theDefaultBranchComesFirstThenTheNewest() throws {
        let repo = try GitRepo()
        _ = try repo.git("branch", "older")
        _ = try repo.git("checkout", "-q", "-b", "newer")
        _ = try repo.git("commit", "-q", "--allow-empty", "-m", "n")
        #expect(Repository.defaultBranch(of: repo.path, launcher: repo.launcher) == "main")
        #expect(Repository.branches(of: repo.path, launcher: repo.launcher) == ["main", "newer", "older"])
    }

    @Test func aRepositoryWithNoUsualBranchFallsBackToMain() throws {
        let repo = try GitRepo(initialBranch: "trunk")
        #expect(Repository.defaultBranch(of: repo.path, launcher: repo.launcher) == "main")
    }
}
```

  - Read `Tests/ShellforgeCoreTests` for the existing git-repository helper and use it. If it lacks `project`, `launcher`, `git(_:in:)` or `initialBranch:`, add them there.
  - The `older`/`newer` order relies on committer dates. If the two land in the same second, give `newer`'s commit `GIT_COMMITTER_DATE` one minute later.
  - Run: `Shellforge/scripts/swift.sh test --package-path Shellforge --filter "DraftWorktreeTests|RepositoryTests|BranchTypeTests|BranchNamingTests|TaskDraftTests"`
  - Expected: build fails.

- [ ] **Step 2: Port `BranchType` and `BranchNaming`, then write the rest.**

`TaskDraft.swift`: port AiTerm's `TaskDraft` with the changes above. Its initialiser:

```swift
public init(baseBranch: String, agentId: String, model: String, reasoning: String?) {
    self.baseBranch = baseBranch; self.agentId = agentId; self.model = model; self.reasoning = reasoning
}

/// Switching model can change which reasoning levels exist, so a level the new model does not
/// offer becomes that model's default. `efforts` is the agent's own list, for a model that
/// publishes none of its own (AiTerm's `Harness.efforts(for:)`).
public mutating func setModel(_ id: String, catalog: [AgentModel], efforts: [String], defaultEffort: String?) {
    model = id
    let picked = catalog.first { $0.id == id }
    if let current = reasoning, (picked?.efforts ?? efforts).contains(current) { return }
    reasoning = picked.map(\.defaultEffort) ?? defaultEffort
}
```

`Repository.swift`:

```swift
import Foundation

/// What the New Task sheet asks a project's repository, through the login shell's git.
public enum Repository {
    public static let fallbackDefaultBranch = "main"

    /// AiTerm's rule: origin's HEAD while it still names a branch, else whichever of origin's or the
    /// local `main`/`master` exists, origin's first; `main` when none does or git cannot be asked.
    public static func defaultBranch(of path: String, launcher: CommandLauncher) -> String {
        let prefix = "refs/remotes/origin/"
        let usual = ["refs/remotes/origin/main", "refs/remotes/origin/master", "refs/heads/main", "refs/heads/master"]
        guard let out = try? launcher.run("git", ["-C", path, "for-each-ref", "--format=%(refname) %(symref)", prefix + "HEAD"] + usual),
              out.status == 0 else { return fallbackDefaultBranch }
        var existing = Set<String>(), originHead: String?
        for line in out.stdout.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            existing.insert(String(fields[0]))
            if fields[0] == prefix + "HEAD", fields.count == 2, fields[1].hasPrefix(prefix) { originHead = String(fields[1]) }
        }
        if let originHead { return String(originHead.dropFirst(prefix.count)) }
        return usual.first(where: existing.contains).map { String($0.split(separator: "/").last!) } ?? fallbackDefaultBranch
    }

    /// The default branch first, then local branches newest first, then branches only on origin.
    public static func branches(of path: String, launcher: CommandLauncher) -> [String] {
        let listing = (try? launcher.run("git", ["-C", path, "for-each-ref", "--format=%(refname)", "--sort=-committerdate",
                                                "refs/heads", "refs/remotes/origin"]))
            .flatMap { $0.status == 0 ? $0.stdout : nil }?
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } ?? []
        let locals = listing.compactMap { $0.hasPrefix("refs/heads/") ? String($0.dropFirst("refs/heads/".count)) : nil }
        let remotes = listing.compactMap { ref -> String? in
            guard ref.hasPrefix("refs/remotes/origin/") else { return nil }
            let name = String(ref.dropFirst("refs/remotes/origin/".count))
            return name == "HEAD" ? nil : name
        }
        var out: [String] = [], seen = Set<String>()
        for name in [defaultBranch(of: path, launcher: launcher)] + locals + remotes where seen.insert(name).inserted { out.append(name) }
        return out
    }
}
```

`TaskWorktrees.create(draft:in:launcher:)`:

```swift
public enum Refusal: Error, Equatable, LocalizedError {
    case invalidBranch(String), emptyTitle, emptyModel
    public var errorDescription: String? {
        switch self {
        case .invalidBranch(let branch): return "“\(branch)” is not a valid Git branch name."
        case .emptyTitle: return "Enter a task name."
        case .emptyModel: return "Choose an available model."
        }
    }
}

/// AiTerm's `TaskCreator.create`: `<project>/.worktrees/<unused slug>` on the draft's branch from its base.
public static func create(draft: TaskDraft, in project: Project, launcher: CommandLauncher) throws -> TaskItem {
    guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Refusal.emptyTitle }
    guard !draft.model.isEmpty else { throw Refusal.emptyModel }
    guard BranchNaming.isValid(draft.branch, launcher: launcher) else { throw Refusal.invalidBranch(draft.branch) }
    func git(_ args: [String]) throws -> String {
        let out = try launcher.run("git", ["-C", project.path] + args)
        guard out.status == 0 else { throw GitFailure(command: "git " + args.joined(separator: " "), message: out.stderr) }
        return out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let slug = BranchNaming.unused(draft.worktreeSlug, in: project.path)
    let path = "\(project.path)/.worktrees/\(slug)"
    try exclude(".worktrees/", gitDir: git(["rev-parse", "--git-common-dir"]), project: project)
    _ = try git(["worktree", "add", "-q", "-b", draft.branch, path, draft.baseBranch])
    return TaskItem(projectId: project.id, title: draft.title, branch: draft.branch, worktreePath: path,
                    baseBranch: draft.baseBranch, agent: draft.agentId, model: draft.model, reasoning: draft.reasoning)
}
```

  - Add `agent`, `model` and `reasoning` to `TaskItem`: optional, after `baseBranch`, defaulting to `nil` in `init`, with `decodeIfPresent` in its `init(from:)`. Write one if it has none, as `Project` does for `collapsed`.
  - Add `lastAgentByProject` and `lastModelByAgent` to `Workspace`, with `decodeIfPresent ?? [:]`, plus:

```swift
/// What the next New Task in this project opens with: this agent, and this model for it.
public mutating func remember(_ draft: TaskDraft, projectId: UUID) {
    lastAgentByProject[projectId] = draft.agentId
    lastModelByAgent[draft.agentId] = draft.model
}
```

- [ ] **Step 3: Run the step-1 filter**, then the whole package: `Shellforge/scripts/swift.sh test --package-path Shellforge`. Expected: all pass, and the existing workspace and worktree tests still pass.
- [ ] **Step 4: Commit**

```bash
git add Shellforge/Sources/ShellforgeCore Shellforge/Tests/ShellforgeCoreTests
git commit -m "A task draft as AiTerm's: typed branch from a chosen base, the unused worktree, the agent remembered

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 4: The agent's command, and the first prompt

**Files:**
- Create (port): `Shellforge/Sources/ShellforgeCore/Agents/AgentCommand.swift` from `AiTermCore/Agents/AgentCommand.swift`.
- Test (port): `Shellforge/Tests/ShellforgeCoreTests/Agents/AgentCommandTests.swift` from AiTerm's, without the ticket cases. Plus the new cases below.

**Interfaces:**
- Consumes: `AgentDefinition.launchWords(model:reasoning:cwd:)`, `ShellWords`, `TaskWorktrees.exclude`.
- Produces:
  - `public enum AgentCommand`:
    - `previewCommand(agent: AgentDefinition, model: String, reasoning: String?, prompt: String?) -> String`
    - `build(agent:model:reasoning:prompt:worktreePath:launcher:) throws -> String`
    - `composePrompt(userText: String?) -> String?`
  - `public enum TabCommand`: `static func initialText(_ command: String) -> String`.

Ported changes, each ledgered:
- `agent.harness.launchWords` → `agent.launchWords(model:reasoning:)` (each word through `shellWord`).
- `.aiterm/first-prompt.md` → `.shellforge/first-prompt.md`.
- `ExcludeFile` → `TaskWorktrees.exclude`, run against the worktree's `git rev-parse --git-common-dir`.
- `composePrompt` loses its ticket arguments (M1d).
- A `PromptDelivery` other than `.argument` throws `AgentCommand.Unsupported`. Presets all use `.argument`; M3 adds the others.

`TabCommand.initialText`: iTerm2 sends a profile's "Initial Text" through its interpolated-string evaluator, so `\(`…`)` would be evaluated. iTerm2 itself doubles backslashes for this (`iTermApplicationDelegate.m:847`). The leading space keeps the command out of a shell history that ignores spaced lines, as AiTerm's daemon typed it.

```swift
/// The line a task's tab types into its shell when it starts.
public enum TabCommand {
    public static func initialText(_ command: String) -> String {
        " " + command.replacingOccurrences(of: "\\", with: "\\\\")
    }
}
```

- [ ] **Step 1: Port the tests, and add:**

```swift
@Test func aPromptWithEveryHazardIsTypedVerbatim() throws {
    let worktree = try GitRepo().path
    let hazards = "it's \"quoted\" \\(not) $HOME `x`\nline two"
    let command = try AgentCommand.build(agent: AgentPresets.claude, model: "opus", reasoning: "high", prompt: hazards,
                                         worktreePath: worktree, launcher: .init())
    #expect(command == "claude --model opus --effort high " + AgentCommand.shellQuote(hazards))
    // What zsh reads back is the prompt itself: run the quoted word through a shell.
    let echoed = try ChildProcess.run("/bin/sh", ["-c", "printf %s " + AgentCommand.shellQuote(hazards)], environment: [:], directory: nil, timeout: 5)
    #expect(echoed.stdout == hazards)
}

@Test func aTabOrEscapeGoesThroughTheFile() throws {
    let worktree = try GitRepo().path
    let command = try AgentCommand.build(agent: AgentPresets.codex, model: "gpt-5.7", reasoning: nil, prompt: "a\tb\u{1B}c",
                                         worktreePath: worktree, launcher: .init())
    #expect(command.hasSuffix("\"$(cat .shellforge/first-prompt.md)\""))
    #expect(try String(contentsOfFile: worktree + "/.shellforge/first-prompt.md", encoding: .utf8) == "a\tb\u{1B}c")
}

@Test func aLongPromptGoesThroughTheFileAndIsExcluded() throws {
    let repo = try GitRepo()
    _ = try AgentCommand.build(agent: AgentPresets.claude, model: "opus", reasoning: nil, prompt: String(repeating: "x", count: 1200),
                               worktreePath: repo.path, launcher: repo.launcher)
    #expect(try repo.git("status", "--porcelain").isEmpty, ".shellforge/ shows as untracked")
}

@Test func thePreviewIsTheCommandThatRuns() throws {
    let worktree = try GitRepo().path
    for prompt in [nil, "short", String(repeating: "y", count: 1200)] {
        let built = try AgentCommand.build(agent: AgentPresets.grok, model: "grok-5", reasoning: "high", prompt: prompt,
                                           worktreePath: worktree, launcher: .init())
        #expect(AgentCommand.previewCommand(agent: AgentPresets.grok, model: "grok-5", reasoning: "high", prompt: prompt) == built)
    }
}

@Test func theInitialTextKeepsBackslashesAndLeadsWithASpace() {
    #expect(TabCommand.initialText(#"claude 'a \(b) c'"#) == #" claude 'a \\(b) c'"#)
}
```

  - Run: `Shellforge/scripts/swift.sh test --package-path Shellforge --filter AgentCommandTests`
  - Expected: build fails.
- [ ] **Step 2: Port `AgentCommand` with the changes above, and add `TabCommand` to the same file.**
- [ ] **Step 3: Run the filter.** Expected: pass.
- [ ] **Step 4: Commit**

```bash
git add Shellforge/Sources/ShellforgeCore/Agents/AgentCommand.swift Shellforge/Tests/ShellforgeCoreTests/Agents/AgentCommandTests.swift
git commit -m "Build the agent's command as AiTerm does, a hazardous or long first prompt read from .shellforge/

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 5: The sheet's state

**Files:**
- Create: `Shellforge/Sources/ShellforgeUI/NewTask/NewTaskModel.swift`.
- Test: `Shellforge/Tests/ShellforgeUITests/NewTaskModelTests.swift`.

**Interfaces:**
- Consumes: Tasks 2–4; `BackgroundWork.run`.
- Produces: `@MainActor public final class NewTaskModel: ObservableObject`. AiTerm's `CreationModel<TaskCreation>`, without search, completions, the generic kind or `@Observable`:

```swift
@MainActor
public final class NewTaskModel: ObservableObject, Identifiable {
    public nonisolated let id = UUID()
    public let project: Project
    public let agents: [AgentDefinition]
    @Published public var draft: TaskDraft
    @Published public private(set) var branches: [String] = []
    @Published public private(set) var models: [AgentModel] = []
    @Published public private(set) var catalogueLoaded = false
    @Published public private(set) var catalogueFailure: String?
    @Published public private(set) var creating = false
    @Published public private(set) var error: CreationFailure?
    /// Whose CLIs the login shell finds; read when the sheet opens.
    public let availableAgents: Set<String>

    public init(project: Project, agents: [AgentDefinition], available: Set<String>, draft: TaskDraft,
                rememberedModels: [String: String],
                catalogue: @escaping @Sendable (AgentDefinition) throws -> [AgentModel],
                branches: @escaping @Sendable () -> [String],
                submit: @escaping @MainActor (TaskDraft) async throws -> Void)

    public var agent: AgentDefinition          // the draft's, else the first
    public var worktreeSlug: String            // BranchNaming.unused(draft.worktreeSlug, in: project.path), memoised per slug
    public var previewCommand: String          // AgentCommand.previewCommand(agent:model:reasoning:prompt: composePrompt)
    public var agentIsReady: Bool              // available.contains(agent.id) && models.contains { $0.id == draft.model }
    public func canAdvance(step: Int) -> Bool  // !creating, title named, and step == 1 || agentIsReady
    public func selectAgent(_ id: String)      // AiTerm's: ignores the current one, clears models, marks a reset
    public func setModel(_ id: String)         // draft.setModel(_:catalog:efforts:defaultEffort:) with agent's levels
    public func loadCatalogue() async          // generation-guarded, off the main actor; ModelPreference.resolve
    public func loadBranches() async
    public func create() async -> Bool         // AiTerm's create: once at a time, error kept on failure
    public static func missingAgentNote(agents: [AgentDefinition], available: Set<String>) -> String?
}

public struct CreationFailure: Equatable { public let reason: String; public let detail: String? }
```

  - `CreationFailure(error)`: `reason` is the error's `localizedDescription`. For `GitFailure`, the reason is its last non-empty stderr line and `detail` is its whole description.
  - Port every body from AiTerm's `CreationModel` and `AgentStep` static helpers, with `AgentKind` → agent id/`AgentDefinition`. Ledger each change.

- [ ] **Step 1: Write the failing tests.**

```swift
import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI

@MainActor @Suite struct NewTaskModelTests {
    private let opus = AgentModel(id: "opus", label: "Opus", detail: nil, efforts: ["low", "high"], defaultEffort: "high")
    private let project = Project(name: "demo", path: FileManager.default.temporaryDirectory.appendingPathComponent("nt-\(UUID().uuidString)").path)

    private func model(available: Set<String> = ["claude", "codex", "grok", "pi"],
                       submit: @escaping @MainActor (TaskDraft) async throws -> Void = { _ in }) -> NewTaskModel {
        NewTaskModel(project: project, agents: AgentPresets.all, available: available,
                     draft: TaskDraft(baseBranch: "main", agentId: "claude", model: "", reasoning: nil),
                     rememberedModels: [:], catalogue: { [opus] _ in [opus] }, branches: { ["main"] }, submit: submit)
    }

    @Test func theFirstStepNeedsOnlyAName() async {
        let sheet = model()
        #expect(!sheet.canAdvance(step: 1))
        sheet.draft.setTitle("Login")
        #expect(sheet.canAdvance(step: 1))
        #expect(!sheet.canAdvance(step: 2), "no model is loaded yet")
        await sheet.loadCatalogue()
        #expect(sheet.draft.model == "opus" && sheet.draft.reasoning == "high")
        #expect(sheet.canAdvance(step: 2) && sheet.canAdvance(step: 3))
    }

    @Test func aMissingAgentCannotBePickedOrCreated() async {
        let sheet = model(available: ["codex"])
        sheet.draft.setTitle("Login")
        await sheet.loadCatalogue()
        #expect(!sheet.agentIsReady && !sheet.canAdvance(step: 2))
        #expect(NewTaskModel.missingAgentNote(agents: AgentPresets.all, available: ["codex"])
                == "Claude Code, Grok Build and PI aren’t installed. Install them in Settings › Agents.")
        #expect(await sheet.create() == false)
    }

    @Test func createRunsOnceWhilePressedTwice() async {
        var submitted = 0
        let sheet = model(submit: { _ in submitted += 1; try await Task.sleep(for: .milliseconds(50)) })
        sheet.draft.setTitle("Login")
        await sheet.loadCatalogue()
        async let first = sheet.create()
        async let second = sheet.create()
        let results = await [first, second]
        #expect(submitted == 1 && results.filter { $0 }.count == 1)
    }

    @Test func anInvalidBranchKeepsTheSheetOpenWithTheReason() async {
        let sheet = model(submit: { throw TaskWorktrees.Refusal.invalidBranch($0.branch) })
        sheet.draft.setTitle("Login")
        await sheet.loadCatalogue()
        #expect(await sheet.create() == false)
        #expect(sheet.error?.reason == "“feat/login” is not a valid Git branch name.")
        #expect(sheet.draft.title == "Login", "the draft survives for correction")
    }

    @Test func switchingAgentReloadsItsModels() async {
        let sheet = model()
        await sheet.loadCatalogue()
        sheet.selectAgent("codex")
        #expect(sheet.models.isEmpty && !sheet.catalogueLoaded)
        await sheet.loadCatalogue()
        #expect(sheet.draft.agentId == "codex" && sheet.draft.model == "opus")
    }

    @Test func thePreviewCarriesTheTypedPrompt() async {
        let sheet = model()
        await sheet.loadCatalogue()
        sheet.draft.promptText = "fix it"
        #expect(sheet.previewCommand == "claude --model opus --effort high 'fix it'")
    }
}
```

  - Run: `Shellforge/scripts/swift.sh test --package-path Shellforge --filter NewTaskModelTests`
  - Expected: build fails.
- [ ] **Step 2: Write `NewTaskModel`** with the interface above. `loadCatalogue`:

```swift
public func loadCatalogue() async {
    catalogueGeneration += 1
    let generation = catalogueGeneration, agent = self.agent, remembered = rememberedModels[agent.id], read = catalogue
    let result = await BackgroundWork.run { () -> (models: [AgentModel], failure: String?) in
        do { return (try read(agent), nil) } catch { return ([], error.localizedDescription) }
    }
    guard !Task.isCancelled, generation == catalogueGeneration, agent.id == draft.agentId else { return }
    models = result.models
    catalogueFailure = result.failure
    catalogueLoaded = true
    if resetModel || !models.contains(where: { $0.id == draft.model }) {
        let preference = ModelPreference.resolve(catalog: models, remembered: remembered)
        draft.model = preference.model
        draft.reasoning = preference.reasoning
        resetModel = false
    }
}
```

  `create`:

```swift
public func create() async -> Bool {
    guard !creating, agentIsReady else { return false }
    creating = true; error = nil
    defer { creating = false }
    do { try await submit(draft); return true }
    catch { self.error = CreationFailure(error) }
    return false
}
```

  Check `BackgroundWork.run`'s real signature (`BackgroundWork.swift:10`) and adapt the call, ledgering it.
- [ ] **Step 3: Run the filter.** Expected: pass.
- [ ] **Step 4: Commit**

```bash
git add Shellforge/Sources/ShellforgeUI/NewTask Shellforge/Tests/ShellforgeUITests/NewTaskModelTests.swift
git commit -m "The New Task sheet's state, AiTerm's creation model on an ObservableObject

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 6: The sheet, in AiTerm's chrome

**Files:**
- Create (port), under `Shellforge/Sources/ShellforgeUI/NewTask/`:
  - `SheetChrome.swift` (`AiTerm/Views/SheetChrome.swift`: `SheetLayout`, `SheetPrimaryButton`, `SheetFooter`, `CreationFooter`, `StepBar`, `AgentSegmented`, `CommandBlock`).
  - `DestinationLine.swift`.
  - `PromptEditor.swift`: `PromptEditor` and `PromptTextView` only, with the completion code removed.
  - `AgentStep.swift`, `PromptStep.swift`, `NewTaskSheet.swift`.
- Test: `Shellforge/Tests/ShellforgeUITests/NewTaskSheetTests.swift`.

**Interfaces:**
- Consumes: `NewTaskModel`, Task 1's primitives, `FormField`, `HelpText`, `VendorMark`, `Hairline`, `Sheet.width`/`Sheet.height`/`Sheet.fittingHeight`, `PanelSlot`.
- Produces:
  - `struct NewTaskSheet: View` with `init(model: NewTaskModel, dismiss: @escaping @MainActor () -> Void)` and `static func seeded(step:)` for tests.
  - `struct Destination: Equatable` with `text`.

Ported changes, each ledgered:
- **No `@Environment(\.dismiss)`:** the panel's `dismiss` closure is passed in; `afterThisEvent` becomes `Task { dismiss() }`.
- **`FrontToBackStack` → `VStack`:** nothing in this sheet hangs over a later sibling once the completion popup and ticket picker are gone.
- **Step 1, Task:** the ticket field and its help text go (M1d). It keeps Task name, then Type / New branch / Base branch.
- **Step 3, Prompt:** no `CompletionPopup`, no `CompletionHint`, no ticket checkbox (M1c-3d, M1d).
- **`PromptEditor`:** `completions`, the `Coordinator`'s trigger and accept code, and the popup go. The `NSTextView` and its insets, placeholder geometry, `focusOnAppear` and focus reporting stay.
- **`AgentSegmented`:** takes `[AgentDefinition]` and an `available: Set<String>`. `VendorMark` gets the preset's `SessionAgent` (`SessionAgent(rawValue: agent.id)`, with `.shell` when there is none).
- **`Destination.text`:** says "Opens in Shellforge", not "Opens in iTerm2". Shellforge is the terminal now.
- **`CreationSheet`'s `.task` loads:** `.task { await model.loadBranches() }` and `.task(id: model.draft.agentId) { await model.loadCatalogue() }`. The search task goes.

- [ ] **Step 1: Write the failing tests.**

```swift
import AppKit
import SwiftUI
import Testing
@testable import ShellforgeCore
import ShellforgeDesign
@testable import ShellforgeUI

@MainActor @Suite struct NewTaskSheetTests {
    private func model() -> NewTaskModel {
        NewTaskModel(project: Project(name: "demo", path: "/tmp/demo"), agents: AgentPresets.all, available: ["claude"],
                     draft: TaskDraft(baseBranch: "main", agentId: "claude", model: "", reasoning: nil), rememberedModels: [:],
                     catalogue: { _ in [] }, branches: { ["main"] }, submit: { _ in })
    }

    @Test func theSheetIsAiTermsSizeAndDarkInALightWindow() throws {
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        parent.appearance = NSAppearance(named: .aqua)
        let slot = PanelSlot()
        let panel = slot.present(over: parent) { dismiss in NewTaskSheet(model: model(), dismiss: dismiss) }
        defer { slot.dismiss() }
        let content = try #require(panel.contentView)
        content.layoutSubtreeIfNeeded()
        #expect(content.fittingSize.width == Sheet.width)
        let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let ground = try #require(bitmap.colorAt(x: Int(content.bounds.width) - 6, y: Int(content.bounds.height) / 2)?.usingColorSpace(.sRGB))
        #expect(ground.brightnessComponent < 0.3, "the sheet draws light: \(ground)")
    }

    /// ⎋ and Back are one move: a step back, or the sheet closed from the first step — never while
    /// a create runs.
    @Test func escapeGoesBackThenCancels() {
        #expect(NewTaskSheet.back(from: 3, creating: false) == .step(2))
        #expect(NewTaskSheet.back(from: 2, creating: false) == .step(1))
        #expect(NewTaskSheet.back(from: 1, creating: false) == .dismiss)
        #expect(NewTaskSheet.back(from: 3, creating: true) == .stay)
    }

    @Test func theDestinationNamesTheWorktreeAndBranch() {
        let project = Project(name: "demo", path: "/tmp/demo")
        #expect(Destination.worktree(project: project, slug: "login-2", branch: "feat/login").text
                == "Opens in Shellforge · demo/.worktrees/login-2 · feat/login")
        #expect(Destination.isShown(onStep: 1) && !Destination.isShown(onStep: 2) && Destination.isShown(onStep: 3))
    }

    @Test func anUninstalledAgentsSegmentIsNotSelectable() {
        #expect(AgentSegmented.isSelectable(AgentPresets.claude, available: ["claude"]))
        #expect(!AgentSegmented.isSelectable(AgentPresets.pi, available: ["claude"]))
    }
}
```

  - `CreationFooter` takes `missingAgentNote: String?` in place of AiTerm's `availableAgents`; ledger it.
  - AiTerm's `back()` rule moves into `static func back(from step: Int, creating: Bool) -> BackMove` (`enum BackMove: Equatable { case step(Int), dismiss, stay }`). The sheet's `back()` applies it, so the test reaches the rule without hosting the sheet.
  - Run: `Shellforge/scripts/swift.sh test --package-path Shellforge --filter NewTaskSheetTests`
  - Expected: build fails.
- [ ] **Step 2: Port the files with the changes above.** `NewTaskSheet.body`:

```swift
var body: some View {
    SheetLayout(title: "New task in \(model.project.name)", height: Sheet.height) {
        StepBar(step: step, names: ["Task", "Agent", "Prompt"])
    } content: {
        VStack(alignment: .leading, spacing: Space.block) {
            switch step {
            case 1: taskStep
            case 2: AgentStep(model: model)
            default: PromptStep(text: $model.draft.promptText, agentId: model.draft.agentId)
            }
            if step > 1 { CommandBlock(caption: "Command", command: model.previewCommand) }
            if Destination.isShown(onStep: step), let destination { DestinationLine(destination) }
        }
    } footer: {
        CreationFooter(step: step, error: model.error,
                       missingAgentNote: NewTaskModel.missingAgentNote(agents: model.agents, available: model.availableAgents),
                       createLabel: "Create Task", creating: model.creating,
                       canAdvance: model.canAdvance(step: step), closeList: { false },
                       back: back, advance: advance)
    }
    .task { await model.loadBranches() }
    .task(id: model.draft.agentId) { await model.loadCatalogue() }
}
```

  - `taskStep` is AiTerm's `ticketStep` from `FormField("Task name")` down, unchanged.
  - `back()` switches on `Self.back(from: step, creating: model.creating)`.
  - `advance` and `create` are AiTerm's, with `dismiss` the passed closure.
- [ ] **Step 3: Run the filter, then the design rules:** `Shellforge/scripts/swift.sh test --package-path Shellforge --filter "NewTaskSheetTests|DesignRulesTests"`. Expected: pass. A literal AiTerm waives gets its AiTerm exception; any other is replaced by a token.
- [ ] **Step 4: Commit**

```bash
git add Shellforge/Sources/ShellforgeUI/NewTask Shellforge/Tests/ShellforgeUITests/NewTaskSheetTests.swift Shellforge/Tests/ShellforgeDesignTests/DesignRulesTests.swift
git commit -m "AiTerm's New Task sheet: Task, Agent and Prompt steps, its step bar, command preview, destination and footer

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 7: New Task… opens the sheet; the tab runs the agent

**Files:**
- Modify: `Shellforge/Sources/ShellforgeUI/SidebarModel.swift`:
  - `TerminalHost.openTab(in:taskId:projectId:title:command:)`.
  - `newTask(draft:in:) async throws`.
  - `makeNewTaskModel(for:) -> NewTaskModel?`.
  - Remove `newTask(title:in:)`.
- Modify: `Shellforge/Sources/ShellforgeUI/ShellforgeSidebar.swift`: the "+" menu's "New Task…" presents the sheet through `sheet` (the `PanelSlot`). Remove the inline field, `newTaskTitle`, `newTaskProject` and `titleFocused`.
- Modify: `Shellforge/Tests/ShellforgeUITests/{SidebarModelTests,SidebarRowsTests}.swift` and the `FakeTerminalHost`:
  - The fake host records `command`.
  - The new-task tests go through `newTask(draft:in:)`.
  - `makeModelWithProject(installed:)` builds the model's launcher on a scratch bin of `exit 0` scripts named by `installed`, plus the real `git`'s folder.
- Modify: `sources/TerminalView/iTermShellforgeSidebar.swift`:
  - `taskTabProfile(base:directory:initialText:)`, and `openTab` passes `TabCommand.initialText(command)`.
  - `makeView` hands the model `AgentPresets.all`, a `ModelCatalogue(home: FileManager.default.homeDirectoryForCurrentUser, launcher: launcher)` and the launcher.
- Modify: the ModernTests file that tests `taskTabProfile`: `grep -rn taskTabProfile ModernTests`.

**Interfaces:**
- Consumes: Tasks 2–6.
- Produces:
  - `SidebarModel.init(host:document:launcher:feed:agents:catalogue:)`, where `agents` defaults to `AgentPresets.all` and `catalogue: @escaping @Sendable (AgentDefinition) throws -> [AgentModel]`.
  - `public func newTask(draft: TaskDraft, in projectId: UUID) async throws` — throws so the sheet keeps its error.
  - `public func makeNewTaskModel(for projectId: UUID) -> NewTaskModel?`:
    - The agent is `lastAgentByProject[project]` when installed, else the first installed preset.
    - `available` is the presets whose `command` `launcher.locate` finds.
    - The base branch is `Repository.defaultBranch`, read when the sheet's branches load. The draft opens with `Repository.fallbackDefaultBranch` and `loadBranches` sets it to the first branch while untouched.

- [ ] **Step 1: Write the failing tests** in `SidebarModelTests`:

```swift
@Test func aNewTaskOpensItsTabRunningTheAgent() async throws {
    let (model, host, repo) = try makeModelWithProject()   // existing helper; extend if it lacks the repo
    var draft = TaskDraft(baseBranch: "main", agentId: "claude", model: "opus", reasoning: "high")
    draft.setTitle("Login")
    draft.promptText = "fix it"
    try await model.newTask(draft: draft, in: repo.projectId)
    let opened = try #require(host.opened.last)
    #expect(opened.directory.hasSuffix("/.worktrees/login"))
    #expect(opened.command == "claude --model opus --effort high 'fix it'")
    #expect(model.document.workspace.lastAgentByProject[repo.projectId] == "claude")
    #expect(model.document.workspace.lastModelByAgent["claude"] == "opus")
}

@Test func theNextSheetOpensWithTheLastAgentWhileItIsInstalled() async throws {
    // The model's launcher sees only a scratch bin holding `claude` and `codex` scripts (`exit 0`):
    // what this Mac has installed never decides the test.
    let (model, _, repo) = try makeModelWithProject(installed: ["claude", "codex"])
    try model.document.update { $0.lastAgentByProject[repo.projectId] = "codex" }
    let sheet = try #require(model.makeNewTaskModel(for: repo.projectId))
    #expect(sheet.availableAgents == ["claude", "codex"])
    #expect(sheet.draft.agentId == "codex")
    try model.document.update { $0.lastAgentByProject[repo.projectId] = "pi" }
    #expect(model.makeNewTaskModel(for: repo.projectId)?.draft.agentId == "claude", "an uninstalled last agent gives way to the first installed")
}

@Test func aFailedCreateLeavesNoTaskAndThrows() async throws {
    let (model, host, repo) = try makeModelWithProject()
    var draft = TaskDraft(baseBranch: "no-such-branch", agentId: "claude", model: "opus", reasoning: nil)
    draft.setTitle("Login")
    await #expect(throws: GitFailure.self) { try await model.newTask(draft: draft, in: repo.projectId) }
    #expect(model.document.workspace.tasks.isEmpty && host.opened.isEmpty)
}
```

  ModernTests, in the existing `taskTabProfile` test file:

```swift
func testTheInitialTextIsSentWithItsBackslashes() {
    let profile = iTermShellforgeSidebar.taskTabProfile(base: [:], directory: "/tmp/x", initialText: #" claude 'a \\(b)'"#)
    XCTAssertEqual(profile[KEY_INITIAL_TEXT] as? String, #" claude 'a \\(b)'"#)
    XCTAssertEqual(profile[KEY_WORKING_DIRECTORY] as? String, "/tmp/x")
}
```

  - Run: `Shellforge/scripts/swift.sh test --package-path Shellforge --filter "SidebarModelTests|SidebarRowsTests"`
  - Expected: build fails.
- [ ] **Step 2: Implement.** `newTask(draft:in:)`:

```swift
public func newTask(draft: TaskDraft, in projectId: UUID) async throws {
    guard let project = document.workspace.projects.first(where: { $0.id == projectId }),
          let agent = agents.first(where: { $0.id == draft.agentId }) else { return }
    let launcher = self.launcher
    let made = try await BackgroundWork.run { () throws -> (TaskItem, String) in
        let task = try TaskWorktrees.create(draft: draft, in: project, launcher: launcher)
        let command = try AgentCommand.build(agent: agent, model: draft.model, reasoning: draft.reasoning,
                                             prompt: AgentCommand.composePrompt(userText: draft.promptText),
                                             worktreePath: task.worktreePath, launcher: launcher)
        return (task, command)
    }
    try document.update { workspace in
        workspace.tasks.append(made.0)
        workspace.remember(draft, projectId: projectId)
        if let i = workspace.projects.firstIndex(where: { $0.id == projectId }) { workspace.projects[i].collapsed = false }
    }
    selectedTaskId = made.0.id
    host.openTab(in: made.0.worktreePath, taskId: made.0.id, projectId: projectId, title: made.0.title, command: made.1)
}
```

  - **`select(task:)`** reopens a task with no tab. It passes `command: nil`: the agent ran once in the first tab, and a reopened tab is a shell, as AiTerm's "New Terminal" is.
  - **The sidebar's "New Task…"** calls `sheet.present(over: anchor.window) { dismiss in NewTaskSheet(model: m, dismiss: dismiss) }` with `m = model.makeNewTaskModel(for:)`. The submit closure calls `try await model.newTask(draft:in:)`.
  - **iTerm2 side:** `taskTabProfile` gains `initialText: String?` and sets `profile[KEY_INITIAL_TEXT]` when non-nil. `openTab` passes `command.map(TabCommand.initialText)`.
  - Check `BackgroundWork.run`'s throwing form and adapt the call, ledgering it.
- [ ] **Step 3: Run the package, the daemon and ModernTests:**

```bash
Shellforge/scripts/swift.sh test --package-path Shellforge
(cd Shellforge/daemon && .venv/bin/pytest -q)
xcodebuild test -project iTerm2.xcodeproj -scheme ModernTests -configuration Development -skipPackagePluginValidation CODE_SIGN_IDENTITY=- -only-testing:ModernTests/<the taskTabProfile test class>
```

  Expected: all pass.
- [ ] **Step 4: Commit.** Stage only `Shellforge/`, `sources/` and `ModernTests/`; the build rewrites checked-in framework binaries, which never go in a commit.

```bash
git add Shellforge sources/TerminalView/iTermShellforgeSidebar.swift ModernTests
git commit -m "New Task… opens AiTerm's sheet; the task's tab starts the chosen agent with its first prompt

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 8: Verify in the app, beside AiTerm

- [ ] **Step 1: Build:** `xcodebuild -project iTerm2.xcodeproj -scheme iTerm2 -configuration Development -skipPackagePluginValidation CODE_SIGN_IDENTITY=- build`. Expected: `** BUILD SUCCEEDED **`.
- [ ] **Step 2: Restart Shellforge with the user's ok.** Their sessions may be running in it; ask before quitting.
- [ ] **Step 3: Ask the user to open New Task… on a project and check:**
  - the three steps;
  - the agent segments with their marks, a missing CLI greyed;
  - the model and reasoning popups filled from their real catalogues;
  - the command preview;
  - the destination line;
  - ⎋ back and cancel;
  - Create Task opening the tab with the agent running and the first prompt in it.

  Compare with AiTerm's sheet: screenshots from the user, or `~/aiterm/docs/design/design-system.html`. Do not click on the user's screen.
- [ ] **Step 4: Ledger what was seen**, and any difference from AiTerm as a ruling or a finding.
