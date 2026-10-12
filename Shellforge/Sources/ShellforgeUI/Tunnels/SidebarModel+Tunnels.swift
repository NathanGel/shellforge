import Foundation
import ShellforgeCore

/// One of a project's tunnels as its sidebar row draws it: the alias, the config's forwards, what
/// the helper says of it, and whether the config still has the host.
public struct TunnelRowItem: Equatable, Identifiable, Sendable {
    public let projectId: UUID
    public let alias: String
    public let forwards: [LocalForward]
    public let state: TunnelState
    public let error: String?
    /// The alias is no longer a host in the config: the row says so and cannot start.
    public let missing: Bool
    public var id: String { "\(projectId)-\(alias)" }

    /// The local ports, as the row shows them: `5432, 6379`.
    public var ports: String { forwards.map { String($0.localPort) }.joined(separator: ", ") }
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
        // A running tunnel taken off its last project would keep its port with no row to stop it.
        let kept = Set(document.workspace.projects.flatMap(\.tunnels).map(\.alias))
        for tunnel in current.tunnels where !kept.contains(tunnel.alias) && [.connecting, .up].contains(tunnelState(tunnel.alias)) {
            feed?.stopTunnel(alias: tunnel.alias)
        }
    }

    /// The project's tunnels as rows, in its order.
    public func tunnelRows(of project: Project) -> [TunnelRowItem] {
        project.tunnels.map { tunnel in
            let info = sessions.tunnels[tunnel.alias]
            let host = sshHosts?[tunnel.alias]
            return TunnelRowItem(projectId: project.id, alias: tunnel.alias, forwards: host?.forwards ?? [],
                                 state: info?.state ?? .stopped, error: info?.error,
                                 missing: sshHosts != nil && host == nil)
        }
    }

    public func tunnelRows(of projectId: UUID) -> [TunnelRowItem] { project(projectId).map(tunnelRows(of:)) ?? [] }

    public func tunnelState(_ alias: String) -> TunnelState { sessions.tunnels[alias]?.state ?? .stopped }

    /// Starts `alias`'s tunnel through the helper; refused, and said, when the config has no such host.
    public func startTunnel(_ alias: String) {
        guard sshHosts?[alias] != nil else {
            lastError = "\(alias) isn’t in ~/.ssh/config."
            return
        }
        feed?.startTunnel(alias: alias)
    }

    public func stopTunnel(_ alias: String) { feed?.stopTunnel(alias: alias) }

    /// What a task's shell gets: the first local port of each tunnel that is up, connecting, or in
    /// `starting`, as `SHELLFORGE_TUNNEL_<NAME>_PORT`. The port is the config's, known before ssh
    /// has bound it, so a tab opened as its tunnel starts gets it too.
    public func portEnvironment(for projectId: UUID, starting: Set<String> = []) -> [String: String] {
        guard let project = project(projectId) else { return [:] }
        var environment: [String: String] = [:]
        for tunnel in project.tunnels where starting.contains(tunnel.alias) || [.connecting, .up].contains(tunnelState(tunnel.alias)) {
            if let port = sshHosts?[tunnel.alias]?.forwards.first?.localPort {
                environment[TunnelDefinition.environmentName(alias: tunnel.alias)] = String(port)
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
        guard !readingSSH, projects.contains(where: { !$0.tunnels.isEmpty }) else { return }
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
        guard helper == .connected else {
            launchRequested = []
            return
        }
        guard sessions.bootstrapped, let sshHosts else { return }
        for project in document.workspace.projects {
            for tunnel in project.tunnels where tunnel.autoStart == .onLaunch
                && sessions.tunnels[tunnel.alias] == nil && sshHosts[tunnel.alias] != nil
                && !launchRequested.contains(tunnel.alias) {
                launchRequested.insert(tunnel.alias)
                feed?.startTunnel(alias: tunnel.alias)
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
            feed?.startTunnel(alias: tunnel.alias)
            started.insert(tunnel.alias)
        }
        return started
    }
}
