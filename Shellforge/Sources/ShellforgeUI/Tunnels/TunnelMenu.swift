import Combine
import Foundation
import ShellforgeCore

/// One item of View › Tunnels: what choosing it does to which tunnel.
public struct TunnelMenuItem: Equatable, Sendable {
    public let alias: String
    public let title: String
    /// Choosing it starts the tunnel; otherwise it stops it.
    public let starts: Bool
}

/// The View › Tunnels menu, which is how tunnels reach the command palette: iTerm2's Open Quickly
/// searches the main menu, so each item is found there by its title.
public enum TunnelMenu {
    public static let emptyTitle = "No Tunnels — add one from a project’s Tunnels…"

    /// Each linked alias once, in project then tunnel order: Stop while connecting or up, Start
    /// otherwise.
    public static func items(projects: [Project], store: SessionStore) -> [TunnelMenuItem] {
        var seen = Set<String>()
        return projects.flatMap(\.tunnels).compactMap { tunnel in
            guard seen.insert(tunnel.alias).inserted else { return nil }
            let running = [.connecting, .up].contains(store.tunnels[tunnel.alias]?.state)
            return TunnelMenuItem(alias: tunnel.alias, title: "\(running ? "Stop" : "Start") Tunnel \(tunnel.alias)", starts: !running)
        }
    }

    /// The items as the workspace's projects and the helper's tunnels change, sent only when they
    /// differ: the helper sends a new store for every event, token tallies included.
    public static func items(projects: AnyPublisher<[Project], Never>, stores: AnyPublisher<SessionStore, Never>)
        -> AnyPublisher<[TunnelMenuItem], Never> {
        projects.combineLatest(stores).map { items(projects: $0, store: $1) }.removeDuplicates().eraseToAnyPublisher()
    }

    /// An item acts through a window's sidebar; with every window closed there is none.
    public static func isEnabled(haveSidebar: Bool) -> Bool { haveSidebar }
}
