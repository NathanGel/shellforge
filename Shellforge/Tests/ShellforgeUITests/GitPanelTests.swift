import AppKit
import Foundation
import ShellforgeDesign
import SwiftUI
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

private final class InertGitWatcher: FolderWatching, @unchecked Sendable {
    func watch(_ path: String, onChange: @escaping @Sendable () -> Void) {}
    func stop() {}
}

/// The Git panel: a section per repository, its branch line, what it offers to do, and a change
/// opened as a diff in a terminal tab.
@MainActor @Suite struct GitPanelTests {
    private let launcher = CommandLauncher(resolve: { ResolvedEnvironment(variables: ["PATH": "/usr/bin"], source: .loginShell("/bin/zsh")) })
    private let demo = Project(name: "demo", path: "/demo")

    private func status(_ head: GitStatus.Head, upstream: String? = nil, staged: [GitChange] = [],
                        unstaged: [GitChange] = []) -> GitStatus {
        var status = GitStatus()
        status.head = head
        status.upstream = upstream
        status.staged = staged
        status.unstaged = unstaged
        return status
    }

    private func section(_ id: GitRepoID, _ status: GitStatus, tasks: [GitSection] = []) -> GitSection {
        GitSection(id: id, title: "demo", path: "/demo", state: .status(status), busy: false, problem: nil, tasks: tasks)
    }

    private func actions(_ host: FakeTerminalHost) -> GitPanelActions {
        GitPanelActions(host: host, defaults: ScratchDefaults.make(), environment: { ["EDITOR": "vim"] },
                        launcher: launcher, prompter: { NullPrompter() }, busyTask: { _ in nil }, kind: { _ in .file })
    }

    private func descendants(of view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }

    private func marks(in host: NSView) -> Set<String> {
        host.layoutSubtreeIfNeeded()
        return Set(descendants(of: host).compactMap { $0.identifier?.rawValue })
    }

    private func gitModel(_ made: (() -> Void)? = nil) -> GitModel {
        made?()
        return GitModel(projects: [], tasks: [], launcher: launcher, watcher: { _ in InertGitWatcher() }, trash: { _ in })
    }

    private func sidebarView(git: GitHolder) -> NSView {
        let folder = TestScratch.root.appendingPathComponent("shellforge-git-\(UUID().uuidString)")
        let document = WorkspaceDocument(store: WorkspaceStore(folder: folder))
        let sidebar = SidebarModel(host: FakeTerminalHost(), document: document, launcher: launcher, jiraSettings: { nil })
        let hooks = AgentHooksModel(integrations: HookIntegrations(home: TestScratch.root.appendingPathComponent("git-home-\(UUID().uuidString)"),
                                                                   resources: .bundled(resourceURL: nil)), names: [:])
        return ShellforgeSidebar.makeView(model: sidebar, chooseFolder: { nil }, hooks: hooks,
                                          machine: MachineMonitor(sensor: InertMachineSensor(), power: InertPower()),
                                          backpack: BackpackController(ports: .inert, settings: BackpackSettings(defaults: nil), toast: { _ in }),
                                          zoom: SidebarZoom(settings: SidebarLayoutSettings(defaults: ScratchDefaults.make())),
                                          terminalMatch: TerminalMatchSettings(defaults: ScratchDefaults.make()), terminalEditorDefaults: ScratchDefaults.make(),
                                          feedback: FeedbackPrompt(defaults: ScratchDefaults.make(), channel: .dev),
                                          git: git)
    }

    /// A window's sidebar over a workspace holding `projects` and `tasks`, its tabs in `host`.
    private func sidebar(_ host: FakeTerminalHost = FakeTerminalHost(), projects: [Project], tasks: [TaskItem] = []) throws -> SidebarModel {
        let folder = TestScratch.root.appendingPathComponent("shellforge-git-tabs-\(UUID().uuidString)")
        let document = WorkspaceDocument(store: WorkspaceStore(folder: folder))
        try document.update { $0.projects += projects; $0.tasks += tasks }
        return SidebarModel(host: host, document: document, launcher: launcher, jiraSettings: { nil })
    }

