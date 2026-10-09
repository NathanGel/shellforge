# M1a Workspace Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The sidebar shows a real, saved projects → tasks → tabs tree. Selecting a task shows only that task's tabs in the same window, with iTerm2's tab bar hidden. A project can be added from a folder, and a plain task (no agent, no Jira) can be created as a git worktree and branch, opening a tab in it.

**Architecture:** Everything that can be pure lives in the Shellforge package and is tested with swiftly: the workspace model and its file, tab tags, the tree, worktree creation (through `CommandLauncher`, so git hooks find `uv`), and the sidebar's view model, which talks to the terminal only through a `TerminalHost` protocol. The iTerm2 side implements `TerminalHost` for one `PseudoTerminal` in the existing bridge file `sources/TerminalView/iTermShellforgeSidebar.swift`. Every tab stays in the window; the sidebar decides which one is selected, and the tab bar is hidden, so only the selected task's tab is ever shown.

**Tech Stack:** Swift 6 package (`Shellforge/`, swift-tools 6.0, macOS 13), Swift Testing, SwiftUI with `ObservableObject` (macOS 13 has no `@Observable`), iTerm2 3.7.4 Objective-C and Swift (`iTerm2SharedARC`), Xcode 27, XCTest for `ModernTests`.

**Spec:** Shellforge PRD, https://claude.ai/code/artifact/89fd80a8-5fcf-4423-a8d6-c62f8512a481 — sections "Requirements: the integrated workspace" (W1–W5, W8, W9), "Requirements: every command finds its tools" (E3), and "Architecture". Research notes: `Shellforge/docs/upstream-hook-points.md`.

## Global Constraints

- The Shellforge package targets macOS 13 (`platforms: [.macOS(.v13)]`) and swift-tools 6.0; test it with `Shellforge/scripts/swift.sh test`, never bare `swift`.
- Every child process goes through `CommandLauncher` (`SourceRulesTests` enforces it). git is started as `launcher.run("git", ["-C", path, …])`.
- Shellforge files under `~/Library/Application Support/Shellforge/`: the workspace is `workspace.json`, its previous save `workspace.json.backup`.
- Session tags are iTerm2 user variables `user.shellforge_task` and `user.shellforge_project`, holding lowercase UUID strings. Every tab carries its own tag; nothing is inherited from the window.
- Worktrees go in `<project>/.worktrees/<slug>`; `.worktrees/` is added to the repository's `info/exclude`, never to a tracked `.gitignore`.
- iTerm2's files change only at the hook points listed in `Shellforge/docs/upstream-hook-points.md`; update that list in the same commit as any new one.
- The sidebar keeps `ShellforgeSidebar.width` (240 pt). M1a uses system colours; AiTerm's design system arrives in M1b.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Nothing is pushed without asking.

## Review Focus

1. **A project folder that is not a git repository**, or a subfolder of one: adding it is refused with git's own reason, never saved half-way. (Task 4 test.)
2. **Two tasks with the same title**: the second gets `-2` on its slug and branch instead of failing on "branch already exists". (Task 3 test.)
3. **A damaged `workspace.json`** (truncated by a crash): the app starts from the backup, and keeps the damaged file aside, rather than starting empty and overwriting it. (Task 1 test.)
4. **Switching tabs with iTerm2's own shortcuts** (Cmd-Shift-], Cmd-1…9) lands on another task's tab: the sidebar follows and selects that task, so the window never shows a tab the sidebar doesn't. (Task 5 test.)
5. **The last tab of a task is closed**: the task stays in the sidebar with no tabs, and selecting it opens a fresh tab in its worktree. (Task 5 test.)

---

## File Structure

| Path | Responsibility |
| --- | --- |
| `Shellforge/Sources/ShellforgeCore/Workspace/Workspace.swift` | `Project`, `TaskItem`, `Workspace` value types and their invariants |
| `Shellforge/Sources/ShellforgeCore/Workspace/WorkspaceStore.swift` | Load and save `workspace.json` with a backup and damaged-file recovery |
| `Shellforge/Sources/ShellforgeCore/Workspace/TabSnapshot.swift` | `TabSnapshot` (one live tab) and `ShellforgeTags` |
| `Shellforge/Sources/ShellforgeCore/Workspace/SidebarTree.swift` | Pure projection: workspace + tabs → project/task/tab nodes |
| `Shellforge/Sources/ShellforgeCore/Workspace/TaskWorktrees.swift` | Slugs, branch names, `git worktree add` through `CommandLauncher` |
| `Shellforge/Sources/ShellforgeCore/Workspace/ProjectFolders.swift` | Validate a folder as a git repository and make a `Project` |
| `Shellforge/Sources/ShellforgeUI/SidebarModel.swift` | `TerminalHost` protocol and the `@MainActor` view model |
| `Shellforge/Sources/ShellforgeUI/ShellforgeSidebar.swift` (modify) | The SwiftUI tree, replacing the M0 placeholder |
| `Shellforge/Tests/ShellforgeCoreTests/Workspace/*` | Tests for the Core files above, with `GitRepoFixture` |
| `Shellforge/Tests/ShellforgeUITests/SidebarModelTests.swift` | View-model tests against `FakeTerminalHost` |
| `sources/TerminalView/iTermShellforgeSidebar.swift` (modify) | `iTermShellforgeHost`, the `TerminalHost` for one `PseudoTerminal`; profile for a task tab |
| `sources/TerminalView/iTermRootTerminalView.m` (modify) | Pass the window controller to the sidebar; hide the tab bar |
| `iTerm2.xcodeproj/project.pbxproj` (modify) | Link `ShellforgeCore` into `iTermSwiftPackages` |
| `ModernTests/ShellforgeHostTest.swift` (new) | Tests for the task-tab profile |
| `Shellforge/docs/upstream-hook-points.md` (modify) | New hook points |

---

### Task 1: Workspace model and its file

**Files:**
- Create: `Shellforge/Sources/ShellforgeCore/Workspace/Workspace.swift`
- Create: `Shellforge/Sources/ShellforgeCore/Workspace/WorkspaceStore.swift`
- Test: `Shellforge/Tests/ShellforgeCoreTests/Workspace/WorkspaceStoreTests.swift`

**Interfaces:**
- Produces:
  - `struct Project: Codable, Equatable, Sendable, Identifiable { var id: UUID; var name: String; var path: String; var addedAt: Date }`
  - `struct TaskItem: Codable, Equatable, Sendable, Identifiable { var id: UUID; var projectId: UUID; var title: String; var branch: String; var worktreePath: String; var baseBranch: String; var createdAt: Date }`
  - `struct Workspace: Codable, Equatable, Sendable { var version: Int = 1; var projects: [Project] = []; var tasks: [TaskItem] = [] }` with `func tasks(in projectId: UUID) -> [TaskItem]`
  - `struct WorkspaceStore: Sendable { init(folder: URL = WorkspaceStore.defaultFolder); static var defaultFolder: URL; func load() throws -> WorkspaceStore.Loaded; func save(_ workspace: Workspace) throws }`
  - `struct WorkspaceStore.Loaded: Equatable { var workspace: Workspace; var recoveredFrom: String? }` — `recoveredFrom` names the damaged file kept aside, when there was one.
  - `enum WorkspaceStore.Refusal: Error, Equatable { case duplicateId(UUID); case taskWithoutProject(UUID) }`

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import ShellforgeCore

