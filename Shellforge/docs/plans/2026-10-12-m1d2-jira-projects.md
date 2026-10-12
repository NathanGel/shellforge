# M1d-2 Jira Projects per Project Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A project links the Jira projects its tickets live in, as in AiTerm:
- a "Jira Projects…" sheet edits the links;
- the project header wears one Jira badge;
- a task row wears its ticket's badge;
- New Task searches only the linked projects, and names them.

**Architecture:**
- **ShellforgeCore:**
  - `Project` gains `jiraProjects: [JiraProjectRef]`.
  - AiTerm's `JiraProjectSearch` ranks the account's projects for the sheet's field.
- **ShellforgeUI:**
  - `SidebarModel` links, loads, and passes the linked projects to New Task's searcher, reading the Jira connection through an injected closure.
  - AiTerm's `JiraProjectSheet`, `ProjectJiraBadge`/`ProjectJiraBadgeView` and the ticket part of `TaskRowBadges` are ported.
  - The project header gains a context menu: "New Task…", then "Jira Projects…".

**Tech Stack:** Swift 6 language mode, macOS 13, SwiftUI + AppKit, `ShellforgeDesign`; Swift Testing via `Shellforge/scripts/swift.sh`.

**Spec:**
- **Shellforge PRD (Claude Doc 89fd80a8-5fcf-4423-a8d6-c62f8512a481), W7:** Jira-backed New Task as in AiTerm.
- **W8:** the design system.
- **The user:** "visually and functionally it should be exactly what aiterm is".

## Global Constraints

