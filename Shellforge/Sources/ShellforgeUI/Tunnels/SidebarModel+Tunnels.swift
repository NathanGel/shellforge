import Foundation
import ShellforgeCore

/// One of a project's tunnels as its sidebar row draws it: the alias, the config's forwards, what
/// the helper says of it, and whether the config still has the host.
public struct TunnelRowItem: Equatable, Identifiable, Sendable {
    public var projectId: UUID
    public var alias: String
    public var forwards: [LocalForward]
    public var state: TunnelState
    public var error: String?
    /// The alias is no longer a host in the config: the row says so and cannot start.
    public var missing: Bool
    /// When it came to its state, in seconds since 1970 (the daemon's wall clock).
    public var since: Double = 0
    public var bytesIn: Int? = nil
    public var bytesOut: Int? = nil
    public var heldBy: TunnelHolder? = nil
    public var needsInput: Bool? = nil
    public var keepRunning = false
    public var id: String { "\(projectId)-\(alias)" }

    /// The local ports, as the row shows them: `5432, 6379`.
    public var ports: String { forwards.map { String($0.localPort) }.joined(separator: ", ") }
}

/// The on-launch tunnels asked of the connected helper, once for the app however many windows'
/// sidebars watch it: shared per workspace document, as `RemovalBoard` is.
@MainActor
final class LaunchStarts {
    var requested: Set<String> = []
    private static let boards = NSMapTable<WorkspaceDocument, LaunchStarts>.weakToStrongObjects()

    static func shared(for document: WorkspaceDocument) -> LaunchStarts {
        if let board = boards.object(forKey: document) { return board }
        let board = LaunchStarts()
        boards.setObject(board, forKey: document)
        return board
    }
}

/// A project's tunnels: kept with the project, read against `~/.ssh/config`, started and stopped
/// through the helper, started by themselves by their rule, and their ports handed to a task's shell.
extension SidebarModel {
    /// Replaces the project's tunnels with `tunnels`, each alias once, in their order.
    public func setTunnels(_ tunnels: [TunnelDefinition], on projectId: UUID) {
        var seen = Set<String>()
        let once = tunnels.filter { seen.insert($0.alias).inserted }
        guard let current = project(projectId), current.tunnels != once else { return }
        do {
            try document.update { workspace in
                if let i = workspace.projects.firstIndex(where: { $0.id == projectId }) { workspace.projects[i].tunnels = once }
            }
            lastError = nil
        } catch {
            lastError = String(describing: error)
            return
        }
        // A running tunnel whose keep-running changed: the helper learns it now, not at its next start.
        let running: Set<TunnelState> = [.connecting, .up]
        for tunnel in once where running.contains(tunnelState(tunnel.alias)) {
            if let before = current.tunnels.first(where: { $0.alias == tunnel.alias }), before.keepRunning != tunnel.keepRunning {
                launchRequested.insert(tunnel.alias)
                feed?.startTunnel(alias: tunnel.alias, keepRunning: keepsRunning(tunnel.alias))
            }
        }
        // A running tunnel taken off its last project would keep its port with no row to stop it.
        let kept = Set(document.workspace.projects.flatMap(\.tunnels).map(\.alias))
        for tunnel in current.tunnels where !kept.contains(tunnel.alias) && [.connecting, .up].contains(tunnelState(tunnel.alias)) {
            feed?.stopTunnel(alias: tunnel.alias)
        }
    }

    /// Settings › Core's environment card, over this sidebar's launcher and agents.
    public func environmentModel() -> EnvironmentModel {
        let model = EnvironmentModel(launcher: launcher, agents: agents)
        model.onReloaded = { [weak self] in self?.onEnvironmentReloaded?() }
        return model
    }

    /// Names the project's SSH host, or none.
    /// The project menu's item: it names the host once one is set, so the setting is seen.
    public nonisolated static func sshHostMenuTitle(_ alias: String?) -> String { alias.map { "SSH Host: \($0)…" } ?? "SSH Host…" }
    public nonisolated static func openSSHHostTitle(_ alias: String) -> String { "Open ssh \(alias)" }

    /// Whether the project's SSH host can be opened: set, and still a host of `~/.ssh/config` as
    /// last read. The menu offers Open only then.
    public func canOpenSSHHost(of projectId: UUID) -> Bool {
        guard let alias = project(projectId)?.sshHost else { return false }
        return sshHosts?[alias] != nil
    }

