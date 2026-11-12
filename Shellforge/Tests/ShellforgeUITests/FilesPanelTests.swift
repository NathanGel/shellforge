import AppKit
import Combine
import Foundation
import ShellforgeDesign
import SwiftUI
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

private final class InertWatcher: FolderWatching, @unchecked Sendable {
    func watch(_ path: String, onChange: @escaping @Sendable () -> Void) {}
    func stop() {}
}

/// Counts the listings, and answers each with the same paths.
private final class CountingLister: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let listing: ProjectFiles.Listing
    init(_ listing: ProjectFiles.Listing) { self.listing = listing }
    func list() -> ProjectFiles.Listing { lock.withLock { count += 1 }; return listing }
    var listed: Int { lock.withLock { count } }
}

/// The Files panel: every project's tree, only open folders' rows drawn, and a file opened in a
/// terminal tab with its editor's line.
@MainActor @Suite struct FilesPanelTests {
    private let demo = Project(name: "demo", path: "/demo")
    private let launcher = CommandLauncher(resolve: { ResolvedEnvironment(variables: ["PATH": "/usr/bin"], source: .loginShell("/bin/zsh")) })
    private let appTs = FileNode(name: "app.ts", path: "src/app.ts", isFolder: false, children: nil)

    private func files(_ lister: CountingLister, projects: [Project]? = nil) -> FilesModel {
        FilesModel(projects: projects ?? [demo], launcher: launcher, defaults: ScratchDefaults.make(), watcher: { _ in InertWatcher() },
                   list: { _, _ in lister.list() })
    }

    private func opener(_ host: FakeTerminalHost, kind: FileKind, editor: String? = "vim") -> FileOpener {
        FileOpener(host: host, defaults: ScratchDefaults.make(), environment: { editor.map { ["EDITOR": $0] } ?? [:] }, kind: { _ in kind })
    }

