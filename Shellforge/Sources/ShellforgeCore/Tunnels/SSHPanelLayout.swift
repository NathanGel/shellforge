import Foundation

/// One host row in the SSH panel.
public struct SSHPanelEntry: Equatable, Sendable, Identifiable {
    public var alias: String
    /// The project's SSH host (what New Task opens beside the agent).
    public var isProjectHost: Bool
    /// One of the project's tunnels.
    public var isTunnel: Bool
    /// Whether `~/.ssh/config` defines the alias; always true before the config has been read.
    public var inConfig: Bool
    public var id: String { alias }

    public init(alias: String, isProjectHost: Bool, isTunnel: Bool, inConfig: Bool) {
        self.alias = alias; self.isProjectHost = isProjectHost; self.isTunnel = isTunnel; self.inConfig = inConfig
    }
}

/// A project's hosts, or the config's hosts no project names.
public struct SSHPanelSection: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable { case project(UUID), other }
    public var kind: Kind
    public var title: String
    public var entries: [SSHPanelEntry]
    public var id: String {
        switch kind {
        case .project(let id): return "project:\(id.uuidString)"
        case .other: return "other"
        }
    }

    public init(kind: Kind, title: String, entries: [SSHPanelEntry]) {
        self.kind = kind; self.title = title; self.entries = entries
    }
}

public enum SSHPanelLayout {
    /// The panel's sections: each project with hosts, in order, then “Other hosts”. `hosts` nil
    /// means the config has not been read yet.
    public static func sections(projects: [Project], hosts: [SSHHost]?) -> [SSHPanelSection] {
        let known = hosts.map { Set($0.map(\.alias)) }
        var named = Set<String>()
        var sections: [SSHPanelSection] = []
        for project in projects {
            var entries: [SSHPanelEntry] = []
            func add(_ alias: String, host: Bool, tunnel: Bool) {
                named.insert(alias)
                if let i = entries.firstIndex(where: { $0.alias == alias }) {
                    entries[i].isProjectHost = entries[i].isProjectHost || host
                    entries[i].isTunnel = entries[i].isTunnel || tunnel
                } else {
                    entries.append(SSHPanelEntry(alias: alias, isProjectHost: host, isTunnel: tunnel,
                                                 inConfig: known?.contains(alias) ?? true))
                }
            }
            if let host = project.sshHost { add(host, host: true, tunnel: false) }
            for tunnel in project.tunnels { add(tunnel.alias, host: false, tunnel: true) }
            if !entries.isEmpty {
                sections.append(SSHPanelSection(kind: .project(project.id), title: project.name, entries: entries))
            }
        }
        if let hosts {
            let others = Set(hosts.map(\.alias)).subtracting(named)
                // Case-insensitively, then by the exact name, so `Staging` and `staging` keep one order.
                .sorted {
                    let order = $0.localizedCaseInsensitiveCompare($1)
                    return order == .orderedSame ? $0 < $1 : order == .orderedAscending
                }
            if !others.isEmpty {
                sections.append(SSHPanelSection(kind: .other, title: "Other hosts", entries: others.map {
                    SSHPanelEntry(alias: $0, isProjectHost: false, isTunnel: false, inConfig: true)
                }))
            }
        }
        return sections
    }
}