    private func window(_ view: NSView) -> NSWindow {
        view.frame = NSRect(x: 0, y: 0, width: Size.sidebarWidth, height: 600)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        return window
    }

    @Test func gitIsAPanel() {
        #expect(ActivityLayout(saved: ["sessions", "metrics", "files"]).order.dropFirst(3).first == .git)
        #expect(ActivityPanel.git.title == "Git")
        #expect(ActivityPanel.git.symbol == "arrow.triangle.branch")
    }

    /// The app's one Git model is made when the panel first shows: before, no repository is read.
    @Test func nothingIsReadBeforeThePanelShows() {
        final class Count { var made = 0 }
        let count = Count()
        let holder = GitHolder { self.gitModel { count.made += 1 } }
        let view = sidebarView(git: holder)
        let window = window(view)
        defer { window.close() }
        #expect(!marks(in: view).contains(GitPanel.markName))
        #expect(count.made == 0 && holder.made == nil, "made before the panel showed")
        ShellforgeSidebar.show(.git, on: view)
        #expect(marks(in: view).contains(GitPanel.markName))
        #expect(count.made == 1)
    }

    @Test func aBranchWithoutUpstreamOffersPublish() {
        #expect(GitPanel.remoteActions(status(.branch("feature/login-page"))) == [.publish])
        #expect(GitPanel.remoteActions(status(.branch("main"), upstream: "origin/main")) == [.pull, .push])
        #expect(GitPanel.RemoteAction.publish.title == "Publish Branch")
    }

    @Test func anUnbornBranchOffersNoPush() {
        #expect(GitPanel.remoteActions(status(.unborn("main"))).isEmpty)
        #expect(GitPanel.remoteActions(status(.detached(sha: "abc1234"))).isEmpty)
        #expect(GitPanel.branchLine(status(.unborn("main"))) == "No commits yet")
        #expect(GitPanel.branchLine(status(.detached(sha: "abc1234"))) == "Detached at abc1234")
        var ahead = status(.branch("main"), upstream: "origin/main")
        ahead.ahead = 2
        ahead.behind = 1
        #expect(GitPanel.branchLine(ahead) == "main ↑2 ↓1")
    }

    @Test func clickingAChangeOpensItsDiff() throws {
        let host = FakeTerminalHost()
        let change = GitChange(path: "src/app.ts", letter: .modified)
        let section = section(.project(demo.id), status(.branch("main"), unstaged: [change]))
        _ = try #require(GitPanel.rows([section], isOpen: { _ in true }).first { $0.id == GitPanel.changeID(section.id, .changes, change) })
        actions(host).viewDiff(change, list: .changes, in: section)
        #expect(host.openedPlain.map { "\($0.directory)|\($0.title)|\($0.command)" } == ["/demo|Diff: app.ts|git diff -- ':(literal)src/app.ts'"])
    }

    /// A diff tab carries its repository's and file's tag, leaves Other Tabs, and lists under its
    /// file's change row; drawn in the panel, it is there.
    @Test func aDiffTabListsUnderItsFile() async throws {
        let change = GitChange(path: "src/app.ts", letter: .modified)
        let ready = status(.branch("main"), unstaged: [change])
        let folder = TestScratch.root.appendingPathComponent("shellforge-gitpanel-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let demo = Project(name: "demo", path: folder)
        let host = FakeTerminalHost()
        let sidebar = try self.sidebar(host, projects: [demo])
        let model = GitModel(projects: [demo], tasks: [], launcher: launcher, watcher: { _ in InertGitWatcher() },
                             read: { _, _ in ready }, act: { _, _, _, _ in })
        await model.settled()
        let section = try #require(model.sections.first)
        actions(host).viewDiff(change, list: .changes, in: section)
        #expect(host.openedPlain.map(\.panel) == [.diff(repo: "project:" + demo.id.uuidString, path: "src/app.ts")])
        #expect(sidebar.tree.otherTabs.isEmpty, "not under Sessions’ Other Tabs")
        let tab = try #require(host.tabs.first)

        let row = GitPanel.changeID(section.id, .changes, change)
        let rows = GitPanel.rows(model.sections, isOpen: { _ in true })
        #expect(GitPanel.tabLines(rows, tabs: [tab], projectOf: { _ in nil }) == [row: [tab]])
        let folded = GitPanel.rows(model.sections, isOpen: { _ in false })
        #expect(GitPanel.tabLines(folded, tabs: [tab], projectOf: { _ in nil }) == [GitPanel.titleID(section.id): [tab]],
                "a folded section lists it under its title")

        let panel = GitPanel(model: model, sidebar: sidebar, titled: true, actions: actions(host))
        let view = NSHostingView(rootView: panel)
        let window = window(view)
        defer { window.close() }
        #expect(marks(in: view).contains(GitPanel.tabMark(row: row, tab: tab.id)))
    }

