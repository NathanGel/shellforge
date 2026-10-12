# M1d-1 Jira in New Task Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Jira works as AiTerm's does, in two places.
- **Connecting:** the person connects Jira once (site, email, API token; the token goes in the Keychain).
- **New Task:** its first step gets AiTerm's ticket field.
  - Opened empty, it lists their open tickets; typing searches by key or text.
  - Picking a ticket fills the name, the branch type and the branch, and stamps the task with its key.
  - On the prompt step, "Include Jira ticket details" appends the ticket to the first prompt.

**Architecture:**
- **ShellforgeCore:** AiTerm's `JiraClient`, `JiraConfig`, `JiraTicket`, `JiraSettings` and `ADFText`, with the HTTP layer they stand on (`HTTPJSON`, `StoredJSON`).
- **TaskDraft:** gets back its ticket fields and `apply(ticket:)`. `composePrompt` gets back its ticket. `TaskItem` gets back `jira`.
- **ShellforgeUI:** AiTerm's `SearchPicker` (with `PickedItemField`, `PickerResultRow` and `LaneChip`) and the search state in `NewTaskModel`. The Jira connection card is AiTerm's `ServiceConnection`, cut to Jira.
- **Settings panel:** Shellforge has no Settings window, so the Mac card's panel becomes a "Settings" panel holding the Jira card and the Mac card. The header's macbook button becomes a gear opening it.
- **Out of scope (M1d-2):** per-project Jira links (`Project.jiraProjects`, the Jira Projects sheet, the header badge). With none linked, AiTerm searches every project the account can see, and so does this.

**Tech Stack:** Swift 6 language mode, macOS 13, URLSession, SwiftUI + AppKit, `ShellforgeDesign`; Swift Testing via `Shellforge/scripts/swift.sh`, with a `URLProtocol` stub. No test reaches the network.

**Spec:**
- **Shellforge PRD W7:** "Jira-backed New Task, MR/PR review and worktree cleanup behave as in AiTerm today."
- **W8:** the design system.
- **The user:** "Ticketing stays as AiTerm has it."

## Global Constraints

