import Foundation
import Testing
@testable import ShellforgeCore

@Suite struct ProviderDetectorTests {
    @Test(arguments: [("git@github.com:NathanGel/shellforge.git", Provider.github), ("https://github.com/a/b.git", .github),
                      ("git@gitlab.com:g/p.git", .gitlab), ("https://gitlab.example.com/g/p.git", .gitlab),
                      ("ssh://git@bitbucket.org/a/b.git", .git), ("", .git)])
    func aRemoteNamesItsHost(url: String, provider: Provider) {
        #expect(ProviderDetector.provider(ofRemote: url) == provider)
    }

    /// A workspace saved before projects could collapse loads them expanded.
    @Test func aProjectSavedWithoutCollapsedLoadsExpanded() throws {
        let json = #"{"id":"6F0E2C1A-9B3D-4E5F-8A7B-0C1D2E3F4A5B","name":"r","path":"/r","addedAt":0}"#
        #expect(try JSONDecoder().decode(Project.self, from: Data(json.utf8)).collapsed == false)
    }
}
