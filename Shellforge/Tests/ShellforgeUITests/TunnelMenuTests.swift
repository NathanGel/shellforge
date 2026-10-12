import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI

/// The View › Tunnels menu, which Open Quickly searches: one item per linked alias, saying what
/// choosing it does.
@Suite struct TunnelMenuTests {
    private func project(_ name: String, _ aliases: [String]) -> Project {
        var project = Project(name: name, path: "/\(name)")
        project.tunnels = aliases.map { TunnelDefinition(alias: $0) }
        return project
    }

    private func store(_ tunnels: [TunnelInfo]) -> SessionStore {
        var snapshot = DaemonSnapshot(protocolVersion: 1, connected: true, sessions: [], usage: .empty)
        snapshot.tunnels = tunnels
        var store = SessionStore()
        store.apply(.snapshot(snapshot))
        return store
    }

    @Test func eachLinkedAliasIsOneItemByItsState() {
        let items = TunnelMenu.items(projects: [project("api", ["db", "cache", "web"])],
                                     store: store([TunnelInfo(alias: "db", state: .up, error: nil, since: 1),
                                                   TunnelInfo(alias: "cache", state: .connecting, error: nil, since: 1),
                                                   TunnelInfo(alias: "web", state: .failed, error: "x", since: 1)]))
        #expect(items == [TunnelMenuItem(alias: "db", title: "Stop Tunnel db", starts: false),
                          TunnelMenuItem(alias: "cache", title: "Stop Tunnel cache", starts: false),
                          TunnelMenuItem(alias: "web", title: "Start Tunnel web", starts: true)])
    }

    @Test func anAliasInTwoProjectsIsOneItem() {
        let items = TunnelMenu.items(projects: [project("api", ["db"]), project("web", ["db", "cdn"])], store: store([]))
        #expect(items.map(\.title) == ["Start Tunnel db", "Start Tunnel cdn"])
    }

    @Test func itemsNeedASidebarToAct() {
        #expect(TunnelMenu.isEnabled(haveSidebar: true))
        #expect(!TunnelMenu.isEnabled(haveSidebar: false))
    }

    @Test func noTunnelsSaySo() {
        #expect(TunnelMenu.items(projects: [project("api", [])], store: store([])).isEmpty)
        #expect(TunnelMenu.emptyTitle == "No Tunnels — add one from a project’s Tunnels…")
    }
}
