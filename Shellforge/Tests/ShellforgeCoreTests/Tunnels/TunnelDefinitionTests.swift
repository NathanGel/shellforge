import Foundation
import Testing
@testable import ShellforgeCore

/// A project's tunnels, as the workspace keeps them, and the variable a task's shell reads a
/// tunnel's port from.
@Suite struct TunnelDefinitionTests {
    @Test func theEnvironmentNameIsTheAliasUpperCased() {
        #expect(TunnelDefinition.environmentName(alias: "db-staging.eu") == "SHELLFORGE_TUNNEL_DB_STAGING_EU_PORT")
        #expect(TunnelDefinition.environmentName(alias: "cache") == "SHELLFORGE_TUNNEL_CACHE_PORT")
    }

    @Test func aProjectFromBeforeTunnelsHasNone() throws {
        let json = #"{"id":"1EB4C0DE-0000-0000-0000-000000000001","name":"Repo","path":"/repo","addedAt":1,"collapsed":false}"#
        #expect(try JSONDecoder().decode(Project.self, from: Data(json.utf8)).tunnels.isEmpty)
    }

    @Test func tunnelsRoundTripInTheirProject() throws {
        var project = Project(name: "Repo", path: "/repo")
        project.tunnels = [TunnelDefinition(alias: "db-staging", autoStart: .onTaskOpen), TunnelDefinition(alias: "cache", autoStart: .never)]
        #expect(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project)) == project)
    }
}