@Suite struct WorkspaceStoreTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shellforge-ws-\(UUID().uuidString)")
    private var store: WorkspaceStore { WorkspaceStore(folder: folder) }

    private func sample() -> Workspace {
        let project = Project(id: UUID(), name: "aiterm", path: "/Users/me/aiterm", addedAt: Date(timeIntervalSince1970: 1_000))
        let task = TaskItem(id: UUID(), projectId: project.id, title: "Fix login", branch: "fix-login",
                            worktreePath: "/Users/me/aiterm/.worktrees/fix-login", baseBranch: "main",
                            createdAt: Date(timeIntervalSince1970: 2_000))
        return Workspace(projects: [project], tasks: [task])
    }

    @Test func withNoFileTheWorkspaceIsEmpty() throws {
        #expect(try store.load() == .init(workspace: Workspace(), recoveredFrom: nil))
    }

    @Test func whatIsSavedLoadsBack() throws {
        try store.save(sample())
        #expect(try store.load().workspace == sample())
    }

    @Test func savingKeepsThePreviousSaveAsTheBackup() throws {
        let first = sample()
        try store.save(first)
        var second = first
        second.projects[0].name = "renamed"
        try store.save(second)
        let backup = try Data(contentsOf: folder.appendingPathComponent("workspace.json.backup"))
        #expect(try JSONDecoder.workspace.decode(Workspace.self, from: backup) == first)
    }

    @Test func aDamagedFileIsKeptAsideAndTheBackupLoads() throws {
        let saved = sample()
        try store.save(saved)
        try store.save(saved)   // the backup now holds `saved` too
        try "{ truncated".write(to: folder.appendingPathComponent("workspace.json"), atomically: true, encoding: .utf8)
        let loaded = try store.load()
        #expect(loaded.workspace == saved)
        let kept = try #require(loaded.recoveredFrom)
        #expect(kept.hasPrefix("workspace.json.damaged-"))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(kept).path))
    }

    @Test func aTaskWhoseProjectIsMissingIsRefused() throws {
        var broken = sample()
        broken.projects = []
        #expect(throws: WorkspaceStore.Refusal.taskWithoutProject(broken.tasks[0].id)) { try store.save(broken) }
    }

    @Test func aRepeatedIdIsRefused() throws {
        var twice = sample()
        twice.projects.append(twice.projects[0])
        #expect(throws: WorkspaceStore.Refusal.duplicateId(twice.projects[0].id)) { try store.save(twice) }
    }
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `cd Shellforge && scripts/swift.sh test --filter WorkspaceStoreTests`
Expected: build fails with `cannot find 'WorkspaceStore' in scope`.

- [ ] **Step 3: Write the model**

`Shellforge/Sources/ShellforgeCore/Workspace/Workspace.swift`:

```swift
import Foundation

/// A git repository the sidebar lists, with its tasks under it.
public struct Project: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// The repository's top-level folder.
    public var path: String
    public var addedAt: Date

    public init(id: UUID = UUID(), name: String, path: String, addedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.path = path
        self.addedAt = addedAt
    }
}

/// A piece of work in its own git worktree and branch. Its tabs are found live by their
/// `user.shellforge_task` tag, never stored here.
public struct TaskItem: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var projectId: UUID
    public var title: String
    public var branch: String
    public var worktreePath: String
    /// The branch the task's branch was made from.
    public var baseBranch: String
    public var createdAt: Date

    public init(id: UUID = UUID(), projectId: UUID, title: String, branch: String, worktreePath: String,
                baseBranch: String, createdAt: Date = Date()) {
        self.id = id
        self.projectId = projectId
        self.title = title
        self.branch = branch
        self.worktreePath = worktreePath
        self.baseBranch = baseBranch
        self.createdAt = createdAt
    }
}

/// Everything the sidebar saves: projects in sidebar order, and their tasks.
public struct Workspace: Codable, Equatable, Sendable {
    /// Bumped when the file's shape changes in a way old code cannot read.
    public var version: Int = 1
    public var projects: [Project] = []
    public var tasks: [TaskItem] = []

    public init(projects: [Project] = [], tasks: [TaskItem] = []) {
        self.projects = projects
        self.tasks = tasks
    }

    /// The project's tasks, oldest first.
    public func tasks(in projectId: UUID) -> [TaskItem] {
        tasks.filter { $0.projectId == projectId }.sorted { $0.createdAt < $1.createdAt }
    }
}

extension JSONEncoder {
    static var workspace: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var workspace: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
```

- [ ] **Step 4: Write the store**

`Shellforge/Sources/ShellforgeCore/Workspace/WorkspaceStore.swift`:

```swift
import Foundation

/// `workspace.json` in Shellforge's Application Support folder. Each save first copies the
/// previous file to `workspace.json.backup`; a file that no longer decodes is kept aside as
/// `workspace.json.damaged-<uuid>` and the backup is loaded instead, so a crash mid-write
/// never costs the user their projects.
public struct WorkspaceStore: Sendable {
    public let folder: URL

    public init(folder: URL = WorkspaceStore.defaultFolder) {
        self.folder = folder
    }

    public static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shellforge", isDirectory: true)
    }

    public struct Loaded: Equatable, Sendable {
        public var workspace: Workspace
        /// The damaged file kept aside, when the backup had to be loaded.
        public var recoveredFrom: String?
    }

    public enum Refusal: Error, Equatable {
        case duplicateId(UUID)
        case taskWithoutProject(UUID)
    }

    private var file: URL { folder.appendingPathComponent("workspace.json") }
    private var backup: URL { folder.appendingPathComponent("workspace.json.backup") }

    public func load() throws -> Loaded {
        guard let data = try? Data(contentsOf: file) else { return Loaded(workspace: Workspace(), recoveredFrom: nil) }
        if let workspace = try? JSONDecoder.workspace.decode(Workspace.self, from: data) {
            return Loaded(workspace: workspace, recoveredFrom: nil)
        }
        let kept = "workspace.json.damaged-\(UUID().uuidString)"
        try FileManager.default.moveItem(at: file, to: folder.appendingPathComponent(kept))
        let fromBackup = (try? Data(contentsOf: backup)).flatMap { try? JSONDecoder.workspace.decode(Workspace.self, from: $0) }
        return Loaded(workspace: fromBackup ?? Workspace(), recoveredFrom: kept)
    }

    public func save(_ workspace: Workspace) throws {
        try check(workspace)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: file.path) {
            _ = try? FileManager.default.removeItem(at: backup)
            try FileManager.default.copyItem(at: file, to: backup)
        }
        try JSONEncoder.workspace.encode(workspace).write(to: file, options: .atomic)
    }

    private func check(_ workspace: Workspace) throws {
        var seen = Set<UUID>()
        for id in workspace.projects.map(\.id) + workspace.tasks.map(\.id) where !seen.insert(id).inserted {
            throw Refusal.duplicateId(id)
        }
        let projects = Set(workspace.projects.map(\.id))
        if let orphan = workspace.tasks.first(where: { !projects.contains($0.projectId) }) {
            throw Refusal.taskWithoutProject(orphan.id)
        }
    }
}
```

- [ ] **Step 5: Run the tests to see them pass**

Run: `cd Shellforge && scripts/swift.sh test --filter WorkspaceStoreTests`
Expected: `Test run with 6 tests in 1 suite passed`.

- [ ] **Step 6: Run the whole package and commit**

Run: `cd Shellforge && scripts/swift.sh test` — expected: every suite passes.

