import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

/// A project's tunnels in the sidebar: kept with the project, started and stopped through the
/// helper, auto-started by rule, and their ports handed to the task's shell. The SSH config is a
/// temporary file; nothing reads `~/.ssh` and nothing reaches the network.
@MainActor @Suite struct TunnelsTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shellforge-tunnels-\(UUID().uuidString)")

    private static let config = """
        Host db
          HostName bastion.example
          LocalForward 5432 db.internal:5432
          LocalForward 6379 cache.internal:6379
        Host web
          LocalForward 8080 web.internal:80
        Host plain
          HostName plain.example
        """

    private func sshConfig(_ text: String = TunnelsTests.config) throws -> SSHConfigSource {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("ssh_config")
        try text.write(to: file, atomically: true, encoding: .utf8)
        return SSHConfigSource(file: file, home: folder)
    }

    private func model(tunnels: [TunnelDefinition] = [], feed: FakeFeed = FakeFeed(), config: String = TunnelsTests.config)
        async throws -> (SidebarModel, FakeTerminalHost, FakeFeed, WorkspaceDocument, UUID) {
        let repo = try GitRepoForUI(installed: ["claude"])
        let host = FakeTerminalHost()
        let document = WorkspaceDocument(store: WorkspaceStore(folder: folder))
        let model = SidebarModel(host: host, document: document, launcher: repo.launcher, feed: feed, catalogue: { _ in [] },
                                 jiraSettings: { nil }, sshConfig: try sshConfig(config))
        await model.addProject(folder: repo.path)
        let project = try #require(document.workspace.projects.first).id
        if !tunnels.isEmpty { model.setTunnels(tunnels, on: project) }
        return (model, host, feed, document, project)
    }

    /// The daemon saying each tunnel's state, as a snapshot.
    private func say(_ feed: FakeFeed, _ tunnels: [TunnelInfo]) {
        var store = SessionStore()
        var snapshot = DaemonSnapshot(protocolVersion: 1, connected: true, sessions: [], usage: .empty)
        snapshot.tunnels = tunnels
        store.apply(.snapshot(snapshot))
        feed.store = store
    }

    @Test func settingTunnelsSavesThemInTheProject() async throws {
        let (model, _, _, document, project) = try await model()
        model.setTunnels([TunnelDefinition(alias: "db", autoStart: .onTaskOpen), TunnelDefinition(alias: "db")], on: project)
        #expect(document.workspace.projects[0].tunnels == [TunnelDefinition(alias: "db", autoStart: .onTaskOpen)], "each alias once")
        #expect(try WorkspaceStore(folder: folder).load().workspace.projects[0].tunnels.map(\.alias) == ["db"])
        #expect(await eventually { model.tunnelRows(of: project).map(\.alias) == ["db"] })
        #expect(model.rows.contains { if case .tunnel(let row) = $0 { row.alias == "db" } else { false } })
    }

    @Test func aTunnelMissingFromTheConfigCannotStart() async throws {
        let (model, _, feed, _, project) = try await model(tunnels: [TunnelDefinition(alias: "gone"), TunnelDefinition(alias: "db")])
        #expect(await eventually { model.tunnelRows(of: project).first?.missing == true })
        model.startTunnel("gone")
        #expect(feed.tunnelCalls.isEmpty)
        #expect(model.lastError == "gone isn’t in ~/.ssh/config.")
        model.startTunnel("db")
        model.stopTunnel("db")
        #expect(feed.tunnelCalls == ["start db", "stop db"])
    }

    @Test func onLaunchTunnelsStartOnceConnected() async throws {
        let feed = FakeFeed()
        feed.status = .starting
        let (model, _, _, _, _) = try await model(tunnels: [TunnelDefinition(alias: "db", autoStart: .onLaunch),
                                                            TunnelDefinition(alias: "web", autoStart: .never)], feed: feed)
        try await Task.sleep(for: .milliseconds(200))
        #expect(feed.tunnelCalls.isEmpty, "nothing before the helper is connected")
        feed.status = .connected
        say(feed, [])
        #expect(await eventually { feed.tunnelCalls == ["start db"] })
        // The daemon's answer, then more updates: started once, not on every one.
        say(feed, [TunnelInfo(alias: "db", state: .connecting, error: nil, since: 1)])
        say(feed, [TunnelInfo(alias: "db", state: .up, error: nil, since: 2)])
        try await Task.sleep(for: .milliseconds(200))
        #expect(feed.tunnelCalls == ["start db"])
        _ = model
    }

    @Test func aTunnelTheUserStoppedIsNotStartedAgainOnLaunch() async throws {
        let feed = FakeFeed()
        let (model, _, _, _, _) = try await model(tunnels: [TunnelDefinition(alias: "db", autoStart: .onLaunch)], feed: feed)
        say(feed, [TunnelInfo(alias: "db", state: .stopped, error: nil, since: 1)])
        try await Task.sleep(for: .milliseconds(300))
        #expect(feed.tunnelCalls.isEmpty, "the daemon already ran it: this helper is not a new one")
        _ = model
    }

    @Test func onTaskOpenTunnelsStartWithANewTask() async throws {
        let (model, _, feed, _, project) = try await model(tunnels: [TunnelDefinition(alias: "db", autoStart: .onTaskOpen),
                                                                     TunnelDefinition(alias: "web", autoStart: .onLaunch)])
        say(feed, [TunnelInfo(alias: "web", state: .up, error: nil, since: 1)])
        var draft = TaskDraft(baseBranch: "main", agentId: "claude", model: "opus", reasoning: nil)
        draft.setTitle("Login")
        try await model.newTask(draft: draft, in: project)
        #expect(await eventually { feed.tunnelCalls.contains("start db") })
        #expect(!feed.tunnelCalls.contains("start web"))
    }

    @Test func upTunnelsBecomeTheTasksEnvironment() async throws {
        let (model, host, feed, _, project) = try await model(tunnels: [TunnelDefinition(alias: "db"), TunnelDefinition(alias: "web")])
        say(feed, [TunnelInfo(alias: "db", state: .up, error: nil, since: 1),
                   TunnelInfo(alias: "web", state: .failed, error: "bind: Address already in use", since: 1)])
        #expect(await eventually { model.portEnvironment(for: project) == ["SHELLFORGE_TUNNEL_DB_PORT": "5432", "SHELLFORGE_TUNNEL_DB_PORT_2": "6379"] })
        var draft = TaskDraft(baseBranch: "main", agentId: "claude", model: "opus", reasoning: nil)
        draft.setTitle("Login")
        try await model.newTask(draft: draft, in: project)
        #expect(host.opened.last?.environment == ["SHELLFORGE_TUNNEL_DB_PORT": "5432", "SHELLFORGE_TUNNEL_DB_PORT_2": "6379"])
    }

    @Test func theRowSaysEachState() {
        func row(_ state: TunnelState, error: String? = nil, missing: Bool = false) -> TunnelRowItem {
            TunnelRowItem(projectId: UUID(), alias: "db", forwards: [LocalForward(bind: nil, localPort: 5432, remoteHost: "db", remotePort: 5432)],
                          state: state, error: error, missing: missing)
        }
        #expect(TunnelRowView.look(row(.stopped)) == .init(tone: .stopped, action: .start, caption: nil))
        #expect(TunnelRowView.look(row(.connecting)) == .init(tone: .connecting, action: .stop, caption: nil))
        #expect(TunnelRowView.look(row(.up)) == .init(tone: .up, action: .stop, caption: nil))
        #expect(TunnelRowView.look(row(.failed, error: "bind: Address already in use"))
                == .init(tone: .failed, action: .start, caption: "bind: Address already in use"))
        #expect(TunnelRowView.look(row(.stopped, missing: true)) == .init(tone: .stopped, action: nil, caption: "Not in ~/.ssh/config"))
        #expect(row(.up).ports == "5432", "the local ports, as the row shows them")
    }

    @Test func theSheetOffersOnlyHostsWithForwardsNotYetLinked() throws {
        let hosts = try sshConfig().read()
        #expect(hosts.map(\.alias) == ["db", "web", "plain"])
        let offered = TunnelsSheet.offered(hosts: hosts, linked: [TunnelDefinition(alias: "web")], query: "")
        #expect(offered.map(\.alias) == ["db"])
        #expect(TunnelsSheet.offered(hosts: hosts, linked: [], query: "WE").map(\.alias) == ["web"])
        #expect(TunnelsSheet.statusLine(loading: false, hosts: try sshConfig("Host plain\n  HostName p\n").read(), linked: [])
                == "No hosts in ~/.ssh/config forward ports.")
    }

    // -- the final review's fixes --

    @Test func aTaskOpenTunnelsPortReachesTheTasksFirstTab() async throws {
        let (model, host, feed, _, project) = try await model(tunnels: [TunnelDefinition(alias: "db", autoStart: .onTaskOpen)])
        #expect(await eventually { model.sshHosts != nil })
        var draft = TaskDraft(baseBranch: "main", agentId: "claude", model: "opus", reasoning: nil)
        draft.setTitle("Login")
        try await model.newTask(draft: draft, in: project)
        #expect(host.opened.last?.environment == ["SHELLFORGE_TUNNEL_DB_PORT": "5432", "SHELLFORGE_TUNNEL_DB_PORT_2": "6379"], "the port is the config's, set as it starts")
        #expect(await eventually { feed.tunnelCalls == ["start db"] })
    }

    @Test func removingARunningTunnelStopsIt() async throws {
        let (model, _, feed, _, project) = try await model(tunnels: [TunnelDefinition(alias: "db"), TunnelDefinition(alias: "web")])
        say(feed, [TunnelInfo(alias: "db", state: .up, error: nil, since: 1),
                   TunnelInfo(alias: "web", state: .stopped, error: nil, since: 1)])
        #expect(await eventually { model.tunnelState("db") == .up })
        model.setTunnels([], on: project)
        #expect(feed.tunnelCalls == ["stop db"], "its row, its only stop, is gone; a stopped one needs nothing")
    }

    @Test func clickingATaskWhoseTabIsOpenStartsNothing() async throws {
        let (model, _, feed, _, project) = try await model(tunnels: [TunnelDefinition(alias: "db", autoStart: .onTaskOpen)])
        #expect(await eventually { model.sshHosts != nil })
        var draft = TaskDraft(baseBranch: "main", agentId: "claude", model: "opus", reasoning: nil)
        draft.setTitle("Login")
        try await model.newTask(draft: draft, in: project)
        #expect(await eventually { feed.tunnelCalls == ["start db"] })
        say(feed, [TunnelInfo(alias: "db", state: .stopped, error: nil, since: 2)])
        #expect(await eventually { model.tunnelState("db") == .stopped })
        model.select(task: try #require(model.tree.projects.first?.tasks.first).id)
        try await Task.sleep(for: .milliseconds(200))
        #expect(feed.tunnelCalls == ["start db"], "the user stopped it; picking the open task does not open it again")
    }

    @Test func anIncludedFileChangingIsSeenAtTheNextRefresh() async throws {
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        let included = folder.appendingPathComponent(".ssh/db.conf")
        try "Host db\n  LocalForward 5432 db.internal:5432\n".write(to: included, atomically: true, encoding: .utf8)
        let (model, _, _, _, project) = try await model(tunnels: [TunnelDefinition(alias: "db")], config: "Include db.conf\n")
        #expect(await eventually { model.tunnelRows(of: project).first?.ports == "5432" })
        try "Host db\n  LocalForward 6432 db.internal:5432\n".write(to: included, atomically: true, encoding: .utf8)
        model.toggleCollapsed(project)
        model.toggleCollapsed(project)
        #expect(await eventually { model.tunnelRows(of: project).first?.ports == "6432" })
    }

    @Test func aModelNotToldWhereTheConfigIsReadsNone() throws {
        let model = SidebarModel(host: FakeTerminalHost(), document: WorkspaceDocument(store: WorkspaceStore(folder: folder)),
                                 launcher: CommandLauncher(resolve: { ResolvedEnvironment(variables: [:], source: .fallback("test")) }),
                                 jiraSettings: { nil })
        #expect(!model.sshConfig.file.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path))
    }

    @Test func answeringInATabOpensItAndHolds() async throws {
        let (model, host, feed, _, project) = try await model(tunnels: [TunnelDefinition(alias: "db")])
        #expect(await eventually { model.sshHosts != nil })
        model.answerInTab("db", in: project)
        let tab = try #require(host.openedPlain.last)
        #expect(tab.title == "ssh db")
        #expect(tab.command == TunnelDefinition.tabCommand(alias: "db"))
        #expect(tab.directory == model.project(project)?.path)
        #expect(feed.tunnelCalls == ["hold db 5432"])
    }

    // -- M2b: uptime, traffic, the tab, keep running --

    private func upRow(since: Double, bytesIn: Int? = nil, bytesOut: Int? = nil, heldBy: TunnelHolder? = nil) -> TunnelRowItem {
        TunnelRowItem(projectId: UUID(), alias: "db", forwards: [LocalForward(bind: nil, localPort: 5432, remoteHost: "db", remotePort: 5432)],
                      state: .up, error: nil, missing: false, since: since, bytesIn: bytesIn, bytesOut: bytesOut, heldBy: heldBy)
    }

    @Test func theUptimeLineReadsWell() {
        #expect(TunnelRowView.uptime(seconds: 20) == "0m")
        #expect(TunnelRowView.uptime(seconds: 59 * 60) == "59m")
        #expect(TunnelRowView.uptime(seconds: 2 * 3600 + 5 * 60) == "2h 5m")
        #expect(TunnelRowView.uptime(seconds: 3 * 86400 + 4 * 3600 + 59) == "3d 4h")
        #expect(TunnelRowView.uptime(seconds: -5) == "0m", "a clock that moved back is no negative uptime")
    }

    @Test func theRowSaysUptimeAndTraffic() {
        let now = Date(timeIntervalSince1970: 10_000)
        let bytes = { (n: Int) in ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }
        #expect(TunnelRowView.detail(upRow(since: 10_000 - 7500, bytesIn: 1_200_000, bytesOut: 30_000), now: now)
                == "up 2h 5m · ↓ \(bytes(1_200_000)) ↑ \(bytes(30_000))")
        #expect(TunnelRowView.detail(upRow(since: 10_000 - 60), now: now) == "up 1m", "no traffic until it is sampled")
        #expect(TunnelRowView.detail(upRow(since: 0, heldBy: .tab), now: now) == "In a tab")
        var stopped = upRow(since: 0)
        stopped.state = .stopped
        #expect(TunnelRowView.detail(stopped, now: now) == nil)
        #expect(TunnelRowView.look(upRow(since: 0, heldBy: .tab)).action == nil, "the tab holds it: stopping is closing that tab")
        #expect(TunnelRowView.portsHelp(upRow(since: 0)) == "Held by db: ssh db in a tab warns it cannot bind 5432, and still connects.")
    }

    @Test func theRowOffersTheTabWhenSshNeedsInput() {
        var row = upRow(since: 0)
        row.state = .failed
        row.error = "Host key verification failed."
        row.needsInput = true
        let look = TunnelRowView.look(row)
        #expect(look.answersInTab && look.action == .start && look.caption == "Host key verification failed.")
        row.needsInput = nil
        #expect(!TunnelRowView.look(row).answersInTab)
    }

    @Test func keepRunningIsSentWithTheStart() async throws {
        let (model, _, feed, _, project) = try await model(tunnels: [TunnelDefinition(alias: "db", keepRunning: true),
                                                                     TunnelDefinition(alias: "web")])
        #expect(await eventually { model.sshHosts != nil })
        model.startTunnel("db")
        model.startTunnel("web")
        #expect(feed.tunnelCalls == ["start db (keep)", "start web"])
        #expect(model.tunnelRows(of: project).map(\.keepRunning) == [true, false])
    }

    // -- M2b final review --

    @Test func changingKeepRunningOnARunningTunnelTellsTheHelper() async throws {
        let (model, _, feed, _, project) = try await model(tunnels: [TunnelDefinition(alias: "db"), TunnelDefinition(alias: "web")])
        say(feed, [TunnelInfo(alias: "db", state: .up, error: nil, since: 1)])
        #expect(await eventually { model.tunnelState("db") == .up })
        model.setTunnels([TunnelDefinition(alias: "db", keepRunning: true), TunnelDefinition(alias: "web", keepRunning: true)], on: project)
        #expect(feed.tunnelCalls == ["start db (keep)"], "the running one learns it; the stopped one learns at its start")
    }

    @Test func eachConnectionHandsRunningTunnelsTheEnvironment() async throws {
        let feed = FakeFeed()
        let (model, _, _, _, _) = try await model(tunnels: [TunnelDefinition(alias: "db", keepRunning: true),
                                                            TunnelDefinition(alias: "web")], feed: feed)
        // A relaunch: the helper kept db running, and adopted it with no environment of its own.
        say(feed, [TunnelInfo(alias: "db", state: .up, error: nil, since: 1),
                   TunnelInfo(alias: "web", state: .stopped, error: nil, since: 1)])
        #expect(await eventually { feed.tunnelCalls == ["start db (keep)"] })
        say(feed, [TunnelInfo(alias: "db", state: .up, error: nil, since: 1)])
        try await Task.sleep(for: .milliseconds(200))
        #expect(feed.tunnelCalls == ["start db (keep)"], "once per connection")
        _ = model
    }

    @Test func theHoldWatchesTheForwardsBindAddress() async throws {
        let config = "Host db\n  LocalForward [::1]:5432 db.internal:5432\n"
        let (model, _, feed, _, project) = try await model(tunnels: [TunnelDefinition(alias: "db")], config: config)
        #expect(await eventually { model.sshHosts != nil })
        model.answerInTab("db", in: project)
        #expect(feed.tunnelCalls == ["hold db 5432 at ::1"])
    }

    // -- M5a --

    @Test func onLaunchIsAskedOncePerAppAcrossWindows() async throws {
        let feed = FakeFeed()
        let (first, _, _, document, _) = try await model(tunnels: [TunnelDefinition(alias: "db", autoStart: .onLaunch)], feed: feed)
        let second = SidebarModel(host: FakeTerminalHost(), document: document, launcher: first.launcher, feed: feed,
                                  jiraSettings: { nil }, sshConfig: first.sshConfig)
        say(feed, [])
        // Waits for the first start however loaded the run is, then gives a second one time to show.
        #expect(await eventually { !feed.tunnelCalls.isEmpty })
        try await Task.sleep(for: .milliseconds(400))
        #expect(feed.tunnelCalls == ["start db"], "two windows, one start")
        _ = second
    }

    /// A window opened after the first asked: its model, not yet told the helper is connected,
    /// must not empty the set every window shares.
    @Test func aWindowOpenedLaterAsksNothingAgain() async throws {
        let feed = FakeFeed()
        let (first, _, _, document, _) = try await model(tunnels: [TunnelDefinition(alias: "db", autoStart: .onLaunch)], feed: feed)
        say(feed, [])
        #expect(await eventually { feed.tunnelCalls == ["start db"] })
        let second = SidebarModel(host: FakeTerminalHost(), document: document, launcher: first.launcher, feed: feed,
                                  jiraSettings: { nil }, sshConfig: first.sshConfig)
        #expect(await eventually { second.sshHosts != nil })
        try await Task.sleep(for: .milliseconds(200))
        #expect(feed.tunnelCalls == ["start db"], "one start for the app")
    }

    /// The helper going away and coming back is a new connection: its on-launch tunnels are asked again.
    @Test func aReconnectedHelperIsAskedAgain() async throws {
        let feed = FakeFeed()
        let (model, _, _, _, _) = try await model(tunnels: [TunnelDefinition(alias: "db", autoStart: .onLaunch)], feed: feed)
        say(feed, [])
        #expect(await eventually { feed.tunnelCalls == ["start db"] })
        feed.status = .starting
        feed.status = .connected
        #expect(await eventually { feed.tunnelCalls == ["start db", "start db"] })
        _ = model
    }

    @Test func startingBeforeTheConfigIsReadReadsIt() async throws {
        let (model, _, feed, _, _) = try await model(tunnels: [TunnelDefinition(alias: "db")])
        model.sshHosts = nil
        model.startTunnel("db")
        #expect(await eventually { feed.tunnelCalls == ["start db"] })
        #expect(model.lastError == nil)
    }

    @Test func aProjectWithOnlyTunnelsFolds() async throws {
        let (model, _, _, _, _) = try await model(tunnels: [TunnelDefinition(alias: "db")])
        let node = try #require(model.tree.projects.first)
        #expect(ProjectHeaderRow.collapses(node))
    }

    @Test func thePortsTooltipIsForARunningTunnel() {
        var row = upRow(since: 0)
        #expect(TunnelRowView.portsHelp(row) != nil)
        row.state = .stopped
        #expect(TunnelRowView.portsHelp(row) == nil, "nothing holds the ports of a stopped tunnel")
    }

    @Test func answerInTabOnAHostWithNoForwardSaysSo() async throws {
        let config = "Host db\n  LocalForward 5432 db:5432\nHost plain\n  HostName p\n"
        let (model, _, feed, _, project) = try await model(tunnels: [TunnelDefinition(alias: "plain")], config: config)
        #expect(await eventually { model.sshHosts != nil })
        model.answerInTab("plain", in: project)
        #expect(model.lastError == "plain forwards no local port to watch.")
        #expect(feed.tunnelCalls.isEmpty)
    }

    @Test func collidingNamesAreLeftOutAndExtraPortsAreNumbered() async throws {
        let config = "Host db-prod\n  LocalForward 5432 a:5432\nHost db.prod\n  LocalForward 5433 b:5432\n"
            + "Host web\n  LocalForward 8080 w:80\n  LocalForward 8443 w:443\n"
        let (model, _, feed, _, project) = try await model(tunnels: [TunnelDefinition(alias: "db-prod"), TunnelDefinition(alias: "db.prod"),
                                                                     TunnelDefinition(alias: "web")], config: config)
        say(feed, ["db-prod", "db.prod", "web"].map { TunnelInfo(alias: $0, state: .up, error: nil, since: 1) })
        #expect(await eventually {
            model.portEnvironment(for: project) == ["SHELLFORGE_TUNNEL_WEB_PORT": "8080", "SHELLFORGE_TUNNEL_WEB_PORT_2": "8443"]
        }, "db-prod and db.prod name the same variable: neither is set")
    }
}