    /// A diff tab whose file has no changes left lists under its repository's title; a task's
    /// whose section is not drawn, under its project's.
    @Test func aDiffTabOfACleanFileListsUnderTheSection() {
        let taskId = UUID()
        let clean = section(.project(demo.id), status(.branch("main")))
        let tab = TabSnapshot(id: "s1", tabId: 1, title: "Diff: app.ts", taskId: nil, projectId: nil,
                              panel: .diff(repo: GitPanel.key(.project(demo.id)), path: "src/app.ts"))
        let ofTask = TabSnapshot(id: "s2", tabId: 2, title: "Diff: app.ts", taskId: nil, projectId: nil,
                                 panel: .diff(repo: "task:" + taskId.uuidString.lowercased(), path: "src/app.ts"))
        let elsewhere = TabSnapshot(id: "s3", tabId: 3, title: "Diff: app.ts", taskId: nil, projectId: nil,
                                    panel: .diff(repo: GitPanel.key(.project(UUID())), path: "src/app.ts"))
        let rows = GitPanel.rows([clean], isOpen: { _ in true })
        let lines = GitPanel.tabLines(rows, tabs: [tab, ofTask, elsewhere], projectOf: { $0 == taskId ? self.demo.id : nil })
        #expect(lines == [GitPanel.titleID(clean.id): [tab, ofTask]], "a repository the panel doesn’t list has no line")
    }