```bash
git add Shellforge/Sources/ShellforgeCore/Workspace Shellforge/Tests/ShellforgeCoreTests/Workspace
git commit -m "feat(workspace): projects and tasks saved with a backup

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Tab tags and the sidebar tree

**Files:**
- Create: `Shellforge/Sources/ShellforgeCore/Workspace/TabSnapshot.swift`
- Create: `Shellforge/Sources/ShellforgeCore/Workspace/SidebarTree.swift`
- Test: `Shellforge/Tests/ShellforgeCoreTests/Workspace/SidebarTreeTests.swift`

**Interfaces:**
- Consumes: `Workspace`, `Project`, `TaskItem` (Task 1).
- Produces:
  - `enum ShellforgeTags { static let task = "user.shellforge_task"; static let project = "user.shellforge_project" }`
  - `struct TabSnapshot: Equatable, Sendable, Identifiable { var id: String /* the session's guid */; var tabId: Int; var title: String; var taskId: UUID?; var projectId: UUID? }`
  - `struct SidebarTree: Equatable, Sendable { var projects: [ProjectNode]; var otherTabs: [TabSnapshot]; static func build(_ workspace: Workspace, tabs: [TabSnapshot]) -> SidebarTree; func task(owning tab: TabSnapshot) -> TaskItem? }`
  - `struct ProjectNode: Equatable, Sendable, Identifiable { var project: Project; var tasks: [TaskNode]; var id: UUID { project.id } }`
  - `struct TaskNode: Equatable, Sendable, Identifiable { var task: TaskItem; var tabs: [TabSnapshot]; var id: UUID { task.id } }`

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import ShellforgeCore

@Suite struct SidebarTreeTests {
    private let project = Project(name: "aiterm", path: "/r/aiterm")
    private var login: TaskItem { TaskItem(projectId: project.id, title: "Fix login", branch: "fix-login",
                                           worktreePath: "/r/aiterm/.worktrees/fix-login", baseBranch: "main",
                                           createdAt: Date(timeIntervalSince1970: 1)) }
    private var docs: TaskItem { TaskItem(projectId: project.id, title: "Docs", branch: "docs",
                                          worktreePath: "/r/aiterm/.worktrees/docs", baseBranch: "main",
                                          createdAt: Date(timeIntervalSince1970: 2)) }

    private func tab(_ id: String, _ tabId: Int, task: UUID?) -> TabSnapshot {
        TabSnapshot(id: id, tabId: tabId, title: id, taskId: task, projectId: task == nil ? nil : project.id)
    }

    @Test func eachTabSitsUnderTheTaskItsOwnTagNames() {
        let (a, b) = (login, docs)
        let tree = SidebarTree.build(Workspace(projects: [project], tasks: [a, b]),
                                     tabs: [tab("s1", 1, task: a.id), tab("s2", 2, task: b.id), tab("s3", 3, task: a.id)])
        #expect(tree.projects.count == 1)
        #expect(tree.projects[0].tasks.map(\.task.id) == [a.id, b.id])
        #expect(tree.projects[0].tasks[0].tabs.map(\.id) == ["s1", "s3"])
        #expect(tree.projects[0].tasks[1].tabs.map(\.id) == ["s2"])
    }

    @Test func aTaskWithNoOpenTabStaysListed() {
        let tree = SidebarTree.build(Workspace(projects: [project], tasks: [login]), tabs: [])
        #expect(tree.projects[0].tasks.map(\.tabs) == [[]])
    }

    @Test func untaggedTabsAndTabsOfUnknownTasksGoUnderOtherTabs() {
        let stray = tab("s9", 9, task: UUID())
        let plain = tab("s0", 0, task: nil)
        let tree = SidebarTree.build(Workspace(projects: [project], tasks: [login]), tabs: [plain, stray])
        #expect(tree.otherTabs.map(\.id) == ["s0", "s9"])
    }

    @Test func tabsKeepTheirOrderInTheWindow() {
        let a = login
        let tree = SidebarTree.build(Workspace(projects: [project], tasks: [a]),
                                     tabs: [tab("late", 7, task: a.id), tab("early", 2, task: a.id)])
        #expect(tree.projects[0].tasks[0].tabs.map(\.id) == ["early", "late"])
    }

    @Test func aTabFindsTheTaskThatOwnsIt() {
        let a = login
        let owned = tab("s1", 1, task: a.id)
        let tree = SidebarTree.build(Workspace(projects: [project], tasks: [a]), tabs: [owned])
        #expect(tree.task(owning: owned) == a)
        #expect(tree.task(owning: tab("s2", 2, task: nil)) == nil)
    }
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `cd Shellforge && scripts/swift.sh test --filter SidebarTreeTests`
Expected: build fails with `cannot find 'SidebarTree' in scope`.

- [ ] **Step 3: Write the tags and the snapshot**

`Shellforge/Sources/ShellforgeCore/Workspace/TabSnapshot.swift`:

```swift
import Foundation

/// The iTerm2 user variables that tie a session to its task. Every tab carries its own: in one
/// shared window, nothing can be inherited from the window as AiTerm did.
public enum ShellforgeTags {
    public static let task = "user.shellforge_task"
    public static let project = "user.shellforge_project"
}

/// One live tab, as the sidebar needs it. Built by the terminal host from iTerm2's sessions.
public struct TabSnapshot: Equatable, Sendable, Identifiable {
    /// The tab's active session's guid.
    public var id: String
    /// iTerm2's unique tab id; also the tab's order in the window.
    public var tabId: Int
    public var title: String
    public var taskId: UUID?
    public var projectId: UUID?

    public init(id: String, tabId: Int, title: String, taskId: UUID?, projectId: UUID?) {
        self.id = id
        self.tabId = tabId
        self.title = title
        self.taskId = taskId
        self.projectId = projectId
    }
}
```

- [ ] **Step 4: Write the tree**

`Shellforge/Sources/ShellforgeCore/Workspace/SidebarTree.swift`:

```swift
import Foundation

public struct TaskNode: Equatable, Sendable, Identifiable {
    public var task: TaskItem
    /// Its open tabs in window order; empty when none is open.
    public var tabs: [TabSnapshot]
    public var id: UUID { task.id }
}

public struct ProjectNode: Equatable, Sendable, Identifiable {
    public var project: Project
    public var tasks: [TaskNode]
    public var id: UUID { project.id }
}

/// What the sidebar draws: projects in saved order, each with its tasks oldest first and each
/// task's tabs in window order; tabs that belong to no known task come last, under "Other tabs".
public struct SidebarTree: Equatable, Sendable {
    public var projects: [ProjectNode]
    public var otherTabs: [TabSnapshot]

    public static func build(_ workspace: Workspace, tabs: [TabSnapshot]) -> SidebarTree {
        let ordered = tabs.sorted { $0.tabId < $1.tabId }
        let known = Set(workspace.tasks.map(\.id))
        let projects = workspace.projects.map { project in
            ProjectNode(project: project, tasks: workspace.tasks(in: project.id).map { task in
                TaskNode(task: task, tabs: ordered.filter { $0.taskId == task.id })
            })
        }
        let other = ordered.filter { $0.taskId.map { !known.contains($0) } ?? true }
        return SidebarTree(projects: projects, otherTabs: other)
    }

    /// The task whose tag `tab` carries, if it is one of the workspace's.
    public func task(owning tab: TabSnapshot) -> TaskItem? {
        projects.lazy.flatMap(\.tasks).first { $0.task.id == tab.taskId }?.task
    }
}
```

- [ ] **Step 5: Run the tests to see them pass**

Run: `cd Shellforge && scripts/swift.sh test --filter SidebarTreeTests`
Expected: `Test run with 5 tests in 1 suite passed`.

- [ ] **Step 6: Commit**

```bash
git add Shellforge/Sources/ShellforgeCore/Workspace Shellforge/Tests/ShellforgeCoreTests/Workspace
git commit -m "feat(workspace): tabs grouped under their task by their own tag

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Task worktrees

**Files:**
- Create: `Shellforge/Sources/ShellforgeCore/Workspace/TaskWorktrees.swift`
- Create: `Shellforge/Tests/ShellforgeCoreTests/Workspace/GitRepoFixture.swift`
- Test: `Shellforge/Tests/ShellforgeCoreTests/Workspace/TaskWorktreesTests.swift`

**Interfaces:**
- Consumes: `CommandLauncher` (`run(_:_:directory:extra:timeout:) throws -> ChildOutput`), `Project`, `TaskItem`.
- Produces:
  - `enum TaskWorktrees { static func slug(for title: String) -> String; static func create(title: String, in project: Project, base: String?, launcher: CommandLauncher) throws -> TaskItem }`
  - `struct GitFailure: Error, CustomStringConvertible, Equatable { var command: String; var message: String }`
  - Test-only `struct GitRepoFixture { let path: String; let launcher: CommandLauncher; init(branch: String = "main") throws; func git(_ args: String...) throws -> String }`

- [ ] **Step 1: Write the fixture**

`Shellforge/Tests/ShellforgeCoreTests/Workspace/GitRepoFixture.swift`:

```swift
import Foundation
@testable import ShellforgeCore

/// A fresh repository with one commit on `branch`, and a launcher whose environment is a
/// hermetic git: no user config, a fixed identity.
struct GitRepoFixture {
    let path: String
    let launcher: CommandLauncher

    init(branch: String = "main") throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shellforge-repo-\(UUID().uuidString)").path
        path = "\(root)/repo"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let env = ["PATH": "/usr/bin:/bin", "HOME": root, "GIT_CONFIG_NOSYSTEM": "1",
                   "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"]
        launcher = CommandLauncher { ResolvedEnvironment(variables: env, source: .loginShell("/bin/sh")) }
        _ = try git("init", "-q", "-b", branch)
        _ = try git("commit", "-q", "--allow-empty", "-m", "first")
    }

    @discardableResult
    func git(_ args: String...) throws -> String {
        let out = try launcher.run("git", ["-C", path] + args)
        guard out.status == 0 else { throw GitFailure(command: "git " + args.joined(separator: " "), message: out.stderr) }
        return out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

- [ ] **Step 2: Write the failing tests**

`Shellforge/Tests/ShellforgeCoreTests/Workspace/TaskWorktreesTests.swift`:

```swift
import Foundation
import Testing
@testable import ShellforgeCore