    private func hosted(_ model: FilesModel) -> (NSView, NSWindow) {
        let panel = FilesPanel(model: model, titled: true, opener: opener(FakeTerminalHost(), kind: .file))
        let host = NSHostingView(rootView: panel)
        host.frame = NSRect(x: 0, y: 0, width: Size.sidebarWidth, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return (host, window)
    }

    private func descendants(of view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }

    private func marks(in host: NSView) -> Set<String> {
        host.layoutSubtreeIfNeeded()
        return Set(descendants(of: host).compactMap { $0.identifier?.rawValue })
    }

    @Test func filesIsAPanel() {
        #expect(ActivityLayout(saved: ["sessions", "metrics"]).order.last == .files)
    }

    @Test func onlyOpenFoldersAreDrawn() async {
        let model = files(CountingLister(.git(["src/app.ts", "README.md"])))
        await model.refresh(project: demo.id)
        let (host, window) = hosted(model)
        defer { window.close() }
        let mark = { FilesPanel.rowMark(project: self.demo.id, path: $0) }
        var drawn = marks(in: host)
        #expect(drawn.isSuperset(of: [mark(""), mark("src"), mark("README.md")]))
        #expect(!drawn.contains(mark("src/app.ts")), "a closed folder’s children have no rows")
        model.toggle(project: demo.id, folder: "src")
        drawn = marks(in: host)
        #expect(drawn.contains(mark("src/app.ts")))
        model.toggle(project: demo.id, folder: "")
        drawn = marks(in: host)
        #expect(drawn.contains(mark("")))
        #expect(!drawn.contains(mark("src")), "a closed section has no rows under its own")
    }

    @Test func clickingAFileOpensItsEditorLine() async {
        let host = FakeTerminalHost()
        await opener(host, kind: .file).open(appTs, in: demo, files: files(CountingLister(.git(["src/app.ts"]))))
        #expect(host.openedPlain.map { "\($0.directory)|\($0.title)|\($0.command)" } == ["/demo|app.ts|exec vim src/app.ts"])
    }

    /// The Settings choice beats `$EDITOR`, read from the injected defaults at the click.
    @Test func theSettingChoosesTheEditor() async {
        let host = FakeTerminalHost()
        let defaults = ScratchDefaults.make()
        defaults.set("nvim -p", forKey: EditorCommand.settingKey)
        let opener = FileOpener(host: host, defaults: defaults, environment: { ["EDITOR": "vim"] }, kind: { _ in .file })
        await opener.open(appTs, in: demo, files: files(CountingLister(.git(["src/app.ts"]))))
        #expect(host.openedPlain.map(\.command) == ["exec nvim -p src/app.ts"])
    }

    @Test func clickingAGoneFileRefreshesAndOpensNothing() async {
        let host = FakeTerminalHost()
        let lister = CountingLister(.git(["README.md"]))
        let model = files(lister)
        await model.settled()
        let before = lister.listed
        await opener(host, kind: .gone).open(appTs, in: demo, files: model)
        #expect(host.openedPlain.isEmpty)
        #expect(lister.listed == before + 1, "the project is listed again")
        #expect(model.sections.first?.state == .tree(FileTree.build(["README.md"])))
    }

    @Test func clickingAFolderNeverOpensAnEditor() async {
        let host = FakeTerminalHost()
        let model = files(CountingLister(.git(["src/app.ts"])))
        let src = FileNode(name: "src", path: "src", isFolder: false, children: nil)
        await opener(host, kind: .folder).open(src, in: demo, files: model)
        #expect(host.openedPlain.isEmpty)
        #expect(model.isOpen(project: demo.id, folder: "src"), "it unfolds instead")
    }

    @Test func aMissingProjectFolderSaysSo() async {
        let model = files(CountingLister(.missing))
        await model.refresh(project: demo.id)
        let rows = FilesPanel.rows(model.sections, isOpen: model.isOpen)
        #expect(rows.contains(.message(project: demo.id, text: "Folder not found", warns: true)))
        #expect(FilesPanel.missingText == "Folder not found")
    }

    /// The sections follow the workspace's projects, in its order.
    @Test func sectionsFollowTheWorkspace() async {
        let acme = Project(name: "acme-web", path: "/acme-web")
        let model = files(CountingLister(.git([])), projects: [])
        let projects = CurrentValueSubject<[Project], Never>([demo, acme])
        model.follow(projects)
        #expect(model.sections.map(\.project.name) == ["demo", "acme-web"])
        projects.send([acme, demo])
        #expect(model.sections.map(\.project.name) == ["acme-web", "demo"])
        projects.send([acme])
        #expect(model.sections.map(\.project.name) == ["acme-web"])
        await model.settled()
    }

    @Test func showFilesSelectsThePanel() throws {
        let folder = TestScratch.root.appendingPathComponent("shellforge-files-\(UUID().uuidString)")
        let document = WorkspaceDocument(store: WorkspaceStore(folder: folder))
        let sidebar = SidebarModel(host: FakeTerminalHost(), document: document, launcher: launcher, jiraSettings: { nil })
        let hooks = AgentHooksModel(integrations: HookIntegrations(home: TestScratch.root.appendingPathComponent("files-home-\(UUID().uuidString)"),
                                                                   resources: .bundled(resourceURL: nil)), names: [:])
        let lister = CountingLister(.git([]))
        let view = ShellforgeSidebar.makeView(model: sidebar, chooseFolder: { nil }, hooks: hooks,
                                              machine: MachineMonitor(sensor: InertMachineSensor(), power: InertPower()),
                                              backpack: BackpackController(ports: .inert, settings: BackpackSettings(defaults: nil), toast: { _ in }),
                                              zoom: SidebarZoom(settings: SidebarLayoutSettings(defaults: ScratchDefaults.make())),
                                              terminalMatch: TerminalMatchSettings(defaults: ScratchDefaults.make()),
                                              feedback: FeedbackPrompt(defaults: ScratchDefaults.make(), channel: .dev),
                                              files: FilesHolder { self.files(lister) })
        view.frame = NSRect(x: 0, y: 0, width: Size.sidebarWidth, height: 600)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        #expect(!marks(in: view).contains(FilesPanel.markName))
        let item = try #require(SidebarCommandMenu.panels.first { $0.panel == .files })
        #expect(item.title == "Show Files" && item.key == "i" && item.modifiers == [.control, .command])
        ShellforgeSidebar.show(item.panel, on: view)
        #expect(ShellforgeSidebar.shownPanel(of: view) == .files)
        #expect(marks(in: view).contains(FilesPanel.markName))
    }
}
