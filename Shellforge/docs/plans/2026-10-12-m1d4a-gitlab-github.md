# M1d-4a GitLab and GitHub Connections Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Settings › Services gains AiTerm's GitLab and GitHub cards next to Jira, saved together all-or-nothing as AiTerm saves them. The core gains AiTerm's GitLab and GitHub clients and the merge request they list. These are what M1d-4b's New Review searches.

**Architecture:**
- **ShellforgeCore:**
  - `GitLab/` and `GitHub/` hold the clients and settings, on the `HTTPJSON`, `Lenient` and `SecretStore` already ported with Jira.
  - `CodeHost.swift` holds `CodeHost` and `MergeRequest`.
- **ShellforgeUI:**
  - `JiraConnection.swift`'s `IntegrationSettingsModel` grows from one card to AiTerm's three, with its `PendingWrite` all-or-nothing save.
  - `SettingsPanel` shows the GitLab and GitHub cards.

**Tech Stack:** Swift 6 language mode, macOS 13, SwiftUI; Swift Testing via `Shellforge/scripts/swift.sh`.

**Spec:**
- **Shellforge PRD (Claude Doc 89fd80a8-5fcf-4423-a8d6-c62f8512a481), W7:** "MR/PR review … as in AiTerm".
- **The user:** "exactly what aiterm is".

## Global Constraints