@Suite struct TaskWorktreesTests {
    @Test(arguments: [("Fix login", "fix-login"), ("  Café: tests & docs!! ", "cafe-tests-docs"), ("PROJ-12 Add API", "proj-12-add-api")])
    func aTitleBecomesASlug(title: String, slug: String) {
        #expect(TaskWorktrees.slug(for: title) == slug)
    }

    @Test func anEmptyTitleStillGivesASlug() {
        #expect(TaskWorktrees.slug(for: "!!!") == "task")
    }

    @Test func aTaskGetsItsOwnWorktreeAndBranchFromTheBase() throws {
        let repo = try GitRepoFixture()
        let project = Project(name: "repo", path: repo.path)
        let task = try TaskWorktrees.create(title: "Fix login", in: project, base: "main", launcher: repo.launcher)
        #expect(task.branch == "fix-login" && task.baseBranch == "main" && task.projectId == project.id)
        #expect(task.worktreePath == "\(repo.path)/.worktrees/fix-login")
        #expect(try repo.git("-C", task.worktreePath, "rev-parse", "--abbrev-ref", "HEAD") == "fix-login")
    }

    @Test func theWorktreesFolderIsExcludedNotGitignored() throws {
        let repo = try GitRepoFixture()
        _ = try TaskWorktrees.create(title: "One", in: Project(name: "repo", path: repo.path), base: "main", launcher: repo.launcher)
        let exclude = try String(contentsOfFile: "\(repo.path)/.git/info/exclude", encoding: .utf8)
        #expect(exclude.components(separatedBy: "\n").contains(".worktrees/"))
        #expect(!FileManager.default.fileExists(atPath: "\(repo.path)/.gitignore"))
        #expect(try repo.git("status", "--porcelain") == "")
    }

    @Test func aSecondTaskWithTheSameTitleGetsANumberedSlug() throws {
        let repo = try GitRepoFixture()
        let project = Project(name: "repo", path: repo.path)
        _ = try TaskWorktrees.create(title: "Fix login", in: project, base: "main", launcher: repo.launcher)
        let second = try TaskWorktrees.create(title: "Fix login", in: project, base: "main", launcher: repo.launcher)
        #expect(second.branch == "fix-login-2")
        #expect(second.worktreePath.hasSuffix("/.worktrees/fix-login-2"))
    }

    @Test func withoutABaseTheCurrentBranchIsUsed() throws {
        let repo = try GitRepoFixture(branch: "trunk")
        let task = try TaskWorktrees.create(title: "X", in: Project(name: "repo", path: repo.path), base: nil, launcher: repo.launcher)
        #expect(task.baseBranch == "trunk")
    }

    @Test func gitsOwnReasonIsReportedWhenItFails() throws {
        let repo = try GitRepoFixture()
        let error = try #require(throws: GitFailure.self) {
            try TaskWorktrees.create(title: "X", in: Project(name: "repo", path: repo.path), base: "no-such-branch", launcher: repo.launcher)
        }
        #expect(error.message.contains("no-such-branch"))
    }
}
```

- [ ] **Step 3: Run the tests to see them fail**

Run: `cd Shellforge && scripts/swift.sh test --filter TaskWorktreesTests`
Expected: build fails with `cannot find 'TaskWorktrees' in scope`.

- [ ] **Step 4: Write the implementation**

`Shellforge/Sources/ShellforgeCore/Workspace/TaskWorktrees.swift`:

```swift
import Foundation

/// A git command that exited non-zero, with git's own words.
public struct GitFailure: Error, CustomStringConvertible, Equatable {
    public var command: String
    public var message: String
    public var description: String { "\(command) failed: \(message.trimmingCharacters(in: .whitespacesAndNewlines))" }
}

/// Makes a task's checkout: `<project>/.worktrees/<slug>` on a new branch `<slug>` from the base.
/// git runs through `CommandLauncher`, so the repository's hooks see the login shell's `PATH`.
public enum TaskWorktrees {
    /// Lowercase ASCII letters and digits, runs of anything else as one `-`; "task" when nothing is left.
    public static func slug(for title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var slug = "", dash = false
        for scalar in folded.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                if dash, !slug.isEmpty { slug.append("-") }
                slug.unicodeScalars.append(scalar)
                dash = false
            } else {
                dash = true
            }
        }
        return slug.isEmpty ? "task" : slug.lowercased()
    }

    public static func create(title: String, in project: Project, base: String?, launcher: CommandLauncher) throws -> TaskItem {
        func git(_ args: [String]) throws -> String {
            let out = try launcher.run("git", ["-C", project.path] + args)
            guard out.status == 0 else { throw GitFailure(command: "git " + args.joined(separator: " "), message: out.stderr) }
            return out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let base = try base ?? git(["rev-parse", "--abbrev-ref", "HEAD"])
        let root = "\(project.path)/.worktrees"
        let stem = slug(for: title)
        var name = stem, n = 1
        while FileManager.default.fileExists(atPath: "\(root)/\(name)")
                || (try? git(["rev-parse", "--verify", "--quiet", "refs/heads/\(name)"])) != nil {
            n += 1
            name = "\(stem)-\(n)"
        }
        try exclude(".worktrees/", gitDir: git(["rev-parse", "--git-common-dir"]), project: project)
        _ = try git(["worktree", "add", "-q", "-b", name, "\(root)/\(name)", base])
        return TaskItem(projectId: project.id, title: title, branch: name, worktreePath: "\(root)/\(name)", baseBranch: base)
    }

    /// Adds `pattern` to the repository's `info/exclude` once, so the worktrees never show as untracked.
    private static func exclude(_ pattern: String, gitDir: String, project: Project) throws {
        let dir = gitDir.hasPrefix("/") ? gitDir : "\(project.path)/\(gitDir)"
        let file = "\(dir)/info/exclude"
        try FileManager.default.createDirectory(atPath: "\(dir)/info", withIntermediateDirectories: true)
        let current = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        guard !current.components(separatedBy: "\n").contains(pattern) else { return }
        let joiner = current.isEmpty || current.hasSuffix("\n") ? "" : "\n"
        try (current + joiner + pattern + "\n").write(toFile: file, atomically: true, encoding: .utf8)
    }
}
```

- [ ] **Step 5: Run the tests to see them pass**

Run: `cd Shellforge && scripts/swift.sh test --filter TaskWorktreesTests`
Expected: `Test run with 7 tests in 1 suite passed` (the slug test runs its 3 arguments as cases of one test).

- [ ] **Step 6: Commit**

```bash
git add Shellforge/Sources/ShellforgeCore/Workspace Shellforge/Tests/ShellforgeCoreTests/Workspace
git commit -m "feat(workspace): a task's own worktree and branch, through CommandLauncher

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Adding a project from a folder

**Files:**
- Create: `Shellforge/Sources/ShellforgeCore/Workspace/ProjectFolders.swift`
- Test: `Shellforge/Tests/ShellforgeCoreTests/Workspace/ProjectFoldersTests.swift`

**Interfaces:**
- Consumes: `GitFailure`, `GitRepoFixture` (Task 3), `Workspace`, `CommandLauncher`.
- Produces: `enum ProjectFolders { static func project(at folder: String, in workspace: Workspace, launcher: CommandLauncher) throws -> Project }` and `enum ProjectFolders.Refusal: Error, Equatable { case notARepository(String); case alreadyAdded(String) }`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import ShellforgeCore

@Suite struct ProjectFoldersTests {
    @Test func aRepositoryBecomesAProjectNamedAfterItsFolder() throws {
        let repo = try GitRepoFixture()
        let project = try ProjectFolders.project(at: repo.path, in: Workspace(), launcher: repo.launcher)
        #expect(project.name == "repo")
        #expect(project.path == URL(fileURLWithPath: repo.path).resolvingSymlinksInPath().path)
    }

    @Test func aSubfolderBecomesItsRepository() throws {
        let repo = try GitRepoFixture()
        try FileManager.default.createDirectory(atPath: "\(repo.path)/src/app", withIntermediateDirectories: true)
        let project = try ProjectFolders.project(at: "\(repo.path)/src/app", in: Workspace(), launcher: repo.launcher)
        #expect(project.path == URL(fileURLWithPath: repo.path).resolvingSymlinksInPath().path)
    }