- **Source:** AiTerm (`~/aiterm`, GPLv3, Laurens D'Hondt), pinned at `c1f851e574d0c8dd45a95957449c8798d60b65f4`. Ported files carry the credit line, and nothing in `~/aiterm` changes.
- **Secrets:**
  - The Jira token lives only in the Keychain (`Keychain`, service `io.github.nathangel.shellforge`, account `jira.token`, already a separate account in `SecretStore.swift`). It is never logged, written to UserDefaults, put in a URL, or shown.
  - The site and email are stored in UserDefaults under `jira.site` and `jira.email`, AiTerm's keys.
  - AiTerm's `CredentialGuard` stays: it strips credentials on a cross-origin redirect.
- **The person enters their own credentials.** No test uses real ones, and the implementer never types or stores any.
- **macOS 13:**
  - No `Mutex` (use `Locked`).
  - No `@Observable` (use `ObservableObject`).
  - No `onChange(of:initial:)` and no two-argument `onChange`: use the one-argument form, plus `.onAppear` for "initial".
- **Design tokens:** every colour, size and type style comes from `ShellforgeDesign`, and `DesignRulesTests` scans `ShellforgeUI`. Dark only, through `PanelSlot`.
- **Commits** end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Stage paths by name; never `commit -a`. Nothing is pushed.

## Review Focus

1. **A wrong token, a site typed with a path or trailing slash, an unreachable host, or a redirect to another host.**
   - The card says why: "Jira rejected the email or API token", the network error, and so on.
   - The token is never sent to the other host.
   - Tests: Task 1 (ported `JiraClientTests` 401, redirect and normalise cases); Task 3 (ported settings-model cases).
2. **Typing fast in the ticket field.** Only the last query's answer shows, and a stale answer never replaces it.
   - Test: Task 4 (ported `TaskCreationModelTests` search cases).
3. **Picking a ticket after editing the name, branch or type, then clearing the ticket.**
   - Edited fields are kept, and clearing keeps the type.
   - Test: Task 2 (ported `TaskCreatorTests` ticket cases).
4. **Jira not connected.**
   - The field says "Connect Jira in Settings, or continue without a ticket." and the task can still be created.
   - Test: Task 4 `withoutJiraTheFieldSaysHowAndCreateStillWorks`.
5. **A ticket with an ADF description: lists, code, mentions.**
   - The appended prompt carries readable text.
   - The prompt with the ticket still goes through the file route when it is long or has control characters.
   - Tests: Task 1 (ported ADF cases); Task 2 `aTicketPromptOverTheLimitGoesThroughTheFile`.

---

### Task 1: Jira's client and the HTTP layer

**Files:**
- Create (port), in `Shellforge/Sources/ShellforgeCore/Jira/`:
  - `JiraTicket.swift`, `JiraClient.swift`, `JiraSettings.swift`, `ADFText.swift` (with `StoredJSON` from `Models.swift:135-162`).
  - `HTTPJSON.swift` (from `AiTermCore/HTTPJSON.swift`).
  - `ActionUnavailable.swift`.
- Create (port): `Shellforge/Tests/ShellforgeTestSupport/StubURLProtocol.swift` (`Mutex` → `Locked`).
- Test (port): `Shellforge/Tests/ShellforgeCoreTests/Jira/{JiraClientTests,JiraSettingsTests}.swift` (all 41 + 1).

**Interfaces:**
- Produces: `JiraConfig(site:email:token:)` (normalised), `JiraClient(config:session:)` with `myOpenIssues(projects:)`, `search(text:projects:)`, `testConnection()` and `projects()`; `JiraError`; `JiraTicket`; `JiraSettings` (load/save/clear over `UserDefaults` + `SecretStore`); `ActionUnavailable`.

Ported changes, each ledgered:
- `Mutex` → `Locked`.
- `JiraProjectRef` arguments stay as AiTerm declares them, and `JiraProjectRef` is ported here: `JiraClient`'s project scope takes it. `Project.jiraProjects` comes in M1d-2.
- Error words naming "Settings › Integrations" say "Settings".

- [ ] Step 1: Port the tests and the stub. Run `--filter "JiraClientTests|JiraSettingsTests"`. Expected: build fails.
- [ ] Step 2: Port the sources.
- [ ] Step 3: Run the filter. Expected: 42 pass.
- [ ] Step 4: Commit: "Jira's client as AiTerm's: open tickets, key and text search, the connection test, the token in the Keychain".

### Task 2: The draft and the prompt carry the ticket

**Files:**
- Modify:
  - `Shellforge/Sources/ShellforgeCore/Workspace/TaskDraft.swift`: AiTerm's `ticket`, `appendTicket`, `titleEdited`, `typeEdited` and `apply(ticket:)`; `setTitle` passes `ticket?.key`; `setBranch` sets `typeEdited`.
  - `Workspace.swift`: `JiraRef` and `TaskItem.jira: JiraRef?` (optional, decoded if present).
  - `TaskWorktrees.create(draft:…)` stamps `jira`.
  - `Agents/AgentCommand.swift`: `composePrompt(userText:ticket:appendTicket:)`, AiTerm's.
  - Callers: `SidebarModel.newTask` and `NewTaskModel.previewCommand` pass the draft's ticket and flag.
- Test (port): AiTerm's `TaskCreatorTests` ticket cases (`testDraftFollowsTicketUntilEdited`, `testTheBranchTypeFollowsTheTicketUntilPicked`, the ticket half of `testATypedPrefixMovesIntoTheType`, and `testCreateBuildsWorktreeAndTaskItem` with its ticket), into `TaskDraftTests`; AiTerm's `testComposePrompt` into `AgentCommandTests`; plus:

```swift
@Test func aTicketPromptOverTheLimitGoesThroughTheFile() throws {
    let worktree = try GitRepoFixture().path
    let ticket = JiraTicket(key: "WEB-1", summary: "Thing", description: String(repeating: "d", count: 1500),
                            issueType: "Task", status: nil, url: "https://x/browse/WEB-1")
    let prompt = AgentCommand.composePrompt(userText: "do it", ticket: ticket, appendTicket: true)
    let command = try AgentCommand.build(agent: AgentPresets.claude, model: "opus", reasoning: nil, prompt: prompt,
                                         worktreePath: worktree, launcher: launcher)
    #expect(command.hasSuffix("\"$(cat .shellforge/first-prompt.md)\""))
}
```

- [ ] Steps: port and write the tests (RED); implement; green; commit "A New Task draft follows its Jira ticket, and the first prompt can carry it, as AiTerm's".

### Task 3: Connecting Jira

**Files:**
- Create (port): `Shellforge/Sources/ShellforgeUI/Settings/JiraConnection.swift`, from `IntegrationSettingsModel.swift`:
  - `JiraFields`, `ServiceConnection<JiraFields>` as an `ObservableObject` (`runTest`, the 1 s retest after edits, `disconnect`, `canDisconnect`), and `ServiceTestRecord`.
  - A Jira-only `save()`/`load()` over `JiraSettings`, with undo of a failed save.
- Create (port): `Shellforge/Sources/ShellforgeUI/Settings/JiraCard.swift`, from `SettingsView.swift:179-189` and `ServiceCard` 276-295: the Site URL, Email and secure API token fields, "Save stores your token in Keychain.", the status line ("Testing…", "Connected as X" or the error), and Disconnect.
- Create: `Shellforge/Sources/ShellforgeUI/Settings/SettingsPanel.swift`.
  - `SheetLayout` titled "Settings", holding the Jira card then the Mac card.
  - Its footer is Cancel/Save, AiTerm's all-or-nothing save; the Mac card needs none.
  - It replaces `MacSettingsPanel`. The header's macbook button becomes a `gearshape` button "Settings…". The footer's right-click keeps its "Mac Settings…" words and opens this panel.
- Test (port): the Jira slice of AiTerm's `IntegrationSettingsModelTests` (every case that builds Jira fields or calls `testJira`; GitLab/GitHub cases are ledgered as not ported), into `Shellforge/Tests/ShellforgeUITests/JiraConnectionTests.swift`.

- [ ] Steps: port the tests (RED); port the model and card, and write the panel; green, plus `DesignRulesTests`; commit "Connect Jira in Settings, as AiTerm's Integrations card does".

### Task 4: The ticket field in New Task

**Files:**
- Create (port): `Shellforge/Sources/ShellforgeUI/NewTask/SearchPicker.swift` (AiTerm's whole file).
  - `.onChange(of: query) { index = 0 }` stays one-argument.
  - `.onChange(of: open, initial: true) { _, open in … }` → `.onAppear { react(open) }` + `.onChange(of: open) { react($0) }`.
- Modify: `NewTaskModel.swift`:
  - `@Published query`, `results` and `searchError`; `setQuery`, `reopenSearch`, `cancelSearch`, and `search(text:debounce:)` with AiTerm's 250 ms debounce and generations.
  - A `searchIssues` init closure.
  - `ticketPlaceholder` ("Search by key or title").
- Modify: `NewTaskSheet.swift`. The task step gains AiTerm's ticket `FormField` with `SearchPicker`, the help text or `searchError`, and `selectedTicket` with `LaneChip`.
  - The prompt step gains "Include Jira ticket details" when a ticket is picked.
  - `.task { await model.search(text: "") }`; `.onDisappear { model.cancelSearch() }`.
  - The pickers' open flag joins `closeList` (⎋ closes the list first).
- Modify: `SidebarModel.makeNewTaskModel` passes `searchIssues`, AiTerm's `jiraSearcher`.
  - It reads `JiraSettings` once, as the sheet opens.
  - With no config it throws `ActionUnavailable("Connect Jira in Settings, or continue without a ticket.")`.
  - An empty query calls `myOpenIssues(projects: [])`, any other `search(text:projects: [])`.
- Test (port): AiTerm's `TaskCreationModelTests` search cases (debounce, stale answer dropped, error clears the list, reopen), adapted to `NewTaskModel`, plus:

```swift
@MainActor @Test func withoutJiraTheFieldSaysHowAndCreateStillWorks() async {
    let sheet = model(searchIssues: { _ in throw ActionUnavailable("Connect Jira in Settings, or continue without a ticket.") })
    await sheet.search(text: "")
    #expect(sheet.searchError == "Connect Jira in Settings, or continue without a ticket.")
    sheet.draft.setTitle("Login")
    await sheet.loadCatalogue()
    #expect(await sheet.create())
}
```

- [ ] Steps: port and write the tests (RED); implement; green (whole package plus `DesignRulesTests`); commit "New Task's ticket field: the person's open Jira tickets, search by key or title, the ticket filling the task".

### Task 5: Verify

- [ ] Build the app. Expected: `** BUILD SUCCEEDED **`.
- [ ] The live check (connect Jira with the person's own token; pick a ticket in New Task; create the task) waits for the user.