    /// The project's SSH host in a tab of its own, in the project's folder: the same ssh New Task
    /// opens beside its agent, without a task. The config is read first when it has not been; a
    /// host since gone from it is said, not run.
    public func openSSHHost(of projectId: UUID) async {
        guard let project = project(projectId), let alias = project.sshHost else { return }
        if sshHosts == nil { _ = await loadSSHHosts() }
        guard sshHosts?[alias] != nil else {
            lastError = "\(alias) isn’t in ~/.ssh/config."
            return
        }
        host.openTab(in: project.path, title: alias, command: SSHConfig.paneCommand(alias: alias))
    }

    public func setSSHHost(_ alias: String?, on projectId: UUID) {
        guard let current = project(projectId), current.sshHost != alias else { return }
        do {
            try document.update { workspace in
                if let i = workspace.projects.firstIndex(where: { $0.id == projectId }) { workspace.projects[i].sshHost = alias }
            }
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    /// The project's SSH host while the config has it: what New Task offers beside the agent.
    func paneHost(of project: Project) -> String? {
        guard let alias = project.sshHost, sshHosts?[alias] != nil else { return nil }
        return alias
    }

    /// The project's tunnels as rows, in its order.
    public func tunnelRows(of project: Project) -> [TunnelRowItem] {
        project.tunnels.map { tunnel in
            let info = sessions.tunnels[tunnel.alias]
            let host = sshHosts?[tunnel.alias]
            return TunnelRowItem(projectId: project.id, alias: tunnel.alias, forwards: host?.forwards ?? [],
                                 state: info?.state ?? .stopped, error: info?.error,
                                 missing: sshHosts != nil && host == nil, since: info?.since ?? 0,
                                 bytesIn: info?.bytesIn, bytesOut: info?.bytesOut, heldBy: info?.heldBy,
                                 needsInput: info?.needsInput, keepRunning: tunnel.keepRunning)
        }
    }

    public func tunnelRows(of projectId: UUID) -> [TunnelRowItem] { project(projectId).map(tunnelRows(of:)) ?? [] }

    public func tunnelState(_ alias: String) -> TunnelState { sessions.tunnels[alias]?.state ?? .stopped }

    /// Starts `alias`'s tunnel through the helper; refused, and said, when the config has no such host.
    public func startTunnel(_ alias: String) {
        // Asked before the config was read: read it, then answer — not "isn't in ~/.ssh/config".
        guard sshHosts != nil else {
            Task {
                _ = await loadSSHHosts()
                startTunnel(alias)
            }
            return
        }
        guard sshHosts?[alias] != nil else {
            lastError = "\(alias) isn’t in ~/.ssh/config."
            return
        }
        feed?.startTunnel(alias: alias, keepRunning: keepsRunning(alias))
    }

    /// Whether any project keeps `alias` running past a quit.
    func keepsRunning(_ alias: String) -> Bool {
        document.workspace.projects.contains { $0.tunnels.contains { $0.alias == alias && $0.keepRunning } }
    }

    public func stopTunnel(_ alias: String) { feed?.stopTunnel(alias: alias) }

    /// ssh needed an answer the supervisor cannot give: the tunnel runs in a tab of its own in the
    /// project's folder, where the user answers, and the helper watches its first port until that
    /// tab's ssh ends.
    public func answerInTab(_ alias: String, in projectId: UUID) {
        guard let project = project(projectId) else { return }
        guard let sshHost = sshHosts?[alias] else {
            lastError = "\(alias) isn’t in ~/.ssh/config."
            return
        }
        guard let forward = sshHost.forwards.first else {
            lastError = "\(alias) forwards no local port to watch."
            return
        }
        host.openTab(in: project.path, title: "ssh \(alias)", command: TunnelDefinition.tabCommand(alias: alias))
        feed?.holdTunnel(alias: alias, port: forward.localPort, bind: forward.bind)
    }

    /// What a task's shell gets: the first local port of each tunnel that is up, connecting, or in
    /// `starting`, as `SHELLFORGE_TUNNEL_<NAME>_PORT`. The port is the config's, known before ssh
    /// has bound it, so a tab opened as its tunnel starts gets it too.
    public func portEnvironment(for projectId: UUID, starting: Set<String> = []) -> [String: String] {
        guard let project = project(projectId) else { return [:] }
        // Two aliases that name one variable (db-prod, db.prod): neither is set, rather than one
        // silently winning.
        var counts: [String: Int] = [:]
        for tunnel in project.tunnels { counts[TunnelDefinition.environmentName(alias: tunnel.alias), default: 0] += 1 }
        var environment: [String: String] = [:]
        for tunnel in project.tunnels where starting.contains(tunnel.alias) || [.connecting, .up].contains(tunnelState(tunnel.alias)) {
            let name = TunnelDefinition.environmentName(alias: tunnel.alias)
            guard counts[name] == 1 else { continue }
            // The first forward is the variable's own; each further one is numbered from 2.
            for (index, forward) in (sshHosts?[tunnel.alias]?.forwards ?? []).enumerated() {
                environment[index == 0 ? name : "\(name)_\(index + 1)"] = String(forward.localPort)
            }
        }
        return environment
    }

    /// Reads the config again, off the main actor, for the Tunnels sheet; kept for the rows.
    public func loadSSHHosts() async -> [SSHHost] {
        let source = sshConfig
        let hosts = await BackgroundWork.run { source.read() }
        take(hosts)
        return hosts
    }

    /// Reads the config off the main actor when a project has tunnels, one read at a time. Every
    /// refresh reads it whole — the files it includes as well as itself — since a port changed in
    /// an included file is a port a new tab would otherwise get wrong; the rows redraw only when
    /// the hosts changed.
    func refreshSSHHosts(_ projects: [Project]) {
        guard !readingSSH, projects.contains(where: { !$0.tunnels.isEmpty || $0.sshHost != nil }) else { return }
        readingSSH = true
        let source = sshConfig
        Task {
            let hosts = await BackgroundWork.run { source.read() }
            readingSSH = false
            take(hosts)
        }
    }

    private func take(_ hosts: [SSHHost]) {
        let byAlias = Dictionary(hosts.map { ($0.alias, $0) }, uniquingKeysWith: { first, _ in first })
        if byAlias != sshHosts { sshHosts = byAlias }
        autoStartOnLaunch()
    }

    /// Starts every `.onLaunch` tunnel the connected helper has no record of — a new helper, at
    /// launch or after one restarted — once per connection. One the helper knows, even stopped, was
    /// started already: the user stopped it, or it failed, and it is left as it is.
    func autoStartOnLaunch() {
        guard helper == .connected else { return }
        guard sessions.bootstrapped, let sshHosts else { return }
        // A keep-running tunnel this helper runs may be one it adopted from the last, with no
        // environment to restart it with after a drop: each connection hands it the app's, once.
        for project in document.workspace.projects {
            for tunnel in project.tunnels where tunnel.keepRunning && !launchRequested.contains(tunnel.alias)
                && [.connecting, .up].contains(sessions.tunnels[tunnel.alias]?.state) && sessions.tunnels[tunnel.alias]?.heldBy == nil {
                launchRequested.insert(tunnel.alias)
                feed?.startTunnel(alias: tunnel.alias, keepRunning: true)
            }
        }
        for project in document.workspace.projects {
            for tunnel in project.tunnels where tunnel.autoStart == .onLaunch
                && sessions.tunnels[tunnel.alias] == nil && sshHosts[tunnel.alias] != nil
                && !launchRequested.contains(tunnel.alias) {
                launchRequested.insert(tunnel.alias)
                feed?.startTunnel(alias: tunnel.alias, keepRunning: keepsRunning(tunnel.alias))
            }
        }
    }

    /// A task's tab is opening: starts the project's `.onTaskOpen` tunnels and gives the
    /// environment the tab opens with.
    func openingTaskTab(in projectId: UUID) -> [String: String] {
        portEnvironment(for: projectId, starting: startTunnelsOnTaskOpen(in: projectId))
    }

    /// Starts the project's `.onTaskOpen` tunnels that are not running, and says which it started.
    /// Before the config has been read it is read first, and the tab opening now goes without them.
    func startTunnelsOnTaskOpen(in projectId: UUID) -> Set<String> {
        guard let project = project(projectId), project.tunnels.contains(where: { $0.autoStart == .onTaskOpen }) else { return [] }
        if sshHosts != nil { return startNow(project) }
        Task {
            _ = await loadSSHHosts()
            _ = startNow(project)
        }
        return []
    }

    private func startNow(_ project: Project) -> Set<String> {
        var started = Set<String>()
        for tunnel in project.tunnels where tunnel.autoStart == .onTaskOpen {
            guard sshHosts?[tunnel.alias] != nil, ![.connecting, .up].contains(tunnelState(tunnel.alias)) else { continue }
            feed?.startTunnel(alias: tunnel.alias, keepRunning: keepsRunning(tunnel.alias))
            started.insert(tunnel.alias)
        }
        return started
    }
}