- **Source:** AiTerm (`~/aiterm`, GPLv3, Laurens D'Hondt), pinned at `c1f851e574d0c8dd45a95957449c8798d60b65f4`.
  - Each ported file starts `// Ported from AiTerm (app/Sources/<path>.swift), GPLv3, Laurens D'Hondt.`; tests credit `app/Tests/<path>`.
  - Nothing in `~/aiterm` changes.
- **macOS 13:** no `@Observable`, no `Mutex` (use `Locked`), no `FrontToBackStack` (explicit `.zIndex`), no two-argument `onChange`.
- **Tests:**
  - They read no real home, keychain or `UserDefaults.standard`, and reach no network.
  - A hosted test waits with `try await Task.sleep`, never `RunLoop.main.run`. The latter starves the views' `.task`s; this was learned in M1d-1.
- **Jira tokens** live only in the Keychain: never logged, never in `UserDefaults`, never in a URL.
- **Design tokens:** every colour, size and type style comes from `ShellforgeDesign`; `DesignRulesTests` scans `ShellforgeUI`.
- **Commits** end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Stage paths by name; never `commit -a`. Nothing is pushed.

**Rulings carried in from Shellforge's world**, ledgered at Task 1:
- **No locked workspace:** Shellforge has none, so AiTerm's "greyed while the workspace is locked" is always enabled.
- **No Interface tab:** Shellforge has no Interface tab (`BadgeDetails`), so the project key and ticket key always show. `ProjectJiraBadge` keeps its `showsKey:` parameter for that tab.
- **No legacy key:** Shellforge never wrote AiTerm's single `jiraProject` key, so only `jiraProjects` is read and written.

## Review Focus

1. **The same Jira project picked twice**, or the list saved empty.
   - Each project is linked once, in the order picked.
   - An empty list unlinks all of them, and New Task searches every project again.
   - Test: Task 2 `linkingKeepsEachJiraProjectOnceAndAnEmptyListUnlinks`.
2. **A workspace file from before this milestone**, with no `jiraProjects` key.
   - It loads with none linked, and saves the key from then on.
   - Test: Task 1 `aProjectFromAnOlderWorkspaceLinksNoJiraProject`.
3. **Opening "Jira Projects…" with Jira not connected**, or with the connection failing.
   - The sheet says "Connect Jira in Settings to choose a Jira project.", or the error.
   - The already linked projects still show and can be unlinked; Save works.
   - Test: Task 3 `withoutJiraTheSheetSaysHowAndStillUnlinks`.
4. **Several linked projects.**
   - The header shows the first key, then a boxed `+n` whose menu lists every project, then "Jira Projects…".
   - The placeholder reads "Search SHOP and PAY by key or title".
   - The search is scoped to exactly those keys.
   - Tests: Task 4 ported badge cases; Task 2 `theTicketFieldNamesAndSearchesTheLinkedProjects`.
5. **The sheet's result list over the status line below it.**
   - The list draws over the help line, as the ticket list now does.
   - Test: Task 3 `theProjectListDrawsOverItsStatusLine`.

---

### Task 1: Linked Jira projects on a project, and the project search

**Files:**
- Modify: `Shellforge/Sources/ShellforgeCore/Workspace/Workspace.swift` (`Project`).
- Create (port): `Shellforge/Sources/ShellforgeCore/Jira/JiraProjectSearch.swift`, from `AiTermCore/Jira/JiraProjectSearch.swift`, verbatim apart from the credit line.
- Test (port): `Shellforge/Tests/ShellforgeCoreTests/Jira/JiraProjectSearchTests.swift`, all 7 of `AiTermCoreTests/JiraProjectSearchTests.swift`.
- Test: `Shellforge/Tests/ShellforgeCoreTests/Workspace/ProjectJiraTests.swift` (new). It ports `ModelsTests`'s `testProjectFromAnOlderStateFileDecodesWithoutAJiraProject` and `testLinkedJiraProjectsReadAsTheirKeysInOrder`, plus a round trip.

**Interfaces:**
- Produces:
  - `Project.jiraProjects: [JiraProjectRef]`, in linking order, default `[]`.
  - `Project.init(id:name:path:addedAt:collapsed:jiraProjects: [JiraProjectRef] = [])`.
  - `JiraProjectSearch.rank(_ projects: [JiraProjectRef], query: String, excluding linked: [JiraProjectRef] = []) -> [JiraProjectRef]`.

- [ ] **Step 1: Write the tests**

```swift
// ProjectJiraTests.swift
import Foundation
import Testing
@testable import ShellforgeCore

/// What a project links, as the workspace file keeps it.
@Suite struct ProjectJiraTests {
    static let site = URL(string: "https://example.atlassian.net")!
    static let shop = JiraProjectRef(id: "10001", key: "SHOP", name: "Storefront", siteURL: site)
    static let pay = JiraProjectRef(id: "10002", key: "PAY", name: "Payments", siteURL: site)

    @Test func aProjectFromAnOlderWorkspaceLinksNoJiraProject() throws {
        let json = #"{"id":"1EB4C0DE-0000-0000-0000-000000000001","name":"Repo","path":"/repo","addedAt":1,"collapsed":false}"#
        let project = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
        #expect(project.jiraProjects.isEmpty)
    }

    @Test func linkedJiraProjectsRoundTripInOrder() throws {
        let project = Project(name: "Repo", path: "/repo", jiraProjects: [Self.pay, Self.shop])
        let back = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        #expect(back.jiraProjects == [Self.pay, Self.shop])
    }

    @Test func linkedJiraProjectsReadAsTheirKeysInOrder() {
        #expect([Self.shop].keyList == "SHOP")
        #expect([Self.shop, Self.pay].keyList == "SHOP and PAY")
    }
}
```

- [ ] **Step 2: Run the tests.**
  - Run: `Shellforge/scripts/swift.sh test --package-path Shellforge --filter "ProjectJiraTests|JiraProjectSearchTests"`
  - Expected: the build fails (no `jiraProjects`, no `JiraProjectSearch`).
- [ ] **Step 3: Implement.**
  - In `Project`:
    - add `public var jiraProjects: [JiraProjectRef]` with its doc line ("The Jira projects whose tickets belong to this one, in the order they were linked. Empty: New Task searches every Jira project.").
    - add the init parameter.
    - add `jiraProjects` to `CodingKeys`.
    - decode it with `decodeIfPresent(...) ?? []`.
    - add an `encode(to:)` that writes all six keys. The synthesised one goes away once `init(from:)` is custom and `CodingKeys` names a new key; write it explicitly.
  - Port `JiraProjectSearch.swift`.
- [ ] **Step 4: Run the filter.** Expected: 10 pass. Then run the whole package; expected: pass. Projects built without the argument still compile.
- [ ] **Step 5: Commit** (paths by name): "A project keeps the Jira projects it links, and AiTerm's ranking of an account's projects".

### Task 2: Linking, and New Task scoped to the links

**Files:**
- Modify: `Shellforge/Sources/ShellforgeUI/SidebarModel.swift`.
  - New init parameter `jiraSettings: @escaping @Sendable () -> JiraConfig? = { JiraSettings.load() }`, kept as `private let jiraSettings`.
  - `makeNewTaskModel` passes `NewTaskModel.jiraSearcher(for: project, jira: jiraSettings())`. This closes M1d-1's deferred minor: tests read real settings.
  - `public func loadJiraProjects() async throws -> [JiraProjectRef]`, from AiTerm's `ProjectActions.loadJiraProjects`. It reads the settings through `BackgroundWork.run`. With none, it throws `ActionUnavailable("Connect Jira in Settings to choose a Jira project.")`; otherwise it returns `try await JiraClient(config:).projects()`.
  - `public func setJiraProjects(_ jiraProjects: [JiraProjectRef], on projectId: UUID)`. It stores `jiraProjects.linkedOnce` through `attempt { try document.update { … } }`, and does nothing when that equals what is stored.
- Modify: `Shellforge/Sources/ShellforgeUI/NewTask/NewTaskModel.swift`.
  - `ticketPlaceholder` is `project.jiraProjects.isEmpty ? "Search by key or title" : "Search \(project.jiraProjects.keyList) by key or title"`.
  - `jiraSearcher(jira:)` becomes `jiraSearcher(for project: Project, jira: JiraConfig?)`, passing `project.jiraProjects` to `myOpenIssues(projects:)` and `search(text:projects:)`.
- Modify: `Shellforge/Sources/ShellforgeUI/ShellforgeSidebar.swift` (`showMacSettings`): read through `model.jiraSettings` rather than `JiraSettings.load()`. Expose it as `let jiraSettings` (internal).
- Test: `Shellforge/Tests/ShellforgeUITests/NewTaskModelTests.swift`, `Shellforge/Tests/ShellforgeUITests/SidebarModelTests.swift`.

**Interfaces:**
- Consumes: Task 1's `Project.jiraProjects`.
- Produces:
  - `SidebarModel.init(..., jiraSettings: @escaping @Sendable () -> JiraConfig? = { JiraSettings.load() })`, placed after `catalogue`.
  - `SidebarModel.loadJiraProjects()`, `SidebarModel.setJiraProjects(_:on:)`, `SidebarModel.jiraSettings`.
  - `NewTaskModel.jiraSearcher(for:jira:)`.

- [ ] **Step 1: Write the tests**

In `NewTaskModelTests` (rename the uses of `jiraSearcher(jira:)` to `jiraSearcher(for: project, jira:)`):

```swift
/// AiTerm's theTicketFieldNamesTheLinkedJiraProjectsItSearches, and the search scoped to them.
@Test func theTicketFieldNamesAndSearchesTheLinkedProjects() async throws {
    let site = URL(string: "https://example.atlassian.net")!
    let linked = [JiraProjectRef(id: "1", key: "SHOP", name: "Storefront", siteURL: site),
                  JiraProjectRef(id: "2", key: "PAY", name: "Payments", siteURL: site)]
    func placeholder(_ jira: [JiraProjectRef]) -> String {
        model(project: Project(name: "Repo", path: "/tmp/repo", jiraProjects: jira)).ticketPlaceholder
    }
    #expect(placeholder(linked) == "Search SHOP and PAY by key or title")
    #expect(placeholder([linked[1]]) == "Search PAY by key or title")
    #expect(placeholder([]) == "Search by key or title")

    // The query names exactly the linked keys.
    let stub = StubSession { _ in (200, Data(#"{"issues":[]}"#.utf8)) }
    let config = JiraConfig(siteURL: site, email: "me@example.com", token: "t")
    _ = try await JiraClient(config: config, session: stub.session).myOpenIssues(projects: linked)
    let body = try #require(stub.lastRequest?.httpBody).utf8String
    #expect(body.contains(#"project in (\"SHOP\", \"PAY\")"#))
}
```

The existing `model(...)` factory gains a `project:` parameter, defaulting to today's project.

The second half pins the client's scoping, which `jiraSearcher(for:)` hands the linked list to. That handing-over is one line, and the review reads it.

In `SidebarModelTests`:

```swift
/// AiTerm's setJiraProjects: a project is linked once, in order; an empty list unlinks; it is saved.
@Test func linkingKeepsEachJiraProjectOnceAndAnEmptyListUnlinks() async throws {
    let repo = try GitRepoForUI()
    let document = WorkspaceDocument(store: WorkspaceStore(folder: folder))
    let sidebar = SidebarModel(host: FakeTerminalHost(), document: document, launcher: repo.launcher, jiraSettings: { nil })
    await sidebar.addProject(folder: repo.path)
    let id = try #require(document.workspace.projects.first?.id)
    let site = URL(string: "https://example.atlassian.net")!
    let shop = JiraProjectRef(id: "10001", key: "SHOP", name: "Storefront", siteURL: site)
    let pay = JiraProjectRef(id: "10002", key: "PAY", name: "Payments", siteURL: site)

    sidebar.setJiraProjects([shop, pay, shop], on: id)
    #expect(document.workspace.projects[0].jiraProjects == [shop, pay])
    #expect(try WorkspaceStore(folder: folder).load().projects[0].jiraProjects == [shop, pay])

    sidebar.setJiraProjects([], on: id)
    #expect(document.workspace.projects[0].jiraProjects.isEmpty)
}

@Test func withoutJiraTheProjectListSaysHow() async throws {
    let repo = try GitRepoForUI()
    let sidebar = SidebarModel(host: FakeTerminalHost(), document: WorkspaceDocument(store: WorkspaceStore(folder: folder)),
                               launcher: repo.launcher, jiraSettings: { nil })
    await #expect { _ = try await sidebar.loadJiraProjects() } throws: {
        ($0 as? ActionUnavailable)?.message == "Connect Jira in Settings to choose a Jira project."
    }
}
```

Every existing `SidebarModel(` in the UI tests passes `jiraSettings: { nil }`, so no test reads the real settings. Adapt the factory at `SidebarModelTests.swift:77` and the direct calls. Use whatever `WorkspaceStore` load call the store has (`load()` or the existing test's equivalent); read it before writing the test.

- [ ] **Step 2: Run** `--filter "NewTaskModelTests|SidebarModelTests"`. Expected: the build fails.
- [ ] **Step 3: Implement as listed.**
- [ ] **Step 4: Run the filter, then the whole package.** Expected: pass.
- [ ] **Step 5: Commit:** "A project links its Jira projects, and New Task searches only those, naming them, as AiTerm does".

### Task 3: The Jira Projects sheet

**Files:**
- Create (port): `Shellforge/Sources/ShellforgeUI/Jira/JiraProjectSheet.swift`, from `AiTerm/Views/JiraProjectSheet.swift`. Changes, each ledgered:
  - `@Environment(\.dismiss)` → `let dismiss: @MainActor () -> Void`; `dismiss.afterThisEvent()` → `Task { @MainActor in dismiss() }`, as `NewTaskSheet` does.
  - `canSubmit` stays and the sidebar passes `true` (no lock).
  - `.zIndex(1)` on the `SearchPicker` inside the `FormField`, so the list draws over `status`.
  - `seeded(projects:open:)` is kept under `#if DEBUG`.
- Modify: `Shellforge/Sources/ShellforgeUI/ShellforgeSidebar.swift`: `showJiraProjects(for: UUID)` presents it in the sidebar's `PanelSlot`:
  - `linked:` the project's current `jiraProjects`;
  - `loadProjects: model.loadJiraProjects`;
  - `submit: { model.setJiraProjects($0, on: id) }`.
- Test (port): `Shellforge/Tests/ShellforgeUITests/JiraProjectSheetTests.swift`, AiTerm's 5 cases on the same harness. `settle(host)` becomes `try await Task.sleep(for: .milliseconds(100))`; the tests become `async`.
- Test: two new cases in the same file.

```swift
/// AiTerm's error branch, held to Review Focus 3: no connection still lets the person unlink.
@Test func withoutJiraTheSheetSaysHowAndStillUnlinks() async throws {
    let h = try await harness(linked: [Self.projects[0]], load: { throw ActionUnavailable("Connect Jira in Settings to choose a Jira project.") })
    #expect(text(in: h.host).contains("Connect Jira in Settings to choose a Jira project."))
    try clickClear("Unlink PLT", in: h.host)
    pressCommandReturn(h)
    #expect(h.submissions.calls == [[]])
}

/// The project list hangs over the status line under its field, as the ticket list does.
@Test func theProjectListDrawsOverItsStatusLine() async throws {
    // As TicketListTests.theTicketListDrawsOverItsHelpText: projects seeded with blank names and
    // zero-width keys, the list open, the status line's row sampled across the list against its far end.
}
```

The harness gains a `load:` parameter, defaulting to `{ Self.projects }`. Here `.task` does run, because the waits sleep. `text(in:)` and `clickClear` are written beside the harness:
- `text(in:)` gathers every `NSTextField`'s `stringValue` and the accessibility labels of SwiftUI text.
- `clickClear` finds the clear button by its tooltip (`toolTip`) and sends it `performClick`.
- When hosted SwiftUI text isn't reachable that way, read `HelpText`'s copy through the sheet's `status` instead: extract `static func statusLine(loading:error:projects:linked:) -> (String, HelpText.Tone)?` and test that. Ledger the choice.

The layering test copies `TicketListTests.theTicketListDrawsOverItsHelpText`'s sampling verbatim. It seeds `JiraProjectRef(id: "\($0)", key: String(repeating: "\u{200B}", count: $0), name: "", siteURL: site)` ×6 with `open: true`.

- [ ] **Step 1: Port and write the tests.** Run `--filter JiraProjectSheetTests`. Expected: the build fails.
- [ ] **Step 2: Port the sheet; add `showJiraProjects`.**
- [ ] **Step 3: Run the filter.** Expected: 7 pass. Then `DesignRulesTests`; expected: pass.
- [ ] **Step 4: Commit:** "Jira Projects…: link a project's Jira projects by searching the account's, as AiTerm does".

### Task 4: The header's Jira badge, its context menu, and a task's ticket badge

**Files:**
- Create (port): `Shellforge/Sources/ShellforgeUI/Sidebar/JiraBadges.swift`:
  - `ProjectJiraBadge` (with `Overflow` and `MenuItem`) and `ProjectJiraBadgeView`, from `AiTerm/Views/SidebarRows.swift:539-625`.
  - `TaskTicketBadge`: the ticket half of `TaskRowBadges` (`SidebarRows.swift:722-742`), as `struct TaskTicketBadge: Equatable { var label: String?; var help: String; var url: String? }` with `init?(jira: JiraRef?, showsKey: Bool = true)`.
  - Opening a link is `NSWorkspace.shared.open(url)`, where AiTerm calls `ExternalApps.open(link:)`.
  - `ProjectJiraBadgeView` takes `canChangeWorkspace: Bool`, and the header passes `true`.
- Modify: `Shellforge/Sources/ShellforgeUI/Sidebar/SidebarRows.swift`:
  - `ProjectHeaderRow` gains `editJiraProjects: () -> Void`.
  - The name sits in an `HStack(spacing: scale(Space.gap))` with the badge after it, as AiTerm's does.
  - `.contextMenu { Button("New Task…", action: newTask); Divider(); Button("Jira Projects…", action: editJiraProjects) }`.
  - `TaskRowView`'s badge line puts the ticket `Badge(…, icon: .brand(Palette.jira), help:, style: .quiet, action:)` before the branch.
- Modify: `ShellforgeSidebar.swift`: pass `editJiraProjects: { showJiraProjects(for: node.id) }`.
- Test (port): `Shellforge/Tests/ShellforgeUITests/ProjectJiraBadgeTests.swift`, all 5 of AiTerm's, with `Project(name:path:jiraProjects:)`.
- Test (port): in the same file, the three ticket cases of `BadgeDetailsTests` (lines 36, 71, 76):
  - a ticket with a URL;
  - a ticket without one;
  - no ticket.

- [ ] **Step 1: Port the tests.** Run `--filter ProjectJiraBadgeTests`. Expected: the build fails.
- [ ] **Step 2: Port and wire.**
- [ ] **Step 3: Run the filter.** Expected: 8 pass. Then the whole package, including `DesignRulesTests` and `SidebarRowGeometryTests`; expected: pass.
- [ ] **Step 4: Commit:** "The project header wears its Jira badge and offers Jira Projects…, and a task row its ticket, as AiTerm's do".

### Task 5: Verify in the app

- [ ] Check that `Shellforge/Sources/ShellforgeDesign/README.md` still matches the code: its project-header badge paragraph (lines 263-270) and the `Badge` row. Correct any line that names something Shellforge lacks, such as "greyed while the workspace is locked", to say what Shellforge does.
- [ ] Build the app (`xcodebuild -project iTerm2.xcodeproj -scheme iTerm2 -configuration Development -skipPackagePluginValidation CODE_SIGN_IDENTITY=- build`). Expected: `** BUILD SUCCEEDED **`.
- [ ] The live check waits for the user:
  1. Link two Jira projects via right-click › Jira Projects….
  2. See SHOP +1 on the header.
  3. Open New Task, and see only those projects' tickets.