    @Test func aFolderOutsideGitIsRefused() throws {
        let repo = try GitRepoFixture()
        let plain = FileManager.default.temporaryDirectory.appendingPathComponent("plain-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        let refusal = try #require(throws: ProjectFolders.Refusal.self) {
            try ProjectFolders.project(at: plain, in: Workspace(), launcher: repo.launcher)
        }
        guard case .notARepository(let reason) = refusal else { Issue.record("wrong refusal"); return }
        #expect(reason.contains("not a git repository"))
    }

    @Test func aRepositoryAlreadyInTheWorkspaceIsRefused() throws {
        let repo = try GitRepoFixture()
        let first = try ProjectFolders.project(at: repo.path, in: Workspace(), launcher: repo.launcher)
        #expect(throws: ProjectFolders.Refusal.alreadyAdded(first.path)) {
            try ProjectFolders.project(at: repo.path, in: Workspace(projects: [first]), launcher: repo.launcher)
        }
    }
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `cd Shellforge && scripts/swift.sh test --filter ProjectFoldersTests`
Expected: build fails with `cannot find 'ProjectFolders' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Turns a folder the user picked into a project: the repository it is in, named after its folder.
public enum ProjectFolders {
    public enum Refusal: Error, Equatable {
        /// git's own reason the folder is not in a repository.
        case notARepository(String)
        /// The repository is already a project, at this path.
        case alreadyAdded(String)
    }

    public static func project(at folder: String, in workspace: Workspace, launcher: CommandLauncher) throws -> Project {
        let out = try launcher.run("git", ["-C", folder, "rev-parse", "--show-toplevel"])
        guard out.status == 0 else { throw Refusal.notARepository(out.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let top = URL(fileURLWithPath: out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath().path
        if workspace.projects.contains(where: { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == top }) {
            throw Refusal.alreadyAdded(top)
        }
        return Project(name: URL(fileURLWithPath: top).lastPathComponent, path: top)
    }
}
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `cd Shellforge && scripts/swift.sh test --filter ProjectFoldersTests`
Expected: `Test run with 4 tests in 1 suite passed`.

- [ ] **Step 5: Commit**

```bash
git add Shellforge/Sources/ShellforgeCore/Workspace/ProjectFolders.swift Shellforge/Tests/ShellforgeCoreTests/Workspace/ProjectFoldersTests.swift
git commit -m "feat(workspace): add a project from any folder in its repository

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: The sidebar's view model

**Files:**
- Modify: `Shellforge/Package.swift` (ShellforgeUI depends on ShellforgeCore)
- Create: `Shellforge/Sources/ShellforgeUI/SidebarModel.swift`
- Test: `Shellforge/Tests/ShellforgeUITests/SidebarModelTests.swift`

**Interfaces:**
- Consumes: `Workspace`, `WorkspaceStore`, `SidebarTree`, `TabSnapshot`, `TaskWorktrees`, `ProjectFolders`, `CommandLauncher`.
- Produces:
  - `@MainActor protocol TerminalHost: AnyObject { var tabs: [TabSnapshot] { get }; var selectedTabId: String? { get }; var onChange: (@MainActor () -> Void)? { get set }; func select(tab id: String); func openTab(in directory: String, taskId: UUID, projectId: UUID, title: String) }`
  - `@MainActor final class SidebarModel: ObservableObject` with `@Published private(set) var tree: SidebarTree`, `@Published private(set) var selectedTaskId: UUID?`, `@Published var lastError: String?`, `init(host: TerminalHost, store: WorkspaceStore, launcher: CommandLauncher)`, `func addProject(folder: String)`, `func newTask(title: String, in projectId: UUID)`, `func select(task id: UUID)`, `func select(tab id: String)`.

- [ ] **Step 1: Make ShellforgeUI depend on ShellforgeCore**

In `Shellforge/Package.swift` replace `.target(name: "ShellforgeUI", path: "Sources/ShellforgeUI"),` with:

```swift
        .target(name: "ShellforgeUI", dependencies: ["ShellforgeCore"], path: "Sources/ShellforgeUI"),
```

and the UI test target with `.testTarget(name: "ShellforgeUITests", dependencies: ["ShellforgeUI", "ShellforgeCore"], path: "Tests/ShellforgeUITests"),`.

- [ ] **Step 2: Write the failing tests**

```swift
import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI

/// Stands in for one iTerm2 window: a list of tabs, the selected one, and the calls made.
@MainActor final class FakeTerminalHost: TerminalHost {
    var tabs: [TabSnapshot] = []
    var selectedTabId: String?
    var onChange: (@MainActor () -> Void)?
    var opened: [(directory: String, taskId: UUID, projectId: UUID, title: String)] = []

    func select(tab id: String) {
        selectedTabId = id
        onChange?()
    }

    func openTab(in directory: String, taskId: UUID, projectId: UUID, title: String) {
        opened.append((directory, taskId, projectId, title))
        let tab = TabSnapshot(id: "s\(tabs.count + 1)", tabId: tabs.count + 1, title: title, taskId: taskId, projectId: projectId)
        tabs.append(tab)
        selectedTabId = tab.id
        onChange?()
    }

    /// iTerm2 switching tabs on its own, as Cmd-Shift-] does.
    func userSwitched(to id: String) {
        selectedTabId = id
        onChange?()
    }

    func close(_ id: String) {
        tabs.removeAll { $0.id == id }
        selectedTabId = tabs.first?.id
        onChange?()
    }
}

@MainActor @Suite struct SidebarModelTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shellforge-model-\(UUID().uuidString)")

    private func model(_ host: FakeTerminalHost, repo: GitRepoForUI) -> SidebarModel {
        SidebarModel(host: host, store: WorkspaceStore(folder: folder), launcher: repo.launcher)
    }

    @Test func addingAProjectListsItAndSavesIt() throws {
        let repo = try GitRepoForUI()
        let host = FakeTerminalHost()
        let sidebar = model(host, repo: repo)
        sidebar.addProject(folder: repo.path)
        #expect(sidebar.tree.projects.map(\.project.name) == ["repo"])
        #expect(try WorkspaceStore(folder: folder).load().workspace.projects.count == 1)
    }

    @Test func aNewTaskGetsAWorktreeAndATabTaggedWithIt() throws {
        let repo = try GitRepoForUI()
        let host = FakeTerminalHost()
        let sidebar = model(host, repo: repo)
        sidebar.addProject(folder: repo.path)
        let project = try #require(sidebar.tree.projects.first).project
        sidebar.newTask(title: "Fix login", in: project.id)
        let task = try #require(sidebar.tree.projects.first?.tasks.first).task
        #expect(host.opened.map(\.directory) == [task.worktreePath])
        #expect(host.opened.first?.taskId == task.id)
        #expect(sidebar.selectedTaskId == task.id)
        #expect(sidebar.tree.projects[0].tasks[0].tabs.count == 1)
    }

    @Test func selectingATaskSelectsItsFirstTab() throws {
        let (sidebar, host, first, _) = try twoTasks()
        sidebar.select(task: first)
        #expect(host.selectedTabId == sidebar.tree.projects[0].tasks.first { $0.id == first }?.tabs.first?.id)
        #expect(sidebar.selectedTaskId == first)
    }

    @Test func whenITerm2SwitchesTabsTheSidebarFollows() throws {
        let (sidebar, host, first, second) = try twoTasks()
        sidebar.select(task: first)
        let otherTab = try #require(sidebar.tree.projects[0].tasks.first { $0.id == second }?.tabs.first)
        host.userSwitched(to: otherTab.id)
        #expect(sidebar.selectedTaskId == second)
    }

    @Test func aTaskWhoseLastTabClosedStaysAndReopensOnSelect() throws {
        let (sidebar, host, first, _) = try twoTasks()
        let tab = try #require(sidebar.tree.projects[0].tasks.first { $0.id == first }?.tabs.first)
        host.close(tab.id)
        #expect(sidebar.tree.projects[0].tasks.first { $0.id == first }?.tabs == [])
        sidebar.select(task: first)
        #expect(host.opened.last?.taskId == first)
        #expect(sidebar.selectedTaskId == first)
    }

    @Test func aFailureIsShownNotThrown() throws {
        let repo = try GitRepoForUI()
        let sidebar = model(FakeTerminalHost(), repo: repo)
        sidebar.addProject(folder: "/")
        #expect(sidebar.lastError?.contains("not a git repository") == true)
        #expect(sidebar.tree.projects.isEmpty)
    }

    private func twoTasks() throws -> (SidebarModel, FakeTerminalHost, UUID, UUID) {
        let repo = try GitRepoForUI()
        let host = FakeTerminalHost()
        let sidebar = model(host, repo: repo)
        sidebar.addProject(folder: repo.path)
        let project = try #require(sidebar.tree.projects.first).project
        sidebar.newTask(title: "One", in: project.id)
        sidebar.newTask(title: "Two", in: project.id)
        let ids = sidebar.tree.projects[0].tasks.map(\.id)
        return (sidebar, host, ids[0], ids[1])
    }
}

/// `GitRepoFixture` lives in the Core tests, which this target cannot import; a copy for UI tests.
struct GitRepoForUI {
    let path: String
    let launcher: CommandLauncher

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shellforge-uirepo-\(UUID().uuidString)").path
        path = "\(root)/repo"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let env = ["PATH": "/usr/bin:/bin", "HOME": root, "GIT_CONFIG_NOSYSTEM": "1",
                   "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"]
        launcher = CommandLauncher { ResolvedEnvironment(variables: env, source: .loginShell("/bin/sh")) }
        for args in [["init", "-q", "-b", "main"], ["commit", "-q", "--allow-empty", "-m", "first"]] {
            let out = try launcher.run("git", ["-C", path] + args)
            guard out.status == 0 else { throw GitFailure(command: "git", message: out.stderr) }
        }
    }
}
```

