import Foundation
import Testing
@testable import ShellforgeCore

@Suite struct ProviderDetectorTests {
    /// Shellforge's cases, beside AiTerm's own: a self-hosted GitLab, a host that only contains
    /// "gitlab", and a remote of no known host.
    @Test(arguments: [("git@github.com:NathanGel/shellforge.git", Provider.github), ("https://github.com/a/b.git", .github),
                      ("git@gitlab.com:g/p.git", .gitlab), ("https://git.company.com/group/sub/repo.git", .gitlab),
                      ("git@notgitlab.example.com:a/b.git", .git), ("ssh://git@bitbucket.org/a/b.git", .git)])
    func aRemoteNamesItsHost(url: String, provider: Provider) {
        #expect(ProviderDetector.detect(remoteUrl: url).provider == provider)
    }

    /// A workspace saved before projects could collapse loads them expanded.
    @Test func aProjectSavedWithoutCollapsedLoadsExpanded() throws {
        let json = #"{"id":"6F0E2C1A-9B3D-4E5F-8A7B-0C1D2E3F4A5B","name":"r","path":"/r","addedAt":0}"#
        #expect(try JSONDecoder().decode(Project.self, from: Data(json.utf8)).collapsed == false)
    }
}