    /// A file both staged and changed again has a row in each list, each with its own id.
    @Test func aFileInBothListsHasTwoRows() {
        let staged = GitChange(path: "src/app.ts", letter: .modified)
        let section = section(.project(demo.id), status(.branch("main"), staged: [staged], unstaged: [staged]))
        let ids = GitPanel.rows([section], isOpen: { _ in true }).map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.contains(GitPanel.changeID(section.id, .staged, staged)) && ids.contains(GitPanel.changeID(section.id, .changes, staged)))
    }

    @Test func theCommitPlaceholderSaysWhatItCommits() {
        let change = GitChange(path: "README.md", letter: .modified)
        #expect(GitPanel.commitPlaceholder(status(.branch("main"), unstaged: [change])) == "Message (commits all changes when none are staged)")
        #expect(GitPanel.commitPlaceholder(status(.branch("main"), staged: [change])) == "Message")
        #expect(!GitPanel.canCommit(message: "  ", busy: false))
        #expect(!GitPanel.canCommit(message: "Add the login page", busy: true))
        #expect(GitPanel.canCommit(message: "Add the login page", busy: false))
    }

    @Test func taskSectionsHaveNoSwitchBranch() {
        let task = section(.task(UUID()), status(.branch("feature/login-page"), unstaged: [GitChange(path: "README.md", letter: .modified)]))
        let project = section(.project(demo.id), status(.branch("main")), tasks: [task])
        #expect(GitPanel.offersSwitchBranch(project))
        #expect(!GitPanel.offersSwitchBranch(task))
        let rows = GitPanel.rows([project], isOpen: { _ in true })
        #expect(rows.contains { $0.id == GitPanel.titleID(task.id) }, "the task’s section is under its project")
    }

    /// Discard is offered only for the Changes list, never for a conflict or a staged change.
    @Test func discardIsOfferedOnlyForChanges() {
        let modified = GitChange(path: "src/app.ts", letter: .modified)
        #expect(GitPanel.offersDiscard(modified, list: .changes))
        #expect(!GitPanel.offersDiscard(modified, list: .staged))
        #expect(!GitPanel.offersDiscard(GitChange(path: "src/app.ts", letter: .conflicted), list: .merge))
    }

    /// The actions a model was asked to run, in order.
    private final class Acted: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [GitAction] = []
        func record(_ action: GitAction) { lock.withLock { log.append(action) } }
        var actions: [GitAction] { lock.withLock { log } }
    }

    private func commandReturn(in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, characters: "\r",
                                      charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    }

    /// ⌘↩ in the commit field commits that repository's message, whatever else holds ⌘↩; with the
    /// message blank, the field still takes the key and nothing is committed.
    @Test func commandReturnInTheFieldCommits() async throws {
        let acted = Acted()
        var clean = GitStatus()
        clean.head = .branch("main")
        clean.unstaged = [GitChange(path: "src/app.ts", letter: .modified)]
        let ready = clean
        // A folder that is there: the read is faked, but a missing folder is not read at all.
        let folder = TestScratch.root.appendingPathComponent("shellforge-gitpanel-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let demo = Project(name: "demo", path: folder)
        let model = GitModel(projects: [demo], tasks: [], launcher: launcher, watcher: { _ in InertGitWatcher() },
                             read: { _, _ in ready }, act: { action, _, _, _ in acted.record(action) })
        await model.settled()
        let panel = GitPanel(model: model, sidebar: try sidebar(projects: [demo]), titled: true, actions: actions(FakeTerminalHost()))
        let host = NSHostingView(rootView: panel)
        let window = window(host)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let field = try #require(descendants(of: host).compactMap { $0 as? CommitTextView }.first)
        #expect(field.accessibilityLabel() == "Commit message")
        #expect(window.makeFirstResponder(field))

        #expect(window.performKeyEquivalent(with: try commandReturn(in: window)), "⌘↩ fell through to the menu")
        await model.settled()
        #expect(acted.actions.isEmpty, "a blank message committed")

        // The key starts the commit in a task of its own: wait until it is queued, then for it.
        let (queued, queuedContinuation) = AsyncStream<GitRepoID>.makeStream()
        model.enqueued = { queuedContinuation.yield($0) }
        model.setCommitMessage("Add the login page", for: .project(demo.id))
        host.layoutSubtreeIfNeeded()
        #expect(window.performKeyEquivalent(with: try commandReturn(in: window)))
        var queue = queued.makeAsyncIterator()
        #expect(await queue.next() == .project(demo.id))
        await model.settled()
        #expect(acted.actions == [.commit(expectsStaged: false)])
    }

    @Test func theCommitFieldGrowsToFiveLines() {
        let font = Typography.body.nsFont
        #expect(CommitMessageField.lines("", font: font, width: 300) == 1)
        #expect(CommitMessageField.lines("Add the login page\n\nWith a form", font: font, width: 300) == 3)
        #expect(CommitMessageField.lines(String(repeating: "line\n", count: 9), font: font, width: 300) == 5)
    }

    @Test func showGitSelectsThePanel() throws {
        let view = sidebarView(git: GitHolder { self.gitModel() })
        let window = window(view)
        defer { window.close() }
        let item = try #require(SidebarCommandMenu.panels.first { $0.panel == .git })
        #expect(item.title == "Show Git" && item.key == "", "every ⌃⌘ letter of Git is taken")
        ShellforgeSidebar.show(item.panel, on: view)
        #expect(ShellforgeSidebar.shownPanel(of: view) == .git)
        #expect(marks(in: view).contains(GitPanel.markName))
    }
}
