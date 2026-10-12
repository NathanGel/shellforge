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

    /// A task's tab gets the tunnels' ports as exported variables before its command, sorted, each
    /// value one shell word; with no command, the exports alone; with neither, nothing typed.
    @Test func theTabExportsThePortsBeforeItsCommand() {
        #expect(TabCommand.exporting(["SHELLFORGE_TUNNEL_WEB_PORT": "8080", "SHELLFORGE_TUNNEL_DB_PORT": "5432"], then: "claude 'go'")
                == "export SHELLFORGE_TUNNEL_DB_PORT='5432' SHELLFORGE_TUNNEL_WEB_PORT='8080'; claude 'go'")
        #expect(TabCommand.exporting(["SHELLFORGE_TUNNEL_DB_PORT": "5432"], then: nil) == "export SHELLFORGE_TUNNEL_DB_PORT='5432'")
        #expect(TabCommand.exporting([:], then: "claude") == "claude")
        #expect(TabCommand.exporting([:], then: nil) == nil)
        #expect(TabCommand.exporting(["X": "it's"], then: nil) == #"export X='it'\''s'"#)
    }

    /// A project saved before keep-running decodes with it off; one with it on keeps it.
    @Test func keepRunningIsOffForAnOldProjectAndKeptOtherwise() throws {
        let old = #"{"alias":"db","autoStart":"never"}"#.data(using: .utf8)!
        #expect(try JSONDecoder().decode(TunnelDefinition.self, from: old).keepRunning == false)
        let kept = TunnelDefinition(alias: "db", autoStart: .onLaunch, keepRunning: true)
        #expect(try JSONDecoder().decode(TunnelDefinition.self, from: JSONEncoder().encode(kept)) == kept)
    }
}
