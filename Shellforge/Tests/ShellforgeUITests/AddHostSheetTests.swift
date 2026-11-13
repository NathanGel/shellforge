import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

/// A watcher that never fires, recording what it was asked to watch.
private final class IdleSSHWatcher: FolderWatching, @unchecked Sendable {
    private let lock = NSLock()
    private var watched: String?
    var path: String? { lock.withLock { watched } }

    func watch(_ path: String, onChange: @escaping @Sendable () -> Void) { lock.withLock { watched = path } }
    func stop() {}
}

/// Add Host: the sheet's model over a scratch config — never the real `~/.ssh`. It refuses a host
/// ssh can't read, appends one it can, reloads the panel's hosts, and makes it a project's host,
/// asking first when that project already has another.
@MainActor @Suite(.serialized) struct AddHostSheetTests {
    private let folder = TestScratch.root.appendingPathComponent("shellforge-addhost-\(UUID().uuidString)")
    private let launcher = CommandLauncher(resolve: { ResolvedEnvironment(variables: ["PATH": "/usr/bin"], source: .loginShell("/bin/zsh")) })
    private static let staging = "Host staging\n  HostName staging.example.com\n  User deploy\n"
    private static let buildBox = NewSSHHost(alias: "build-box", hostName: "build-box.example.com", user: "deploy")

    private var sshFolder: URL { folder.appendingPathComponent("ssh") }
    private var configFile: URL { sshFolder.appendingPathComponent("config") }

    /// Project `demo` naming `sshHost`, over a scratch config holding `config` (none when nil).
    private func sidebar(sshHost: String? = nil, config: String? = staging) throws -> (SidebarModel, UUID) {
        if let config {
            try FileManager.default.createDirectory(at: sshFolder, withIntermediateDirectories: true)
            try config.write(to: configFile, atomically: true, encoding: .utf8)
        }
        let document = WorkspaceDocument(store: WorkspaceStore(folder: folder.appendingPathComponent("workspace")))
        var project = Project(name: "demo", path: "/demo")
        project.sshHost = sshHost
        try document.update { $0.projects.append(project) }
        let model = SidebarModel(host: FakeTerminalHost(), document: document, launcher: launcher, jiraSettings: { nil },
                                 sshConfig: SSHConfigSource(file: configFile, home: folder))
        model.makeSSHWatcher = { IdleSSHWatcher() }
        return (model, project.id)
    }

    private func config() throws -> String { try String(contentsOf: configFile, encoding: .utf8) }

    private func warning(for config: String, _ host: NewSSHHost) async throws -> (String?, Bool) {
        let (sidebar, _) = try sidebar(config: config)
        let model = AddHostModel(sidebar: sidebar)
        await model.load()
        model.draft = host
        return (model.status.warning, model.canAdd)
    }

    @Test func anEarlierWildcardUserIsWarnedAbout() async throws {
        let (warning, canAdd) = try await warning(for: "Host *\n  User ops\n\n" + Self.staging, Self.buildBox)
        #expect(warning == "An earlier Host * block in your SSH config sets User, so it applies before this host’s own.")
        #expect(canAdd, "a warning, not a refusal")
    }

    @Test func aWildcardPortAndHostNameAreNamedToo() async throws {
        let (warning, _) = try await warning(for: "Match all\n  Port 2200\n  HostName gateway.example.com\n",
                                             NewSSHHost(alias: "build-box", hostName: "b.example.com", port: "2222"))
        #expect(warning == "An earlier Match all block in your SSH config sets Port and HostName, so it applies before this host’s own.")
    }

    @Test func aWildcardIdentityFileIsNotWarnedAbout() async throws {
        let (warning, _) = try await warning(for: "Host *\n  IdentityFile ~/.ssh/id_shared\n", Self.buildBox)
        #expect(warning == nil, "ssh adds IdentityFile up across blocks")
    }

    @Test func aWildcardUserTheHostDoesNotSetIsNotWarnedAbout() async throws {
        let (warning, _) = try await warning(for: "Host *\n  User ops\n", NewSSHHost(alias: "build-box", hostName: "b.example.com"))
        #expect(warning == nil)
    }

    @Test func aConcreteHostsUserIsNotWarnedAbout() async throws {
        let (warning, _) = try await warning(for: Self.staging, Self.buildBox)
        #expect(warning == nil)
    }

    @Test func addIsDisabledUntilTheHostIsValid() async throws {
        let (sidebar, _) = try sidebar()
        let model = AddHostModel(sidebar: sidebar)
        await model.load()
        #expect(model.problem == "Give the host a name.")
        #expect(!model.canAdd)
        model.draft.alias = "staging"
        model.draft.hostName = "staging.example.com"
        #expect(model.problem == "“staging” is already in your SSH config.", "the config as last read")
        model.draft.alias = "build-box"
        model.draft.hostName = ""
        #expect(model.problem == "Give the host’s address.")
        model.draft.hostName = "build-box.example.com"
        model.draft.port = "70000"
        #expect(model.problem == "The port is a number from 1 to 65535.")
        model.draft.port = "2222"
        #expect(model.problem == nil)
        #expect(model.canAdd)
        #expect(model.projects.map(\.name) == ["demo"])
        #expect(AddHostSheet.footnote == "Added to ~/.ssh/config. The file is copied to config.shellforge-backup first.")
    }