- [ ] **Step 3: Run the tests to see them fail**

Run: `cd Shellforge && scripts/swift.sh test --filter SidebarModelTests`
Expected: build fails with `cannot find type 'TerminalHost' in scope`.

- [ ] **Step 4: Write the view model**

`Shellforge/Sources/ShellforgeUI/SidebarModel.swift`:

```swift
import Combine
import Foundation
import ShellforgeCore

/// One terminal window, as the sidebar sees it. iTerm2 implements it in-process
/// (`iTermShellforgeHost`); the tests use a fake.
@MainActor
public protocol TerminalHost: AnyObject {
    var tabs: [TabSnapshot] { get }
    var selectedTabId: String? { get }
    /// Called whenever a tab opens, closes, is renamed or is selected — by the sidebar or by iTerm2.
    var onChange: (@MainActor () -> Void)? { get set }
    func select(tab id: String)
    /// Opens a tab in `directory`, running the login shell, tagged with the task and project, and selects it.
    func openTab(in directory: String, taskId: UUID, projectId: UUID, title: String)
}

/// The sidebar's state for one window: the saved workspace, the window's tabs, and which task is
/// shown. Every change to the workspace is saved at once.
@MainActor
public final class SidebarModel: ObservableObject {
    @Published public private(set) var tree = SidebarTree(projects: [], otherTabs: [])
    @Published public private(set) var selectedTaskId: UUID?
    /// The last action's failure, in words the user can act on; cleared by the next success.
    @Published public var lastError: String?

    private let host: TerminalHost
    private let store: WorkspaceStore
    private let launcher: CommandLauncher
    private var workspace: Workspace

    public init(host: TerminalHost, store: WorkspaceStore, launcher: CommandLauncher) {
        self.host = host
        self.store = store
        self.launcher = launcher
        let loaded = try? store.load()
        workspace = loaded?.workspace ?? Workspace()
        if let kept = loaded?.recoveredFrom {
            lastError = "Your workspace file was damaged; it was kept as \(kept) and the last good copy loaded."
        }
        host.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    public func addProject(folder: String) {
        attempt {
            workspace.projects.append(try ProjectFolders.project(at: folder, in: workspace, launcher: launcher))
            try store.save(workspace)
        }
        refresh()
    }

    public func newTask(title: String, in projectId: UUID) {
        guard let project = workspace.projects.first(where: { $0.id == projectId }) else { return }
        attempt {
            let task = try TaskWorktrees.create(title: title, in: project, base: nil, launcher: launcher)
            workspace.tasks.append(task)
            try store.save(workspace)
            selectedTaskId = task.id
            host.openTab(in: task.worktreePath, taskId: task.id, projectId: project.id, title: task.title)
        }
        refresh()
    }

    /// Shows the task: its first open tab, or a new one in its worktree when none is open.
    public func select(task id: UUID) {
        guard let node = tree.projects.lazy.flatMap(\.tasks).first(where: { $0.id == id }) else { return }
        selectedTaskId = id
        if let tab = node.tabs.first {
            host.select(tab: tab.id)
        } else {
            host.openTab(in: node.task.worktreePath, taskId: id, projectId: node.task.projectId, title: node.task.title)
        }
    }

    public func select(tab id: String) {
        host.select(tab: id)
    }

    private func refresh() {
        tree = SidebarTree.build(workspace, tabs: host.tabs)
        // Follow iTerm2: whatever tab is selected decides the task shown.
        if let selected = host.tabs.first(where: { $0.id == host.selectedTabId }), let task = tree.task(owning: selected) {
            selectedTaskId = task.id
        }
    }

    private func attempt(_ action: () throws -> Void) {
        do {
            try action()
            lastError = nil
        } catch let refusal as ProjectFolders.Refusal {
            switch refusal {
            case .notARepository(let reason): lastError = reason
            case .alreadyAdded(let path): lastError = "\(path) is already in the sidebar."
            }
        } catch {
            lastError = String(describing: error)
        }
    }
}
```

- [ ] **Step 5: Run the tests to see them pass**

Run: `cd Shellforge && scripts/swift.sh test --filter SidebarModelTests`
Expected: `Test run with 6 tests in 1 suite passed`.

- [ ] **Step 6: Run the whole package and commit**

Run: `cd Shellforge && scripts/swift.sh test` — expected: every suite passes.

```bash
git add Shellforge/Package.swift Shellforge/Sources/ShellforgeUI/SidebarModel.swift Shellforge/Tests/ShellforgeUITests/SidebarModelTests.swift
git commit -m "feat(sidebar): a view model over the workspace and one window's tabs

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: The sidebar's tree view

**Files:**
- Modify: `Shellforge/Sources/ShellforgeUI/ShellforgeSidebar.swift`
- Test: `Shellforge/Tests/ShellforgeUITests/SidebarTests.swift`

**Interfaces:**
- Consumes: `SidebarModel` (Task 5).
- Produces: `ShellforgeSidebar.makeView(model: SidebarModel, chooseFolder: @escaping @MainActor () -> String?) -> NSView` (replaces the M0 `makeView()`; `width` is unchanged).

- [ ] **Step 1: Update the tests for the new signature**

Replace the body of `SidebarTests` with:

```swift
import AppKit
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI

@MainActor @Suite struct SidebarTests {
    private func sidebarModel() throws -> SidebarModel {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shellforge-view-\(UUID().uuidString)")
        return SidebarModel(host: FakeTerminalHost(), store: WorkspaceStore(folder: folder), launcher: try GitRepoForUI().launcher)
    }

    @Test func theHostViewIsAsWideAsTheSidebar() throws {
        #expect(ShellforgeSidebar.makeView(model: try sidebarModel(), chooseFolder: { nil }).frame.width == ShellforgeSidebar.width)
    }