- **Source:** AiTerm (`~/aiterm`, GPLv3, Laurens D'Hondt), pinned at `c1f851e574d0c8dd45a95957449c8798d60b65f4`.
  - Ported files start `// Ported from AiTerm (app/Sources/<path>.swift), GPLv3, Laurens D'Hondt.`.
  - Nothing in `~/aiterm` changes.
- **Tokens:** they live only in the Keychain (`gitlab.token`, `github.token`). They are never logged, never put in `UserDefaults`, never put in a URL, and never sent after a cross-origin redirect (`HTTPJSON` already strips `PRIVATE-TOKEN` and `Authorization`). The GitLab host URL goes in `UserDefaults` `gitlab.host`, as in AiTerm.
- **Tests:** no real network (`StubSession`; `SourceRulesTests.noTestDialsARealHost` holds), no real Keychain (`MemorySecretStore`), no `UserDefaults.standard` (`ScratchDefaults`).
- **Copy:** "Settings › Integrations" in AiTerm's copy becomes "Settings", as it did for Jira.
- **macOS 13:** no `@Observable`, no `Mutex`.
- **Commits** end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; stage by path; never push.

## Review Focus

1. **A GitLab host typed with a path, a trailing slash, `http://`, or a self-hosted instance with no API.** The card says why: AiTerm's `noAPI`, `unauthorized` or `network` copy. The token never leaves for another host.
   - Tests: Task 1 (ported `GitLabClientTests` `noAPI`, redirect, normalisation cases).
2. **A GitHub token that is fine-grained but lacks pull-request access (403), or a repository that is not found.** These give the `forbidden` and `repoNotFound` copy, not "Try again".
   - Test: Task 2 (ported `GitHubClientTests`).
3. **Saving three cards where the second's Keychain write is refused.** The first card's write is undone, nothing is half-saved, and the footer says which.
   - Tests: Task 3 (ported `aRefusedWritePutsBackTheEarlierWritesOfThisSave`, `anUndoTheKeychainRefusesIsSaid`).
4. **One invalid card among valid ones.** Nothing is written, and the invalid card's message shows.
   - Test: Task 3 (ported `aFailingLaterCardLeavesEarlierCredentialsUntouched`).
5. **A search typed as `!87`, `#87` or `87`.** It goes straight to that request, and an unknown number lists nothing rather than an error.
   - Tests: Tasks 1 and 2 (ported number fast-path cases).

---

### Task 1: GitLab, and the merge request

**Files:**
- Create (port), in `Shellforge/Sources/ShellforgeCore/`:
  - `CodeHost.swift` (`AiTermCore/CodeHost.swift` 1-39): `CodeHost`, `MergeRequest`.
  - `GitLab/GitLabClient.swift` (`AiTermCore/GitLab/GitLabClient.swift` 1-117).
  - `GitLab/GitLabSettings.swift` (1-19).
- Test (port): `Shellforge/Tests/ShellforgeCoreTests/GitLab/GitLabClientTests.swift` (all 12), `GitLabSettingsTests.swift` (2), `Shellforge/Tests/ShellforgeCoreTests/CodeHostTests.swift` (2).

**Interfaces:**
- Produces (as AiTerm):
  - `GitLabConfig(hostURL:token:)`, `GitLabError`.
  - `GitLabClient(config:session:)` with `testConnection() async throws -> String` and `mergeRequests(project: String, search: String) async throws -> [MergeRequest]`.
  - `GitLabSettings.load(store:defaults:) -> GitLabConfig?` and `save(_:store:defaults:) -> Bool`.
  - `CodeHost { gitLab, gitHub }` with `init(webURL:)` and `reference(_:)`.
  - `MergeRequest` with `iid`, `title`, `sourceBranch`, `targetBranch`, `author`, `state`, `draft`, `url`, `forkHead`, `lane`, `host`, `reference`.

Ported changes, each ledgered:
- `Keychain.shared` → `SecretStore` defaults, as `JiraSettings` does.
- `Log.network` → the `HTTPLog` shim.
- `Mutex` → `Locked`.

- [ ] **Step 1: Port the tests** (`@testable import ShellforgeCore`, `ShellforgeTestSupport`'s `StubSession`/`RedirectStub`, `MemorySecretStore`, `ScratchDefaults`). Run `--filter "GitLabClientTests|GitLabSettingsTests|CodeHostTests"`. Expected: the build fails.
- [ ] **Step 2: Port the three sources.**
- [ ] **Step 3: Run the filter.** Expected: 16 pass. Then the package, including `SourceRulesTests`. Expected: pass.
- [ ] **Step 4: Commit:** "GitLab's client and settings, and the merge request they list, as AiTerm's".

### Task 2: GitHub

**Files:**
- Create (port): `Shellforge/Sources/ShellforgeCore/GitHub/GitHubClient.swift` (`AiTermCore/GitHub/GitHubClient.swift` 1-104), `GitHub/GitHubSettings.swift` (1-14).
- Test (port): `Shellforge/Tests/ShellforgeCoreTests/GitHub/GitHubClientTests.swift` (all 13), `GitHubSettingsTests.swift` (2).

**Interfaces:**
- Consumes: Task 1's `MergeRequest`, `CodeHost`.
- Produces:
  - `GitHubConfig(token:)`, `GitHubError`.
  - `GitHubClient(config:session:)` with `testConnection()` and `pullRequests(repo: String, search: String) async throws -> [MergeRequest]`.
  - `GitHubSettings.load(store:) -> GitHubConfig?` and `save(_:store:) -> Bool`.

- [ ] **Step 1: Port the tests.** Run `--filter "GitHubClientTests|GitHubSettingsTests"`. Expected: the build fails.
- [ ] **Step 2: Port the two sources.**
- [ ] **Step 3: Run the filter.** Expected: 15 pass. Then the package. Expected: pass.
- [ ] **Step 4: Commit:** "GitHub's client and settings, as AiTerm's".

### Task 3: Three cards, saved all or nothing

**Files:**
- Modify: `Shellforge/Sources/ShellforgeUI/Settings/JiraConnection.swift`, porting from `AiTerm/IntegrationSettingsModel.swift`:
  - `GitLabFields` (40-51), `GitHubFields` (53-62);
  - `ServiceTestRecord`'s `gitLabFailed`/`gitHubFailed` (67-74);
  - `IntegrationSettingsModel` (152-276) whole: the three `ServiceConnection`s, `pending(...)` (202-239), `PendingWrite` and `save()` (247-275).

  Keep Shellforge's `ObservableObject` shape. The init gains `gitLab: GitLabConfig?`, `gitHub: GitHubConfig?`, `testGitLab:` and `testGitHub:` (defaults call the real clients). Rename the file to `IntegrationSettingsModel.swift` (`git mv`) now that it is no longer Jira's alone; its credit names `AiTerm/IntegrationSettingsModel.swift`.
- Create (port): `Shellforge/Sources/ShellforgeUI/Settings/CodeHostCards.swift`, the GitLab card (`AiTerm/Views/SettingsView.swift` 191-200) and the GitHub card (202-210) on the existing `ServiceCard`, each with "Save stores your token in Keychain." once a token is typed.
- Modify: `Shellforge/Sources/ShellforgeUI/Settings/SettingsPanel.swift`. Services shows Jira, GitLab, GitHub, in that order; the subtitle names all three as AiTerm's Integrations tab does.
- Modify: `Shellforge/Sources/ShellforgeUI/ShellforgeSidebar.swift` `showMacSettings`. It reads `GitLabSettings.load()` and `GitHubSettings.load()` with Jira's, through injectable closures on `SidebarModel` (`gitLabSettings`, `gitHubSettings`, as `jiraSettings`), so tests never read the real store.
- Test (port): `Shellforge/Tests/ShellforgeUITests/IntegrationSettingsModelTests.swift` (`git mv` from `JiraConnectionTests.swift`, keeping its 12). It adds AiTerm's multi-card and GitLab/GitHub cases:
  - 41, 55, 66;
  - `saveStoresEachTypedServiceBehindTheSecretStore` (82);
  - `openingTestsEachConfiguredServiceOnItsOwnCard` (116);
  - `aFailingLaterCardLeavesEarlierCredentialsUntouched` (217);
  - `fixingTheFailingCardLetsTheWholeSaveThrough` (235);
  - `aRefusedWritePutsBackTheEarlierWritesOfThisSave` (251);
  - `anEarlierNewConfigIsUndoneWhenALaterWriteIsRefused` (274);
  - `aReplacedConfigIsPutBackWhenALaterWriteIsRefused` (290);
  - `aFailedSaveLeavesTheTestRecordUntouched` (306);
  - `anUndoTheKeychainRefusesIsSaid` (326);
  - `aSavedServicesLastTestIsRemembered` (345).

  A store that refuses one key is a small `SecretStore` stand-in in the test file (port AiTerm's if it has one).

- [ ] **Step 1: Port the tests.** Run `--filter IntegrationSettingsModelTests`. Expected: the build fails.
- [ ] **Step 2: Port the model, the cards and the panel wiring.**
- [ ] **Step 3: Run the filter, then the package with `DesignRulesTests`.** Expected: pass.
- [ ] **Step 4: Commit:** "Settings connects GitLab and GitHub beside Jira, all three saved together or not at all, as AiTerm's Integrations do".

### Task 4: Verify in the app

- [ ] Build the app. Expected: `** BUILD SUCCEEDED **`.
- [ ] The live check waits for the user: open Settings, connect GitLab and/or GitHub with their own tokens, and see "Connected as …".