    /// No project: the host is appended, the config read again, and the panel lists it under Other hosts.
    @Test func addingWritesTheConfigAndReloads() async throws {
        let (sidebar, _) = try sidebar()
        let model = AddHostModel(sidebar: sidebar)
        await model.load()
        model.draft = Self.buildBox
        #expect(await model.add())
        #expect(try config() == Self.staging + "\nHost build-box\n    HostName build-box.example.com\n    User deploy\n")
        #expect(FileManager.default.fileExists(atPath: sshFolder.appendingPathComponent("config.shellforge-backup").path))
        #expect(sidebar.sshHosts?["build-box"] != nil)
        let other = try #require(SSHPanel.sections(sidebar).last)
        #expect(other.kind == .other && other.entries.map(\.alias).contains("build-box"))
        #expect(model.note == nil, "the config was there already")
        #expect(model.problem == "“build-box” is already in your SSH config.", "added twice")
    }

    @Test func addingForAProjectSetsItsHost() async throws {
        let (sidebar, project) = try sidebar()
        let prompter = ScriptedPrompter([])
        sidebar.prompter = prompter
        let model = AddHostModel(sidebar: sidebar)
        await model.load()
        model.draft = Self.buildBox
        model.project = project
        #expect(await model.add())
        #expect(sidebar.project(project)?.sshHost == "build-box")
        #expect(prompter.asked.isEmpty, "nothing to replace")
        let first = try #require(SSHPanel.sections(sidebar).first)
        #expect(first.kind == .project(project) && first.entries.map(\.alias) == ["build-box"])
    }

    /// The project already names another host: asked first. Keep — the safe answer, ⎋'s — leaves
    /// it; Replace takes the new one. Either way the host is in the config.
    @Test func replacingAProjectsHostAsksFirst() async throws {
        let (sidebar, project) = try sidebar(sshHost: "staging")
        let prompter = ScriptedPrompter([AlertAnswer(button: 1), AlertAnswer(button: 0)])
        sidebar.prompter = prompter
        let model = AddHostModel(sidebar: sidebar)
        await model.load()
        model.draft = Self.buildBox
        model.project = project
        #expect(await model.add())
        let asked = try #require(prompter.asked.first)
        #expect(asked.message == "Replace staging as demo’s SSH host?")
        #expect(asked.buttons == ["Replace", "Keep staging"])
        #expect(asked.escapeButton == 1)
        #expect(sidebar.project(project)?.sshHost == "staging")
        #expect(try config().contains("Host build-box\n"))

        let again = AddHostModel(sidebar: sidebar)
        again.draft = NewSSHHost(alias: "db-tunnel", hostName: "db.example.com")
        again.project = project
        #expect(await again.add())
        #expect(sidebar.project(project)?.sshHost == "db-tunnel")
    }

    /// The folder can't take the backup: nothing is added, the reason is the problem line, and the
    /// sheet stays open (`add` is false).
    @Test(.disabled(if: getuid() == 0, "root writes through 0500"))
    func aWriteFailureIsShown() async throws {
        let (sidebar, _) = try sidebar()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: sshFolder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sshFolder.path) }
        let model = AddHostModel(sidebar: sidebar)
        await model.load()
        model.draft = Self.buildBox
        #expect(await model.add() == false)
        let problem = try #require(model.problem)
        #expect(problem.hasPrefix("Your SSH config couldn’t be backed up, so nothing was added."))
        #expect(try config() == Self.staging)
        #expect(model.canAdd, "tried again once the folder is fixed")
        model.draft.user = "ops"
        #expect(model.problem == nil, "an edit clears the failure")
    }

    /// Choose… starts in the config's own folder, and writes a key in the home folder with `~`.
    @Test func chooseStartsInTheConfigFolderAndAbbreviatesHome() throws {
        let (sidebar, _) = try sidebar()
        #expect(AddHostModel(sidebar: sidebar).identityFolder == sshFolder)
        let home = URL(fileURLWithPath: NSHomeDirectory())
        #expect(AddHostModel.identityPath(home.appendingPathComponent(".ssh/id_ed25519")) == "~/.ssh/id_ed25519")
        #expect(AddHostModel.identityPath(URL(fileURLWithPath: "/Volumes/Keys/id_ed25519")) == "/Volumes/Keys/id_ed25519",
                "a key outside the home folder stays absolute")
    }

    /// No `~/.ssh` yet: Add Host makes it, says so, and the panel starts watching it.
    @Test func aNewConfigIsSaidAndWatched() async throws {
        let (sidebar, _) = try sidebar(config: nil)
        sidebar.watchSSHConfig()
        #expect(sidebar.sshWatchers.isEmpty, "no folder to watch yet")
        let model = AddHostModel(sidebar: sidebar)
        await model.load()
        model.draft = Self.buildBox
        #expect(await model.add())
        #expect(model.note == "Created ~/.ssh/config.")
        #expect(sidebar.notice == "Created ~/.ssh/config.")
        #expect(sidebar.sshWatchers.count == 1)
        #expect(sidebar.sshHosts?["build-box"] != nil)
    }
}
