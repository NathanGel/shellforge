import AppKit
import Foundation
import ShellforgeDesign
import SwiftUI
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

/// A watcher the test fires itself, recording what it was asked to watch.
private final class FakeSSHWatcher: FolderWatching, @unchecked Sendable {
    private let lock = NSLock()
    private var change: (@Sendable () -> Void)?
    private(set) var path: String?

    func watch(_ path: String, onChange: @escaping @Sendable () -> Void) {
        lock.withLock { self.path = path; change = onChange }
    }

    func stop() {}

    func fire() { lock.withLock { change }?() }
}

/// Counts the watchers a model makes, and keeps them for the test to fire.
@MainActor private final class SSHWatchers {
    var made: [FakeSSHWatcher] = []
    func install(on model: SidebarModel) {
        model.makeSSHWatcher = { [self] in
            let watcher = FakeSSHWatcher()
            made.append(watcher)
            return watcher
        }
    }
}

/// The SSH panel: each project's hosts and tunnels, the config's other hosts, Connect in a tab of
/// its own, and `~/.ssh` (here a scratch folder) watched once the panel shows.
@MainActor @Suite struct SSHPanelTests {
    private let folder = TestScratch.root.appendingPathComponent("shellforge-sshpanel-\(UUID().uuidString)")
    private let launcher = CommandLauncher(resolve: { ResolvedEnvironment(variables: ["PATH": "/usr/bin"], source: .loginShell("/bin/zsh")) })
    private static let twoHosts = "Host staging\n  HostName staging.example.com\n  User deploy\nHost build-box\n  HostName build-box.example.com\n"

    private var configFile: URL { folder.appendingPathComponent("ssh/config") }

    private func writeConfig(_ text: String) throws {
        try FileManager.default.createDirectory(at: configFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: configFile, atomically: true, encoding: .utf8)
    }

    /// Project `demo` at `/demo`, naming `sshHost`, over a scratch config holding `config`.
    private func model(sshHost: String? = nil, config: String = twoHosts) throws -> (SidebarModel, FakeTerminalHost, UUID, SSHWatchers) {
        try writeConfig(config)
        let document = WorkspaceDocument(store: WorkspaceStore(folder: folder.appendingPathComponent("workspace")))
        var project = Project(name: "demo", path: "/demo")
        project.sshHost = sshHost
        try document.update { $0.projects.append(project) }
        let host = FakeTerminalHost()
        let model = SidebarModel(host: host, document: document, launcher: launcher, jiraSettings: { nil },
                                 sshConfig: SSHConfigSource(file: configFile, home: folder))
        let watchers = SSHWatchers()
        watchers.install(on: model)
        return (model, host, project.id, watchers)
    }

    /// The sidebar as the app makes it, in a window.
    private func made(_ sidebar: SidebarModel) -> (NSView, NSWindow) {
        let hooks = AgentHooksModel(integrations: HookIntegrations(home: folder.appendingPathComponent("home"), resources: .bundled(resourceURL: nil)), names: [:])
        let view = ShellforgeSidebar.makeView(model: sidebar, chooseFolder: { nil }, hooks: hooks,
                                              machine: MachineMonitor(sensor: InertMachineSensor(), power: InertPower()),
                                              backpack: BackpackController(ports: .inert, settings: BackpackSettings(defaults: nil), toast: { _ in }),
                                              zoom: SidebarZoom(settings: SidebarLayoutSettings(defaults: ScratchDefaults.make())),
                                              terminalMatch: TerminalMatchSettings(defaults: ScratchDefaults.make()), terminalEditorDefaults: ScratchDefaults.make(),
                                              feedback: FeedbackPrompt(defaults: ScratchDefaults.make(), channel: .dev))
        view.frame = NSRect(x: 0, y: 0, width: Size.sidebarWidth, height: 600)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return (view, window)
    }

    private func descendants(of view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }

    private func marks(in host: NSView) -> Set<String> {
        host.layoutSubtreeIfNeeded()
        return Set(descendants(of: host).compactMap { $0.identifier?.rawValue })
    }

    @Test func sshIsAPanel() {
        #expect(ActivityLayout(saved: ["sessions", "metrics", "files", "git"]).order.last == .ssh, "appended to a saved order")
        #expect(ActivityPanel.ssh.title == "SSH")
        #expect(ActivityPanel.ssh.symbol == "server.rack")
    }