    @Test func theSidebarStretchesWithTheWindowsHeightOnly() throws {
        #expect(ShellforgeSidebar.makeView(model: try sidebarModel(), chooseFolder: { nil }).autoresizingMask == [.height])
    }
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `cd Shellforge && scripts/swift.sh test --filter SidebarTests`
Expected: build fails with `extra arguments at positions #1, #2 in call`.

- [ ] **Step 3: Write the view**

Replace `Shellforge/Sources/ShellforgeUI/ShellforgeSidebar.swift` with:

```swift
import AppKit
import ShellforgeCore
import SwiftUI

/// The sidebar on the left of a Shellforge window: projects → tasks → tabs.
@MainActor
public enum ShellforgeSidebar {
    /// Its width in points. The window's layout gives the session area what is left.
    public static let width: CGFloat = 240

    /// The view the window places at its left edge: as wide as the sidebar, and only its height
    /// follows the window's. `chooseFolder` asks the user for a project folder (an open panel).
    public static func makeView(model: SidebarModel, chooseFolder: @escaping @MainActor () -> String?) -> NSView {
        let host = NSHostingView(rootView: SidebarView(model: model, chooseFolder: chooseFolder))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        host.autoresizingMask = [.height]
        return host
    }
}

struct SidebarView: View {
    @ObservedObject var model: SidebarModel
    let chooseFolder: @MainActor () -> String?
    @State private var newTaskProject: UUID?
    @State private var newTaskTitle = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if model.tree.projects.isEmpty {
                Text("No projects yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(16)
            }
            List {
                ForEach(model.tree.projects) { node in
                    Section {
                        ForEach(node.tasks) { task in taskRow(task) }
                        if newTaskProject == node.id { newTaskField(node.project) }
                    } header: {
                        projectHeader(node.project)
                    }
                }
                if !model.tree.otherTabs.isEmpty {
                    Section("Other tabs") {
                        ForEach(model.tree.otherTabs) { tab in tabRow(tab) }
                    }
                }
            }
            .listStyle(.sidebar)
            if let error = model.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(12)
            }
        }
        .frame(width: ShellforgeSidebar.width, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack {
            Text("Shellforge").font(.headline)
            Spacer()
            Button {
                if let folder = chooseFolder() { model.addProject(folder: folder) }
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("Add a project folder")
        }
        .padding(16)
    }

    private func projectHeader(_ project: Project) -> some View {
        HStack {
            Text(project.name)
            Spacer()
            Button {
                newTaskProject = project.id
                newTaskTitle = ""
            } label: {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.borderless)
            .help("New task in \(project.name)")
        }
    }

    private func newTaskField(_ project: Project) -> some View {
        TextField("Task title", text: $newTaskTitle)
            .onSubmit {
                let title = newTaskTitle.trimmingCharacters(in: .whitespaces)
                newTaskProject = nil
                if !title.isEmpty { model.newTask(title: title, in: project.id) }
            }
            .onExitCommand { newTaskProject = nil }
    }

    private func taskRow(_ node: TaskNode) -> some View {
        DisclosureGroup(isExpanded: .constant(model.selectedTaskId == node.id)) {
            ForEach(node.tabs) { tab in tabRow(tab) }
        } label: {
            HStack {
                Text(node.task.title)
                    .fontWeight(model.selectedTaskId == node.id ? .semibold : .regular)
                Spacer()
                Text(node.task.branch).font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { model.select(task: node.id) }
        }
    }

    private func tabRow(_ tab: TabSnapshot) -> some View {
        Text(tab.title)
            .font(.callout)
            .lineLimit(1)
            .contentShape(Rectangle())
            .onTapGesture { model.select(tab: tab.id) }
    }
}
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `cd Shellforge && scripts/swift.sh test`
Expected: every suite passes, including `SidebarTests` (2) and `SidebarModelTests` (6).

- [ ] **Step 5: Commit**

```bash
git add Shellforge/Sources/ShellforgeUI/ShellforgeSidebar.swift Shellforge/Tests/ShellforgeUITests/SidebarTests.swift
git commit -m "feat(sidebar): the projects, tasks and tabs tree

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: The iTerm2 terminal host, and the tab bar hidden

**Files:**
- Modify: `iTerm2.xcodeproj/project.pbxproj` (link `ShellforgeCore` into `iTermSwiftPackages`)
- Modify: `sources/TerminalView/iTermShellforgeSidebar.swift`
- Modify: `sources/TerminalView/iTermRootTerminalView.m`
- Test: `ModernTests/ShellforgeHostTest.swift`
- Modify: `Shellforge/docs/upstream-hook-points.md`

**Interfaces:**
- Consumes: `TerminalHost`, `SidebarModel`, `ShellforgeSidebar.makeView(model:chooseFolder:)`, `ShellforgeTags`, `TabSnapshot`, `WorkspaceStore`, `CommandLauncher`.
- Produces: `@objc(iTermShellforgeSidebar) class iTermShellforgeSidebar { @objc static var width: CGFloat; @objc static func makeView(for windowController: PseudoTerminal) -> NSView; static func taskTabProfile(base: [AnyHashable: Any], directory: String) -> [AnyHashable: Any] }` and `final class iTermShellforgeHost: TerminalHost`.

- [ ] **Step 1: Link ShellforgeCore into the project**

From the worktree root, run this script once (it mirrors how `ShellforgeUI` was linked in M0; every anchor must occur exactly once):

```bash
/usr/bin/python3 -I - iTerm2.xcodeproj/project.pbxproj <<'EOF'
import sys, secrets
path = sys.argv[1]
t = open(path).read()
def new_id():
    while True:
        i = secrets.token_hex(12).upper()
        if i not in t: return i
BF, DEP = new_id(), new_id()
def after(anchor, text):
    global t
    assert t.count(anchor) == 1, anchor
    t = t.replace(anchor, anchor + text)
def before(anchor, text):
    global t
    assert t.count(anchor) == 1, anchor
    t = t.replace(anchor, text + anchor)
before("/* End PBXBuildFile section */",
       f"\t\t{BF} /* ShellforgeCore in Frameworks */ = {{isa = PBXBuildFile; productRef = {DEP} /* ShellforgeCore */; }};\n")
after("\t\t\t\tA6C7C96D2E172F3E00AA7668 /* WebExtensionsFramework in Frameworks */,\n", f"\t\t\t\t{BF} /* ShellforgeCore in Frameworks */,\n")
after("\t\t\t\tA6C7C96C2E172F3E00AA7668 /* WebExtensionsFramework */,\n", f"\t\t\t\t{DEP} /* ShellforgeCore */,\n")
before("/* End XCSwiftPackageProductDependency section */",
       f"\t\t{DEP} /* ShellforgeCore */ = {{\n\t\t\tisa = XCSwiftPackageProductDependency;\n\t\t\tproductName = ShellforgeCore;\n\t\t}};\n")
open(path, "w").write(t)
EOF
plutil -lint iTerm2.xcodeproj/project.pbxproj
```

Expected: `iTerm2.xcodeproj/project.pbxproj: OK`.

- [ ] **Step 2: Write the failing test for the task tab's profile**

`ModernTests/ShellforgeHostTest.swift`:

```swift
//
//  ShellforgeHostTest.swift
//  Shellforge
//
//  A task's tab runs the user's login shell in the task's worktree, whatever the default
//  profile says about its command or directory.
//

import XCTest
@testable import iTerm2SharedARC

final class ShellforgeHostTest: XCTestCase {
    func testATaskTabRunsTheLoginShellInTheWorktree() {
        let base: [AnyHashable: Any] = [KEY_CUSTOM_COMMAND: "Yes", KEY_COMMAND_LINE: "/usr/bin/top",
                                        KEY_CUSTOM_DIRECTORY: "No", KEY_NAME: "Default"]
        let profile = iTermShellforgeSidebar.taskTabProfile(base: base, directory: "/r/aiterm/.worktrees/fix-login")
        XCTAssertEqual(profile[KEY_CUSTOM_COMMAND] as? String, "No")
        XCTAssertEqual(profile[KEY_CUSTOM_DIRECTORY] as? String, kProfilePreferenceInitialDirectoryCustomValue)
        XCTAssertEqual(profile[KEY_WORKING_DIRECTORY] as? String, "/r/aiterm/.worktrees/fix-login")
        XCTAssertEqual(profile[KEY_NAME] as? String, "Default")
    }
}
```

- [ ] **Step 3: Run it to see it fail**

Run: `xcodebuild test -project iTerm2.xcodeproj -scheme ModernTests -configuration Development -destination 'platform=macOS' -skipPackagePluginValidation CODE_SIGN_IDENTITY=- -only-testing:ModernTests/ShellforgeHostTest`
Expected: compile error `type 'iTermShellforgeSidebar' has no member 'taskTabProfile'`.

- [ ] **Step 4: Write the host and the bridge**

Replace `sources/TerminalView/iTermShellforgeSidebar.swift` with:

```swift
//
//  iTermShellforgeSidebar.swift
//  Shellforge
//
//  Hands the Shellforge sidebar, which lives in the Shellforge package, to the Objective-C window
//  code, and implements its TerminalHost over one PseudoTerminal's tabs.
//

import AppKit
import ShellforgeCore
import ShellforgeUI

@objc(iTermShellforgeSidebar)
@MainActor
final class iTermShellforgeSidebar: NSObject {
    /// The sidebar column's width in points.
    @objc static var width: CGFloat { ShellforgeSidebar.width }

    /// One shared launcher, so the login shell's environment is read once per app run.
    static let launcher = CommandLauncher()

    /// A new sidebar for `windowController`'s window.
    @objc static func makeView(for windowController: PseudoTerminal) -> NSView {
        let host = iTermShellforgeHost(windowController: windowController)
        let model = SidebarModel(host: host, store: WorkspaceStore(), launcher: launcher)
        return ShellforgeSidebar.makeView(model: model, chooseFolder: {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.prompt = "Add Project"
            return panel.runModal() == .OK ? panel.url?.path : nil
        })
    }

    /// The default profile changed to run the login shell in `directory`.
    static func taskTabProfile(base: [AnyHashable: Any], directory: String) -> [AnyHashable: Any] {
        var profile = base
        profile[KEY_CUSTOM_COMMAND] = "No"
        profile[KEY_CUSTOM_DIRECTORY] = kProfilePreferenceInitialDirectoryCustomValue
        profile[KEY_WORKING_DIRECTORY] = directory
        return profile
    }
}

/// `TerminalHost` for one window: its tabs, read live from iTerm2, tagged by user variables.
@MainActor
final class iTermShellforgeHost: TerminalHost {
    private weak var windowController: PseudoTerminal?
    var onChange: (@MainActor () -> Void)?
    private var observers: [NSObjectProtocol] = []

    init(windowController: PseudoTerminal) {
        self.windowController = windowController
        let names: [Notification.Name] = [
            NSNotification.Name(rawValue: PTYSessionCreatedNotification),
            NSNotification.Name(rawValue: PTYSessionTerminatedNotification),
            NSNotification.Name(rawValue: PTYSessionPresentationNameDidChangeNotification),
            NSNotification.Name(rawValue: iTermTabDidCloseNotification),
            NSNotification.Name(rawValue: iTermSelectedTabDidChange),
        ]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // Session-created fires before the session joins a tab; read the window next turn.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.onChange?() } }
            })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    var tabs: [TabSnapshot] {
        (windowController?.tabs() ?? []).compactMap { tab in
            guard let session = tab.activeSession else { return nil }
            let scope = session.genericScope
            return TabSnapshot(id: session.guid, tabId: Int(tab.uniqueId), title: session.name ?? "",
                               taskId: (scope.value(forVariableName: ShellforgeTags.task) as? String).flatMap(UUID.init(uuidString:)),
                               projectId: (scope.value(forVariableName: ShellforgeTags.project) as? String).flatMap(UUID.init(uuidString:)))
        }
    }

    var selectedTabId: String? { windowController?.currentTab()?.activeSession?.guid }

    func select(tab id: String) {
        guard let tab = windowController?.tabs().first(where: { $0.activeSession?.guid == id }),
              let item = tab.tabViewItem else { return }
        item.tabView?.selectTabViewItem(item)
        onChange?()
    }

    func openTab(in directory: String, taskId: UUID, projectId: UUID, title: String) {
        guard let windowController, let base = ProfileModel.sharedInstance()?.defaultBookmark() else { return }
        let profile = iTermShellforgeSidebar.taskTabProfile(base: base, directory: directory)
        iTermSessionLauncher.launchBookmark(profile, in: windowController, style: .tab, withURL: nil,
                                            hotkeyWindowType: .none, makeKey: true, canActivate: true,
                                            respectTabbingMode: false, index: nil, command: nil,
                                            makeSession: nil, didMakeSession: { session in
            session.genericScope.setValue(taskId.uuidString.lowercased(), forVariableNamed: ShellforgeTags.task)
            session.genericScope.setValue(projectId.uuidString.lowercased(), forVariableNamed: ShellforgeTags.project)
        }, completion: { [weak self] _, _ in
            MainActor.assumeIsolated { self?.onChange?() }
        })
    }
}
```

- [ ] **Step 5: Wire the window and hide the tab bar**

In `sources/TerminalView/iTermRootTerminalView.m`:

1. Replace `_shellforgeSidebar = [iTermShellforgeSidebar makeView];` with:

```objc
        _shellforgeSidebar = [iTermShellforgeSidebar makeViewFor:(PseudoTerminal *)delegate];
```

where `delegate` is the `initWithFrame:…delegate:` parameter (the window controller). Check the exact parameter name in the initializer signature before editing.

2. At the top of `- (BOOL)tabBarShouldBeVisibleWithAdditionalTabs:(int)numberOfAdditionalTabs {` insert:

```objc
    // Shellforge: the sidebar lists the tabs; iTerm2's tab bar would show other tasks' tabs.
    if (_shellforgeSidebar) {
        return NO;
    }
```

3. Add two rows to `Shellforge/docs/upstream-hook-points.md`'s table:

```markdown
| `sources/TerminalView/iTermRootTerminalView.m` (`tabBarShouldBeVisibleWithAdditionalTabs:`) | No tab bar in a window with the sidebar | The sidebar lists the tabs; the tab bar would show other tasks' |
| `iTerm2.xcodeproj/project.pbxproj` | `ShellforgeCore` linked into `iTermSwiftPackages` | The host builds `TabSnapshot`s and the model |
```

- [ ] **Step 6: Build and run the test**

Run: `PATH="$HOME/.cargo/bin:$PATH" make Development 2>&1 | tail -3` — expected `** BUILD SUCCEEDED **`.
Run the Step 3 command again — expected `ShellforgeHostTest.testATaskTabRunsTheLoginShellInTheWorktree()` passed.
Run: `xcodebuild test … -only-testing:ModernTests/ShellforgeSidebarLayoutTest -only-testing:ModernTests/iTermLayoutCalculatorTest` — expected all passed.

If `iTermSelectedTabDidChange` is not the notification's name in this tree, find it with `grep -rn "SelectedTabDidChange\|didSelectTab" sources/TerminalView/PseudoTerminal.h` and use what is there.

- [ ] **Step 7: Commit**

```bash
git add iTerm2.xcodeproj/project.pbxproj sources/TerminalView/iTermShellforgeSidebar.swift sources/TerminalView/iTermRootTerminalView.m ModernTests/ShellforgeHostTest.swift Shellforge/docs/upstream-hook-points.md
git commit -m "feat(sidebar): tasks as tagged tabs in one window, tab bar hidden

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: End-to-end check in the running app

**Files:**
- Modify: `Shellforge/docs/upstream-hook-points.md` (an "M1a: verified" section)

- [ ] **Step 1: Launch the build**

Run: `open -n ~/Library/Developer/Xcode/DerivedData/iTerm2-*/Build/Products/Development/iTerm2.app` and open a window if none appears: `osascript -e 'tell application id "io.github.nathangel.shellforge" to create window with default profile'`.

- [ ] **Step 2: Walk the five behaviours**

1. Press the sidebar's `+`, choose `~/aiterm` (or any repository). It appears as a project. Choose a non-repository folder: the sidebar shows git's "not a git repository" message.
2. Press the project's `⊕`, type "Try shellforge", Return. `~/aiterm/.worktrees/try-shellforge` exists on branch `try-shellforge`; a tab opens there (`pwd` in it says so) and is listed under the task. The tab bar is not shown.
3. Create a second task, then click the first: the window shows the first task's tab. Press Cmd-Shift-]: the sidebar highlights the task whose tab is now shown.
4. Close the first task's only tab (Cmd-W): the task stays listed with no tabs. Click it: a new tab opens in its worktree.
5. Quit and relaunch: both tasks are listed; their restored tabs are back under them (the tags survive restoration).

- [ ] **Step 3: Record and commit**

Append to `Shellforge/docs/upstream-hook-points.md` a section `## M1a: verified on <date>` listing the five behaviours and anything that did not hold, then:

```bash
git add Shellforge/docs/upstream-hook-points.md
git commit -m "docs(shellforge): M1a verified in the running app

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Remove the two trial worktrees afterwards with `git -C ~/aiterm worktree remove .worktrees/try-shellforge` (and the second one), and delete their branches only after confirming with the user.