    /// Nothing reads or watches `~/.ssh` before the panel first shows; then it is read, and its
    /// folder watched, once however often the panel shows again.
    @Test func nothingIsReadBeforeThePanelShows() async throws {
        let (model, _, _, watchers) = try model()
        let (view, window) = made(model)
        defer { window.close() }
        #expect(model.sshHosts == nil, "read before the panel showed")
        #expect(watchers.made.isEmpty, "watched before the panel showed")
        ShellforgeSidebar.show(.ssh, on: view)
        #expect(await eventually { model.sshHosts?["staging"] != nil })
        #expect(watchers.made.count == 1)
        #expect(watchers.made.first?.path == FolderWatcher.resolvedRoot(configFile.deletingLastPathComponent().path))
        ShellforgeSidebar.show(.sessions, on: view)
        ShellforgeSidebar.show(.ssh, on: view)
        model.watchSSHConfig()
        #expect(watchers.made.count == 1, "a second watcher for the same folder")
    }

    /// A config that is a link: its own folder and its target's are both watched.
    @Test func aLinkedConfigsTargetFolderIsWatchedToo() throws {
        let dotfiles = folder.appendingPathComponent("dotfiles")
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        try Self.twoHosts.write(to: dotfiles.appendingPathComponent("ssh_config"), atomically: true, encoding: .utf8)
        let link = folder.appendingPathComponent("linked/config")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dotfiles.appendingPathComponent("ssh_config"))
        #expect(SidebarModel.sshFolders(of: link) == [FolderWatcher.resolvedRoot(link.deletingLastPathComponent().path),
                                                      FolderWatcher.resolvedRoot(dotfiles.path)])
        try writeConfig(Self.twoHosts)
        #expect(SidebarModel.sshFolders(of: configFile) == [FolderWatcher.resolvedRoot(configFile.deletingLastPathComponent().path)])
        #expect(SidebarModel.sshFolders(of: folder.appendingPathComponent("absent/config")).isEmpty, "a folder that isn’t there")
    }

    @Test func connectOpensSSHInTheProjectFolder() async throws {
        let (model, host, project, _) = try model(sshHost: "staging")
        await model.connect(alias: "staging", in: project)
        let opened = try #require(host.openedPlain.last)
        #expect(opened.directory == "/demo" && opened.title == "staging")
        #expect(opened.command == "ssh -o ClearAllForwardings=yes staging")
    }

    @Test func anOtherHostConnectsFromHome() async throws {
        let (model, host, _, _) = try model(sshHost: "staging")
        _ = await model.loadSSHHosts()
        let sections = SSHPanel.sections(model)
        let other = try #require(sections.last)
        #expect(other.kind == .other && other.title == "Other hosts")
        #expect(other.entries.map(\.alias) == ["build-box"], "staging is demo’s, so not repeated")
        await model.connect(alias: "build-box", in: nil)
        let opened = try #require(host.openedPlain.last)
        #expect(opened.directory == NSHomeDirectory() && opened.title == "build-box")
        #expect(opened.command == SSHConfig.paneCommand(alias: "build-box"))
    }

    /// A host a project names that the config no longer has: listed, dimmed, said, and never run.
    @Test func aMissingHostHasNoConnect() async throws {
        let (model, host, project, _) = try model(sshHost: "staging", config: "Host build-box\n  HostName build-box.example.com\n")
        _ = await model.loadSSHHosts()
        let entry = try #require(SSHPanel.sections(model).first?.entries.first)
        #expect(entry.alias == "staging" && !entry.inConfig)
        #expect(!SSHPanel.accessibilityActions(entry, tunnel: nil).contains(SSHPanel.connectTitle))
        #expect(SSHPanel.missingText == "Not in ~/.ssh/config")
        await model.connect(alias: "staging", in: project)
        #expect(host.openedPlain.isEmpty)
        #expect(model.lastError == "staging isn’t in ~/.ssh/config.")
        let present = SSHPanelEntry(alias: "build-box", isProjectHost: false, isTunnel: false, inConfig: true)
        #expect(SSHPanel.accessibilityActions(present, tunnel: nil) == [SSHPanel.connectTitle])
        #expect(SSHPanel.accessibilityLabel(present, tunnel: nil) == "build-box, host")
    }

    /// A tunnel's row speaks its state, and offers Start or Stop as the tunnel's own row does.
    @Test func aTunnelSpeaksItsState() {
        let entry = SSHPanelEntry(alias: "db-tunnel", isProjectHost: false, isTunnel: true, inConfig: true)
        var tunnel = TunnelRowItem(projectId: UUID(), alias: "db-tunnel", forwards: [], state: .up, error: nil, missing: false)
        #expect(SSHPanel.accessibilityLabel(entry, tunnel: tunnel) == "db-tunnel, up")
        #expect(SSHPanel.accessibilityActions(entry, tunnel: tunnel) == [SSHPanel.connectTitle, SSHPanel.stopTitle])
        tunnel.state = .stopped
        #expect(SSHPanel.accessibilityActions(entry, tunnel: tunnel) == [SSHPanel.connectTitle, SSHPanel.startTitle])
    }

    @Test func anEmptyConfigOffersAddHost() async throws {
        let (model, _, _, _) = try model(config: "")
        #expect(!SSHPanel.showsEmptyState(SSHPanel.sections(model), loaded: model.sshHosts != nil), "said before the config was read")
        _ = await model.loadSSHHosts()
        #expect(SSHPanel.showsEmptyState(SSHPanel.sections(model), loaded: model.sshHosts != nil))
        #expect(SSHPanel.emptyText == "No hosts in ~/.ssh/config yet.")
        #expect(SSHPanel.addHostTitle == "Add Host…")
        let (view, window) = made(model)
        defer { window.close() }
        ShellforgeSidebar.show(.ssh, on: view)
        #expect(marks(in: view).contains(SSHPanel.markName))
    }

    /// The config changes on disk: the watcher's event reads it again, and a host a project names
    /// that has gone from it turns missing.
    @Test func aRemovedHostTurnsMissing() async throws {
        let (model, _, _, watchers) = try model(sshHost: "staging")
        model.watchSSHConfig()
        #expect(await eventually { model.sshHosts?["staging"] != nil })
        #expect(SSHPanel.sections(model).first?.entries.first?.inConfig == true)
        try writeConfig("Host build-box\n  HostName build-box.example.com\n")
        try #require(watchers.made.first).fire()
        #expect(await eventually { SSHPanel.sections(model).first?.entries.first?.inConfig == false })
        #expect(model.sshHosts?["staging"] == nil)
    }

    /// Two reads of the config overlap and the older finishes last: the newer one's hosts stay.
    @Test func anOlderReadFinishingLastIsDropped() throws {
        let (model, _, _, _) = try model()
        let older = model.beginSSHRead(), newer = model.beginSSHRead()
        model.take([SSHHost(alias: "staging", forwards: []), SSHHost(alias: "build-box", forwards: [])], generation: newer)
        model.take([SSHHost(alias: "staging", forwards: [])], generation: older)
        #expect(model.sshHosts.map { Set($0.keys) } == ["staging", "build-box"])
    }

    /// Reads that finish in the order they started are each kept.
    @Test func readsFinishingInOrderAreEachKept() throws {
        let (model, _, _, _) = try model()
        let first = model.beginSSHRead(), second = model.beginSSHRead()
        model.take([SSHHost(alias: "staging", forwards: [])], generation: first)
        #expect(model.sshHosts.map { Set($0.keys) } == ["staging"])
        model.take([SSHHost(alias: "build-box", forwards: [])], generation: second)
        #expect(model.sshHosts.map { Set($0.keys) } == ["build-box"])
    }

    @Test func showSSHSelectsThePanel() throws {
        let (model, _, _, _) = try model()
        let (view, window) = made(model)
        defer { window.close() }
        #expect(!marks(in: view).contains(SSHPanel.markName))
        let item = try #require(SidebarCommandMenu.panels.first { $0.panel == .ssh })
        #expect(item.title == "Show SSH" && item.key == "h" && item.modifiers == [.control, .command])
        ShellforgeSidebar.show(item.panel, on: view)
        #expect(ShellforgeSidebar.shownPanel(of: view) == .ssh)
        #expect(marks(in: view).contains(SSHPanel.markName))
    }
}
